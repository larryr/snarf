//! Synchronous 9P2000 client. file-as-struct (S-07 P-1): this file *is* the
//! `Client`. It drives one `transport.Transport` endpoint, issuing T-messages
//! and matching each against its R-message reply by tag.
//!
//! There is no single lib9p analog for the client side (lib9p is a server
//! framework); the behaviour here is spec-driven — see S-01 §3 (framing/RPC)
//! and §4 (fid/tag lifecycle). Where a rule mirrors kernel/9pfs semantics it is
//! cited inline (e.g. mnt.c walk chunking, `9/port/*`).
//!
//! Concurrency model (R7): a `Client` is single-threaded and *synchronous*. Each
//! call sends one request and blocks until its reply arrives. Because the
//! transport is non-blocking, a `WouldBlock` from the transport is resolved by
//! invoking the optional `Pump` (which drives the peer, e.g. a same-thread
//! server's `poll`) and retrying; with no pump, `WouldBlock` surfaces to the
//! caller (a SharedArrayBuffer/worker bridge fills this slot later).
const std = @import("std");
const msg = @import("msg.zig");
const Qid = @import("qid.zig");
const stat_mod = @import("stat.zig");
const transport = @import("transport.zig");
const errors = @import("errors.zig");
const tickets = @import("tickets.zig");

const Message = msg.Message;
const Body = msg.Body;
const NOTAG = msg.NOTAG;
const NOFID = msg.NOFID;
const IOHDRSZ = msg.IOHDRSZ;
const MAXWELEM = msg.MAXWELEM;

/// This file *is* the Client (S-07 P-1); the `pub` alias lets `ninep.zig`
/// re-export it as `@import("client.zig").Client`.
pub const Client = @This();

/// Everything a walk/attach hands back: the established fid and the file it
/// names. `qid` is a value copy; it does not alias any buffer.
pub const FidInfo = struct { fid: u32, qid: Qid };

/// An outstanding non-blocking read (R-P6-4). Opaque: the caller holds only the
/// tag and hands the ticket back to `checkRead`/`cancelRead`. A ticket is live
/// from `beginRead` until it is consumed (a non-null `checkRead`, or
/// `cancelRead`). Since phase 13a this is the generic `tickets.Ticket` — read
/// tickets are the `.payload` mode of one mechanism (S-01 §3.2).
pub const ReadTicket = tickets.Ticket;

/// Drives the peer when the transport would block. `run` is invoked on every
/// transport `WouldBlock`, then the operation retries. With no pump a
/// `WouldBlock` surfaces to the caller instead (S-01 §3.2). A pump failure
/// surfaces as error.IoError (which stops the retry loop; a pump that keeps
/// erroring must fail rather than spin forever).
///
/// FORBIDDEN (R-P6-4): never issue a blocking `rpc` (`read`, or any synchronous
/// op) against a file that may PARK the request server-side (mouse, kbd, any
/// wait-queue file). The peer never answers until data arrives, so `rpc` pumps
/// forever — the pump keeps producing no reply and the loop cannot make
/// progress. Use the ticket API (`beginRead`/`checkRead`/`cancelRead`) for
/// parkable files: it registers a pending slot and lets `rpc`/`checkRead`
/// dispatch the reply out of band whenever it finally arrives.
pub const Pump = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) anyerror!void,
};

/// The client error set: typed 9P op errors (mapped from Rerror), plus the
/// transport's own errors, plus local failures. Declared in `tickets.zig` (the
/// asynchronous half of this file) so that `Client`'s field layout — it holds a
/// map of `tickets.Pending`, whose failure arm is this set — does not depend on
/// `Client`'s own namespace. Same members, same name.
pub const Error = tickets.Error;

allocator: std.mem.Allocator,
tport: transport.Transport,
/// Negotiated max message size; 0 until `version` succeeds.
msize: u32 = 0,
/// Ceiling we will propose and the size of `rbuf`/`wbuf`.
max_msize: u32,
/// Next tag to hand out; wraps 0..0xFFFE, never NOTAG (S-01 §4).
next_tag: u16 = 0,
/// Next fresh fid number when the free list is empty.
next_fid: u32 = 0,
/// Recycled fid numbers (LIFO), reused before minting fresh ones.
free_fids: std.ArrayListUnmanaged(u32) = .empty,
/// Live fids the client believes the server holds, → their last-known qid.
fids: std.AutoHashMapUnmanaged(u32, Qid) = .empty,
/// Outstanding tickets keyed by their tag (R-P6-4, generalised in phase 13a).
/// A reply whose tag is not `t.tag` of the in-flight `rpc` is routed here rather
/// than being a ProtocolError; only a tag matching neither is a real protocol
/// violation. Owned by `tickets.zig`, which is the only file that writes it.
pending: std.AutoHashMapUnmanaged(u16, tickets.Pending) = .empty,
/// Owned read buffer, `max_msize` bytes; decoded replies alias it.
rbuf: []u8,
/// Owned write buffer, `max_msize` bytes.
wbuf: []u8,
pump: ?Pump = null,
/// Raw ename of the most recent unrecognized Rerror (error.Other), so the
/// caller can recover the server's original text via `lastErrorString`.
last_rerror_buf: [128]u8 = undefined,
last_rerror_len: u8 = 0,

/// Allocate the read/write buffers (`max_msize` each) and return a fresh
/// client. Set `.pump` afterward if the transport can block.
pub fn init(allocator: std.mem.Allocator, tport: transport.Transport, max_msize: u32) Error!Client {
    const rbuf = try allocator.alloc(u8, max_msize);
    errdefer allocator.free(rbuf);
    const wbuf = try allocator.alloc(u8, max_msize);
    return .{
        .allocator = allocator,
        .tport = tport,
        .max_msize = max_msize,
        .rbuf = rbuf,
        .wbuf = wbuf,
    };
}

