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
//! Three invariants make the scheme safe (rulings R-P13a-1/-3):
//!
//!   * **`check` never pumps and never blocks.** It drains whatever frames the
//!     transport can hand over right now (a `WouldBlock` ends the drain) and
//!     reports the slot. `begin` may pump, but only for the SEND — exactly what
//!     `beginRead` has always done through `Client.sendFrame`.
//!   * **A live tag is always in `Client.pending`.** `Client.rpc` routes any
//!     reply whose tag is not its own through `dispatch`, so an out-of-order
//!     reply for a standing ticket is absorbed rather than being a protocol
//!     error; only a tag matching neither is a real violation.
//!   * **Abandoning never leaves an owed reply homeless.** Giving up on a
//!     request does NOT free its tag: the slot becomes a TOMBSTONE (`.discard`)
//!     that absorbs and drops whatever finally arrives. Without it, abandoning
//!     poisons the NEXT ticket's `check`: the server still owes a reply for the
//!     old tag, that reply arrives on some later tick with no slot to land in,
//!     and `drainReady` reports ProtocolError to whichever innocent ticket
//!     happened to drain it. The whole cleanup path — `cancel`, and the
//!     mid-flight clunks a job's `deinit` owes — is therefore ASYNCHRONOUS:
//!     nothing on it may call `Client.rpc`, which on an un-pumped client (the
//!     origin, whose frames only arrive on a later tick) sends its T-message,
//!     fails with WouldBlock, and abandons the tag anyway.
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
/// matching reply is dispatched (during any `rpc`/pump/`check`), or waiting →
/// discard when the caller abandons the request.
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
        /// TOMBSTONE: nobody wants this reply any more, but the server still
        /// owes one, so the tag stays booked (`buf` is empty and never
        /// written). `dispatch` drops the reply and removes the slot; `check`
        /// treats the tag as consumed (ProtocolError, like an unknown tag).
        /// Produced by `cancel` — for both the flushed tag and the Tflush's own
        /// tag — and by `beginDiscard`/`discardClunk`.
        discard,
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
        // Abandoned: the tag is still booked for the reply the server owes,
        // but the ticket is as consumed as if the slot were gone.
        .discard => return error.ProtocolError,
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

/// Abandon a ticket. ASYNCHRONOUS, and it must stay that way: it sends
/// `Tflush(oldtag = t.tag)` on a tombstone slot and returns, never waiting for
/// a reply (an `rpc` here would pump on a pumped client — against R-P13a-3 —
/// and, on an un-pumped one, would send the Tflush and then fail WouldBlock,
/// abandoning BOTH tags with no slot for the two replies still owed).
///
/// The ticket is CONSUMED either way, and both server orderings are absorbed
/// [flush(5); srv.c's deferred Rflush]:
///
///   * still parked ⇒ Rerror "interrupted" on the OLD tag, then Rflush on the
///     flush's own tag;
///   * the real reply raced ahead ⇒ Rwalk/Rread/… on the old tag, then Rflush.
///
/// Both tags hold `.discard` slots, so whichever arrives first (and on whatever
/// later tick) is dropped and its slot removed. If the old tag had ALREADY been
/// answered into its slot, nothing more is owed for it and the slot is dropped
/// outright — only the flush's tag is left tombstoned.
///
/// Finally drains whatever is ready, so the common pumped case (both replies
/// already queued) leaves no tombstone behind at all.
pub fn cancel(c: *Client, t: Ticket) Error!void {
    abandon(c, t.tag);
    try beginDiscard(c, .{ .tag = 0, .body = .{ .tflush = .{ .oldtag = t.tag } } });
    try drainReady(c);
}

/// Give up on a slot without sending anything: tombstone it if the server still
/// owes a reply, drop it if the reply already landed. Idempotent; an unknown tag
/// is a no-op.
fn abandon(c: *Client, tag: u16) void {
    const entry = c.pending.getPtr(tag) orelse return;
    if (entry.state == .waiting) {
        entry.state = .discard;
        entry.buf = c.rbuf[0..0]; // a tombstone borrows nothing
    } else {
        _ = c.pending.remove(tag);
    }
}

/// Send `t` on a tombstone slot: a fresh tag is allocated and booked so the
/// reply has somewhere to land, but the reply itself is dropped. For the
/// fire-and-forget messages of a cleanup path (Tflush, Tclunk), which must not
/// block and whose answers nobody reads.
///
/// Slot lifetime: a tombstone is removed when its reply arrives (`dispatch`).
/// A transport that never answers therefore leaks one map entry per abandoned
/// request until `Client.deinit` — bounded by the number of abandoned requests,
/// and `Client.version` clears the whole table when a session restarts.
pub fn beginDiscard(c: *Client, t: Message) Error!void {
    const tag = c.allocTag();
    try c.pending.put(c.allocator, tag, .{ .buf = c.rbuf[0..0], .mode = .frame, .state = .discard });
    errdefer _ = c.pending.remove(tag);
    var m = t;
    m.tag = tag;
    try c.sendFrame(m);
}

