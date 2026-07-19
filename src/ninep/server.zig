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
//! Phase-6 (contract phase6-input, R-P6-2/5): a framework-level parked-read
//! wait queue with kernel-style RE-RUN completion. `Ops.read` may return
//! `error.WouldBlockRead` ("no data now, park me"); the request is filed on a
//! FIFO `parked` list and no reply is sent until `completeReads` re-runs it
//! (or a Tflush/Tclunk/Tversion tears it down). This is the port of the
//! deferred-flush machinery in `srv.c` (:245 sflush, :751 respond,
//! :862 deferred `or->flush[]`, :812-826 tag-reuse doc) and flush(5).
//!
//! Everything is std-only; no globals; the allocator is explicit (S-07 §6).
const std = @import("std");
const Qid = @import("qid.zig");
const msg = @import("msg.zig");
const stat = @import("stat.zig");
const errors = @import("errors.zig");
const transport = @import("transport.zig");

const OpError = errors.OpError;

/// The error set an `Ops.read` may return. It widens `OpError` with the single
/// synthetic `WouldBlockRead` — the framework signal "no data on this file now,
/// park the request" (R-P6-2). It is DELIBERATELY NOT a member of
/// `errors.OpError`: it must never become an Rerror string, so `errors.zig`
/// stays untouched and `errorString` stays total over `OpError`. `handleRead`
/// and `completeReads` peel `WouldBlockRead` off before any `replyError`.
pub const ReadError = OpError || error{WouldBlockRead};

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
    /// May return `error.WouldBlockRead` to be parked until `completeReads`
    /// (R-P6-2). [srv.c:467 sread]
    read: *const fn (ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, buf: []u8) ReadError!usize,
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

