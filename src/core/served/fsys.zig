//! fsys — the `/mnt/snarf-self` directory server (acme's `fsys.c`), served over
//! 9P. This is the DIRECTORY half of the served tree (wave 10a-A3): the qid
//! scheme, the root + per-window dirtabs, and attach/walk/open/dir-read/stat.
//! Per-file read/write DELEGATES to `served/xfid.zig` (wave 10b-B3): index
//! reads, body/tag reads (xfidutfread) and ctl/body/tag writes all call into
//! `xfid.zig`; this file implements only what its own tests need directly —
//! the `w_ctl` read (via `Window.ctlPrint`) and the directory machinery. The
//! remaining `// SEAM(O21)` marker (addr/data/xdata) is still deferred.
//!
//! Ported from larryr/plan9port@337c6ac acme/fsys.c; cite as `fsys.c:NN`.
//! Qid packing is dat.h:481-483; the Q enum mirrors dat.h:1-26 (v1 serves only
//! `dir/index/new/w_body/w_ctl/w_tag`, the rest reserved so paths never
//! renumber). The rulings adopted here are R-P10-A..J
//! (agents/contracts/phase10-served.md §3.1).
//!
//! Lifetime (R-P10-C, no refcount): a fid carries only its qid; every Ops
//! callback re-resolves the window id inside `qid.path` back to a `*Window`
//! through `ed.row` (the `lookid` analog, look.c:789). A deleted window is
//! simply not found — `error.DeletedWindow` on an open fid's read/write
//! (xfid.c:320-323), `error.FileDoesNotExist` on a fresh walk (fsys.c:498-500).
//! `Fid.ctx` stays null.
//!
//! Imports: `std` + `ninep` (the 9P framework, S-07 §6 amendment R-P10-9b) +
//! sibling core files. Never dev/shim.
const std = @import("std");
const ninep = @import("ninep");
const Editor = @import("../Editor.zig");
const Window = @import("../Window.zig");
const cmd_window = @import("../exec/cmd_window.zig");
const xfid = @import("xfid.zig");

const Server = ninep.server.Server;
const Fid = ninep.server.Fid;
const ReadError = ninep.server.ReadError;
const Qid = ninep.Qid;
const OpError = ninep.errors.OpError;
const Stat = ninep.stat;

/// Mode bits (libc.h:580-582): the directory + append flags stripped when a mode
/// is checked against a file's access bits. `DMDIR` also lives in `ninep.stat`.
const DMDIR: u32 = Stat.DMDIR; // 0x8000_0000
const DMAPPEND: u32 = 0x4000_0000;

// ===========================================================================
// Qid scheme (R-P10-A; dat.h:1-26, :481-483).
// ===========================================================================

/// The acme qid FILE field. `path = (win<<8)|Q`; window id 0 is the global
/// level. v1 walks/serves ONLY `dir, index, new, w_body, w_ctl, w_tag`; the rest
/// are reserved (O21/B3 seams) so a path never renumbers when they land.
pub const Q = enum(u8) {
    dir = 0,
    index,
    new,
    w_addr,
    w_body,
    w_ctl,
    w_data,
    w_event,
    w_tag,
    w_xdata,
};

/// `QID(w,q)` (dat.h:481).
pub fn qpath(win: u32, q: Q) u64 {
    return (@as(u64, win) << 8) | @intFromEnum(q);
}

/// `WIN(q)` (dat.h:482).
pub fn qwin(path: u64) u32 {
    return @intCast((path >> 8) & 0xFFFFFF);
}

/// `FILE(q)` (dat.h:483).
pub fn qfile(path: u64) Q {
    return @enumFromInt(@as(u8, @intCast(path & 0xFF)));
}

// ===========================================================================
// Dirtabs (R-P10-A; fsys.c:65-95, reduced to the v1 row set).
// ===========================================================================

const DirEnt = struct { name: []const u8, q: Q, dir: bool, perm: u32 };

