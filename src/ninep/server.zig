//! server.zig — a lib9p-shaped 9P2000 `Srv` framework.
//!
//! Port of plan9port's `src/lib9p/srv.c` dispatch loop, restructured for Zig:
//! the C library is callback-driven off a blocking `getreq`; ours is a
//! non-blocking `step()`/`poll()` pump over a `transport.Transport`. The file
//! server implements the `Ops` vtable (the moral equivalent of `Srv`'s
//! `attach`/`walk1`/`open`/... function pointers, 9p.h:180-207); this framework
//! owns the fid table, protocol state machine, and message (de)coding.
//!
//! Rulings applied (contract phase1-ninep §7):
//!   R4 — `Ops.stat` returns a decoded `stat.Stat`; we encode it via stat.zig.
//!   R5 — LIFTED by phase 14a: create/remove/wstat now have `Ops` fields and
//!        real handlers (`server_mut.zig`); only Tauth/Rauth are still answered
//!        from the `error.Unsupported` decode path (see handleUnsupported).
//!
//! Parking (R-P6-2/5, generalised by phase 14a to EVERY operation): an `Ops`
//! callback may answer `error.WouldBlock` ("I asked someone, ask me again
//! later") and the whole T-frame is filed on a FIFO with no reply sent until
//! `retryParked` re-dispatches it (or a Tflush/Tclunk/Tversion tears it down).
//! The mechanism lives in `park.zig`; this file only decides *when* to park.
//! It is the port of the deferred-flush machinery in `srv.c` (:245 sflush,
//! :751 respond, :862 deferred `or->flush[]`, :812-826 tag-reuse doc) and
//! flush(5).
//!
//! SIZE (S-07 §2): framing, session state, the fid table and the data path
//! (read/write/stat) live here; every handler that ESTABLISHES, RE-POINTS or
//! DESTROYS a fid (attach, walk, open, create, clunk, remove, wstat) is in
//! `server_mut.zig`, and the wait queue is `park.zig`. Same `Server` fields.
//!
//! Everything is std-only; no globals; the allocator is explicit (S-07 §6).
const std = @import("std");
const Qid = @import("qid.zig");
const msg = @import("msg.zig");
const stat = @import("stat.zig");
const errors = @import("errors.zig");
const transport = @import("transport.zig");
pub const park = @import("park.zig");
pub const server_mut = @import("server_mut.zig");

const OpError = errors.OpError;

/// The error sets a PARKABLE `Ops` callback may return: `errors.OpError`
/// widened with the park signal (`WouldBlock`, plus phase 6's `WouldBlockRead`
/// spelling for `read`). Neither block member is in `errors.OpError`, so
/// neither can ever become an Rerror string; the handlers peel them off. A
/// callback declared with the narrower `errors.OpError` coerces into these
/// slots unchanged, which is why no device server changed in phase 14a.
/// Re-exports, so callers name one module (see `park.zig`, `server_mut.zig`).
pub const ReadError = park.ReadError;
pub const OpBlockError = park.OpBlockError;
pub const Outcome = park.Outcome;
pub const max_parked = park.max_parked;
pub const CreateResult = server_mut.CreateResult;

/// A server-side fid: the client's handle onto a file. Mirrors `Fid` in
/// 9p.h:39-54 (fid number, current qid, open mode, per-fid aux pointer, owner).
/// A `*Fid` handed to an `Ops` callback is valid ONLY for that call; persist
/// anything you need across calls behind `ctx`.
pub const Fid = struct {
    fid: u32,
    qid: Qid,
    /// null == not open (C's `omode == -1`). Low 2 bits are the access mode
    /// with OEXEC normalized to OREAD (see handleOpen).
    omode: ?u8 = null,
    /// Opaque per-fid state owned by the `Ops` implementation.
    ctx: ?*anyopaque = null,
    /// Owning user name, allocated by the framework (freed on clunk / clear).
    uname: []u8,
};

/// The file-server callback table. Each fn takes `(ctx, srv, fid, ...)` where
/// `ctx` is the `Ops` implementation's own context (the `Server.ctx` pointer)
/// and returns `errors.OpError!...`. Optional slots (`?*const fn`) default to
/// null and are simply skipped. The PARKABLE slots are typed `OpBlockError`
/// (phase 14a) so an implementation may answer `error.WouldBlock`; one declared
/// with the narrower `errors.OpError` coerces in unchanged.
pub const Ops = struct {
    /// Bind the freshly-allocated `fid` to the tree root; return its qid.
    /// [srv.c:211 sattach]
    attach: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, aname: []const u8) OpError!Qid,
    /// Walk `fid` one component named `name`, mutating it to the child; return
    /// the child qid. [srv.c:143 oldwalk1 / walkandclone]
    walk1: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, name: []const u8) OpBlockError!Qid,
    /// Optional clone hook, called when a walk targets a distinct newfid, after
    /// `new.qid`/`new.ctx` have been seeded from the source. [srv.c:133 clone]
    clone: ?*const fn (ctx: *anyopaque, srv: *Server, old: *Fid, new: *Fid) OpError!void = null,
    /// Open `fid` with `mode`; return the qid to report in Ropen. [srv.c:361]
    open: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, mode: u8) OpBlockError!Qid,
    /// Read up to `buf.len` bytes at `offset` into `buf`; return count (0=EOF).
    /// May block (parked until `completeReads`/`retryParked`, R-P6-2).
    /// [srv.c:467 sread]
    read: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, buf: []u8) ReadError!usize,
    /// Write `data` at `offset`; return count accepted. [srv.c:513 swrite]
    write: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, data: []const u8) OpBlockError!usize,
    /// Optional clunk notification; the fid is removed unconditionally after.
    /// [srv.c:554 sclunk / :561 rclunk]
    clunk: ?*const fn (ctx: *anyopaque, srv: *Server, fid: *Fid) void = null,
    /// Return the directory entry for `fid` (R4). `stat.zig` is file-as-struct,
    /// so the `Stat` type is the module itself. [srv.c:601 sstat]
    stat: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid) OpBlockError!stat,
    /// Optional flush notification; the reply is always Rflush. [srv.c:245]
    flush: ?*const fn (ctx: *anyopaque, srv: *Server, oldtag: u16) void = null,
    /// Create `name` under the directory `fid` and open the RESULT as `fid`;
    /// `perm` includes DMDIR and is masked against the parent BY THE SERVER,
    /// which alone knows `dir.perm` (`5/open`). Absent ⇒ "create prohibited".
    /// [lib9p/srv.c:17 Enocreate]
    create: ?*const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, name: []const u8, perm: u32, mode: u8) OpBlockError!CreateResult = null,
    /// Remove the file `fid` names; the framework clunks `fid` afterwards
    /// whether this succeeds or not (`5/remove`). Absent ⇒ "remove prohibited".
    /// [lib9p/srv.c:20 Enoremove]
    remove: ?*const fn (ctx: *anyopaque, srv: *Server, fid: *Fid) OpBlockError!void = null,
    /// Apply the decoded `st` to `fid`; "don't touch" fields are `~0` / empty
    /// strings and must be left alone (`5/stat`). Absent ⇒ "wstat prohibited".
    /// [lib9p/srv.c:23 Enowstat]
    wstat: ?*const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, st: stat) OpBlockError!void = null,
};