pub fn deinit(self: *Client) void {
    self.allocator.free(self.rbuf);
    self.allocator.free(self.wbuf);
    self.free_fids.deinit(self.allocator);
    self.fids.deinit(self.allocator);
    self.pending.deinit(self.allocator);
    self.* = undefined;
}

// --- fid / tag allocation -------------------------------------------------

/// Hand out a fid number, preferring a recycled one. Infallible.
pub fn allocFid(self: *Client) u32 {
    if (self.free_fids.pop()) |f| return f;
    const f = self.next_fid;
    self.next_fid +%= 1;
    return f;
}

/// Return a fid number to the pool and drop any local qid for it. Best-effort:
/// if recording the recycled number OOMs we simply mint a fresh one next time.
pub fn freeFid(self: *Client, fid: u32) void {
    _ = self.fids.remove(fid);
    self.free_fids.append(self.allocator, fid) catch {};
}

/// Record the Rattach/Rwalk qid a hand-driven handshake learned out of band —
/// see `origin/handshake.zig`, which drives version+attach at the frame level
/// and then hands the session to this client. Overwrites any existing entry.
/// Best-effort, like every other write to this cache: `walk` falls back to a
/// zero qid when the fid is unknown.
pub fn seedQid(self: *Client, fid: u32, qid: Qid) void {
    self.fids.put(self.allocator, fid, qid) catch {};
}

/// Next tag, wrapping 0..0xFFFE and skipping NOTAG (0xFFFF). [S-01 §4]
/// `pub` for `tickets.zig` only — the asynchronous half of this file (S-07 P-1
/// splits one type across two files here); no other module allocates tags.
pub fn allocTag(self: *Client) u16 {
    const t = self.next_tag;
    self.next_tag = if (self.next_tag >= 0xFFFE) 0 else self.next_tag + 1;
    return t;
}

// --- RPC core -------------------------------------------------------------

/// The largest frame we will encode/accept: the negotiated msize, or (before
/// version negotiation) the full buffer.
fn frameLimit(self: *const Client) usize {
    return if (self.msize == 0) self.max_msize else self.msize;
}

/// Send one T-message and return its matching R-message. The returned Message
/// aliases `rbuf`, so it is valid only until the next call. An Rerror reply is
/// turned into its typed error (unrecognized text → error.Other, with the raw
/// text stashed for `lastErrorString`). [S-01 §3]
///
/// Tag DISPATCH (R-P6-4): a reply whose tag is *not* `t.tag` is not immediately a
/// ProtocolError. If it matches an outstanding read ticket (`self.pending`) it is
/// routed to that ticket's slot — the payload copied out of `rbuf` right now,
/// before we loop and overwrite the buffer — and we keep reading until OUR reply
/// (tag `t.tag`) arrives. Only a tag matching neither is a ProtocolError. This is
/// how an out-of-order Rread for a standing ticket is absorbed while a synchronous
/// op (e.g. stat) is in flight.
///
/// FORBIDDEN: do not call `rpc` (directly or via `read`/`stat`/...) on a file that
/// may PARK the request server-side — the reply never comes and, with a pump set,
/// this loop pumps forever (see `Pump`). Parkable files use the ticket API.
pub fn rpc(self: *Client, t: Message) Error!Message {
    try self.sendFrame(t);
    while (true) {
        const reply_bytes = try self.readFrame();
        const reply = msg.decode(reply_bytes) catch return error.ProtocolError;
        if (reply.tag == t.tag) {
            if (reply.body == .rerror) return self.mapRerror(reply.body.rerror.ename);
            return reply;
        }
        // Not our reply: route it to a waiting ticket, or fail. dispatch copies
        // any payload out of rbuf before we loop and read over it.
        try tickets.dispatch(self, reply_bytes, reply);
    }
}

/// Encode `t` into `wbuf` and write the whole frame (pumping on WouldBlock).
/// Shared by `rpc` and the ticket senders (`tickets.begin`/`beginRead`, which
/// send without waiting for a reply); `pub` for `tickets.zig` only.
pub fn sendFrame(self: *Client, t: Message) Error!void {
    const limit = self.frameLimit();
    const n = msg.encode(&t, self.wbuf[0..limit]) catch |e| return switch (e) {
        error.ShortBuffer => error.MessageTooBig, // frame exceeds msize
        error.BadMessage => error.ProtocolError,
    };
    try self.writeFrame(self.wbuf[0..n]);
}

/// Write a whole frame, pumping the peer on WouldBlock. FrameTooBig from the
/// transport means the frame exceeds what the peer will accept ⇒ MessageTooBig.
fn writeFrame(self: *Client, frame: []const u8) Error!void {
    while (true) {
        self.tport.writeMsg(frame) catch |e| switch (e) {
            error.WouldBlock => {
                if (self.pump) |p| {
                    p.run(p.ctx) catch return error.IoError;
                    continue;
                }
                return error.WouldBlock;
            },
            error.FrameTooBig => return error.MessageTooBig,
            else => return e, // Closed, BadFrame
        };
        return;
    }
}

/// Read the next whole frame into `rbuf`, pumping on WouldBlock. A reply larger
/// than our buffer ⇒ MessageTooBig.
fn readFrame(self: *Client) Error![]u8 {
    while (true) {
        return self.tport.readMsg(self.rbuf) catch |e| switch (e) {
            error.WouldBlock => {
                if (self.pump) |p| {
                    p.run(p.ctx) catch return error.IoError;
                    continue;
                }
                return error.WouldBlock;
            },
            error.FrameTooBig => return error.MessageTooBig,
            else => return e, // Closed, BadFrame
        };
    }
}