/// Root directory (`dirtab`, fsys.c:65-78) — v1 rows: `index` (0400) and `new`
/// (a DIRECTORY, 0500). `acme/cons/consctl/draw/editout/label/log` are deferred
/// (R-P10-J). "." is implicit (the framework never asks for it in a dir read).
const dirtab = [_]DirEnt{
    .{ .name = "index", .q = .index, .dir = false, .perm = 0o400 },
    .{ .name = "new", .q = .new, .dir = true, .perm = DMDIR | 0o500 },
};

/// Per-window directory (`dirtabw`, fsys.c:80-95) — v1 rows: `body`
/// (append, 0600), `ctl` (0600), `tag` (append, 0600). `addr/data/editout/
/// errors/event/rdsel/wrsel/xdata` are deferred (R-P10-J).
const dirtabw = [_]DirEnt{
    .{ .name = "body", .q = .w_body, .dir = false, .perm = DMAPPEND | 0o600 },
    .{ .name = "ctl", .q = .w_ctl, .dir = false, .perm = 0o600 },
    .{ .name = "tag", .q = .w_tag, .dir = false, .perm = DMAPPEND | 0o600 },
};

/// The `Dirtab` row a qid FILE field maps to — its name and perm for stat/open
/// (fsys.c: f->dir). A directory qid (root or per-window) reports "." with the
/// dir perm, exactly as the C's `f->dir` points at dirtab[0]/dirtabw[0] (".").
fn entryFor(q: Q) DirEnt {
    return switch (q) {
        .dir => .{ .name = ".", .q = .dir, .dir = true, .perm = DMDIR | 0o500 },
        .index => dirtab[0],
        .new => dirtab[1],
        .w_body => dirtabw[0],
        .w_ctl => dirtabw[1],
        .w_tag => dirtabw[2],
        // Reserved (O21/B3 seams) — names/perms for completeness; never walked in v1.
        .w_addr => .{ .name = "addr", .q = .w_addr, .dir = false, .perm = 0o600 },
        .w_data => .{ .name = "data", .q = .w_data, .dir = false, .perm = 0o600 },
        .w_event => .{ .name = "event", .q = .w_event, .dir = false, .perm = 0o600 },
        .w_xdata => .{ .name = "xdata", .q = .w_xdata, .dir = false, .perm = 0o600 },
    };
}

fn qidDir(win: u32) Qid {
    return .{ .path = qpath(win, .dir), .qtype = .{ .dir = true } };
}

fn qidOf(win: u32, e: DirEnt) Qid {
    return .{ .path = qpath(win, e.q), .qtype = .{ .dir = e.dir } };
}

// ===========================================================================
// Fsys — the served tree, bound to one Editor.
// ===========================================================================

