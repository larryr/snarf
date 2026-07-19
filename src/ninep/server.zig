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
//!   R5 — create/remove/wstat/auth have no `Ops` fields; those type codes are
//!        answered from the `error.Unsupported` decode path (see handleUnsupported).
//!
//! Everything is std-only; no globals; the allocator is explicit (S-07 §6).
const std = @import("std");
const Qid = @import("qid.zig");
const msg = @import("msg.zig");
const stat = @import("stat.zig");
const errors = @import("errors.zig");
const transport = @import("transport.zig");

const OpError = errors.OpError;

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
/// null and are simply skipped. No create/remove/wstat (R5).
pub const Ops = struct {
    /// Bind the freshly-allocated `fid` to the tree root; return its qid.
    /// [srv.c:211 sattach]
    attach: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, aname: []const u8) OpError!Qid,
    /// Walk `fid` one component named `name`, mutating it to the child; return
    /// the child qid. [srv.c:143 oldwalk1 / walkandclone]
    walk1: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, name: []const u8) OpError!Qid,
    /// Optional clone hook, called when a walk targets a distinct newfid, after
    /// `new.qid`/`new.ctx` have been seeded from the source. [srv.c:133 clone]
    clone: ?*const fn (ctx: *anyopaque, srv: *Server, old: *Fid, new: *Fid) OpError!void = null,
    /// Open `fid` with `mode`; return the qid to report in Ropen. [srv.c:361]
    open: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, mode: u8) OpError!Qid,
    /// Read up to `buf.len` bytes at `offset` into `buf`; return count (0=EOF).
    /// [srv.c:467 sread]
    read: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, buf: []u8) OpError!usize,
    /// Write `data` at `offset`; return count accepted. [srv.c:513 swrite]
    write: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, data: []const u8) OpError!usize,
    /// Optional clunk notification; the fid is removed unconditionally after.
    /// [srv.c:554 sclunk / :561 rclunk]
    clunk: ?*const fn (ctx: *anyopaque, srv: *Server, fid: *Fid) void = null,
    /// Return the directory entry for `fid` (R4). `stat.zig` is file-as-struct,
    /// so the `Stat` type is the module itself. [srv.c:601 sstat]
    stat: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid) OpError!stat,
    /// Optional flush notification; the reply is always Rflush. [srv.c:245]
    flush: ?*const fn (ctx: *anyopaque, srv: *Server, oldtag: u16) void = null,
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
        return .{
            .allocator = allocator,
            .tport = tport,
            .ops = ops,
            .ctx = ctx,
            .max_msize = max_msize,
            .rbuf = rbuf,
            .wbuf = wbuf,
        };
    }

    pub fn deinit(self: *Server) void {
        self.clearFids();
        self.fids.deinit(self.allocator);
        self.allocator.free(self.rbuf);
        self.allocator.free(self.wbuf);
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

    fn dupUname(self: *Server, s: []const u8) Error![]u8 {
        return self.allocator.dupe(u8, s);
    }

    // -- reply helpers ------------------------------------------------------

    /// Encode `m` into wbuf and hand the frame to the transport. The message
    /// is one we constructed and always fits within `max_msize`, so encoding
    /// cannot fail (a failure is a framework bug, hence `unreachable`).
    fn reply(self: *Server, m: msg.Message) Error!void {
        const n = msg.encode(&m, self.wbuf) catch unreachable;
        try self.tport.writeMsg(self.wbuf[0..n]);
    }

    fn replyError(self: *Server, tag: u16, e: OpError) Error!void {
        return self.reply(.{ .tag = tag, .body = .{ .rerror = .{ .ename = errors.errorString(e) } } });
    }

    fn replyWalk(self: *Server, tag: u16, qids: []const Qid) Error!void {
        return self.reply(.{ .tag = tag, .body = .{ .rwalk = msg.Body.Rwalk.init(qids) } });
    }

    // -- dispatch -----------------------------------------------------------

    fn handleFrame(self: *Server, frame: []const u8) Error!void {
        const m = msg.decode(frame) catch |e| switch (e) {
            // R5: valid-but-unimplemented codes answered by type byte.
            error.Unsupported => return self.handleUnsupported(frame),
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

        // Tversion is the only message legal before (and illegal after) a
        // successful negotiation. [srv.c:166 sversion; R7 second-version]
        if (m.body == .tversion) {
            if (self.msize != 0) return self.replyError(tag, error.BadMessage);
            return self.handleVersion(tag, m.body.tversion);
        }
        if (self.msize == 0) return self.replyError(tag, error.BadMessage); // pre-version

        switch (m.body) {
            .tattach => |a| return self.handleAttach(tag, a),
            .twalk => return self.handleWalk(tag, m.body.twalk),
            .topen => |o| return self.handleOpen(tag, o.fid, o.mode),
            .tread => |r| return self.handleRead(tag, r.fid, r.offset, r.count),
            .twrite => return self.handleWrite(tag, m.body.twrite),
            .tclunk => |c| return self.handleClunk(tag, c.fid),
            .tflush => |fl| return self.handleFlush(tag, fl.oldtag),
            .tstat => |s| return self.handleStat(tag, s.fid),
            // Any R-message (a response) is illegal arriving at a server.
            else => return self.replyError(tag, error.BadMessage),
        }
    }

    /// R5: answer create/remove/wstat/auth (and stray R-codes) from the raw
    /// frame. Reaching here means decode parsed the 7-byte header, so the tag
    /// at frame[5..7] is always recoverable.
    fn handleUnsupported(self: *Server, frame: []const u8) Error!void {
        const tag = std.mem.readInt(u16, frame[5..7], .little);
        const e: OpError = switch (frame[4]) {
            102 => error.AuthNotRequired, // Tauth [srv.c:187 sauth]
            114, 122, 126 => error.PermissionDenied, // Tcreate/Tremove/Twstat
            else => error.BadMessage, // Rauth/Rcreate/Rremove/Rwstat
        };
        return self.replyError(tag, e);
    }

    // -- per-message handlers ----------------------------------------------

    /// [srv.c:166 sversion + :180 rversion/changemsize]
    fn handleVersion(self: *Server, tag: u16, v: msg.Body.Version) Error!void {
        self.clearFids(); // a new session aborts all outstanding fids
        const clamped: u32 = @min(v.msize, self.max_msize);
        if (!std.mem.startsWith(u8, v.version, msg.version9p)) {
            // Unknown dialect: stay unversioned, let the client retry.
            return self.reply(.{ .tag = tag, .body = .{ .rversion = .{ .msize = clamped, .version = "unknown" } } });
        }
        if (v.msize < msg.min_msize) return self.replyError(tag, error.BadMessage);
        self.msize = clamped; // guaranteed within [min_msize, max_msize]
        return self.reply(.{ .tag = tag, .body = .{ .rversion = .{ .msize = clamped, .version = msg.version9p } } });
    }

    /// [srv.c:211 sattach]
    fn handleAttach(self: *Server, tag: u16, a: anytype) Error!void {
        if (self.fids.contains(a.fid)) return self.replyError(tag, error.FidInUse); // Edupfid
        if (a.afid != msg.NOFID) return self.replyError(tag, error.AuthNotRequired); // no auth
        var fid = Fid{ .fid = a.fid, .qid = undefined, .uname = try self.dupUname(a.uname) };
        const q = self.ops.attach(self.ctx, self, &fid, a.aname) catch |e| {
            self.allocator.free(fid.uname);
            return self.replyError(tag, e);
        };
        fid.qid = q;
        try self.fids.put(self.allocator, a.fid, fid);
        return self.reply(.{ .tag = tag, .body = .{ .rattach = .{ .qid = q } } });
    }

    /// [srv.c:305 swalk + :133 walkandclone + :339 rwalk]
    fn handleWalk(self: *Server, tag: u16, t: msg.Body.Twalk) Error!void {
        const src = self.fids.get(t.fid) orelse return self.replyError(tag, error.UnknownFid);
        if (src.omode != null) return self.replyError(tag, error.FidOpen); // cannot clone open fid
        if (t.nwname > 0 and !src.qid.qtype.dir) return self.replyError(tag, error.WalkNoDir);
        const same = (t.fid == t.newfid);
        if (!same and self.fids.contains(t.newfid)) return self.replyError(tag, error.FidInUse);

        // Tentative newfid: a private copy that walk1 mutates in place. It is
        // only installed on success; on any failure it is discarded (== C's
        // "removefid" of the tentative newfid, srv.c:341).
        var work = Fid{
            .fid = t.newfid,
            .qid = src.qid,
            .omode = null,
            .ctx = src.ctx,
            .uname = try self.dupUname(src.uname),
        };
        if (!same) {
            if (self.ops.clone) |cl| {
                var srccopy = src;
                cl(self.ctx, self, &srccopy, &work) catch |e| {
                    self.allocator.free(work.uname);
                    return self.replyError(tag, e);
                };
            }
        }

        var qids: [msg.MAXWELEM]Qid = undefined;
        var i: usize = 0;
        var first_err: OpError = error.FileDoesNotExist;
        while (i < t.nwname) : (i += 1) {
            const q = self.ops.walk1(self.ctx, self, &work, t.wname[i]) catch |e| {
                first_err = e;
                break;
            };
            work.qid = q;
            qids[i] = q;
        }
        const nwqid = i;

        if (nwqid < t.nwname) {
            // Walk did not complete: discard the tentative newfid.
            self.allocator.free(work.uname);
            if (nwqid == 0) return self.replyError(tag, first_err); // first name failed
            return self.replyWalk(tag, qids[0..nwqid]); // partial: no error, no newfid
        }

        // Full success (nwname==0 is a bare clone): install the newfid.
        if (same) self.allocator.free(src.uname); // replace-in-place frees the old name
        try self.fids.put(self.allocator, t.newfid, work);
        return self.replyWalk(tag, qids[0..nwqid]);
    }

    /// [srv.c:361 sopen + :425 ropen]
    fn handleOpen(self: *Server, tag: u16, fid: u32, mode: u8) Error!void {
        const fp = self.fids.getPtr(fid) orelse return self.replyError(tag, error.UnknownFid);
        const base = mode & 3;
        const norm_base: u8 = if (base == msg.OEXEC) msg.OREAD else base; // OEXEC→OREAD
        const wants_write = norm_base == msg.OWRITE or norm_base == msg.ORDWR or (mode & msg.OTRUNC) != 0;
        if (fp.qid.qtype.dir and wants_write) return self.replyError(tag, error.FileIsDirectory);
        const q = self.ops.open(self.ctx, self, fp, mode) catch |e| return self.replyError(tag, e);
        fp.omode = (mode & ~@as(u8, 3)) | norm_base;
        return self.reply(.{ .tag = tag, .body = .{ .ropen = .{ .qid = q, .iounit = 0 } } });
    }

    /// [srv.c:467 sread]
    fn handleRead(self: *Server, tag: u16, fid: u32, offset: u64, count: u32) Error!void {
        const fp = self.fids.getPtr(fid) orelse return self.replyError(tag, error.UnknownFid);
        if (fp.omode == null or (fp.omode.? & 3) == msg.OWRITE) {
            return self.replyError(tag, error.PermissionDenied);
        }
        const maxc = self.msize - msg.IOHDRSZ;
        const clamped: usize = @min(count, maxc);
        // Reuse rbuf as the read scratch: the incoming frame has already been
        // fully decoded (Tread carries only scalars), and the reply is encoded
        // into the *separate* wbuf, so there is no aliasing on encode.
        const dst = self.rbuf[0..clamped];
        const n = self.ops.read(self.ctx, self, fp, offset, dst) catch |e| return self.replyError(tag, e);
        return self.reply(.{ .tag = tag, .body = .{ .rread = .{ .data = self.rbuf[0..n] } } });
    }

    /// [srv.c:513 swrite]
    fn handleWrite(self: *Server, tag: u16, w: anytype) Error!void {
        const fp = self.fids.getPtr(w.fid) orelse return self.replyError(tag, error.UnknownFid);
        const base = if (fp.omode) |m| m & 3 else 0xFF;
        if (base != msg.OWRITE and base != msg.ORDWR) return self.replyError(tag, error.PermissionDenied);
        const maxc = self.msize - msg.IOHDRSZ;
        var data = w.data;
        if (data.len > maxc) data = data[0..maxc];
        const n = self.ops.write(self.ctx, self, fp, w.offset, data) catch |e| return self.replyError(tag, e);
        return self.reply(.{ .tag = tag, .body = .{ .rwrite = .{ .count = @intCast(n) } } });
    }

    /// [srv.c:554 sclunk] — notify then remove unconditionally.
    fn handleClunk(self: *Server, tag: u16, fid: u32) Error!void {
        const fp = self.fids.getPtr(fid) orelse return self.replyError(tag, error.UnknownFid);
        if (self.ops.clunk) |c| c(self.ctx, self, fp);
        const owned = fp.uname;
        _ = self.fids.remove(fid);
        self.allocator.free(owned);
        return self.reply(.{ .tag = tag, .body = .rclunk });
    }

    /// [srv.c:245 sflush] — v1 is synchronous with nothing pending, so the
    /// reply is always Rflush. (A wait-queue will slot in at the Tread arm.)
    fn handleFlush(self: *Server, tag: u16, oldtag: u16) Error!void {
        if (self.ops.flush) |fl| fl(self.ctx, self, oldtag);
        return self.reply(.{ .tag = tag, .body = .rflush });
    }

    /// [srv.c:601 sstat + :626 rstat] — encode the Stat (R4) into a scratch
    /// buffer FIRST, then let `reply` memcpy it into wbuf (avoids the aliasing
    /// trap of building the blob inside wbuf).
    fn handleStat(self: *Server, tag: u16, fid: u32) Error!void {
        const fp = self.fids.getPtr(fid) orelse return self.replyError(tag, error.UnknownFid);
        const st = self.ops.stat(self.ctx, self, fp) catch |e| return self.replyError(tag, e);
        var blob: [1024]u8 = undefined;
        const n = st.encode(&blob) catch unreachable; // fixture stats fit
        return self.reply(.{ .tag = tag, .body = .{ .rstat = .{ .stat = blob[0..n] } } });
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

/// In-memory duplex transport: `requests` are frames the test enqueues for the
/// server to read; `replies` are frames the server writes back.
const TestTransport = struct {
    alloc: std.mem.Allocator,
    requests: std.ArrayList([]u8) = .empty,
    replies: std.ArrayList([]u8) = .empty,
    closed: bool = false,

    fn deinit(self: *TestTransport) void {
        for (self.requests.items) |fr| self.alloc.free(fr);
        for (self.replies.items) |fr| self.alloc.free(fr);
        self.requests.deinit(self.alloc);
        self.replies.deinit(self.alloc);
    }

    fn pushReq(self: *TestTransport, frame: []const u8) !void {
        try self.requests.append(self.alloc, try self.alloc.dupe(u8, frame));
    }

    fn popReply(self: *TestTransport) ?[]u8 {
        if (self.replies.items.len == 0) return null;
        return self.replies.orderedRemove(0);
    }

    fn vWrite(ctx: *anyopaque, frame: []const u8) transport.Error!void {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        if (frame.len < msg.header_size) return error.BadFrame;
        if (std.mem.readInt(u32, frame[0..4], .little) != frame.len) return error.BadFrame;
        const copy = self.alloc.dupe(u8, frame) catch unreachable;
        self.replies.append(self.alloc, copy) catch unreachable;
    }

    fn vRead(ctx: *anyopaque, buf: []u8) transport.Error![]u8 {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        if (self.requests.items.len == 0) return if (self.closed) error.Closed else error.WouldBlock;
        const front = self.requests.items[0];
        if (front.len > buf.len) return error.FrameTooBig;
        @memcpy(buf[0..front.len], front);
        _ = self.requests.orderedRemove(0);
        self.alloc.free(front);
        return buf[0..front.len];
    }

    fn vClose(ctx: *anyopaque) void {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }

    const vtable = transport.Transport.VTable{ .writeMsg = vWrite, .readMsg = vRead, .close = vClose };

    fn asTransport(self: *TestTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// A tree node addressed by qid path. Directories list child paths by number.
const Node = struct {
    path: u64 = 0,
    name: []const u8 = "",
    is_dir: bool = false,
    content: []const u8 = "",
    writable: bool = false,
    children: []const u64 = &.{},
};

/// Contract §10 fixture: root(1) dir → {index(2) "hello, snarf\n" ro,
/// notes(3) writable, sub(4) dir → leaf(5) "leaf\n"}.
const TestTree = struct {
    nodes: [6]Node,
    notes: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) TestTree {
        return .{
            .alloc = alloc,
            .notes = .empty,
            .nodes = .{
                .{}, // path 0 — unused
                .{ .path = 1, .name = "", .is_dir = true, .children = &.{ 2, 3, 4 } },
                .{ .path = 2, .name = "index", .content = "hello, snarf\n" },
                .{ .path = 3, .name = "notes", .writable = true },
                .{ .path = 4, .name = "sub", .is_dir = true, .children = &.{5} },
                .{ .path = 5, .name = "leaf", .content = "leaf\n" },
            },
        };
    }

    fn deinit(self: *TestTree) void {
        self.notes.deinit(self.alloc);
    }
};

fn qidOf(n: *const Node) Qid {
    return .{ .path = n.path, .qtype = .{ .dir = n.is_dir } };
}

fn nodeOf(fid: *Fid) *Node {
    return @ptrCast(@alignCast(fid.ctx.?));
}

fn treeAttach(ctx: *anyopaque, srv: *Server, fid: *Fid, aname: []const u8) OpError!Qid {
    _ = srv;
    _ = aname;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    fid.ctx = &tree.nodes[1];
    return qidOf(&tree.nodes[1]);
}

fn treeWalk1(ctx: *anyopaque, srv: *Server, fid: *Fid, name: []const u8) OpError!Qid {
    _ = srv;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    const cur = nodeOf(fid);
    for (cur.children) |cp| {
        const child = &tree.nodes[cp];
        if (std.mem.eql(u8, child.name, name)) {
            fid.ctx = child;
            return qidOf(child);
        }
    }
    return error.FileDoesNotExist;
}

fn treeOpen(ctx: *anyopaque, srv: *Server, fid: *Fid, mode: u8) OpError!Qid {
    _ = ctx;
    _ = srv;
    _ = mode;
    return fid.qid;
}

fn treeRead(ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, buf: []u8) OpError!usize {
    _ = srv;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    const node = nodeOf(fid);
    if (node.is_dir) return 0; // fixtures return 0 for dir reads (R7)
    const data = if (node.writable) tree.notes.items else node.content;
    if (offset >= data.len) return 0;
    const avail = data[@intCast(offset)..];
    const n = @min(avail.len, buf.len);
    @memcpy(buf[0..n], avail[0..n]);
    return n;
}

fn treeWrite(ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, data: []const u8) OpError!usize {
    _ = srv;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    const node = nodeOf(fid);
    if (!node.writable) return error.PermissionDenied;
    const off: usize = @intCast(offset);
    const end = off + data.len;
    if (end > tree.notes.items.len) tree.notes.resize(tree.alloc, end) catch return error.IoError;
    @memcpy(tree.notes.items[off..end], data);
    return data.len;
}

fn treeStat(ctx: *anyopaque, srv: *Server, fid: *Fid) OpError!stat {
    _ = srv;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    const node = nodeOf(fid);
    const len: u64 = if (node.is_dir) 0 else if (node.writable) tree.notes.items.len else node.content.len;
    return .{
        .qid = qidOf(node),
        .mode = if (node.is_dir) (stat.DMDIR | 0o555) else 0o644,
        .length = len,
        .name = node.name,
    };
}

const tree_ops = Ops{
    .attach = treeAttach,
    .walk1 = treeWalk1,
    .open = treeOpen,
    .read = treeRead,
    .write = treeWrite,
    .stat = treeStat,
};

/// Heap-pinned harness so the transport/tree pointers held by `Server` stay
/// stable across the whole test.
const Fixture = struct {
    alloc: std.mem.Allocator,
    tt: TestTransport,
    tree: TestTree,
    srv: Server,
    rbuf: [8192]u8 = undefined,

    fn create(alloc: std.mem.Allocator) !*Fixture {
        const self = try alloc.create(Fixture);
        self.alloc = alloc;
        self.tt = .{ .alloc = alloc };
        self.tree = TestTree.init(alloc);
        self.srv = try Server.init(alloc, self.tt.asTransport(), &tree_ops, &self.tree, 8192);
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.srv.deinit();
        self.tree.deinit();
        self.tt.deinit();
        self.alloc.destroy(self);
    }

    /// Encode `m`, feed it to the server, decode the single reply. The reply
    /// bytes are copied into `self.rbuf` so the decoded slices stay valid.
    fn transact(self: *Fixture, m: msg.Message) !msg.Message {
        var enc: [8192]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        return self.transactRaw(enc[0..n]);
    }

    fn transactRaw(self: *Fixture, frame: []const u8) !msg.Message {
        try self.tt.pushReq(frame);
        _ = try self.srv.step();
        const reply = self.tt.popReply() orelse return error.NoReply;
        defer self.alloc.free(reply);
        @memcpy(self.rbuf[0..reply.len], reply);
        return try msg.decode(self.rbuf[0..reply.len]);
    }

    fn doVersion(self: *Fixture) !void {
        const r = try self.transact(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect(r.body == .rversion);
    }

    fn doAttach(self: *Fixture, fid: u32) !Qid {
        const r = try self.transact(.{ .tag = 1, .body = .{ .tattach = .{ .fid = fid, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
        try testing.expect(r.body == .rattach);
        return r.body.rattach.qid;
    }

    fn expectRerror(_: *Fixture, r: msg.Message, want: []const u8) !void {
        try testing.expect(r.body == .rerror);
        try testing.expectEqualStrings(want, r.body.rerror.ename);
    }
};

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
    // Build 7-byte header-only frames; decode returns Unsupported before any
    // body parse, so the framework answers purely by type byte (R5).
    const cases = [_]struct { code: u8, want: []const u8 }{
        .{ .code = 102, .want = "authentication not required" }, // Tauth
        .{ .code = 114, .want = "permission denied" }, // Tcreate
        .{ .code = 122, .want = "permission denied" }, // Tremove
        .{ .code = 126, .want = "permission denied" }, // Twstat
    };
    for (cases) |c| {
        var frame: [7]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], 7, .little);
        frame[4] = c.code;
        std.mem.writeInt(u16, frame[5..7], 77, .little);
        const r = try f.transactRaw(&frame);
        try testing.expectEqual(@as(u16, 77), r.tag);
        try f.expectRerror(r, c.want);
    }
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