/// Map a received Rerror string to a typed error; for the catch-all error.Other
/// stash the raw text (truncated to 128 bytes) BEFORE returning it. `pub` for
/// `tickets.zig` only (it maps an Rerror into a ticket's slot).
pub fn mapRerror(self: *Client, ename: []const u8) Error {
    const e = errors.errorFromString(ename);
    if (e == error.Other) {
        const m = @min(ename.len, self.last_rerror_buf.len);
        @memcpy(self.last_rerror_buf[0..m], ename[0..m]);
        self.last_rerror_len = @intCast(m);
    }
    return e;
}

/// The raw text of the most recent error.Other Rerror (empty if none).
pub fn lastErrorString(self: *const Client) []const u8 {
    return self.last_rerror_buf[0..self.last_rerror_len];
}

// --- protocol operations --------------------------------------------------

/// Negotiate the protocol version and msize. Uses NOTAG, proposes
/// min(want_msize, max_msize), and stores the (possibly smaller) value the
/// server returns. Resets all tag/fid state — a fresh session. A reply that is
/// not Rversion, or whose version is not "9P2000" (the server says "unknown"
/// when it cannot speak our version), is a ProtocolError. [S-01 §3]
pub fn version(self: *Client, want_msize: u32) Error!u32 {
    const proposed = @min(want_msize, self.max_msize);
    const reply = try self.rpc(.{ .tag = NOTAG, .body = .{
        .tversion = .{ .msize = proposed, .version = msg.version9p },
    } });
    switch (reply.body) {
        .rversion => |v| {
            if (!std.mem.eql(u8, v.version, msg.version9p)) return error.ProtocolError;
            self.msize = @min(v.msize, proposed);
            self.next_tag = 0;
            self.next_fid = 0;
            self.free_fids.clearRetainingCapacity();
            self.fids.clearRetainingCapacity();
            // A fresh session: any tickets from the old one are abandoned
            // silently, mirroring the server clearing its parked queue on
            // Tversion (R-P6-5). Their tags belong to the previous session.
            self.pending.clearRetainingCapacity();
            return self.msize;
        },
        else => return error.ProtocolError,
    }
}

/// Attach to the file tree root as `uname` (no auth: afid = NOFID). Returns the
/// root fid and its qid.
pub fn attach(self: *Client, uname: []const u8, aname: []const u8) Error!FidInfo {
    const fid = self.allocFid();
    errdefer self.freeFid(fid);
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tattach = .{ .fid = fid, .afid = NOFID, .uname = uname, .aname = aname },
    } });
    switch (reply.body) {
        .rattach => |a| {
            try self.fids.put(self.allocator, fid, a.qid);
            return .{ .fid = fid, .qid = a.qid };
        },
        else => return error.ProtocolError,
    }
}

/// Walk `names` from `fid` to a freshly allocated newfid (clone + walk). Names
/// are sent in successive Twalks of at most MAXWELEM each (mnt.c chunking). The
/// newfid is established only on FULL success; any short/partial Rwalk yields
/// error.FileDoesNotExist. `names.len == 0` is a pure clone. [S-01 §4, `5/walk`]
///
/// Cleanup on failure (walkCleanup): a partial on the FIRST Twalk leaves newfid
/// untouched server-side, so the number is simply recycled. But once any chunk
/// fully succeeds the server holds newfid at an intermediate node; a later
/// failure must release it with a best-effort Tclunk, and the number is only
/// recycled if that clunk is acknowledged (otherwise it is burned, never handed
/// out again, so a still-live server fid can never collide).
pub fn walk(self: *Client, fid: u32, names: []const []const u8) Error!FidInfo {
    const newfid = self.allocFid();
    var established = false; // has any Twalk chunk fully succeeded?
    errdefer self.walkCleanup(newfid, established);

    var final_qid: Qid = self.fids.get(fid) orelse .{ .path = 0 };
    var clone_from = fid;
    var remaining = names;
    while (remaining.len > 0) {
        const chunk_len = @min(remaining.len, MAXWELEM);
        const chunk = remaining[0..chunk_len];
        const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
            .twalk = Body.Twalk.init(clone_from, newfid, chunk),
        } });
        switch (reply.body) {
            .rwalk => |rw| {
                if (rw.nwqid != chunk_len) return error.FileDoesNotExist; // partial
                final_qid = rw.wqid[chunk_len - 1];
                clone_from = newfid; // later chunks walk newfid in place
                established = true;
                remaining = remaining[chunk_len..];
            },
            else => return error.ProtocolError,
        }
    }
    if (names.len == 0) {
        // Pure clone: reply must be an empty Rwalk; newfid mirrors `fid`.
        const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
            .twalk = Body.Twalk.init(fid, newfid, &.{}),
        } });
        switch (reply.body) {
            .rwalk => |rw| if (rw.nwqid != 0) return error.ProtocolError,
            else => return error.ProtocolError,
        }
    }
    try self.fids.put(self.allocator, newfid, final_qid);
    return .{ .fid = newfid, .qid = final_qid };
}

/// Release the tentative newfid of a failed walk. If it was never established
/// server-side, just recycle the number. Otherwise send a best-effort Tclunk
/// and recycle the number only if the server acknowledges — else burn it.
fn walkCleanup(self: *Client, newfid: u32, established: bool) void {
    if (!established) {
        self.freeFid(newfid);
        return;
    }
    if (self.clunkQuiet(newfid)) self.freeFid(newfid);
    // clunk failed ⇒ the server may still hold newfid: burn the number.
}

/// Send Tclunk(fid) and report whether the server acknowledged it. Never frees
/// the fid number (the caller decides based on the result) and never surfaces
/// an error — used only for best-effort cleanup.
fn clunkQuiet(self: *Client, fid: u32) bool {
    const reply = self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tclunk = .{ .fid = fid },
    } }) catch return false;
    return reply.body == .rclunk;
}

/// Open `fid` for `mode` (an OREAD/OWRITE/... constant). The server tracks the
/// open mode; we just return the qid it reports.
pub fn open(self: *Client, fid: u32, mode: u8) Error!Qid {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .topen = .{ .fid = fid, .mode = mode },
    } });
    switch (reply.body) {
        .ropen => |o| return o.qid,
        else => return error.ProtocolError,
    }
}

