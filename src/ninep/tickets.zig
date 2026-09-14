//! tickets.zig — the ASYNCHRONOUS half of the 9P client (R-9P-13, S-01 §3.2).
//!
//! `client.zig` is synchronous: `rpc` sends one T-message and spins on the
//! transport until its R-message arrives. That is correct for a pumped
//! in-process server and IMPOSSIBLE for anything the browser main thread cannot
//! drive (`/n/origin` has no pump — its frames arrive on a later tick through
//! `wsPush`), and forbidden for any file that may PARK server-side (mouse, kbd).
//! A *ticket* is the answer: send now, register a slot keyed by tag, and poll
//! the slot later. Phase 6 had exactly one ticket type (Tread, R-P6-4); this
//! file generalises it to EVERY T-message the editor issues, which is what
//! `nsjob.zig` builds its namespace jobs out of.
//!
//! Two invariants make the scheme safe (rulings R-P13a-1/-3):
//!
//!   * **`check` never pumps and never blocks.** It drains whatever frames the
//!     transport can hand over right now (a `WouldBlock` ends the drain) and
//!     reports the slot. `begin` may pump, but only for the SEND — exactly what
//!     `beginRead` has always done through `Client.sendFrame`.
//!   * **A live tag is always in `Client.pending`.** `Client.rpc` routes any
//!     reply whose tag is not its own through `dispatch`, so an out-of-order
//!     reply for a standing ticket is absorbed rather than being a protocol
//!     error; only a tag matching neither is a real violation.
//!
//! TWO SLOT MODES (deviation from the phase-13a contract §3a sketch, forced by
//! ruling R-P13a-1 "zero change to the existing behaviour"). The sketch has
//! `dispatch` copy the WHOLE reply frame into the caller's buffer for every
//! ticket. That cannot carry the phase-6 read tickets: `beginRead` asks for
//! `min(buf.len, msize-IOHDRSZ)` bytes, so an Rread frame for a full buffer is
//! `buf.len + 11` bytes and does not fit — the 49-byte `/dev/mouse` buffer in
//! `main_wasm` would fail every read with ProtocolError. So a slot records
//! which shape it wants:
//!   * `.frame` — the raw reply frame, any R-type (generic tickets; `check`
//!     decodes it in place, so the returned `Message` aliases the caller's buf);
//!   * `.payload` — the Rread DATA only, copied to `buf[0..n]` (read tickets;
//!     byte-identical to phases 6-12).
//!
//! Imports: std + sibling ninep files (S-07 §6). Nothing here touches `core`,
//! `dev` or `shim`.
const std = @import("std");
const msg = @import("msg.zig");
const transport = @import("transport.zig");
const errors = @import("errors.zig");

const Client = @import("client.zig").Client;
const Message = msg.Message;

/// The client error set, defined HERE rather than in `client.zig` so that
/// `Client`'s own field layout (it holds a map of `Pending`) does not depend on
/// `Client`'s namespace. `Client.Error` is an alias of this set — same members,
/// same name, unchanged public surface.
pub const Error = errors.OpError || transport.Error || error{
    OutOfMemory,
    /// The reply violated the protocol: wrong tag, undecodable, or an
    /// unexpected message type for the request.
    ProtocolError,
    /// A frame would exceed the negotiated msize (on encode or on read).
    MessageTooBig,
};

/// An outstanding asynchronous request. Opaque: the caller holds only the tag
/// and hands the ticket back to `check`/`cancel`. A ticket is live from `begin`
/// until it is consumed (a non-null `check`, or `cancel`).
pub const Ticket = struct { tag: u16 };

/// The client-side slot for one `Ticket`. `buf` is the caller-owned destination
/// the reply is copied into; the client only borrows it and it must outlive the
/// ticket. `state` advances waiting → done/failed exactly once, when the
/// matching reply is dispatched (during any `rpc`/pump/`check`).
pub const Pending = struct {
    buf: []u8,
    mode: Mode,
    state: union(enum) {
        waiting,
        /// The reply arrived; `buf[0..n]` holds it (a whole frame in `.frame`
        /// mode, the Rread payload in `.payload` mode).
        done: usize,
        /// Rerror arrived (a flushed ticket lands here as error.Interrupted), or
        /// the reply was malformed/oversized (error.ProtocolError).
        failed: Error,
    },

    /// What the slot wants copied out of the reply — see the header note.
    pub const Mode = enum { frame, payload };
};