pub const Fsys = struct {
    ed: *Editor,
    allocator: std.mem.Allocator,

    /// The 9P callback table. No `create/remove/wstat` (framework R5); no
    /// `clunk` (R-P10-C: no per-window open-count state in v1, clunk is clean);
    /// no `flush` (no parked reads — every file answers synchronously).
    pub const ops: ninep.server.Ops = .{
        .attach = attachOp,
        .walk1 = walk1Op,
        .open = openOp,
        .read = readOp,
        .write = writeOp,
        .stat = statOp,
    };

    pub fn init(ed: *Editor) Fsys {
        return .{ .ed = ed, .allocator = ed.allocator };
    }

    /// `lookid` (look.c:789): the window with `id`, scanning `row->col->w`, or
    /// null (a deleted / never-created window). The re-resolution seam that
    /// replaces the C's refcount (R-P10-C).
    fn lookid(self: *Fsys, id: u32) ?*Window {
        const row = self.ed.row orelse return null;
        for (row.col.items) |c| {
            for (c.w.items) |w| {
                if (w.id == id) return w;
            }
        }
        return null;
    }

    /// The column a walk-to-`new` mints its window in (R-P10-I): `ed.seltext`'s
    /// column, else the first column of `ed.row`, else an error (no column
    /// creation from a 9P walk in v1). No `cnewwindow` channel — a direct call.
    fn newWindow(self: *Fsys) OpError!*Window {
        var col: ?*@import("../Column.zig") = null;
        if (self.ed.seltext) |t| {
            if (t.w) |wp| col = wp.col;
        }
        if (col == null) {
            const row = self.ed.row orelse return error.IoError;
            if (row.col.items.len == 0) return error.IoError;
            col = row.col.items[0];
        }
        return cmd_window.makeWindow(col.?, "") catch return error.IoError;
    }

    fn fsysOf(ctx: *anyopaque) *Fsys {
        return @ptrCast(@alignCast(ctx));
    }

    // -- attach (fsys.c:342-377) -------------------------------------------

    /// The uname check + Mntdir lookup collapse (R-P10-D): single user, no
    /// external commands, so any `aname` attaches to the tree root.
    fn attachOp(_: *anyopaque, _: *Server, _: *Fid, _: []const u8) OpError!Qid {
        return qidDir(0);
    }

    // -- walk (fsys.c:379-522, reduced) ------------------------------------

    fn walk1Op(ctx: *anyopaque, _: *Server, fid: *Fid, name: []const u8) OpError!Qid {
        const self = fsysOf(ctx);
        const id = qwin(fid.qid.path);
        const q = qfile(fid.qid.path);
        const eq = std.mem.eql;

        if (eq(u8, name, "..")) return qidDir(0); // fsys.c:426-433 → root

        if (id == 0 and q == .dir) {
            // Root. An all-digit name is a window directory (fsys.c:446-464):
            // re-resolve via lookid; a miss is a fresh walk to a dead/absent id
            // ⇒ "file does not exist" (fsys.c:454-458).
            if (allDigits(name)) {
                const wid = std.fmt.parseInt(u32, name, 10) catch return error.FileDoesNotExist;
                _ = self.lookid(wid) orelse return error.FileDoesNotExist;
                return qidDir(wid);
            }
            // "new" CREATES a window (fsys.c:466-476) — intercepted before the
            // dirtab scan, so the dirtab "new" row exists only for the listing.
            if (eq(u8, name, "new")) {
                const w = try self.newWindow();
                return qidDir(w.id);
            }
            // Linear dirtab scan (fsys.c:478-490).
            for (dirtab) |e| {
                if (eq(u8, name, e.name)) return qidOf(0, e);
            }
            return error.FileDoesNotExist;
        }

        if (q == .dir) {
            // A per-window directory (id>0): dirtabw scan. `27/23` (a numeric
            // name here) is not in dirtabw ⇒ miss, exactly as the C breaks out
            // (fsys.c:449-450).
            for (dirtabw) |e| {
                if (eq(u8, name, e.name)) return qidOf(id, e);
            }
            return error.FileDoesNotExist;
        }

        return error.FileDoesNotExist; // walk beneath a file
    }

    // -- open (fsys.c:524-560) ---------------------------------------------

    /// Strip/deny per fsysopen, then check the requested access against the
    /// file's perm bits. OTRUNC/OCEXEC are ignored by the framework's mode
    /// normalization; OEXEC/ORCLOSE are denied here.
    fn openOp(ctx: *anyopaque, _: *Server, fid: *Fid, mode: u8) OpError!Qid {
        const self = fsysOf(ctx);
        const id = qwin(fid.qid.path);
        const q = qfile(fid.qid.path);

        // Re-resolve an open of a per-window file: a window deleted between walk
        // and open is already gone (R-P10-C).
        if (id != 0 and q != .dir) {
            _ = self.lookid(id) orelse return error.DeletedWindow;
        }

        const perm = entryFor(q).perm;
        const m: u32 = switch (mode & 3) {
            0 => 0o400, // OREAD
            1 => 0o200, // OWRITE
            2 => 0o600, // ORDWR
            else => return error.PermissionDenied, // OEXEC (fsys.c:530-531)
        };
        if ((perm & ~(DMDIR | DMAPPEND)) & m != m) return error.PermissionDenied; // fsys.c:544-545
        return fid.qid;
    }

    // -- read (fsys.c:576-651 dir; xfid.c:289-403 file) --------------------

    fn readOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, buf: []u8) ReadError!usize {
        const self = fsysOf(ctx);
        const id = qwin(fid.qid.path);
        const q = qfile(fid.qid.path);

        if (q == .dir) return self.readDir(id, offset, buf); // directory reads answered inline

        // Windowless files (fsys.c:585-590, xfid.c:300-317).
        switch (q) {
            .index => return xfid.indexRead(self.ed, offset, buf, self.allocator), // xfid.c:1090-1147
            .new => return 0, // never a real fid (walk-to-new returns the window dir)
            else => {}, // per-window file
        }

        // Per-window file: re-resolve (R-P10-C). A missing window is the analog
        // of the C's `w->col == nil` ⇒ Edel guard (xfid.c:320-323).
        const w = self.lookid(id) orelse return error.DeletedWindow;
        switch (q) {
            .w_ctl => {
                // winctlprint(w, buf, 1) sliced by offset/count (xfid.c:336-354).
                var tmp: [256]u8 = undefined;
                const line = w.ctlPrint(&tmp, true);
                if (offset >= line.len) return 0;
                const avail = line[@intCast(offset)..];
                const n = @min(avail.len, buf.len);
                @memcpy(buf[0..n], avail[0..n]);
                return n;
            },
            .w_body, .w_tag => return xfid.read(self, w, q, offset, buf), // xfid.c:934-996
            // SEAM(O21): needs address() — xfid.c:483-502 (addr/data/xdata reads).
            .w_addr, .w_data, .w_xdata => return error.FileDoesNotExist,
            else => return error.FileDoesNotExist,
        }
    }

    /// Compose a directory read (fsys.c:598-637): stat blobs for each entry, at
    /// entry-boundary offsets. Root lists `dirtab` rows then window dirs SORTED
    /// BY ID; a per-window dir lists `dirtabw` rows. `stat.length = 0` always
    /// (fsys.c:739). Uses `buf.len` as the request count (the framework already
    /// clamped it to `msize - IOHDRSZ`).
    fn readDir(self: *Fsys, id: u32, offset: u64, buf: []u8) OpError!usize {
        var i: u64 = 0; // cumulative byte offset across ALL entries
        var n: usize = 0; // bytes written into buf

        if (id == 0) {
            for (dirtab) |e| {
                if (!pushEntry(e.name, qpath(0, e.q), e.dir, e.perm, &i, &n, offset, buf)) return n;
            }
            // Window directories, ids qsort'ed ascending (fsys.c:611-637).
            var ids: std.ArrayList(u32) = .empty;
            defer ids.deinit(self.allocator);
            if (self.ed.row) |row| {
                for (row.col.items) |c| {
                    for (c.w.items) |w| {
                        ids.append(self.allocator, w.id) catch return error.IoError;
                    }
                }
            }
            std.mem.sort(u32, ids.items, {}, comptime std.sort.asc(u32));
            var nb: [16]u8 = undefined;
            for (ids.items) |wid| {
                const name = std.fmt.bufPrint(&nb, "{d}", .{wid}) catch unreachable;
                // dt.qid = QID(k, Qdir); dt.perm = DMDIR|0700 (fsys.c:630-633).
                if (!pushEntry(name, qpath(wid, .dir), true, DMDIR | 0o700, &i, &n, offset, buf)) return n;
            }
        } else {
            for (dirtabw) |e| {
                if (!pushEntry(e.name, qpath(id, e.q), e.dir, e.perm, &i, &n, offset, buf)) return n;
            }
        }
        return n;
    }

    // -- write (xfid.c:447-620) --------------------------------------------

    /// The write dispatch: `w->col == nil` ⇒ Edel guard (xfid.c:465-467) applied
    /// here before delegating to `xfid.write` for the ctl/body/tag arms
    /// (xfid.c:622-844, :577-608).
    fn writeOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, data: []const u8) OpError!usize {
        const self = fsysOf(ctx);
        const id = qwin(fid.qid.path);
        const q = qfile(fid.qid.path);
        if (q == .dir) return error.PermissionDenied;
        if (id == 0) return error.PermissionDenied; // index/new not writable in v1
        const w = self.lookid(id) orelse return error.DeletedWindow; // xfid.c:465-467 Edel guard
        return switch (q) {
            .w_ctl, .w_body, .w_tag => xfid.write(self, w, q, offset, data),
            else => error.PermissionDenied,
        };
    }

    // -- stat (fsys.c:676-748) ---------------------------------------------

    /// `dostat` (fsys.c:733-748): qid from the fid's path, mode/name from its
    /// dirtab row (`f->dir`), `length = 0` always. uid/gid/muid default to the
    /// single user (stat.zig defaults).
    fn statOp(_: *anyopaque, _: *Server, fid: *Fid) OpError!Stat {
        const e = entryFor(qfile(fid.qid.path));
        return .{
            .qid = .{ .path = fid.qid.path, .qtype = .{ .dir = e.dir } },
            .mode = e.perm,
            .length = 0,
            .name = e.name,
        };
    }
};