/// Read up to `buf.len` bytes at `offset`. The requested count is clamped to
/// msize-IOHDRSZ (the max payload a single Rread can carry). Returns bytes read;
/// 0 means EOF. The caller loops for more.
pub fn read(self: *Client, fid: u32, offset: u64, buf: []u8) Error!usize {
    const count: u32 = @intCast(@min(buf.len, self.ioMax()));
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tread = .{ .fid = fid, .offset = offset, .count = count },
    } });
    switch (reply.body) {
        .rread => |r| {
            if (r.data.len > buf.len) return error.ProtocolError;
            @memcpy(buf[0..r.data.len], r.data);
            return r.data.len;
        },
        else => return error.ProtocolError,
    }
}

/// Write up to `data.len` bytes at `offset`. Payload is clamped to
/// msize-IOHDRSZ; if `data` is larger only the clamp is sent and the caller
/// loops. Returns the count the server acknowledges.
pub fn write(self: *Client, fid: u32, offset: u64, data: []const u8) Error!usize {
    const n = @min(data.len, self.ioMax());
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .twrite = .{ .fid = fid, .offset = offset, .data = data[0..n] },
    } });
    switch (reply.body) {
        .rwrite => |w| return w.count,
        else => return error.ProtocolError,
    }
}

/// Max single-message payload: msize - IOHDRSZ. `pub` for `tickets.zig` and
/// `nsjob.zig`, which size their own Tread counts against it.
pub fn ioMax(self: *const Client) usize {
    return self.frameLimit() - IOHDRSZ;
}

/// Clunk (release) `fid`. The fid number is always freed locally, even if the
/// server answers Rerror — the fid is gone either way.
pub fn clunk(self: *Client, fid: u32) Error!void {
    defer self.freeFid(fid);
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tclunk = .{ .fid = fid },
    } });
    switch (reply.body) {
        .rclunk => return,
        else => return error.ProtocolError,
    }
}

/// Fetch the stat(5) record for `fid`. The returned Stat's strings alias `rbuf`
/// (R4): valid only until the next client call.
///
/// `stat.zig` is file-as-struct, so the module handle `stat_mod` *is* the Stat
/// type; `stat_mod.Stat` would name the file's private self-alias (not `pub`) and
/// fails to compile once analyzed — a latent bug uncovered by the first caller
/// (ticket test 12). Reference the type as `stat_mod`.
pub fn stat(self: *Client, fid: u32) Error!stat_mod {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tstat = .{ .fid = fid },
    } });
    switch (reply.body) {
        .rstat => |r| return stat_mod.decode(r.stat) catch return error.ProtocolError,
        else => return error.ProtocolError,
    }
}

/// What `create` reports back: the new file's qid and the server's iounit
/// (0 = no guarantee). [`5/open` Rcreate]
pub const CreateResult = msg.mut.Rcreate;

/// Create `name` in the directory `fid` and open the RESULT as `fid` (`5/open`):
/// on success this client's cached qid for `fid` becomes the new file's. `perm`
/// carries DMDIR for a directory; the server masks it against the parent.
pub fn create(self: *Client, fid: u32, name: []const u8, perm: u32, mode: u8) Error!CreateResult {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tcreate = .{ .fid = fid, .name = name, .perm = perm, .mode = mode },
    } });
    switch (reply.body) {
        .rcreate => |c| {
            self.seedQid(fid, c.qid); // the fid now names the new file
            return c;
        },
        else => return error.ProtocolError,
    }
}

/// Remove the file `fid` names. `5/remove`: the server clunks the fid even when
/// the remove fails, so the number is recycled either way — exactly like
/// `clunk`.
pub fn remove(self: *Client, fid: u32) Error!void {
    defer self.freeFid(fid);
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tremove = .{ .fid = fid },
    } });
    switch (reply.body) {
        .rremove => return,
        else => return error.ProtocolError,
    }
}

/// Change `fid`'s directory entry. Fields `st` leaves at their "don't touch"
/// values (`~0`, empty strings) are not altered (`5/stat`); build one with
/// `stat_mod.dontTouch()`. The blob is encoded into a local scratch buffer, so
/// nothing aliases `wbuf`.
pub fn wstat(self: *Client, fid: u32, st: stat_mod) Error!void {
    var blob: [1024]u8 = undefined;
    const n = st.encode(&blob) catch return error.MessageTooBig;
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .twstat = .{ .fid = fid, .stat = blob[0..n] },
    } });
    switch (reply.body) {
        .rwstat => return,
        else => return error.ProtocolError,
    }
}

/// Ask the server to abandon the pending request tagged `oldtag`. In v1 the
/// server is synchronous so this always returns promptly. [`5/flush`]
pub fn flushTag(self: *Client, oldtag: u16) Error!void {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tflush = .{ .oldtag = oldtag },
    } });
    switch (reply.body) {
        .rflush => return,
        else => return error.ProtocolError,
    }
}

// --- non-blocking read tickets (R-P6-4) -----------------------------------
//
// Three forwarders into `tickets.zig`, which owns the whole asynchronous half
// since phase 13a (S-01 §3.2). The semantics are UNCHANGED — a read ticket is
// simply the `.payload` mode of the generic ticket:
//
//   * `beginRead` sends `Tread(fid, offset, min(buf.len, msize-IOHDRSZ))`
//     without waiting; `buf` is borrowed and must outlive the ticket.
//   * `checkRead` polls without pumping or blocking; `null` ⇒ still pending, a
//     byte count ⇒ `buf[0..n]` holds the payload and the ticket is CONSUMED, an
//     error ⇒ the reply's error (a flushed ticket surfaces error.Interrupted).
//   * `cancelRead` Tflushes the ticket and consumes it either way.
//
// Use these (never `read`/`rpc`) for files that may park server-side.