/// One turn of the pump: whether `step` handled a frame or found none ready.
pub const Progress = enum { idle, handled };

/// Errors escaping the pump: transport failures plus allocator failure. A
/// read `WouldBlock` never escapes — it becomes `Progress.idle`.
pub const Error = transport.Error || std.mem.Allocator.Error;

/// A 9P2000 server bound to one transport. Not thread-safe; drive it from one
/// task via `step`/`poll`. [srv.c:691 srv()]
pub const Server = struct {
    allocator: std.mem.Allocator,
    tport: transport.Transport,
    ops: *const Ops,
    ctx: *anyopaque,
    fids: std.AutoHashMapUnmanaged(u32, Fid) = .empty,
    /// Negotiated message size; 0 means "no Tversion yet" (unversioned).
    msize: u32 = 0,
    max_msize: u32,
    rbuf: []u8,
    wbuf: []u8,
    /// FIFO of parked requests, in park order (R-P6-2, generalised; park.zig).
    parked: park.Queue = .{},
    /// Completion scratch for retried reads. A SEPARATE buffer, never
    /// `rbuf`: completions can fire from inside `Ops.write`, where `rbuf` still
    /// holds the in-flight Twrite's data (the aliasing trap, R-P6-5 / O11 D6).
    /// Allocated `max_msize` in `init`, freed in `deinit`.
    pbuf: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        tport: transport.Transport,
        ops: *const Ops,
        ctx: *anyopaque,
        max_msize: u32,
    ) Error!Server {
        std.debug.assert(max_msize >= msg.min_msize);
        const rbuf = try allocator.alloc(u8, max_msize);
        errdefer allocator.free(rbuf);
        const wbuf = try allocator.alloc(u8, max_msize);
        errdefer allocator.free(wbuf);
        const pbuf = try allocator.alloc(u8, max_msize);
        return .{
            .allocator = allocator,
            .tport = tport,
            .ops = ops,
            .ctx = ctx,
            .max_msize = max_msize,
            .rbuf = rbuf,
            .wbuf = wbuf,
            .pbuf = pbuf,
        };
    }

    pub fn deinit(self: *Server) void {
        self.clearFids();
        self.fids.deinit(self.allocator);
        self.parked.deinit(self.allocator);
        self.allocator.free(self.rbuf);
        self.allocator.free(self.wbuf);
        self.allocator.free(self.pbuf);
        self.* = undefined;
    }

    /// Look up a fid by number (null if absent). The pointer is valid until the
    /// next fid-table mutation.
    pub fn lookupFid(self: *Server, fid: u32) ?*Fid {
        return self.fids.getPtr(fid);
    }

    /// Read and fully handle at most one request frame. `WouldBlock` on the
    /// read becomes `.idle`; every other transport error propagates.
    pub fn step(self: *Server) Error!Progress {
        const frame = self.tport.readMsg(self.rbuf) catch |e| switch (e) {
            error.WouldBlock => return .idle,
            else => |other| return other,
        };
        try self.handleFrame(frame);
        return .handled;
    }

    /// Handle frames until the transport would block (or drains closed).
    /// Returns the number handled.
    pub fn poll(self: *Server) Error!usize {
        var n: usize = 0;
        while (true) {
            const p = self.step() catch |e| switch (e) {
                error.Closed => return n, // peer drained and closed
                else => |other| return other,
            };
            switch (p) {
                .idle => return n,
                .handled => n += 1,
            }
        }
    }

    // -- fid table helpers --------------------------------------------------

    fn clearFids(self: *Server) void {
        var it = self.fids.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.uname);
        self.fids.clearRetainingCapacity();
    }

    /// `pub` for `server_mut.zig` (attach/walk install fids).
    pub fn dupUname(self: *Server, s: []const u8) Error![]u8 {
        return self.allocator.dupe(u8, s);
    }

    // -- reply helpers ------------------------------------------------------

    /// Encode `m` into wbuf and hand the frame to the transport. The message
    /// is one we constructed and always fits within `max_msize`, so encoding
    /// cannot fail (a failure is a framework bug, hence `unreachable`).
    pub fn reply(self: *Server, m: msg.Message) Error!void {
        const n = msg.encode(&m, self.wbuf) catch unreachable;
        try self.tport.writeMsg(self.wbuf[0..n]);
    }

    /// Rerror with a raw string, for the handful of framework conditions that
    /// are not file errors and so have no `OpError` member (the parked-queue
    /// bound). `pub` for `park.zig` / `server_mut.zig`.
    pub fn replyRaw(self: *Server, tag: u16, ename: []const u8) Error!void {
        return self.reply(.{ .tag = tag, .body = .{ .rerror = .{ .ename = ename } } });
    }

    /// `pub` for `park.zig` / `server_mut.zig`.
    pub fn replyError(self: *Server, tag: u16, e: OpError) Error!void {
        return self.replyRaw(tag, errors.errorString(e));
    }

    /// `pub` for `server_mut.zig` (handleWalk lives there).
    pub fn replyWalk(self: *Server, tag: u16, qids: []const Qid) Error!void {
        return self.reply(.{ .tag = tag, .body = .{ .rwalk = msg.Body.Rwalk.init(qids) } });
    }

    // -- dispatch -----------------------------------------------------------

    fn handleFrame(self: *Server, frame: []const u8) Error!void {
        const m = msg.decode(frame) catch |e| switch (e) {
            // Tauth/Rauth, the last unimplemented pair (S-01 §2, OQ-9P-3):
            // answered by type byte, since decode stopped before the body.
            // [srv.c:187 sauth]
            error.Unsupported => return self.replyError(
                std.mem.readInt(u16, frame[5..7], .little),
                if (frame[4] == 102) error.AuthNotRequired else error.BadMessage,
            ),
            // Malformed: reply "bad message" if the tag survives, else drop.
            error.BadMessage => {
                if (frame.len >= msg.header_size) {
                    const tag = std.mem.readInt(u16, frame[5..7], .little);
                    return self.replyError(tag, error.BadMessage);
                }
                return; // too short to even recover a tag — drop silently
            },
        };
        const tag = m.tag;

        // Hardening (R-P6-5): a new T-message reusing a tag that is currently
        // parked (in-flight) is a protocol violation — reply "bad message" on
        // the new frame and leave the parked entry untouched. [srv.c:812-826
        // tag-reuse race] (parked is only ever non-empty post-version, so this
        // never shadows first-Tversion handling.)
        if (self.parked.has(tag)) return self.replyError(tag, error.BadMessage);

        // Tversion is the only message legal before (and illegal after) a
        // successful negotiation. [srv.c:166 sversion; R7 second-version]
        if (m.body == .tversion) {
            if (self.msize != 0) return self.replyError(tag, error.BadMessage);
            return self.handleVersion(tag, m.body.tversion);
        }
        if (self.msize == 0) return self.replyError(tag, error.BadMessage); // pre-version

        // The handler either answered or asked to be parked; on the latter we
        // file the WHOLE frame (R-P14a-2) and send nothing.
        if (try self.dispatchT(m, self.rbuf) == .blocked) {
            if (!try park.park(self, tag, frame)) {
                return self.replyRaw(tag, park.too_many_parked);
            }
        }
    }

    /// Dispatch one decoded T-message. `scratch` is the buffer a read's payload
    /// is built in: `rbuf` on the fresh path (the frame is already decoded and
    /// the reply encodes into `wbuf`), `pbuf` on the retry path, where `rbuf`
    /// may still alias an in-flight Twrite (R-P6-5 / O11 D6). `pub` for
    /// `park.zig`, which re-dispatches parked frames through it.
    pub fn dispatchT(self: *Server, m: msg.Message, scratch: []u8) Error!Outcome {
        const tag = m.tag;
        switch (m.body) {
            .tattach => |a| return server_mut.handleAttach(self, tag, a),
            .twalk => return server_mut.handleWalk(self, tag, m.body.twalk),
            .topen => |o| return server_mut.handleOpen(self, tag, o.fid, o.mode),
            .tread => |r| return self.handleRead(tag, r.fid, r.offset, r.count, scratch),
            .twrite => return self.handleWrite(tag, m.body.twrite),
            .tclunk => |c| return server_mut.handleClunk(self, tag, c.fid),
            .tflush => |fl| return self.handleFlush(tag, fl.oldtag),
            .tstat => |s| return self.handleStat(tag, s.fid),
            .tcreate => |c| return server_mut.handleCreate(self, tag, c),
            .tremove => |r| return server_mut.handleRemove(self, tag, r.fid),
            .twstat => |w| return server_mut.handleWstat(self, tag, w),
            // Any R-message (a response) is illegal arriving at a server.
            else => return self.replied(self.replyError(tag, error.BadMessage)),
        }
    }

    /// `Outcome.replied` sugar; `pub` for `server_mut.zig`.
    pub fn replied(_: *Server, r: Error!void) Error!Outcome {
        try r;
        return .replied;
    }

    // -- per-message handlers ----------------------------------------------

    /// [srv.c:166 sversion + :180 rversion/changemsize]
    fn handleVersion(self: *Server, tag: u16, v: msg.Body.Version) Error!void {
        self.clearFids(); // a new session aborts all outstanding fids
        self.parked.clear(self.allocator); // ...and discards parked requests SILENTLY (R-P6-5)
        const clamped: u32 = @min(v.msize, self.max_msize);
        if (!std.mem.startsWith(u8, v.version, msg.version9p)) {
            // Unknown dialect: stay unversioned, let the client retry.
            return self.reply(.{ .tag = tag, .body = .{ .rversion = .{ .msize = clamped, .version = "unknown" } } });
        }
        if (v.msize < msg.min_msize) return self.replyError(tag, error.BadMessage);
        self.msize = clamped; // guaranteed within [min_msize, max_msize]
        return self.reply(.{ .tag = tag, .body = .{ .rversion = .{ .msize = clamped, .version = msg.version9p } } });
    }

    /// [srv.c:467 sread]
    fn handleRead(self: *Server, tag: u16, fid: u32, offset: u64, count: u32, scratch: []u8) Error!Outcome {
        const fp = self.fids.getPtr(fid) orelse return self.replied(self.replyError(tag, error.UnknownFid));
        if (fp.omode == null or (fp.omode.? & 3) == msg.OWRITE) {
            return self.replied(self.replyError(tag, error.PermissionDenied));
        }
        const maxc = self.msize - msg.IOHDRSZ;
        const clamped: usize = @min(@as(usize, @min(count, maxc)), scratch.len);
        // `scratch` is rbuf on the fresh path (the incoming frame is already
        // fully decoded — Tread carries only scalars — and the reply encodes
        // into the *separate* wbuf) and pbuf on the retry path (R-P6-5/D6).
        const dst = scratch[0..clamped];
        const n = self.ops.read(self.ctx, self, fp, offset, dst) catch |e| switch (e) {
            // No data yet: park the frame and reply NOTHING now; `retryParked`
            // re-runs it when data arrives (R-P6-2).
            error.WouldBlock, error.WouldBlockRead => return .blocked,
            else => |oe| return self.replied(self.replyError(tag, oe)),
        };
        return self.replied(self.reply(.{ .tag = tag, .body = .{ .rread = .{ .data = scratch[0..n] } } }));
    }

    /// [srv.c:513 swrite]
    fn handleWrite(self: *Server, tag: u16, w: anytype) Error!Outcome {
        const fp = self.fids.getPtr(w.fid) orelse return self.replied(self.replyError(tag, error.UnknownFid));
        const base = if (fp.omode) |m| m & 3 else 0xFF;
        if (base != msg.OWRITE and base != msg.ORDWR) return self.replied(self.replyError(tag, error.PermissionDenied));
        const maxc = self.msize - msg.IOHDRSZ;
        var data = w.data;
        if (data.len > maxc) data = data[0..maxc];
        const n = self.ops.write(self.ctx, self, fp, w.offset, data) catch |e| switch (e) {
            error.WouldBlock, error.WouldBlockRead => return .blocked,
            else => |oe| return self.replied(self.replyError(tag, oe)),
        };
        return self.replied(self.reply(.{ .tag = tag, .body = .{ .rwrite = .{ .count = @intCast(n) } } }));
    }

    /// [srv.c:245 sflush] — if `oldtag` names a parked read, interrupt it FIRST
    /// (Rerror "interrupted" on the old tag), THEN send Rflush on the flush's
    /// own tag; this deferred ordering is mandated by flush(5) and mirrors
    /// srv.c's deferred `or->flush[]` list (:862 / :751 respond). With nothing
    /// parked under `oldtag` it is a plain Rflush (the idle case, test 4).
    fn handleFlush(self: *Server, tag: u16, oldtag: u16) Error!Outcome {
        if (self.ops.flush) |fl| fl(self.ctx, self, oldtag);
        _ = try park.flushTag(self, oldtag); // interrupted FIRST (if parked)
        return self.replied(self.reply(.{ .tag = tag, .body = .rflush })); // then Rflush
    }

    /// [srv.c:601 sstat + :626 rstat] — encode the Stat (R4) into a scratch
    /// buffer FIRST, then let `reply` memcpy it into wbuf (avoids the aliasing
    /// trap of building the blob inside wbuf). A Stat too large for the
    /// scratch degrades to an Rerror — device servers may return arbitrary
    /// strings and the framework must never trap on their size.
    fn handleStat(self: *Server, tag: u16, fid: u32) Error!Outcome {
        const fp = self.fids.getPtr(fid) orelse return self.replied(self.replyError(tag, error.UnknownFid));
        const st = self.ops.stat(self.ctx, self, fp) catch |e| switch (e) {
            error.WouldBlock, error.WouldBlockRead => return .blocked,
            else => |oe| return self.replied(self.replyError(tag, oe)),
        };
        var blob: [1024]u8 = undefined;
        const n = st.encode(&blob) catch |e| return self.replied(self.replyError(tag, switch (e) {
            error.ShortBuffer => error.IoError,
            error.BadMessage => error.BadMessage,
        }));
        return self.replied(self.reply(.{ .tag = tag, .body = .{ .rstat = .{ .stat = blob[0..n] } } }));
    }

    // -- wait queue (R-P6-2 / R-P6-5, generalised: see park.zig) -----------

    /// Number of requests currently parked. Test/adapter observability.
    pub fn parkedCount(self: *const Server) usize {
        return self.parked.count();
    }

    /// Re-dispatch EVERY parked request in park order; returns how many
    /// completed (phase 14a, contract §3b).
    pub fn retryParked(self: *Server) Error!usize {
        return park.retryParked(self);
    }

    /// Device/adapter signal (R-P6-3), UNCHANGED since phase 6: data MAY now
    /// exist on the file(s) whose `qid.path == path`; re-dispatch just those
    /// parked requests, in park order (a thin alias over the filtered retry,
    /// R-P14a-1). SAFE from inside `Ops.write`: retries read into `pbuf`.
    pub fn completeReads(self: *Server, path: u64) Error!usize {
        return park.retryParkedPath(self, path);
    }
};