/// A parked (blocked) Tread awaiting data (R-P6-2). We store the fid NUMBER,
/// not a `*Fid` — the fid table may rehash between park and completion, so the
/// pointer would dangle; `completeReads` re-looks-up the number. Mirrors the
/// per-request state `srv.c` keeps on its deferred-flush list (:862).
const Parked = struct { tag: u16, fid: u32, offset: u64, count: u32 };

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
    /// FIFO of blocked Treads, in park order (R-P6-2).
    parked: std.ArrayList(Parked) = .empty,
    /// Completion scratch for `completeReads` reads. A SEPARATE buffer, never
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

        // Hardening (R-P6-5): a new T-message reusing a tag that is currently
        // parked (in-flight) is a protocol violation — reply "bad message" on
        // the new frame and leave the parked entry untouched. [srv.c:812-826
        // tag-reuse race] (parked is only ever non-empty post-version, so this
        // never shadows first-Tversion handling.)
        if (self.tagParked(tag)) return self.replyError(tag, error.BadMessage);

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
        self.parked.clearRetainingCapacity(); // ...and discards parked reads SILENTLY (R-P6-5)
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
        const n = self.ops.read(self.ctx, self, fp, offset, dst) catch |e| switch (e) {
            // No data yet: file the request on the wait queue and reply NOTHING
            // now; `completeReads` re-runs it when data arrives (R-P6-2).
            error.WouldBlockRead => return self.park(tag, fid, offset, clamped),
            else => |oe| return self.replyError(tag, oe),
        };
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
        // Before the fid dies, interrupt any reads parked on it: Rerror
        // "interrupted" per entry, in park order (R-P6-5).
        try self.sweepParked(fid);
        if (self.ops.clunk) |c| c(self.ctx, self, fp);
        const owned = fp.uname;
        _ = self.fids.remove(fid);
        self.allocator.free(owned);
        return self.reply(.{ .tag = tag, .body = .rclunk });
    }

    /// [srv.c:245 sflush] — if `oldtag` names a parked read, interrupt it FIRST
    /// (Rerror "interrupted" on the old tag), THEN send Rflush on the flush's
    /// own tag; this deferred ordering is mandated by flush(5) and mirrors
    /// srv.c's deferred `or->flush[]` list (:862 / :751 respond). With nothing
    /// parked under `oldtag` it is a plain Rflush (the idle case, test 4).
    fn handleFlush(self: *Server, tag: u16, oldtag: u16) Error!void {
        if (self.ops.flush) |fl| fl(self.ctx, self, oldtag);
        if (self.findParked(oldtag)) |idx| {
            _ = self.parked.orderedRemove(idx);
            try self.replyError(oldtag, error.Interrupted); // interrupted FIRST
        }
        return self.reply(.{ .tag = tag, .body = .rflush }); // then Rflush
    }

    /// [srv.c:601 sstat + :626 rstat] — encode the Stat (R4) into a scratch
    /// buffer FIRST, then let `reply` memcpy it into wbuf (avoids the aliasing
    /// trap of building the blob inside wbuf). A Stat too large for the
    /// scratch degrades to an Rerror — device servers may return arbitrary
    /// strings and the framework must never trap on their size.
    fn handleStat(self: *Server, tag: u16, fid: u32) Error!void {
        const fp = self.fids.getPtr(fid) orelse return self.replyError(tag, error.UnknownFid);
        const st = self.ops.stat(self.ctx, self, fp) catch |e| return self.replyError(tag, e);
        var blob: [1024]u8 = undefined;
        const n = st.encode(&blob) catch |e| return self.replyError(tag, switch (e) {
            error.ShortBuffer => error.IoError,
            error.BadMessage => error.BadMessage,
        });
        return self.reply(.{ .tag = tag, .body = .{ .rstat = .{ .stat = blob[0..n] } } });
    }

    // -- wait queue (R-P6-2 / R-P6-5) --------------------------------------

    /// File a blocked Tread on the FIFO; send NO reply. Called from `handleRead`
    /// when `Ops.read` returns `error.WouldBlockRead`.
    fn park(self: *Server, tag: u16, fid: u32, offset: u64, count: usize) Error!void {
        try self.parked.append(self.allocator, .{
            .tag = tag,
            .fid = fid,
            .offset = offset,
            .count = @intCast(count),
        });
    }

    /// Is `tag` currently parked (in-flight)?
    fn tagParked(self: *const Server, tag: u16) bool {
        for (self.parked.items) |p| if (p.tag == tag) return true;
        return false;
    }

    /// Index of the parked entry with tag `tag`, or null.
    fn findParked(self: *const Server, tag: u16) ?usize {
        for (self.parked.items, 0..) |p, i| if (p.tag == tag) return i;
        return null;
    }

    /// Interrupt (Rerror "interrupted") and remove every parked read on `fid`,
    /// in park order. Used by clunk (R-P6-5).
    fn sweepParked(self: *Server, fid: u32) Error!void {
        var i: usize = 0;
        while (i < self.parked.items.len) {
            if (self.parked.items[i].fid == fid) {
                const p = self.parked.orderedRemove(i); // shift left; do not advance i
                try self.replyError(p.tag, error.Interrupted);
            } else i += 1;
        }
    }

    /// Number of reads currently parked. Test/adapter observability.
    pub fn parkedCount(self: *const Server) usize {
        return self.parked.items.len;
    }

    /// Device/adapter signal (R-P6-3): data MAY now exist on the file(s) whose
    /// `qid.path == path`. Re-runs each matching parked read IN PARK ORDER,
    /// looking the fid up afresh to recover its qid: a success sends Rread and
    /// unparks; `WouldBlockRead` leaves it parked; any other error sends Rerror
    /// and unparks. Returns the number of replies sent. SAFE to call from
    /// inside `Ops.write` and from tick-level code — completions read into
    /// `pbuf`, NEVER `rbuf`, because when a completion fires from within an
    /// `Ops.write` the `rbuf` still aliases that in-flight Twrite's data
    /// (R-P6-5 / O11 D6); replies encode into `wbuf` via `reply` as usual.
    pub fn completeReads(self: *Server, path: u64) Error!usize {
        var replies: usize = 0;
        var i: usize = 0;
        while (i < self.parked.items.len) {
            const p = self.parked.items[i];
            const fp = self.fids.getPtr(p.fid);
            // Fid gone (shouldn't happen — clunk sweeps) or a different file:
            // leave parked, move on.
            if (fp == null or fp.?.qid.path != path) {
                i += 1;
                continue;
            }
            const clamped: usize = @min(@as(usize, p.count), self.pbuf.len);
            const n = self.ops.read(self.ctx, self, fp.?, p.offset, self.pbuf[0..clamped]) catch |e| switch (e) {
                error.WouldBlockRead => {
                    i += 1; // still no data — stays parked, order preserved
                    continue;
                },
                else => |oe| {
                    _ = self.parked.orderedRemove(i); // shift left; do not advance i
                    try self.replyError(p.tag, oe);
                    replies += 1;
                    continue;
                },
            };
            _ = self.parked.orderedRemove(i); // shift left; do not advance i
            try self.reply(.{ .tag = p.tag, .body = .{ .rread = .{ .data = self.pbuf[0..n] } } });
            replies += 1;
        }
        return replies;
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
    try f.srv.parked.append(testing.allocator, .{ .tag = 10, .fid = 1, .offset = 0, .count = 4 });
    try f.srv.parked.append(testing.allocator, .{ .tag = 11, .fid = 2, .offset = 0, .count = 4 });
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