/// Bytes an Rread frame costs on top of its payload: `size[4] type[1] tag[2]`
/// plus `count[4]` (fcall.h:65-74). A `.frame` ticket reading N bytes therefore
/// needs an N+11 byte buffer.
pub const rread_overhead: usize = msg.header_size + 4;

// --- generic tickets ------------------------------------------------------

/// Send `t` WITHOUT waiting for the reply, returning a ticket. `t.tag` is
/// IGNORED — a fresh tag is allocated and stamped on the frame, which is what
/// keeps "a live tag is always in `pending`" true. `buf` is borrowed, not
/// owned: it must outlive the ticket and it receives the RAW reply frame
/// (any R-type), so size it for the reply you expect — Rwalk ≤ 7+2+16·13 B,
/// Ropen/Rclunk/Rflush tiny, Rstat/Rread up to the negotiated msize.
pub fn begin(c: *Client, t: Message, buf: []u8) Error!Ticket {
    const tag = c.allocTag();
    // Register the slot BEFORE sending: a reply cannot arrive before the send,
    // but registering first keeps the invariant and lets the errdefer undo
    // cleanly if the send fails.
    try c.pending.put(c.allocator, tag, .{ .buf = buf, .mode = .frame, .state = .waiting });
    errdefer _ = c.pending.remove(tag);
    var m = t;
    m.tag = tag;
    try c.sendFrame(m);
    return .{ .tag = tag };
}

/// Non-blocking poll of a ticket (R-P13a-3: never pumps, never blocks). First
/// drains every frame the transport can hand over right now, dispatching each
/// by tag; then reports the slot. `null` ⇒ still pending. A non-null return
/// CONSUMES the ticket: the decoded reply (aliasing the caller's `buf`), or the
/// reply's error — a ticket the server flushed surfaces error.Interrupted here.
/// An unknown ticket is a ProtocolError.
pub fn check(c: *Client, t: Ticket) Error!?Message {
    try drainReady(c);
    const entry = c.pending.getPtr(t.tag) orelse return error.ProtocolError;
    switch (entry.state) {
        .waiting => return null,
        .done => |n| {
            const bytes = entry.buf[0..n];
            _ = c.pending.remove(t.tag);
            return msg.decode(bytes) catch error.ProtocolError;
        },
        .failed => |e| {
            _ = c.pending.remove(t.tag);
            return e;
        },
    }
}

/// Abandon a ticket. Sends `Tflush(oldtag = t.tag)` synchronously via `rpc`
/// (flushes themselves never park, so this cannot wedge). The server answers the
/// old tag FIRST — Rerror "interrupted" if the request was still parked, which
/// `rpc` dispatches into the slot — then Rflush on the flush's own tag; OR, if
/// the reply raced ahead, it is dispatched into the slot and then Rflush
/// arrives. Either ordering is handled: the ticket is always CONSUMED here and
/// any dispatched result is discarded. [flush(5); srv.c deferred-Rflush]
pub fn cancel(c: *Client, t: Ticket) Error!void {
    defer _ = c.pending.remove(t.tag);
    const reply = try c.rpc(.{ .tag = c.allocTag(), .body = .{ .tflush = .{ .oldtag = t.tag } } });
    switch (reply.body) {
        .rflush => return,
        else => return error.ProtocolError,
    }
}

// --- read tickets (the phase-6 API, R-P6-4) -------------------------------

/// `Client.beginRead`'s body: `Tread(fid, offset, min(buf.len, msize-IOHDRSZ))`
/// without waiting, on a `.payload` slot so the Rread DATA lands at `buf[0..n]`
/// exactly as it has since phase 6.
pub fn beginRead(c: *Client, fid: u32, offset: u64, buf: []u8) Error!Ticket {
    const tag = c.allocTag();
    const count: u32 = @intCast(@min(buf.len, c.ioMax()));
    try c.pending.put(c.allocator, tag, .{ .buf = buf, .mode = .payload, .state = .waiting });
    errdefer _ = c.pending.remove(tag);
    try c.sendFrame(.{ .tag = tag, .body = .{
        .tread = .{ .fid = fid, .offset = offset, .count = count },
    } });
    return .{ .tag = tag };
}