// ===========================================================================
// Tests (§T-server) — 17 named cases.
//
// A private in-file TestTransport (two ArrayList frame queues) and a private
// TestTree fixture (contract §10, duplicated here) exercise the framework end
// to end via raw msg.encode frames. NO dependency on chan.zig or client.zig.
// ===========================================================================
const testing = std.testing;

/// The test harness (transport + contract §10 fixture tree) moved to
/// `testsrv.zig` in phase 14a; the aliases keep every test body unchanged.
const testsrv = @import("testsrv.zig");
const TestTransport = testsrv.TestTransport;
const TestTree = testsrv.TestTree;
const Fixture = testsrv.Fixture;

test "server: pre-version message rejected" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    // A Tattach before any Tversion ⇒ "bad message". [srv.c pre-version invariant]
    const r = try f.transact(.{ .tag = 7, .body = .{ .tattach = .{ .fid = 0, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
    try testing.expectEqual(@as(u16, 7), r.tag);
    try f.expectRerror(r, "bad message");
}

test "server: Tversion msize clamp" {
    // Four cases (fresh server each, since success is sticky).
    // (a) below the floor ⇒ "bad message".
    {
        const f = try Fixture.create(testing.allocator);
        defer f.destroy();
        const r = try f.transact(.{ .tag = 1, .body = .{ .tversion = .{ .msize = 4096, .version = msg.version9p } } });
        try f.expectRerror(r, "bad message");
    }
    // (b) exactly at the floor ⇒ echoed.
    {
        const f = try Fixture.create(testing.allocator);
        defer f.destroy();
        const r = try f.transact(.{ .tag = 1, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect(r.body == .rversion);
        try testing.expectEqual(@as(u32, 8192), r.body.rversion.msize);
        try testing.expectEqualStrings("9P2000", r.body.rversion.version);
    }
    // (c) above the ceiling ⇒ clamped down to max_msize (8192).
    {
        const f = try Fixture.create(testing.allocator);
        defer f.destroy();
        const r = try f.transact(.{ .tag = 1, .body = .{ .tversion = .{ .msize = 100000, .version = msg.version9p } } });
        try testing.expect(r.body == .rversion);
        try testing.expectEqual(@as(u32, 8192), r.body.rversion.msize);
    }
    // (d) unknown dialect ⇒ Rversion "unknown".
    {
        const f = try Fixture.create(testing.allocator);
        defer f.destroy();
        const r = try f.transact(.{ .tag = 1, .body = .{ .tversion = .{ .msize = 65536, .version = "9Punknown" } } });
        try testing.expect(r.body == .rversion);
        try testing.expectEqualStrings("unknown", r.body.rversion.version);
    }
}

test "server: second Tversion rejected" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    const r = try f.transact(.{ .tag = 2, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
    try f.expectRerror(r, "bad message");
}

test "server: attach root" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    const q = try f.doAttach(0);
    try testing.expectEqual(@as(u64, 1), q.path);
    try testing.expect(q.qtype.dir);
    try testing.expectEqual(@as(usize, 1), f.srv.fids.count());
}

test "server: attach dup fid" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    const r = try f.transact(.{ .tag = 3, .body = .{ .tattach = .{ .fid = 0, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
    try f.expectRerror(r, "fid in use");
}

test "server: walk existing" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    const r = try f.transact(.{ .tag = 4, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"index"}) } });
    try testing.expect(r.body == .rwalk);
    try testing.expectEqual(@as(u16, 1), r.body.rwalk.nwqid);
    try testing.expectEqual(@as(u64, 2), r.body.rwalk.qids()[0].path);
    try testing.expect(f.srv.lookupFid(1) != null);
}

test "server: walk missing" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    const r = try f.transact(.{ .tag = 5, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"nope"}) } });
    // First-name failure ⇒ Rerror, tentative newfid never installed.
    try f.expectRerror(r, "file does not exist");
    try testing.expect(f.srv.lookupFid(1) == null);
}

