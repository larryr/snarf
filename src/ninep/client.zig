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

/// Drives the peer when the transport would block. `run` is invoked on every
/// transport `WouldBlock`, then the operation retries. With no pump a
/// `WouldBlock` surfaces to the caller instead (S-01 §3.2). `run` handles its
/// own errors; from the client's view pumping cannot fail.
pub const Pump = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

/// The client error set: typed 9P op errors (mapped from Rerror), plus the
/// transport's own errors, plus local failures.
pub const Error = errors.OpError || transport.Error || error{
    OutOfMemory,
    /// The reply violated the protocol: wrong tag, undecodable, or an
    /// unexpected message type for the request.
    ProtocolError,
    /// A frame would exceed the negotiated msize (on encode or on read).
    MessageTooBig,
};

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

/// Next tag, wrapping 0..0xFFFE and skipping NOTAG (0xFFFF). [S-01 §4]
fn allocTag(self: *Client) u16 {
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
pub fn rpc(self: *Client, t: Message) Error!Message {
    const limit = self.frameLimit();
    const n = msg.encode(&t, self.wbuf[0..limit]) catch |e| return switch (e) {
        error.ShortBuffer => error.MessageTooBig, // frame exceeds msize
        error.BadMessage => error.ProtocolError,
    };
    try self.writeFrame(self.wbuf[0..n]);
    const reply_bytes = try self.readFrame();

    const reply = msg.decode(reply_bytes) catch return error.ProtocolError;
    if (reply.tag != t.tag) return error.ProtocolError;
    if (reply.body == .rerror) return self.mapRerror(reply.body.rerror.ename);
    return reply;
}

/// Write a whole frame, pumping the peer on WouldBlock. FrameTooBig from the
/// transport means the frame exceeds what the peer will accept ⇒ MessageTooBig.
fn writeFrame(self: *Client, frame: []const u8) Error!void {
    while (true) {
        self.tport.writeMsg(frame) catch |e| switch (e) {
            error.WouldBlock => {
                if (self.pump) |p| {
                    p.run(p.ctx);
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
                    p.run(p.ctx);
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
/// stash the raw text (truncated to 128 bytes) BEFORE returning it.
fn mapRerror(self: *Client, ename: []const u8) Error {
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
/// error.FileDoesNotExist and the newfid number is recycled. `names.len == 0`
/// is a pure clone. [S-01 §4, `5/walk`]
pub fn walk(self: *Client, fid: u32, names: []const []const u8) Error!FidInfo {
    const newfid = self.allocFid();
    errdefer self.freeFid(newfid);

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

/// Max single-message payload: msize - IOHDRSZ.
fn ioMax(self: *const Client) usize {
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
pub fn stat(self: *Client, fid: u32) Error!stat_mod.Stat {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tstat = .{ .fid = fid },
    } });
    switch (reply.body) {
        .rstat => |r| return stat_mod.Stat.decode(r.stat) catch return error.ProtocolError,
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