pub fn beginRead(self: *Client, fid: u32, offset: u64, buf: []u8) Error!ReadTicket {
    return tickets.beginRead(self, fid, offset, buf);
}

pub fn checkRead(self: *Client, t: ReadTicket) Error!?usize {
    return tickets.checkRead(self, t);
}

pub fn cancelRead(self: *Client, t: ReadTicket) Error!void {
    return tickets.cancel(self, t);
}

// ==========================================================================
// Tests (§T-client)
// ==========================================================================
const testing = std.testing;

/// A scripted transport: records every frame the client SENDS (so a test can
/// decode and assert on it) and hands back pre-loaded reply frames in order.
/// A read past the end of the script returns WouldBlock. No dependency on
/// chan.zig or server.zig.
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

/// Queue an Rversion(8192) and run `version`, asserting 8192 back. Leaves the
/// client ready with next_tag = 0, next_fid = 0.
fn doVersion(client: *Client, st: *ScriptedTransport) !void {
    try st.pushReply(.{ .tag = NOTAG, .body = .{
        .rversion = .{ .msize = 8192, .version = msg.version9p },
    } });
    try testing.expectEqual(@as(u32, 8192), try client.version(65536));
}

test "client: version negotiation" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();

    // Propose 65536, but max_msize caps it to 8192; server accepts 8192.
    try st.pushReply(.{ .tag = NOTAG, .body = .{
        .rversion = .{ .msize = 8192, .version = msg.version9p },
    } });
    try testing.expectEqual(@as(u32, 8192), try client.version(65536));
    try testing.expectEqual(@as(u32, 8192), client.msize);

    // The Tversion we sent proposed min(65536, 8192) with tag NOTAG.
    const sent = try st.sentMsg(0);
    try testing.expectEqual(NOTAG, sent.tag);
    try testing.expectEqual(@as(u32, 8192), sent.body.tversion.msize);
    try testing.expectEqualStrings(msg.version9p, sent.body.tversion.version);

    // A server that cannot speak 9P2000 replies "unknown" ⇒ ProtocolError.
    try st.pushReply(.{ .tag = NOTAG, .body = .{
        .rversion = .{ .msize = 8192, .version = "unknown" },
    } });
    try testing.expectError(error.ProtocolError, client.version(8192));
}

test "client: attach" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    try st.pushReply(.{ .tag = 0, .body = .{
        .rattach = .{ .qid = .{ .path = 1, .qtype = .{ .dir = true } } },
    } });
    const info = try client.attach("glenda", "");
    try testing.expectEqual(@as(u32, 0), info.fid);
    try testing.expectEqual(@as(u64, 1), info.qid.path);
    try testing.expect(info.qid.qtype.dir);
    try testing.expect(client.fids.contains(0));

    const sent = try st.sentMsg(1); // sent[0] was the Tversion
    try testing.expectEqual(@as(u32, 0), sent.body.tattach.fid);
    try testing.expectEqual(NOFID, sent.body.tattach.afid);
    try testing.expectEqualStrings("glenda", sent.body.tattach.uname);
    try testing.expectEqualStrings("", sent.body.tattach.aname);
}

test "client: walk full" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    // attach → fid 0
    try st.pushReply(.{ .tag = 0, .body = .{ .rattach = .{ .qid = .{ .path = 1, .qtype = .{ .dir = true } } } } });
    const root = try client.attach("glenda", "");

    // walk ["dev","mouse"] → two qids; last is the target.
    const q1 = Qid{ .path = 10, .qtype = .{ .dir = true } };
    const q2 = Qid{ .path = 20 };
    try st.pushReply(.{ .tag = 1, .body = .{ .rwalk = Body.Rwalk.init(&.{ q1, q2 }) } });
    const info = try client.walk(root.fid, &.{ "dev", "mouse" });

    try testing.expectEqual(@as(u32, 1), info.fid); // newfid
    try testing.expectEqual(@as(u64, 20), info.qid.path);
    try testing.expect(client.fids.contains(1));

    const sent = try st.sentMsg(2); // Tversion(0), Tattach(1), Twalk(2)
    try testing.expectEqual(@as(u32, 0), sent.body.twalk.fid);
    try testing.expectEqual(@as(u32, 1), sent.body.twalk.newfid);
    try testing.expectEqual(@as(u16, 2), sent.body.twalk.nwname);
    try testing.expectEqualStrings("dev", sent.body.twalk.names()[0]);
    try testing.expectEqualStrings("mouse", sent.body.twalk.names()[1]);
}

test "client: partial walk recycles fid" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    // Request 2 names but the server returns only 1 qid: a short/partial walk.
    try st.pushReply(.{ .tag = 0, .body = .{
        .rwalk = Body.Rwalk.init(&.{Qid{ .path = 10, .qtype = .{ .dir = true } }}),
    } });
    // newfid allocated here is 0 (next_fid started at 0).
    try testing.expectError(error.FileDoesNotExist, client.walk(5, &.{ "a", "b" }));
    // The newfid number was recycled and no fid was established locally.
    try testing.expect(!client.fids.contains(0));
    try testing.expectEqual(@as(u32, 0), client.allocFid());
    // A first-Twalk partial leaves newfid untouched server-side: no Tclunk.
    // Only the Tversion and the single Twalk were sent.
    try testing.expectEqual(@as(usize, 2), st.sent.items.len);
    try testing.expectEqual(msg.Kind.twalk, (try st.sentMsg(1)).body.kind());
}