test "server: walk partial" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    // "sub" resolves (path 4), then "nope" fails ⇒ partial Rwalk of the first
    // qid only, with the tentative newfid discarded.
    const r = try f.transact(.{ .tag = 6, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{ "sub", "nope" }) } });
    try testing.expect(r.body == .rwalk);
    try testing.expectEqual(@as(u16, 1), r.body.rwalk.nwqid);
    try testing.expectEqual(@as(u64, 4), r.body.rwalk.qids()[0].path);
    try testing.expect(f.srv.lookupFid(1) == null);
}

test "server: walk unknown fid" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    const r = try f.transact(.{ .tag = 7, .body = .{ .twalk = msg.Body.Twalk.init(99, 1, &.{"index"}) } });
    try f.expectRerror(r, "unknown fid");
}

test "server: walk non-directory" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    // Reach a non-dir fid first, then try to walk beneath it.
    _ = try f.transact(.{ .tag = 8, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"index"}) } });
    const r = try f.transact(.{ .tag = 9, .body = .{ .twalk = msg.Body.Twalk.init(1, 2, &.{"x"}) } });
    try f.expectRerror(r, "walk in non-directory");
}

test "server: open read write clunk" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);

    // Read path: walk→open(OREAD)→read→clunk on the read-only "index".
    _ = try f.transact(.{ .tag = 10, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"index"}) } });
    const ro = try f.transact(.{ .tag = 11, .body = .{ .topen = .{ .fid = 1, .mode = msg.OREAD } } });
    try testing.expect(ro.body == .ropen);
    try testing.expectEqual(@as(u32, 0), ro.body.ropen.iounit);
    const rr = try f.transact(.{ .tag = 12, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 100 } } });
    try testing.expect(rr.body == .rread);
    try testing.expectEqualStrings("hello, snarf\n", rr.body.rread.data);
    const rc = try f.transact(.{ .tag = 13, .body = .{ .tclunk = .{ .fid = 1 } } });
    try testing.expect(rc.body == .rclunk);

    // Write path: walk→open(ORDWR)→write→read-back→clunk on "notes".
    _ = try f.transact(.{ .tag = 14, .body = .{ .twalk = msg.Body.Twalk.init(0, 2, &.{"notes"}) } });
    _ = try f.transact(.{ .tag = 15, .body = .{ .topen = .{ .fid = 2, .mode = msg.ORDWR } } });
    const rw = try f.transact(.{ .tag = 16, .body = .{ .twrite = .{ .fid = 2, .offset = 0, .data = "abc" } } });
    try testing.expect(rw.body == .rwrite);
    try testing.expectEqual(@as(u32, 3), rw.body.rwrite.count);
    const rb = try f.transact(.{ .tag = 17, .body = .{ .tread = .{ .fid = 2, .offset = 0, .count = 100 } } });
    try testing.expectEqualStrings("abc", rb.body.rread.data);
    _ = try f.transact(.{ .tag = 18, .body = .{ .tclunk = .{ .fid = 2 } } });
}