/// Emit one directory entry into `buf` at the 9P entry-boundary offset. `i` is
/// the running cumulative offset across all entries (advanced for every entry,
/// included or not); `n` is bytes written. An entry is copied only once
/// `i >= offset` and only if it fits; returns false to STOP the enclosing loop
/// (past `offset+count`, or the buffer is full). Mirrors fsys.c:598-608.
fn pushEntry(name: []const u8, path: u64, isdir: bool, mode: u32, i: *u64, n: *usize, offset: u64, buf: []u8) bool {
    const st = Stat{
        .qid = .{ .path = path, .qtype = .{ .dir = isdir } },
        .mode = mode,
        .length = 0,
        .name = name,
    };
    const len = st.encodedSize();
    if (i.* >= offset + buf.len) return false; // C's `i < e` guard (e = offset+count)
    if (i.* >= offset) {
        if (n.* + len > buf.len) return false; // won't fit (C's len<=BIT16SZ)
        _ = st.encode(buf[n.*..]) catch return false;
        n.* += len;
    }
    i.* += len;
    return true;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

// ===========================================================================
// Tests (side contract §4, tests 1, 2, 5, 6, 7 — tests 3-4 are wave B3's).
// A Pipe + Server(Fsys.ops) harness over a booted tree, driven with raw msg
// frames (the dev/input.zig pattern). Test 1 is renamed per the master's one
// documented rename: the byte-exact `index` read belongs to B3, so A3 pins the
// walk/stat plumbing instead.
// ===========================================================================
const testing = std.testing;
const chan = ninep.chan;
const msg = ninep.msg;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const boot = @import("../boot.zig");

/// Heap-pinned harness: the Server holds `&fsys`, `fsys` holds `&ed`, `ed`
/// holds `tree.row` — none may move for the test's life.
const Harness = struct {
    alloc: std.mem.Allocator,
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,
    fsys: Fsys,
    pipe: *chan.Pipe,
    srv: Server,
    rbuf: [8192]u8 = undefined,
    tag: u16 = 0,

    fn create(alloc: std.mem.Allocator, name: []const u8, body: []const u8) !*Harness {
        const self = try alloc.create(Harness);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.tag = 0;
        self.fx = try Frame.TestFixture.init();
        self.tree = try boot.boot(alloc, self.fx.disp, self.fx.font, proto.Rect.make(0, 0, 640, 480), .{
            .win_name = name,
            .body = body,
        });
        self.ed = Editor.init(alloc);
        self.ed.row = self.tree.row;
        self.fsys = Fsys.init(&self.ed);
        self.pipe = try chan.Pipe.init(alloc, 16384);
        self.srv = try Server.init(alloc, self.pipe.serverEnd(), &Fsys.ops, &self.fsys, 8192);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.srv.deinit();
        self.pipe.deinit();
        self.ed.deinit();
        self.tree.deinit();
        self.fx.deinit();
        self.alloc.destroy(self);
    }

    fn nextTag(self: *Harness) u16 {
        self.tag += 1;
        return self.tag;
    }

    fn send(self: *Harness, m: msg.Message) !void {
        var enc: [2048]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        try self.pipe.clientEnd().writeMsg(enc[0..n]);
        _ = try self.srv.step();
    }

    fn recv(self: *Harness) !?msg.Message {
        const frame = self.pipe.clientEnd().readMsg(&self.rbuf) catch |e| switch (e) {
            error.WouldBlock => return null,
            else => return e,
        };
        return try msg.decode(frame);
    }

    fn transact(self: *Harness, m: msg.Message) !msg.Message {
        try self.send(m);
        return (try self.recv()) orelse error.NoReply;
    }

    fn connect(self: *Harness) !void {
        const rv = try self.transact(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect(rv.body == .rversion);
        const ra = try self.transact(.{ .tag = self.nextTag(), .body = .{ .tattach = .{ .fid = 0, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
        try testing.expect(ra.body == .rattach);
    }

    fn walk(self: *Harness, fid: u32, newfid: u32, names: []const []const u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(fid, newfid, names) } });
    }

    fn open(self: *Harness, fid: u32, mode: u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .topen = .{ .fid = fid, .mode = mode } } });
    }

    fn read(self: *Harness, fid: u32, offset: u64, count: u32) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .tread = .{ .fid = fid, .offset = offset, .count = count } } });
    }

    fn statOf(self: *Harness, fid: u32) !Stat {
        const r = try self.transact(.{ .tag = self.nextTag(), .body = .{ .tstat = .{ .fid = fid } } });
        try testing.expect(r.body == .rstat);
        return try Stat.decode(r.body.rstat.stat);
    }
};