test "client: walk: multi-chunk partial clunks established newfid" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();

    // 20 names ⇒ two Twalks: 16 (chunk 1) then 4 (chunk 2). No version call, so
    // the first sent frame is the Twalk and newfid == 0.
    const names: [20][]const u8 = @splat("x");

    // Chunk 1 fully succeeds: newfid is now established server-side.
    const full: [MAXWELEM]Qid = @splat(.{ .path = 7, .qtype = .{ .dir = true } });
    try st.pushReply(.{ .tag = 0, .body = .{ .rwalk = Body.Rwalk.init(&full) } });
    // Chunk 2 requests 4 but the server returns only 2 qids: a partial walk.
    try st.pushReply(.{ .tag = 1, .body = .{ .rwalk = Body.Rwalk.init(&.{
        Qid{ .path = 8, .qtype = .{ .dir = true } },
        Qid{ .path = 9 },
    }) } });
    // The best-effort cleanup Tclunk(newfid) is acknowledged.
    try st.pushReply(.{ .tag = 2, .body = .rclunk });

    try testing.expectError(error.FileDoesNotExist, client.walk(3, &names));

    // Three frames were sent: Twalk, Twalk, and the cleanup Tclunk. The third
    // is a Tclunk for the newfid used in the walks (0).
    try testing.expectEqual(@as(usize, 3), st.sent.items.len);
    const clunk_msg = try st.sentMsg(2);
    try testing.expectEqual(msg.Kind.tclunk, clunk_msg.body.kind());
    try testing.expectEqual(@as(u32, 0), clunk_msg.body.tclunk.fid);
    // Because the clunk succeeded, the number is recycled and handed out again.
    try testing.expect(!client.fids.contains(0));
    try testing.expectEqual(@as(u32, 0), client.allocFid());
}

test "client: seedQid seeds fid cache for clone walk" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    // Seed fid 5 with a qid learned out of band (e.g. a hand-driven Rattach
    // during the origin handshake, see origin/handshake.zig) — no RPC needed.
    const seeded = Qid{ .path = 42, .vers = 1, .qtype = .{ .dir = true } };
    client.seedQid(5, seeded);
    try testing.expect(client.fids.contains(5));
    try testing.expectEqual(seeded, client.fids.get(5).?);

    // Overwriting an existing entry replaces it, not merges or errors.
    const reseeded = Qid{ .path = 99 };
    client.seedQid(5, reseeded);
    try testing.expectEqual(reseeded, client.fids.get(5).?);

    // A subsequent zero-name walk (clone) on that fid behaves as before: the
    // server's Rwalk carries no qid for a pure clone, so the client mirrors
    // the source fid's last-known qid onto newfid — here, the seeded one.
    try st.pushReply(.{ .tag = 0, .body = .{ .rwalk = Body.Rwalk.init(&.{}) } });
    const info = try client.walk(5, &.{});
    try testing.expectEqual(@as(u32, 0), info.fid); // first fid handed out
    try testing.expectEqual(reseeded, info.qid);
    try testing.expectEqual(reseeded, client.fids.get(0).?);
}

test "client: tag wrap skips NOTAG" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    // Force the tag counter to the top of its range.
    client.next_tag = 0xFFFE;
    try st.pushReply(.{ .tag = 0xFFFE, .body = .rflush });
    try st.pushReply(.{ .tag = 0x0000, .body = .rflush });
    try client.flushTag(1);
    try client.flushTag(2);

    // sent[0] is the Tversion; the two flushes are sent[1] and sent[2].
    try testing.expectEqual(@as(u16, 0xFFFE), (try st.sentMsg(1)).tag);
    try testing.expectEqual(@as(u16, 0x0000), (try st.sentMsg(2)).tag);
}

test "client: tag mismatch" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    // Request will carry tag 0; the reply carries a different tag.
    try st.pushReply(.{ .tag = 99, .body = .rflush });
    try testing.expectError(error.ProtocolError, client.flushTag(1));
}

test "client: Rerror mapping" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    // A recognized ename maps to its typed error.
    try st.pushReply(.{ .tag = 0, .body = .{ .rerror = .{ .ename = "file does not exist" } } });
    try testing.expectError(error.FileDoesNotExist, client.open(3, msg.OREAD));

    // An unrecognized ename becomes error.Other, with the raw text recoverable.
    try st.pushReply(.{ .tag = 1, .body = .{ .rerror = .{ .ename = "flargle" } } });
    try testing.expectError(error.Other, client.open(3, msg.OREAD));
    try testing.expectEqualStrings("flargle", client.lastErrorString());
}

test "client: read clamps count" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st); // msize == 8192

    try st.pushReply(.{ .tag = 0, .body = .{ .rread = .{ .data = "hi" } } });
    // A buffer far larger than msize-IOHDRSZ; the count must be clamped.
    const buf = try testing.allocator.alloc(u8, 20000);
    defer testing.allocator.free(buf);
    const n = try client.read(7, 0, buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("hi", buf[0..2]);

    // The Tread we sent asked for exactly msize - IOHDRSZ bytes.
    const sent = try st.sentMsg(1);
    try testing.expectEqual(@as(u32, 8192 - IOHDRSZ), sent.body.tread.count);
}

test "client: fid reuse after clunk" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    try st.pushReply(.{ .tag = 0, .body = .{ .rattach = .{ .qid = .{ .path = 1, .qtype = .{ .dir = true } } } } });
    const root = try client.attach("glenda", ""); // fid 0
    try testing.expectEqual(@as(u32, 0), root.fid);

    try st.pushReply(.{ .tag = 1, .body = .rclunk });
    try client.clunk(root.fid);
    try testing.expect(!client.fids.contains(0));

    // The freed fid number is reused before a fresh one is minted.
    try testing.expectEqual(@as(u32, 0), client.allocFid());
}