test "server: wrong-direction read" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    _ = try f.transact(.{ .tag = 20, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"notes"}) } });
    _ = try f.transact(.{ .tag = 21, .body = .{ .topen = .{ .fid = 1, .mode = msg.OWRITE } } });
    const r = try f.transact(.{ .tag = 22, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 10 } } });
    try f.expectRerror(r, "permission denied");
}

test "server: clunk frees fid for reuse" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    _ = try f.transact(.{ .tag = 30, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"index"}) } });
    _ = try f.transact(.{ .tag = 31, .body = .{ .tclunk = .{ .fid = 1 } } });
    try testing.expect(f.srv.lookupFid(1) == null);
    // fid 1 is free again: the same walk now succeeds.
    const r = try f.transact(.{ .tag = 32, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"index"}) } });
    try testing.expect(r.body == .rwalk);
    try testing.expect(f.srv.lookupFid(1) != null);
}

test "server: unknown fid read" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    const r = try f.transact(.{ .tag = 40, .body = .{ .tread = .{ .fid = 99, .offset = 0, .count = 10 } } });
    try f.expectRerror(r, "unknown fid");
}

test "server: flush idle returns Rflush" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    const r = try f.transact(.{ .tag = 50, .body = .{ .tflush = .{ .oldtag = 12345 } } });
    try testing.expect(r.body == .rflush);
    try testing.expectEqual(@as(u16, 50), r.tag);
}

test "server: tauth/tcreate/tremove/twstat defaults" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    // Tauth: a 7-byte header-only frame; decode returns Unsupported before any
    // body parse, so the framework answers purely by type byte (R5 remnant —
    // auth is the last unimplemented pair, S-01 §2 / OQ-9P-3).
    var aframe: [7]u8 = undefined;
    std.mem.writeInt(u32, aframe[0..4], 7, .little);
    aframe[4] = 102;
    std.mem.writeInt(u16, aframe[5..7], 77, .little);
    const ra = try f.transactRaw(&aframe);
    try testing.expectEqual(@as(u16, 77), ra.tag);
    try f.expectRerror(ra, "authentication not required");
    // create/remove/wstat now DECODE (phase 14a lifted ruling R5); with no
    // `Ops` slot bound the framework answers lib9p's refusal strings
    // [lib9p/srv.c:17,20,23 Enocreate/Enoremove/Enowstat].
    // fid 0 is the attached root: a directory, unopened — so each refusal is
    // reached past every fid check lib9p makes first (srv.c:383/573/644).
    const rc = try f.transact(.{ .tag = 77, .body = .{ .tcreate = .{ .fid = 0, .name = "x", .perm = 0o644, .mode = msg.OWRITE } } });
    try testing.expectEqual(@as(u16, 77), rc.tag);
    try f.expectRerror(rc, server_mut.create_prohibited);

    var blob: [64]u8 = undefined;
    const nst = try (stat{ .qid = .{ .path = ~@as(u64, 0), .vers = 0xFFFF_FFFF, .qtype = @bitCast(@as(u8, 0xFF)) }, .ktype = 0xFFFF, .kdev = 0xFFFF_FFFF, .mode = 0xFFFF_FFFF, .atime = 0xFFFF_FFFF, .mtime = 0xFFFF_FFFF, .length = ~@as(u64, 0), .name = "", .uid = "", .gid = "", .muid = "" }).encode(&blob);
    const rw = try f.transact(.{ .tag = 77, .body = .{ .twstat = .{ .fid = 0, .stat = blob[0..nst] } } });
    try f.expectRerror(rw, server_mut.wstat_prohibited);

    // Tremove is a clunk with a side effect: the fid is gone even though the
    // remove itself was refused (`5/remove`, R-P14a-3).
    const rr = try f.transact(.{ .tag = 77, .body = .{ .tremove = .{ .fid = 0 } } });
    try f.expectRerror(rr, server_mut.remove_prohibited);
    const after = try f.transact(.{ .tag = 78, .body = .{ .tstat = .{ .fid = 0 } } });
    try f.expectRerror(after, "unknown fid");
}

test "server: stat name and length" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy();
    try f.doVersion();
    _ = try f.doAttach(0);
    _ = try f.transact(.{ .tag = 60, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"index"}) } });
    const r = try f.transact(.{ .tag = 61, .body = .{ .tstat = .{ .fid = 1 } } });
    try testing.expect(r.body == .rstat);
    const st = try stat.decode(r.body.rstat.stat);
    try testing.expectEqualStrings("index", st.name);
    try testing.expectEqual(@as(u64, 13), st.length);
    try testing.expectEqual(@as(u64, 2), st.qid.path);
}