/// Release `fid` server-side WITHOUT waiting — the only clunk a job's `deinit`
/// may use (`Client.clunk` is an `rpc`). The Tclunk goes out on a tombstone and
/// the number is recycled immediately: a Tclunk releases the fid even when the
/// reply is an Rerror [`5/clunk`], so the server holds nothing either way, and
/// the Rclunk lands on the tombstone instead of poisoning a later `check`.
/// Best effort — a transport that refuses the send leaves the fid to the
/// session teardown.
///
/// ASSUMPTION (review nit, phase 13a): recycling the number before the Rclunk
/// is safe only because every peer processes one connection's frames in order
/// (`ninep.server.poll` is sequential; `snarf-origin` runs one blocking pump per
/// connection), so a reused fid in the next Twalk always lands after the Tclunk.
/// A reordering server (a threaded ADR-0005 native host) would need the
/// tombstone to carry the fid and `dispatch` to free it on the Rclunk instead.
pub fn discardClunk(c: *Client, fid: u32) void {
    beginDiscard(c, .{ .tag = 0, .body = .{ .tclunk = .{ .fid = fid } } }) catch {};
    c.freeFid(fid);
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
        .discard => return error.ProtocolError, // abandoned; see `check`
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
/// ignored, not an error). A TOMBSTONE slot (`.discard`) swallows the reply,
/// whatever its type, and frees the tag: this is what makes an abandoned
/// request harmless to every later ticket.
///
/// `frame` is the raw bytes `reply` was decoded from; `.frame` slots take those
/// verbatim, `.payload` slots take only the Rread data.
pub fn dispatch(c: *Client, frame: []const u8, reply: Message) Error!void {
    const entry = c.pending.getPtr(reply.tag) orelse return error.ProtocolError;
    if (entry.state == .discard) {
        // The owed reply finally came; nobody wants it. Drop it and release
        // the tag — the tombstone has done its job.
        _ = c.pending.remove(reply.tag);
        return;
    }
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

// ==========================================================================
// Named battery T1-T3 (test writer's, phase13a contract §4). A scripted
// transport — copied from `client.zig`'s own test section, same ~60-line
// recipe (S-07 §6: no dependency on chan.zig/server.zig, so tickets.zig can
// pin `begin`/`check`/`cancel`'s reply-ordering and pump-discipline contracts
// with byte-exact control over what "arrives" and when).
// ==========================================================================
const Stat = @import("stat.zig");

/// A scripted transport: records every frame the client SENDS (so a test can
/// decode and assert on it) and hands back pre-loaded reply frames in order.
/// A read past the end of the script returns WouldBlock.
const ScriptedTransport = struct {
    allocator: std.mem.Allocator,
    sent: std.ArrayListUnmanaged([]u8) = .empty,
    replies: std.ArrayListUnmanaged([]u8) = .empty,
    reply_idx: usize = 0,

    fn init(allocator: std.mem.Allocator) ScriptedTransport {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ScriptedTransport) void {
        for (self.sent.items) |f| self.allocator.free(f);
        for (self.replies.items) |f| self.allocator.free(f);
        self.sent.deinit(self.allocator);
        self.replies.deinit(self.allocator);
    }

    /// Encode `m` and queue it as the next reply the client will read.
    fn pushReply(self: *ScriptedTransport, m: Message) !void {
        var tmp: [4096]u8 = undefined;
        const n = try msg.encode(&m, &tmp);
        const copy = try self.allocator.dupe(u8, tmp[0..n]);
        try self.replies.append(self.allocator, copy);
    }

    /// The i-th frame the client sent, decoded.
    fn sentMsg(self: *ScriptedTransport, i: usize) !Message {
        return msg.decode(self.sent.items[i]);
    }

    fn writeMsg(ctx: *anyopaque, frame: []const u8) transport.Error!void {
        const self: *ScriptedTransport = @ptrCast(@alignCast(ctx));
        const copy = self.allocator.dupe(u8, frame) catch return error.Closed;
        self.sent.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return error.Closed;
        };
    }

    fn readMsg(ctx: *anyopaque, buf: []u8) transport.Error![]u8 {
        const self: *ScriptedTransport = @ptrCast(@alignCast(ctx));
        if (self.reply_idx >= self.replies.items.len) return error.WouldBlock;
        const r = self.replies.items[self.reply_idx];
        if (buf.len < r.len) return error.FrameTooBig;
        @memcpy(buf[0..r.len], r);
        self.reply_idx += 1;
        return buf[0..r.len];
    }

    fn close(ctx: *anyopaque) void {
        _ = ctx;
    }

    const vtable: transport.Transport.VTable = .{
        .writeMsg = writeMsg,
        .readMsg = readMsg,
        .close = close,
    };

    fn endpoint(self: *ScriptedTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "tickets: two tickets resolve independently in reverse-arrival order; a third tag is ProtocolError (T1)" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();

    var buf1: [512]u8 = undefined;
    var buf2: [512]u8 = undefined;
    const t1 = try begin(&client, .{ .tag = 0, .body = .{
        .twalk = msg.Body.Twalk.init(0, 1, &.{"a"}),
    } }, &buf1); // tag 0
    const t2 = try begin(&client, .{ .tag = 0, .body = .{
        .tstat = .{ .fid = 5 },
    } }, &buf2); // tag 1

    // Replies arrive in REVERSE order: t2's Rstat is queued (and thus read)
    // before t1's Rwalk.
    var stat_bytes: [128]u8 = undefined;
    const sn = try (Stat{ .qid = .{ .path = 9 }, .mode = 0, .length = 0, .name = "f" }).encode(&stat_bytes);
    try st.pushReply(.{ .tag = 1, .body = .{ .rstat = .{ .stat = stat_bytes[0..sn] } } });
    try st.pushReply(.{ .tag = 0, .body = .{
        .rwalk = msg.Body.Rwalk.init(&.{.{ .path = 10, .qtype = .{ .dir = true } }}),
    } });

    // Checking t2 first drains BOTH queued frames (check drains everything
    // ready, regardless of which ticket is asked about) and reports its own.
    const r2 = (try check(&client, t2)).?;
    try testing.expectEqual(msg.Kind.rstat, r2.body.kind());
    try testing.expectEqualStrings("f", (try Stat.decode(r2.body.rstat.stat)).name);

    // t1's reply was already dispatched into its own slot by that drain.
    const r1 = (try check(&client, t1)).?;
    try testing.expectEqual(msg.Kind.rwalk, r1.body.kind());
    try testing.expectEqual(@as(u16, 1), r1.body.rwalk.nwqid);

    // A tag matching no outstanding ticket is a protocol violation.
    try testing.expectError(error.ProtocolError, check(&client, .{ .tag = 99 }));
}

test "tickets: check never pumps when the transport has no frames ready (T2)" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();

    var pumps: usize = 0;
    client.pump = .{ .ctx = &pumps, .run = struct {
        fn run(ctx: *anyopaque) anyerror!void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.run };

    var buf: [512]u8 = undefined;
    const t = try begin(&client, .{ .tag = 0, .body = .{ .tstat = .{ .fid = 0 } } }, &buf);

    // No reply queued: check must report `null` without ever invoking the pump
    // (R-P13a-3) — try it more than once to rule out a first-call fluke.
    try testing.expectEqual(@as(?Message, null), try check(&client, t));
    try testing.expectEqual(@as(?Message, null), try check(&client, t));
    try testing.expectEqual(@as(usize, 0), pumps);
}

test "tickets: an Rerror maps to the ticket's error; cancel Tflushes and frees the slot (T3)" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();

    // An Rerror reply surfaces as the ticket's mapped, typed error and
    // consumes the slot.
    var buf1: [512]u8 = undefined;
    const t1 = try begin(&client, .{ .tag = 0, .body = .{ .tstat = .{ .fid = 0 } } }, &buf1); // tag 0
    try st.pushReply(.{ .tag = 0, .body = .{ .rerror = .{ .ename = "file does not exist" } } });
    try testing.expectError(error.FileDoesNotExist, check(&client, t1));
    try testing.expect(!client.pending.contains(t1.tag));

    // cancel: Tflush the ticket and free the slot. A reply that races ahead
    // for the OLD tag is absorbed by cancel's own dispatch loop, not
    // resurrected — the ticket is consumed either way and a later check on it
    // is a ProtocolError (unknown tag), matching `cancelRead`'s contract.
    var buf2: [512]u8 = undefined;
    const t2 = try begin(&client, .{ .tag = 0, .body = .{ .tstat = .{ .fid = 1 } } }, &buf2); // tag 1
    try st.pushReply(.{ .tag = 1, .body = .{ .rerror = .{ .ename = "interrupted" } } }); // races ahead
    try st.pushReply(.{ .tag = 2, .body = .rflush }); // the flush's own tag
    try cancel(&client, t2);
    try testing.expect(!client.pending.contains(t2.tag));

    // The Tflush we sent carried oldtag == t2's tag (sent[0]=Tstat(0),
    // [1]=Tstat(1), [2]=Tflush(2)).
    const flush_sent = try st.sentMsg(2);
    try testing.expectEqual(msg.Kind.tflush, flush_sent.body.kind());
    try testing.expectEqual(t2.tag, flush_sent.body.tflush.oldtag);

    try testing.expectError(error.ProtocolError, check(&client, t2));
}

test "tickets: cancel on an un-pumped client tombstones both tags; late replies in either order never poison a fresh ticket (T8b)" {
    // ordering A: the flushed ticket's own Rerror races ahead of its Rflush.
    {
        var st = ScriptedTransport.init(testing.allocator);
        defer st.deinit();
        var client = try Client.init(testing.allocator, st.endpoint(), 8192);
        defer client.deinit();

        var buf0: [512]u8 = undefined;
        const t0 = try begin(&client, .{ .tag = 0, .body = .{ .tstat = .{ .fid = 0 } } }, &buf0); // tag 0

        // Nothing is ready: cancel sends the Tflush (tag 1) on a tombstone and
        // its own drain finds nothing to absorb yet.
        try cancel(&client, t0);
        const flush_sent = try st.sentMsg(1);
        try testing.expectEqual(msg.Kind.tflush, flush_sent.body.kind());
        try testing.expectEqual(@as(u16, 0), flush_sent.body.tflush.oldtag);

        var buf2: [512]u8 = undefined;
        const t2 = try begin(&client, .{ .tag = 0, .body = .{ .tstat = .{ .fid = 1 } } }, &buf2); // tag 2
        try testing.expectEqual(@as(?Message, null), try check(&client, t2));

        // The cancelled ticket is already unreachable, before either late
        // reply has even been queued.
        try testing.expectError(error.ProtocolError, check(&client, t0));

        // Late replies land in send order: the flushed request's own Rerror,
        // then the Rflush, then the unrelated ticket's real reply.
        try st.pushReply(.{ .tag = 0, .body = .{ .rerror = .{ .ename = "interrupted" } } });
        try st.pushReply(.{ .tag = 1, .body = .rflush });
        var stat_bytes: [128]u8 = undefined;
        const sn = try (Stat{ .qid = .{ .path = 9 }, .mode = 0, .length = 0, .name = "f" }).encode(&stat_bytes);
        try st.pushReply(.{ .tag = 2, .body = .{ .rstat = .{ .stat = stat_bytes[0..sn] } } });

        const r2 = (try check(&client, t2)).?;
        try testing.expectEqual(msg.Kind.rstat, r2.body.kind());
        try testing.expectEqual(@as(usize, 0), client.pending.count());
        try testing.expectError(error.ProtocolError, check(&client, t0));
    }

    // ordering B: the real reply races ahead of the Rflush instead.
    {
        var st = ScriptedTransport.init(testing.allocator);
        defer st.deinit();
        var client = try Client.init(testing.allocator, st.endpoint(), 8192);
        defer client.deinit();

        var buf0: [512]u8 = undefined;
        const t0 = try begin(&client, .{ .tag = 0, .body = .{ .tstat = .{ .fid = 0 } } }, &buf0); // tag 0

        try cancel(&client, t0);
        const flush_sent = try st.sentMsg(1);
        try testing.expectEqual(msg.Kind.tflush, flush_sent.body.kind());
        try testing.expectEqual(@as(u16, 0), flush_sent.body.tflush.oldtag);

        var buf2: [512]u8 = undefined;
        const t2 = try begin(&client, .{ .tag = 0, .body = .{ .tstat = .{ .fid = 1 } } }, &buf2); // tag 2
        try testing.expectEqual(@as(?Message, null), try check(&client, t2));

        try testing.expectError(error.ProtocolError, check(&client, t0));

        // This time the Rflush arrives first, then a REAL Rstat on the
        // flushed tag (the server's answer raced ahead of its own Rflush),
        // then the unrelated ticket's real reply.
        try st.pushReply(.{ .tag = 1, .body = .rflush });
        var stat0_bytes: [128]u8 = undefined;
        const sn0 = try (Stat{ .qid = .{ .path = 3 }, .mode = 0, .length = 0, .name = "g" }).encode(&stat0_bytes);
        try st.pushReply(.{ .tag = 0, .body = .{ .rstat = .{ .stat = stat0_bytes[0..sn0] } } });
        var stat_bytes: [128]u8 = undefined;
        const sn = try (Stat{ .qid = .{ .path = 9 }, .mode = 0, .length = 0, .name = "f" }).encode(&stat_bytes);
        try st.pushReply(.{ .tag = 2, .body = .{ .rstat = .{ .stat = stat_bytes[0..sn] } } });

        const r2 = (try check(&client, t2)).?;
        try testing.expectEqual(msg.Kind.rstat, r2.body.kind());
        try testing.expectEqual(@as(usize, 0), client.pending.count());
        try testing.expectError(error.ProtocolError, check(&client, t0));
    }
}