test "client: beginRead pending then completes" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    var buf: [64]u8 = undefined;
    const ticket = try client.beginRead(7, 0, &buf); // tag 0
    try testing.expect(client.pending.contains(0));

    // No reply queued yet: the transport WouldBlocks, checkRead stays pending
    // (it must NOT pump/spin — the script is simply empty).
    try testing.expectEqual(@as(?usize, null), try client.checkRead(ticket));

    // The Tread we sent asked for min(64, msize-IOHDRSZ) == 64 bytes at offset 0.
    const sent = try st.sentMsg(1); // sent[0] was the Tversion
    try testing.expectEqual(msg.Kind.tread, sent.body.kind());
    try testing.expectEqual(@as(u32, 7), sent.body.tread.fid);
    try testing.expectEqual(@as(u32, 64), sent.body.tread.count);

    // Now the data arrives; checkRead drains it, copies into buf, and consumes.
    try st.pushReply(.{ .tag = 0, .body = .{ .rread = .{ .data = "mouse" } } });
    try testing.expectEqual(@as(?usize, 5), try client.checkRead(ticket));
    try testing.expectEqualStrings("mouse", buf[0..5]);
    try testing.expect(!client.pending.contains(0)); // consumed
}

test "client: out-of-order reply dispatched during rpc" {
    // THE crux (test 12): a standing read ticket's reply arrives interleaved with
    // a synchronous stat. rpc must dispatch the stray Rread to the ticket and keep
    // reading until its own Rstat — both operations succeed.
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    var buf: [64]u8 = undefined;
    const ticket = try client.beginRead(7, 0, &buf); // tag 0

    // Build a valid stat(5) blob for the Rstat reply (tag 1, stat's tag).
    var stat_bytes: [128]u8 = undefined;
    const sfile = stat_mod{ .qid = .{ .path = 5 }, .mode = 0, .length = 0, .name = "f" };
    const sn = try sfile.encode(&stat_bytes);

    // Scripted order: the ticket's Rread (tag 0) THEN the stat's Rstat (tag 1).
    try st.pushReply(.{ .tag = 0, .body = .{ .rread = .{ .data = "ev" } } });
    try st.pushReply(.{ .tag = 1, .body = .{ .rstat = .{ .stat = stat_bytes[0..sn] } } });

    // The synchronous stat absorbs the out-of-order Rread and still returns.
    const got = try client.stat(9);
    try testing.expectEqual(@as(u64, 5), got.qid.path);

    // The ticket completed as a side effect of the stat's dispatch loop.
    try testing.expectEqual(@as(?usize, 2), try client.checkRead(ticket));
    try testing.expectEqualStrings("ev", buf[0..2]);
}

test "client: cancelRead consumes interrupted-then-Rflush" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    var buf: [64]u8 = undefined;
    const ticket = try client.beginRead(7, 0, &buf); // tag 0

    // Server order for a still-parked read: Rerror "interrupted" on the OLD tag
    // (0), then Rflush on the flush's own tag (1).
    try st.pushReply(.{ .tag = 0, .body = .{ .rerror = .{ .ename = "interrupted" } } });
    try st.pushReply(.{ .tag = 1, .body = .rflush });
    try client.cancelRead(ticket);

    // The flush carried oldtag == the ticket's tag.
    const sent = try st.sentMsg(2); // Tversion(0), Tread(1), Tflush(2)
    try testing.expectEqual(msg.Kind.tflush, sent.body.kind());
    try testing.expectEqual(@as(u16, 0), sent.body.tflush.oldtag);

    // The ticket is consumed: polling it now is a protocol error (unknown tag).
    try testing.expect(!client.pending.contains(0));
    try testing.expectError(error.ProtocolError, client.checkRead(ticket));
}

test "client: cancelRead races completion" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    var buf: [64]u8 = undefined;
    const ticket = try client.beginRead(7, 0, &buf); // tag 0

    // Data raced ahead of the flush: Rread on the old tag (0) THEN Rflush (1).
    // cancelRead dispatches the Rread into the slot, then consumes+discards it.
    try st.pushReply(.{ .tag = 0, .body = .{ .rread = .{ .data = "late" } } });
    try st.pushReply(.{ .tag = 1, .body = .rflush });
    try client.cancelRead(ticket);

    try testing.expect(!client.pending.contains(0)); // consumed, data discarded
}

test "client: flushed ticket surfaces error.Interrupted via checkRead" {
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    var buf: [64]u8 = undefined;
    const ticket = try client.beginRead(7, 0, &buf); // tag 0

    // The server flushed this parked read (on behalf of some other actor): the
    // ticket's tag receives Rerror "interrupted", which checkRead surfaces.
    try st.pushReply(.{ .tag = 0, .body = .{ .rerror = .{ .ename = "interrupted" } } });
    try testing.expectError(error.Interrupted, client.checkRead(ticket));
    try testing.expect(!client.pending.contains(0)); // consumed
}

test "client: create/remove/wstat sync helpers (phase 14a)" {
    // Smoke only — T4 in the phase-14a contract §4 pins the pumped-pipe and
    // ticket paths.
    var st = ScriptedTransport.init(testing.allocator);
    defer st.deinit();
    var client = try Client.init(testing.allocator, st.endpoint(), 8192);
    defer client.deinit();
    try doVersion(&client, &st);

    const newq = Qid{ .path = 77, .vers = 1 };
    try st.pushReply(.{ .tag = 0, .body = .{ .rcreate = .{ .qid = newq, .iounit = 8168 } } });
    const res = try client.create(5, "made", 0o644, msg.OWRITE);
    try testing.expectEqual(@as(u64, 77), res.qid.path);
    try testing.expectEqual(@as(u32, 8168), res.iounit);
    const tc = (try st.sentMsg(1)).body.tcreate;
    try testing.expectEqual(@as(u32, 5), tc.fid);
    try testing.expectEqualStrings("made", tc.name);
    try testing.expectEqual(@as(u32, 0o644), tc.perm);
    try testing.expectEqual(@as(u8, msg.OWRITE), tc.mode);
    // The fid now names the new file (`5/open`), so the client's cache agrees.
    try testing.expectEqual(@as(u64, 77), client.fids.get(5).?.path);

    var want = stat_mod.dontTouch();
    want.name = "renamed";
    try st.pushReply(.{ .tag = 1, .body = .rwstat });
    try client.wstat(5, want);
    const tw = (try st.sentMsg(2)).body.twstat;
    try testing.expectEqual(@as(u32, 5), tw.fid);
    try testing.expectEqualStrings("renamed", (try stat_mod.decode(tw.stat)).name);

    try st.pushReply(.{ .tag = 2, .body = .rremove });
    try client.remove(5);
    try testing.expectEqual(@as(u32, 5), (try st.sentMsg(3)).body.tremove.fid);
    // `5/remove` clunks the fid even on error, so the number was recycled.
    try testing.expectEqual(@as(?Qid, null), client.fids.get(5));
    try testing.expectEqual(@as(u32, 5), client.allocFid());
}