test "server: oversized stat degrades to Rerror" {
    // Wave C regression: Ops.stat may return a Stat whose strings exceed the
    // encode scratch (device servers control those strings). The framework
    // must answer Rerror "i/o error", never trap.
    const Big = struct {
        fn attachOp(_: *anyopaque, _: *Server, _: *Fid, _: []const u8) OpError!Qid {
            return .{ .path = 1, .qtype = .{ .dir = true } };
        }
        fn walk1Op(_: *anyopaque, _: *Server, _: *Fid, _: []const u8) OpError!Qid {
            return error.FileDoesNotExist;
        }
        fn openOp(_: *anyopaque, _: *Server, _: *Fid, _: u8) OpError!Qid {
            return error.PermissionDenied;
        }
        fn readOp(_: *anyopaque, _: *Server, _: *Fid, _: u64, _: []u8) OpError!usize {
            return error.PermissionDenied;
        }
        fn writeOp(_: *anyopaque, _: *Server, _: *Fid, _: u64, _: []const u8) OpError!usize {
            return error.PermissionDenied;
        }
        fn statOp(_: *anyopaque, _: *Server, _: *Fid) OpError!stat {
            return .{
                .qid = .{ .path = 1, .qtype = .{ .dir = true } },
                .mode = stat.DMDIR,
                .length = 0,
                .name = "x" ** 1200, // encodedSize 1249 > the 1024 scratch
            };
        }
        const ops = Ops{
            .attach = attachOp,
            .walk1 = walk1Op,
            .open = openOp,
            .read = readOp,
            .write = writeOp,
            .stat = statOp,
        };
    };

    var tt = TestTransport{ .alloc = testing.allocator };
    defer tt.deinit();
    var dummy: u8 = 0;
    var srv = try Server.init(testing.allocator, tt.asTransport(), &Big.ops, &dummy, 8192);
    defer srv.deinit();

    var enc: [512]u8 = undefined;
    var rbuf: [512]u8 = undefined;
    const steps = [_]msg.Message{
        .{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } },
        .{ .tag = 1, .body = .{ .tattach = .{ .fid = 0, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } },
        .{ .tag = 2, .body = .{ .tstat = .{ .fid = 0 } } },
    };
    var last: msg.Message = undefined;
    for (steps) |m| {
        const n = try msg.encode(&m, &enc);
        try tt.pushReq(enc[0..n]);
        _ = try srv.step();
        const reply = tt.popReply() orelse return error.NoReply;
        defer testing.allocator.free(reply);
        @memcpy(rbuf[0..reply.len], reply);
        last = try msg.decode(rbuf[0..reply.len]);
    }
    try testing.expect(last.body == .rerror);
    try testing.expectEqualStrings("i/o error", last.body.rerror.ename);
}

// ===========================================================================
// Phase-6 wait-queue tests (contract phase6-input-ninep §A1, tests 1-10; test
// 4 is "flush idle" above, retained). A `BlockTree` with injectable per-file
// byte queues: `read` drains its file's queue or returns `WouldBlockRead`;
// `ctl` write drives test 10's completion-from-inside-Ops.write path.
// ===========================================================================

/// Blocking tree: root(1) dir → { a(2), b(3): stream files whose `read` parks
/// when their queue is empty; ctl(4): writable, drives completeReads (test 10) }.
const BlockTree = struct {
    alloc: std.mem.Allocator,
    qa: std.ArrayList(u8) = .empty, // path 2 "a"
    qb: std.ArrayList(u8) = .empty, // path 3 "b"
    last_write: std.ArrayList(u8) = .empty, // ctl write payload, recorded AFTER completion (D6)

    /// A 40-byte completion payload for test 10 — longer than a Twrite header
    /// (23 bytes) so, had completeReads read into `rbuf`, it would clobber the
    /// in-flight Twrite's `data` region (rbuf[23..]) and corrupt `last_write`.
    const completion_payload = "A" ** 40;

    fn deinit(self: *BlockTree) void {
        self.qa.deinit(self.alloc);
        self.qb.deinit(self.alloc);
        self.last_write.deinit(self.alloc);
    }

    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 } };
    }

    fn queueFor(self: *BlockTree, path: u64) ?*std.ArrayList(u8) {
        return switch (path) {
            2 => &self.qa,
            3 => &self.qb,
            else => null,
        };
    }

    fn attachOp(_: *anyopaque, _: *Server, _: *Fid, _: []const u8) OpError!Qid {
        return BlockTree.qidOf(1);
    }
    fn walk1Op(_: *anyopaque, _: *Server, fid: *Fid, name: []const u8) OpError!Qid {
        const eq = std.mem.eql;
        if (fid.qid.path != 1) return error.WalkNoDir;
        if (eq(u8, name, "a")) return BlockTree.qidOf(2);
        if (eq(u8, name, "b")) return BlockTree.qidOf(3);
        if (eq(u8, name, "ctl")) return BlockTree.qidOf(4);
        return error.FileDoesNotExist;
    }
    fn openOp(_: *anyopaque, _: *Server, fid: *Fid, _: u8) OpError!Qid {
        return fid.qid;
    }
    /// Stream read: drain the file's queue, or park (WouldBlockRead) if empty.
    fn readOp(ctx: *anyopaque, _: *Server, fid: *Fid, _: u64, buf: []u8) ReadError!usize {
        const self: *BlockTree = @ptrCast(@alignCast(ctx));
        const q = self.queueFor(fid.qid.path) orelse return 0; // ctl / dir: EOF
        if (q.items.len == 0) return error.WouldBlockRead;
        const n = @min(q.items.len, buf.len);
        @memcpy(buf[0..n], q.items[0..n]);
        std.mem.copyForwards(u8, q.items[0 .. q.items.len - n], q.items[n..]); // consume front n
        q.shrinkRetainingCapacity(q.items.len - n);
        return n;
    }
    /// ctl write (test 10): inject a completion payload for "a" that DIFFERS
    /// from `data`, complete the parked read (reads into pbuf), THEN record
    /// `data` — which aliases rbuf. Correct pbuf isolation ⇒ `last_write`
    /// equals `data`; an rbuf-aliased completion would corrupt it (D6).
    fn writeOp(ctx: *anyopaque, srv: *Server, fid: *Fid, _: u64, data: []const u8) OpError!usize {
        const self: *BlockTree = @ptrCast(@alignCast(ctx));
        if (fid.qid.path != 4) return error.PermissionDenied; // only ctl is writable
        self.qa.appendSlice(self.alloc, completion_payload) catch return error.IoError;
        _ = srv.completeReads(2) catch return error.IoError;
        self.last_write.appendSlice(self.alloc, data) catch return error.IoError;
        return data.len;
    }
    fn statOp(ctx: *anyopaque, _: *Server, fid: *Fid) OpError!stat {
        _ = ctx;
        const path = fid.qid.path;
        return .{
            .qid = BlockTree.qidOf(path),
            .mode = if (path == 1) (stat.DMDIR | 0o555) else 0o666,
            .length = 0,
            .name = "f",
        };
    }
    const ops = Ops{
        .attach = attachOp,
        .walk1 = walk1Op,
        .open = openOp,
        .read = readOp,
        .write = writeOp,
        .stat = statOp,
    };
};