test "served: walk and stat two windows" {
    const h = try Harness.create(testing.allocator, "one", "hello\n");
    defer h.destroy();
    _ = try h.tree.addWindow("two", "hi\n"); // id 2
    try h.connect();

    // walk root → "1" yields the window directory qid.
    const w1 = try h.walk(0, 1, &.{"1"});
    try testing.expect(w1.body == .rwalk);
    try testing.expectEqual(@as(u16, 1), w1.body.rwalk.nwqid);
    try testing.expectEqual(qpath(1, .dir), w1.body.rwalk.qids()[0].path);
    try testing.expect(w1.body.rwalk.qids()[0].qtype.dir);

    // stat of the window dir: name ".", DMDIR|0500 (f->dir == dirtabw[0]).
    const s1 = try h.statOf(1);
    try testing.expectEqualStrings(".", s1.name);
    try testing.expectEqual(DMDIR | @as(u32, 0o500), s1.mode);
    try testing.expect(s1.qid.qtype.dir);
    try testing.expectEqual(qpath(1, .dir), s1.qid.path);

    // walk root → "1"/"ctl": two qids, the second the ctl file.
    const wc = try h.walk(0, 2, &.{ "1", "ctl" });
    try testing.expect(wc.body == .rwalk);
    try testing.expectEqual(@as(u16, 2), wc.body.rwalk.nwqid);
    try testing.expectEqual(qpath(1, .dir), wc.body.rwalk.qids()[0].path);
    try testing.expectEqual(qpath(1, .w_ctl), wc.body.rwalk.qids()[1].path);
    const sc = try h.statOf(2);
    try testing.expectEqualStrings("ctl", sc.name);
    try testing.expectEqual(@as(u32, 0o600), sc.mode);
    try testing.expect(!sc.qid.qtype.dir);
    try testing.expectEqual(qpath(1, .w_ctl), sc.qid.path);

    // Window 2: body + tag walk/stat.
    const wb = try h.walk(0, 3, &.{ "2", "body" });
    try testing.expectEqual(qpath(2, .w_body), wb.body.rwalk.qids()[1].path);
    const sb = try h.statOf(3);
    try testing.expectEqualStrings("body", sb.name);
    try testing.expectEqual(DMAPPEND | @as(u32, 0o600), sb.mode);

    const wt = try h.walk(0, 4, &.{ "2", "tag" });
    try testing.expectEqual(qpath(2, .w_tag), wt.body.rwalk.qids()[1].path);
    const st = try h.statOf(4);
    try testing.expectEqualStrings("tag", st.name);

    // A missing window id ⇒ "file does not exist".
    const miss = try h.walk(0, 5, &.{"9"});
    try testing.expect(miss.body == .rerror);
    try testing.expectEqualStrings("file does not exist", miss.body.rerror.ename);
}