// ==========================================================================
// T4 (phase-14a contract §4): the smoke test above only pins the wire shape
// against a `ScriptedTransport`, which never drives `Client.pump`. This pins
// `tickets.begin`/`check` decoding a REAL Tcreate/Tremove round trip, and
// `Client.create`/`remove`/`wstat` working over a genuinely pumped
// `chan.Pipe` + `server.Server` — the shape every real caller (nsjob, the
// served tree, tools/origin) actually uses.
// ==========================================================================
const chan = @import("chan.zig");
const server = @import("server.zig");

/// A minimal tree: root(1, dir) → "x"(2, file). `create` always mints path 3
/// and re-opens the fid on it; `remove`/`wstat` are no-op successes. Only the
/// WIRE is under test here — the per-check battery (open-fid, non-dir, bad
/// name, iounit default) is `server_mut.zig`'s T3.
const T4Tree = struct {
    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 } };
    }
    fn attachOp(_: *anyopaque, _: *server.Server, _: *server.Fid, _: []const u8) errors.OpError!Qid {
        return qidOf(1);
    }
    fn walk1Op(_: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) server.OpBlockError!Qid {
        if (fid.qid.path == 1 and std.mem.eql(u8, name, "x")) return qidOf(2);
        return error.FileDoesNotExist;
    }
    fn openOp(_: *anyopaque, _: *server.Server, fid: *server.Fid, _: u8) server.OpBlockError!Qid {
        return fid.qid;
    }
    fn readOp(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u64, _: []u8) server.ReadError!usize {
        return 0;
    }
    fn writeOp(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u64, data: []const u8) server.OpBlockError!usize {
        return data.len;
    }
    fn statOp(_: *anyopaque, _: *server.Server, fid: *server.Fid) server.OpBlockError!stat_mod {
        return .{ .qid = fid.qid, .mode = if (fid.qid.qtype.dir) stat_mod.DMDIR | 0o555 else 0o644, .length = 0, .name = "x" };
    }
    fn createOp(_: *anyopaque, _: *server.Server, _: *server.Fid, name: []const u8, _: u32, _: u8) server.OpBlockError!server.CreateResult {
        _ = name;
        return .{ .qid = qidOf(3) };
    }
    fn removeOp(_: *anyopaque, _: *server.Server, _: *server.Fid) server.OpBlockError!void {}
    fn wstatOp(_: *anyopaque, _: *server.Server, _: *server.Fid, _: stat_mod) server.OpBlockError!void {}

    const ops = server.Ops{
        .attach = attachOp,
        .walk1 = walk1Op,
        .open = openOp,
        .read = readOp,
        .write = writeOp,
        .stat = statOp,
        .create = createOp,
        .remove = removeOp,
        .wstat = wstatOp,
    };
};

fn t4Pump(ctx: *anyopaque) anyerror!void {
    const s: *server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "client: tickets decode Tcreate/Tremove replies, and create/remove/wstat work over a real pumped pipe (T4)" {
    const a = testing.allocator;
    var tree = T4Tree{};
    const pipe = try chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try server.Server.init(a, pipe.serverEnd(), &T4Tree.ops, &tree, 8192);
    defer srv.deinit();
    var cl = try Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = t4Pump };
    _ = try cl.version(8192);
    const root = try cl.attach("glenda", "");

    // --- ticket path: begin/check decode a real Tcreate/Tremove round trip.
    var buf1: [512]u8 = undefined;
    const t1 = try tickets.begin(&cl, .{ .tag = 0, .body = .{
        .tcreate = .{ .fid = root.fid, .name = "made", .perm = 0o644, .mode = msg.OWRITE },
    } }, &buf1);
    // Nothing has driven the server yet: `check` must not pump (R-P13a-3).
    try testing.expectEqual(@as(?Message, null), try tickets.check(&cl, t1));
    _ = try srv.poll();
    const r1 = (try tickets.check(&cl, t1)).?;
    try testing.expectEqual(msg.Kind.rcreate, r1.body.kind());
    try testing.expectEqual(@as(u64, 3), r1.body.rcreate.qid.path);

    var buf2: [512]u8 = undefined;
    const t2 = try tickets.begin(&cl, .{ .tag = 0, .body = .{
        .tremove = .{ .fid = root.fid },
    } }, &buf2);
    _ = try srv.poll();
    const r2 = (try tickets.check(&cl, t2)).?;
    try testing.expectEqual(msg.Kind.rremove, r2.body.kind());

    // --- sync helpers over the SAME real pumped server, a fresh fid.
    const root2 = try cl.attach("glenda", "");
    const cres = try cl.create(root2.fid, "made2", 0o644, msg.OWRITE);
    try testing.expectEqual(@as(u64, 3), cres.qid.path);
    try testing.expectEqual(@as(u64, 3), cl.fids.get(root2.fid).?.path);

    var want = stat_mod.dontTouch();
    want.name = "renamed2";
    try cl.wstat(root2.fid, want);

    try cl.remove(root2.fid);
    try testing.expectEqual(@as(?Qid, null), cl.fids.get(root2.fid));
}