/// Heap-pinned harness around a `BlockTree`, mirroring `Fixture` but with
/// lower-level `feed`/`popMsg` primitives (a parked read yields no reply).
const BlockFixture = struct {
    alloc: std.mem.Allocator,
    tt: TestTransport,
    tree: BlockTree,
    srv: Server,
    rbuf: [8192]u8 = undefined,

    fn create(alloc: std.mem.Allocator) !*BlockFixture {
        const self = try alloc.create(BlockFixture);
        self.alloc = alloc;
        self.tt = .{ .alloc = alloc };
        self.tree = .{ .alloc = alloc };
        self.srv = try Server.init(alloc, self.tt.asTransport(), &BlockTree.ops, &self.tree, 8192);
        return self;
    }

    fn destroy(self: *BlockFixture) void {
        self.srv.deinit();
        self.tree.deinit();
        self.tt.deinit();
        self.alloc.destroy(self);
    }

    /// Encode `m` and let the server handle it; DO NOT expect a reply.
    fn feed(self: *BlockFixture, m: msg.Message) !void {
        var enc: [8192]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        try self.tt.pushReq(enc[0..n]);
        _ = try self.srv.step();
    }

    /// Pop the next reply frame (decoded into `self.rbuf`), or null if none.
    fn popMsg(self: *BlockFixture) !?msg.Message {
        const reply = self.tt.popReply() orelse return null;
        defer self.alloc.free(reply);
        @memcpy(self.rbuf[0..reply.len], reply);
        return try msg.decode(self.rbuf[0..reply.len]);
    }

    fn setup(self: *BlockFixture) !void {
        try self.feed(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect((try self.popMsg()).?.body == .rversion);
        try self.feed(.{ .tag = 1, .body = .{ .tattach = .{ .fid = 0, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
        try testing.expect((try self.popMsg()).?.body == .rattach);
    }

    /// Walk root→`newfid` by `name`, then open with `mode`.
    fn walkOpen(self: *BlockFixture, newfid: u32, name: []const u8, mode: u8) !void {
        try self.feed(.{ .tag = 900, .body = .{ .twalk = msg.Body.Twalk.init(0, newfid, &.{name}) } });
        try testing.expect((try self.popMsg()).?.body == .rwalk);
        try self.feed(.{ .tag = 901, .body = .{ .topen = .{ .fid = newfid, .mode = mode } } });
        try testing.expect((try self.popMsg()).?.body == .ropen);
    }

    fn inject(self: *BlockFixture, path: u64, bytes: []const u8) !void {
        try self.tree.queueFor(path).?.appendSlice(self.alloc, bytes);
    }
};

test "server: park and complete round trip" {
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);

    // Read with an empty queue ⇒ parked, NO reply.
    try f.feed(.{ .tag = 70, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 100 } } });
    try testing.expect((try f.popMsg()) == null);
    try testing.expectEqual(@as(usize, 1), f.srv.parkedCount());

    // Data arrives; the adapter signals the qid.path.
    try f.inject(2, "hello");
    try testing.expectEqual(@as(usize, 1), try f.srv.completeReads(2));
    const r = (try f.popMsg()).?;
    try testing.expect(r.body == .rread);
    try testing.expectEqual(@as(u16, 70), r.tag);
    try testing.expectEqualStrings("hello", r.body.rread.data);
    try testing.expectEqual(@as(usize, 0), f.srv.parkedCount());
}

test "server: flush interrupts parked read" {
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);
    try f.feed(.{ .tag = 77, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 100 } } });
    try testing.expectEqual(@as(usize, 1), f.srv.parkedCount());

    // Flush the parked tag: exactly two frames IN ORDER — Rerror "interrupted"
    // on the OLD tag first, then Rflush on the flush's tag.
    try f.feed(.{ .tag = 88, .body = .{ .tflush = .{ .oldtag = 77 } } });
    const e = (try f.popMsg()).?;
    try testing.expect(e.body == .rerror);
    try testing.expectEqual(@as(u16, 77), e.tag);
    try testing.expectEqualStrings("interrupted", e.body.rerror.ename);
    const fl = (try f.popMsg()).?;
    try testing.expect(fl.body == .rflush);
    try testing.expectEqual(@as(u16, 88), fl.tag);
    try testing.expect((try f.popMsg()) == null);
    try testing.expectEqual(@as(usize, 0), f.srv.parkedCount());

    // The read is gone: a later completion sends nothing.
    try f.inject(2, "late");
    try testing.expectEqual(@as(usize, 0), try f.srv.completeReads(2));
    try testing.expect((try f.popMsg()) == null);
}

test "server: flush of completed tag is plain Rflush" {
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);
    try f.feed(.{ .tag = 33, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 100 } } });
    try f.inject(2, "done");
    _ = try f.srv.completeReads(2);
    try testing.expect((try f.popMsg()).?.body == .rread); // consume the completion

    // Flushing an already-completed (unknown) tag ⇒ a single plain Rflush.
    try f.feed(.{ .tag = 90, .body = .{ .tflush = .{ .oldtag = 33 } } });
    const fl = (try f.popMsg()).?;
    try testing.expect(fl.body == .rflush);
    try testing.expectEqual(@as(u16, 90), fl.tag);
    try testing.expect((try f.popMsg()) == null);
}

test "server: clunk with parked reads interrupts then Rclunk" {
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);
    // Two reads parked on the same fid, in park order T1=41, T2=42.
    try f.feed(.{ .tag = 41, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });
    try f.feed(.{ .tag = 42, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });
    try testing.expectEqual(@as(usize, 2), f.srv.parkedCount());

    try f.feed(.{ .tag = 43, .body = .{ .tclunk = .{ .fid = 1 } } });
    // Interrupts in park order, THEN Rclunk.
    const e1 = (try f.popMsg()).?;
    try testing.expect(e1.body == .rerror);
    try testing.expectEqual(@as(u16, 41), e1.tag);
    try testing.expectEqualStrings("interrupted", e1.body.rerror.ename);
    const e2 = (try f.popMsg()).?;
    try testing.expect(e2.body == .rerror);
    try testing.expectEqual(@as(u16, 42), e2.tag);
    const rc = (try f.popMsg()).?;
    try testing.expect(rc.body == .rclunk);
    try testing.expectEqual(@as(u16, 43), rc.tag);
    try testing.expectEqual(@as(usize, 0), f.srv.parkedCount());
}

test "server: multiple parked tags on one file complete in park order" {
    // Variant (a): one fid, two tags.
    {
        const f = try BlockFixture.create(testing.allocator);
        defer f.destroy();
        try f.setup();
        try f.walkOpen(1, "a", msg.OREAD);
        try f.feed(.{ .tag = 11, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });
        try f.feed(.{ .tag = 12, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });
        try f.inject(2, "AB"); // one byte each, in order
        try testing.expectEqual(@as(usize, 2), try f.srv.completeReads(2));
        const r1 = (try f.popMsg()).?;
        try testing.expectEqual(@as(u16, 11), r1.tag);
        try testing.expectEqualStrings("A", r1.body.rread.data);
        const r2 = (try f.popMsg()).?;
        try testing.expectEqual(@as(u16, 12), r2.tag);
        try testing.expectEqualStrings("B", r2.body.rread.data);
        try testing.expectEqual(@as(usize, 0), f.srv.parkedCount());
    }
    // Variant (b): two fids on the same file, park order preserved.
    {
        const f = try BlockFixture.create(testing.allocator);
        defer f.destroy();
        try f.setup();
        try f.walkOpen(1, "a", msg.OREAD);
        try f.walkOpen(2, "a", msg.OREAD);
        try f.feed(.{ .tag = 21, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });
        try f.feed(.{ .tag = 22, .body = .{ .tread = .{ .fid = 2, .offset = 0, .count = 1 } } });
        try f.inject(2, "AB");
        try testing.expectEqual(@as(usize, 2), try f.srv.completeReads(2));
        const r1 = (try f.popMsg()).?;
        try testing.expectEqual(@as(u16, 21), r1.tag);
        try testing.expectEqualStrings("A", r1.body.rread.data);
        const r2 = (try f.popMsg()).?;
        try testing.expectEqual(@as(u16, 22), r2.tag);
        try testing.expectEqualStrings("B", r2.body.rread.data);
    }
}