test "served: ctl line exact" {
    const h = try Harness.create(testing.allocator, "one", "hello\n");
    defer h.destroy();
    try h.connect();
    const w = h.tree.row.col.items[0].w.items[0];

    // Read 1/ctl fully.
    _ = try h.walk(0, 1, &.{ "1", "ctl" });
    const o = try h.open(1, msg.OREAD);
    try testing.expect(o.body == .ropen);
    const rr = try h.read(1, 0, 4096);
    try testing.expect(rr.body == .rread);

    // maxtab is 72 for the 9x18 body frame (Frame contract). dx = Dx(body.fr.r),
    // hand-derived from the booted scene.
    try testing.expectEqual(@as(i32, 72), w.body.fr.maxtab);
    const dx: u32 = @intCast(w.body.fr.r.max.x - w.body.fr.r.min.x);

    var expbuf: [256]u8 = undefined;
    const exp = try std.fmt.bufPrint(&expbuf, "{d:>11} {d:>11} {d:>11} {d:>11} {d:>11} {d:>11} fixed9x18 {d:>11} {d:>11} {d:>11} ", .{
        @as(u32, w.id),
        @as(usize, w.tag.file.buffer.len()),
        @as(usize, w.body.file.buffer.len()),
        @as(u32, 0), // isdir
        @as(u32, @intFromBool(w.dirty)), // dirty (false at boot)
        dx,
        @as(u32, 72), // maxtab
        @as(u32, 0), // undo pending
        @as(u32, 0), // redo pending
    });
    try testing.expectEqualStrings(exp, rr.body.rread.data);
    // The 60-byte prefix is exactly five columns.
    try testing.expectEqual(Window.ctl_size, @as(usize, 60));

    // One undoable body insert ⇒ the undo column flips to 1 (and dirty to 1).
    h.ed.seq += 1;
    w.body.file.mark(h.ed.seq);
    try w.body.insertAt(0, "X", true);
    try testing.expect(w.body.file.undoSeq() != 0);
    try testing.expect(w.dirty);

    _ = try h.walk(0, 2, &.{ "1", "ctl" });
    _ = try h.open(2, msg.OREAD);
    const rr2 = try h.read(2, 0, 4096);
    var expbuf2: [256]u8 = undefined;
    const exp2 = try std.fmt.bufPrint(&expbuf2, "{d:>11} {d:>11} {d:>11} {d:>11} {d:>11} {d:>11} fixed9x18 {d:>11} {d:>11} {d:>11} ", .{
        @as(u32, w.id),
        @as(usize, w.tag.file.buffer.len()),
        @as(usize, w.body.file.buffer.len()),
        @as(u32, 0),
        @as(u32, 1), // dirty now true
        dx,
        @as(u32, 72),
        @as(u32, 1), // undo pending now true
        @as(u32, 0),
    });
    try testing.expectEqualStrings(exp2, rr2.body.rread.data);
}