/// `Client.checkRead`'s body: like `check`, but reports the Rread byte count
/// already sitting at the front of the caller's buffer.
pub fn checkRead(c: *Client, t: Ticket) Error!?usize {
    try drainReady(c);
    const entry = c.pending.getPtr(t.tag) orelse return error.ProtocolError;
    switch (entry.state) {
        .waiting => return null,
        .done => |n| {
            _ = c.pending.remove(t.tag);
            return n;
        },
        .failed => |e| {
            _ = c.pending.remove(t.tag);
            return e;
        },
    }
}

// --- routing --------------------------------------------------------------

/// Route a reply whose tag is not the one an in-flight `rpc` awaits. If it
/// matches an outstanding ticket, transition that ticket's slot — copying out of
/// the client's `rbuf` IMMEDIATELY, before the caller loops and reads over it. A
/// tag matching no pending ticket is a genuine ProtocolError. A slot already
/// resolved is left as-is (the first reply for a tag wins; a duplicate is
/// ignored, not an error).
///
/// `frame` is the raw bytes `reply` was decoded from; `.frame` slots take those
/// verbatim, `.payload` slots take only the Rread data.
pub fn dispatch(c: *Client, frame: []const u8, reply: Message) Error!void {
    const entry = c.pending.getPtr(reply.tag) orelse return error.ProtocolError;
    if (entry.state != .waiting) return; // already resolved; ignore duplicate.
    // A flushed ticket lands here as Rerror "interrupted" ⇒ error.Interrupted.
    if (reply.body == .rerror) {
        entry.state = .{ .failed = c.mapRerror(reply.body.rerror.ename) };
        return;
    }
    switch (entry.mode) {
        .frame => {
            if (frame.len > entry.buf.len) {
                entry.state = .{ .failed = error.ProtocolError };
            } else {
                @memcpy(entry.buf[0..frame.len], frame);
                entry.state = .{ .done = frame.len };
            }
        },
        .payload => switch (reply.body) {
            .rread => |r| {
                if (r.data.len > entry.buf.len) {
                    entry.state = .{ .failed = error.ProtocolError };
                } else {
                    @memcpy(entry.buf[0..r.data.len], r.data);
                    entry.state = .{ .done = r.data.len };
                }
            },
            // Any other reply type for a read tag is a protocol violation.
            else => entry.state = .{ .failed = error.ProtocolError },
        },
    }
}

/// Drain every frame available WITHOUT blocking or pumping, dispatching each to
/// its pending ticket. A transport `WouldBlock` means "nothing ready" and ends
/// the drain (this is the non-blocking twin of `Client.readFrame`, which pumps).
/// A frame for an unknown tag is a ProtocolError; an oversized frame is
/// MessageTooBig.
pub fn drainReady(c: *Client) Error!void {
    while (true) {
        const frame = c.tport.readMsg(c.rbuf) catch |e| switch (e) {
            error.WouldBlock => return,
            error.FrameTooBig => return error.MessageTooBig,
            else => return e, // Closed, BadFrame
        };
        const reply = msg.decode(frame) catch return error.ProtocolError;
        try dispatch(c, frame, reply);
    }
}

// ==========================================================================
// Smoke tests (§T-tickets). The named battery T1-T3 is the test writer's; this
// only pins that the new decls are reachable and that a generic ticket round
// trips over the same fixture `nsdir` uses.
// ==========================================================================
const testing = std.testing;
const nsdir = @import("nsdir.zig");

test "tickets: a generic Twalk ticket round-trips over a pumped fake server" {
    const a = testing.allocator;
    var tree = nsdir.FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var s = try nsdir.FakeServer.init(a, &tree);
    defer s.deinit();

    var buf: [512]u8 = undefined;
    const newfid = s.client.allocFid();
    const t = try begin(s.client, .{ .tag = 0, .body = .{
        .twalk = msg.Body.Twalk.init(s.root_fid, newfid, &.{"rc"}),
    } }, &buf);

    // Nothing has driven the server yet, so the reply cannot be there and
    // `check` must NOT pump for it.
    try testing.expectEqual(@as(?Message, null), try check(s.client, t));

    _ = try s.srv.poll();
    const reply = (try check(s.client, t)).?;
    try testing.expectEqual(msg.Kind.rwalk, reply.body.kind());
    try testing.expectEqual(@as(u16, 1), reply.body.rwalk.nwqid);
    try testing.expect(reply.body.rwalk.qids()[0].qtype.dir);

    // The ticket was consumed by that non-null check.
    try testing.expectError(error.ProtocolError, check(s.client, t));
    try s.client.clunk(newfid);
}