test "server: partial completion leaves remainder parked" {
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);
    try f.feed(.{ .tag = 51, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });
    try f.feed(.{ .tag = 52, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });

    // Only enough data for the first parked read; the second re-parks.
    try f.inject(2, "A");
    try testing.expectEqual(@as(usize, 1), try f.srv.completeReads(2));
    const r1 = (try f.popMsg()).?;
    try testing.expectEqual(@as(u16, 51), r1.tag);
    try testing.expectEqualStrings("A", r1.body.rread.data);
    try testing.expect((try f.popMsg()) == null);
    try testing.expectEqual(@as(usize, 1), f.srv.parkedCount());

    // Remainder arrives ⇒ the second completes.
    try f.inject(2, "B");
    try testing.expectEqual(@as(usize, 1), try f.srv.completeReads(2));
    const r2 = (try f.popMsg()).?;
    try testing.expectEqual(@as(u16, 52), r2.tag);
    try testing.expectEqualStrings("B", r2.body.rread.data);
    try testing.expectEqual(@as(usize, 0), f.srv.parkedCount());
}

test "server: version reset silently discards parked" {
    // A fresh (pre-version) server with parked entries preloaded (white-box:
    // the wire cannot park before a version, and a second Tversion is rejected
    // as "bad message" — R7 — so this pins handleVersion's parked-clear line
    // directly): a first Tversion must reply ONLY Rversion and clear the queue.
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    // Phase 14a: a parked entry is now the raw T-frame (R-P14a-2), so the
    // preload encodes the two Treads it used to spell as {tag,fid,offset,count}.
    var pre: [64]u8 = undefined;
    for ([_]struct { tag: u16, fid: u32 }{ .{ .tag = 10, .fid = 1 }, .{ .tag = 11, .fid = 2 } }) |x| {
        const n = try msg.encode(&.{ .tag = x.tag, .body = .{ .tread = .{ .fid = x.fid, .offset = 0, .count = 4 } } }, &pre);
        try testing.expect(try f.srv.parked.append(testing.allocator, x.tag, pre[0..n]));
    }
    try testing.expectEqual(@as(usize, 2), f.srv.parkedCount());

    try f.feed(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
    const r = (try f.popMsg()).?;
    try testing.expect(r.body == .rversion);
    try testing.expect((try f.popMsg()) == null); // no interrupt frames
    try testing.expectEqual(@as(usize, 0), f.srv.parkedCount());
}

test "server: duplicate tag while parked rejected" {
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);
    try f.feed(.{ .tag = 55, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 100 } } });
    try testing.expectEqual(@as(usize, 1), f.srv.parkedCount());

    // A new T-message reusing the in-flight tag ⇒ "bad message"; parked untouched.
    try f.feed(.{ .tag = 55, .body = .{ .tstat = .{ .fid = 1 } } });
    const r = (try f.popMsg()).?;
    try testing.expect(r.body == .rerror);
    try testing.expectEqual(@as(u16, 55), r.tag);
    try testing.expectEqualStrings("bad message", r.body.rerror.ename);
    try testing.expectEqual(@as(usize, 1), f.srv.parkedCount());
}

test "server: completeReads from inside Ops.write does not corrupt the write" {
    // D6: a completion fired from within Ops.write must read into pbuf, never
    // rbuf (which still holds the in-flight Twrite's data). The ctl write
    // injects a 40-byte completion payload for "a", completes the parked read,
    // then records the Twrite's rbuf-aliased `data`; if pbuf==rbuf, `data`
    // would be clobbered.
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);
    try f.walkOpen(2, "ctl", msg.ORDWR);

    try f.feed(.{ .tag = 71, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 100 } } });
    try testing.expectEqual(@as(usize, 1), f.srv.parkedCount());

    // ctl write triggers the completion mid-write.
    try f.feed(.{ .tag = 72, .body = .{ .twrite = .{ .fid = 2, .offset = 0, .data = "trigger" } } });

    // Reply order: the completion's Rread(71) precedes the Rwrite(72).
    const rr = (try f.popMsg()).?;
    try testing.expect(rr.body == .rread);
    try testing.expectEqual(@as(u16, 71), rr.tag);
    try testing.expectEqualStrings(BlockTree.completion_payload, rr.body.rread.data);
    const rw = (try f.popMsg()).?;
    try testing.expect(rw.body == .rwrite);
    try testing.expectEqual(@as(u32, 7), rw.body.rwrite.count);

    // The write data survived intact (validated AFTER the in-write completion).
    try testing.expectEqualStrings("trigger", f.tree.last_write.items);
    try testing.expectEqual(@as(usize, 0), f.srv.parkedCount());
}

test "server: retryParked is completeReads without the path filter" {
    // Phase 14a smoke (R-P14a-1): the same parked read completes identically
    // through either entry point. The named battery is contract §4 T5-T10.
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);

    try f.feed(.{ .tag = 61, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 100 } } });
    try testing.expectEqual(@as(usize, 1), f.srv.parkedCount());
    // A path filter that matches nothing leaves it parked; so does an empty queue.
    try testing.expectEqual(@as(usize, 0), try f.srv.completeReads(3));
    try testing.expectEqual(@as(usize, 0), try f.srv.retryParked());
    try testing.expectEqual(@as(usize, 1), f.srv.parkedCount());

    try f.inject(2, "xyz");
    try testing.expectEqual(@as(usize, 1), try f.srv.retryParked());
    const r = (try f.popMsg()).?;
    try testing.expectEqual(@as(u16, 61), r.tag);
    try testing.expectEqualStrings("xyz", r.body.rread.data);
    try testing.expectEqual(@as(usize, 0), f.srv.parkedCount());
}

test "server: the parked queue is bounded" {
    const f = try BlockFixture.create(testing.allocator);
    defer f.destroy();
    try f.setup();
    try f.walkOpen(1, "a", msg.OREAD);
    var t: u16 = 0;
    while (t < park.max_parked) : (t += 1) {
        try f.feed(.{ .tag = t, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });
    }
    try testing.expectEqual(park.max_parked, f.srv.parkedCount());
    try testing.expect((try f.popMsg()) == null);

    // One too many ⇒ refused on the spot, queue unchanged.
    try f.feed(.{ .tag = 999, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 1 } } });
    const r = (try f.popMsg()).?;
    try testing.expectEqual(@as(u16, 999), r.tag);
    try testing.expectEqualStrings(park.too_many_parked, r.body.rerror.ename);
    try testing.expectEqual(park.max_parked, f.srv.parkedCount());
}