test "served: dead window fid" {
    const h = try Harness.create(testing.allocator, "one", "hello\n");
    defer h.destroy();
    try h.connect();
    const col = h.tree.row.col.items[0];
    const w1 = col.w.items[0];

    // Open 1/body — succeeds even though the body READ is a B3 stub.
    _ = try h.walk(0, 1, &.{ "1", "body" });
    const o = try h.open(1, msg.ORDWR);
    try testing.expect(o.body == .ropen);

    // Delete window 1 directly (ctl-write "del" is B3's).
    try col.close(&h.ed, w1, true);

    // A read on the still-open body fid ⇒ "deleted window" (the Edel analog).
    const rr = try h.read(1, 0, 100);
    try testing.expect(rr.body == .rerror);
    try testing.expectEqualStrings("deleted window", rr.body.rerror.ename);

    // A FRESH walk to its id ⇒ "file does not exist".
    const rw = try h.walk(0, 2, &.{"1"});
    try testing.expect(rw.body == .rerror);
    try testing.expectEqualStrings("file does not exist", rw.body.rerror.ename);
}

test "served: walk new creates window" {
    const h = try Harness.create(testing.allocator, "one", "hello\n");
    defer h.destroy();
    try h.connect();
    const col = h.tree.row.col.items[0];
    try testing.expectEqual(@as(usize, 1), col.w.items.len);

    // Walk root → "new"/"ctl": mints a window, returns [dir(newid), w_ctl].
    const rw = try h.walk(0, 1, &.{ "new", "ctl" });
    try testing.expect(rw.body == .rwalk);
    try testing.expectEqual(@as(u16, 2), rw.body.rwalk.nwqid);

    try testing.expectEqual(@as(usize, 2), col.w.items.len); // the column grew
    const newid = col.w.items[1].id;
    try testing.expectEqual(@as(u32, 2), newid);
    try testing.expectEqual(qpath(newid, .dir), rw.body.rwalk.qids()[0].path);
    try testing.expectEqual(qpath(newid, .w_ctl), rw.body.rwalk.qids()[1].path);

    // The ctl read shows the fresh id in its first column.
    _ = try h.open(1, msg.OREAD);
    const rr = try h.read(1, 0, 4096);
    try testing.expect(rr.body == .rread);
    var idbuf: [16]u8 = undefined;
    const idcol = try std.fmt.bufPrint(&idbuf, "{d:>11} ", .{newid});
    try testing.expect(std.mem.startsWith(u8, rr.body.rread.data, idcol));
}

test "served: root dir read lists sorted window dirs" {
    const h = try Harness.create(testing.allocator, "one", "a\n"); // id 1
    defer h.destroy();
    _ = try h.tree.addWindow("two", "b\n"); // id 2
    try h.connect();

    // Force iteration order != id order (id 2 before id 1) so the qsort is
    // load-bearing.
    const col = h.tree.row.col.items[0];
    std.mem.swap(*Window, &col.w.items[0], &col.w.items[1]);

    _ = try h.open(0, msg.OREAD); // open the root directory
    const rr = try h.read(0, 0, 8192);
    try testing.expect(rr.body == .rread);

    // Entries come out index, new, then window ids ASCENDING.
    const want = [_][]const u8{ "index", "new", "1", "2" };
    var data = rr.body.rread.data;
    var off: usize = 0;
    var idx: usize = 0;
    while (off < data.len) : (idx += 1) {
        const size = std.mem.readInt(u16, data[off..][0..2], .little);
        const total = 2 + @as(usize, size);
        const st = try Stat.decode(data[off..][0..total]);
        try testing.expectEqualStrings(want[idx], st.name);
        off += total;
    }
    try testing.expectEqual(want.len, idx);

    // Entry-boundary offset continuation: cut the request so only index+new fit,
    // then a second read at that offset yields exactly the two window dirs.
    const size0 = 2 + @as(usize, std.mem.readInt(u16, data[0..2], .little)); // index
    const size1 = 2 + @as(usize, std.mem.readInt(u16, data[size0..][0..2], .little)); // new
    const cut: u32 = @intCast(size0 + size1);

    const first = try h.read(0, 0, cut);
    try testing.expect(first.body == .rread);
    try testing.expectEqual(@as(usize, size0 + size1), first.body.rread.data.len);

    const second = try h.read(0, cut, 8192);
    try testing.expect(second.body == .rread);
    data = second.body.rread.data;
    off = 0;
    idx = 0;
    const want2 = [_][]const u8{ "1", "2" };
    while (off < data.len) : (idx += 1) {
        const size = std.mem.readInt(u16, data[off..][0..2], .little);
        const total = 2 + @as(usize, size);
        const st = try Stat.decode(data[off..][0..total]);
        try testing.expectEqualStrings(want2[idx], st.name);
        off += total;
    }
    try testing.expectEqual(want2.len, idx);
}
