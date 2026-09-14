//! devopfs — `/mnt/opfs`, the browser's Origin Private File System served as a
//! 9P tree from inside the module (R-9P-09's OPFS half, S-02 §4).
//!
//! It is the first CREATABLE tree Snarf has: plain files and directories,
//! read/write, create/remove, OTRUNC and a length-only wstat. It is also the
//! first tree that cannot answer anything synchronously — every OPFS call in a
//! browser main thread is a promise — so EVERY operation here may return
//! `park.WouldBlock` and be answered on a later frame (14a's generalised
//! parking; R-9P-13).
//!
//! THE SHAPE, in one paragraph. A 9P op arrives; the device turns it into an
//! `FsRecord` (`shim/FsRecord.zig`), hands it to a `Requester` with a fresh
//! ticket, files a slot (`opfs_slots.zig`) and answers `WouldBlock`. The
//! framework parks the whole T-frame. Some time later the browser answers: the
//! glue calls `complete(ticket, status, payload)` — which only caches — and
//! then `Server.retryParked()`, which re-dispatches the parked frame. The op
//! re-runs from the top, finds its answers already in their slots, and replies.
//! Nothing spins, nothing blocks, and a completion that arrives for a fid that
//! has since been clunked is dropped on the floor (R-P14b-3).
//!
//! WHY A `Requester` VTABLE. `DevOpfs` never calls `shim.abi.fsOp` itself. In
//! the browser the requester IS that import (`shimRequester`); in tests it is a
//! scripted queue that can answer in any order, so the whole device — parking,
//! out-of-order completion, error mapping, the listing cache — runs natively
//! under `zig build test` with no browser and no shim (R-CON-02's spirit for a
//! device: the browser is a plug, not a dependency).
//!
//! WHAT IT DOES NOT DO (R-P14b-4, draft R-P13-6): no rename — OPFS's `move()`
//! is Chromium-only, so a `wstat` that changes a name is refused outright; no
//! recursive remove (9P has none: a non-empty directory is `"directory not
//! empty"`); no sync access handles (worker-only, and they arrive free with the
//! Worker+SAB move).
//!
//! Ground truth: `5/open` (create perm masking, OTRUNC), `5/remove`, `5/stat`,
//! `5/walk` (partial walks), `5/read` (whole directory records) at the pinned
//! `larryr/plan9@ed1a9c2`; the device pattern is `dev/input.zig`, the tree
//! logic is `tools/origin/hostfs.zig` with the synchronous host calls replaced
//! by parked round trips.
//!
//! Imports: std + `ninep` + `shim` (S-07 §6). No `core`, no browser API.
const std = @import("std");
const ninep = @import("ninep");
const shim = @import("shim");
const tree = @import("opfs_tree.zig");
const slots = @import("opfs_slots.zig");
const opfs_io = @import("opfs_io.zig");
const opfs_cache = @import("opfs_cache.zig");

const Server = ninep.server.Server;
const Fid = ninep.server.Fid;
const ReadError = ninep.server.ReadError;
const OpBlockError = ninep.server.OpBlockError;
const CreateResult = ninep.server.CreateResult;
const OpError = ninep.errors.OpError;
const Qid = ninep.Qid;
const Stat = ninep.stat;
const msg = ninep.msg;
const FsRecord = shim.abi.FsRecord;

pub const Completion = slots.Completion;

/// Where the module sends its requests. One call, `issue`: "perform this
/// record and, some time later and NEVER re-entrantly, hand the answer to
/// `DevOpfs.complete` under this ticket." `record` is borrowed for the
/// duration of the call only.
pub const Requester = struct {
    ctx: ?*anyopaque = null,
    issue: *const fn (ctx: ?*anyopaque, ticket: u32, record: []const u8) void,
};

/// Where the one-line diagnostics go (the root owns `consoleLog`, R-P5-6).
pub const LogHook = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, line: []const u8) void,
};

/// The production requester: the `fsOp` ABI import (ABI v6).
pub fn shimRequester() Requester {
    return .{ .ctx = null, .issue = shimIssue };
}

fn shimIssue(_: ?*anyopaque, ticket: u32, record: []const u8) void {
    shim.abi.fsOp(record.ptr, @intCast(record.len), ticket);
}

/// The single line printed when the backend answers `io` for the first time —
/// which is what a browser with no `navigator.storage.getDirectory` does for
/// every ticket (R-P14b-2: the mount exists unconditionally and its absence
/// surfaces as errors plus this one line, not as a missing mount point).
pub const unavailable_line = "/mnt/opfs: unavailable";

pub const DevOpfs = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    req: Requester,
    log: ?LogHook = null,
    /// qid.path → absolute path. The ONLY per-file state; fids carry nothing.
    paths: tree.PathTable = .{},
    /// In-flight and cached `fsOp` answers, keyed by (fid, op, key).
    pending: slots.Table = .{},
    /// Per-fid directory listing, built by the first read of an open directory
    /// and served offset-addressed from then on. Dropped on clunk, on re-open
    /// and on a create through the same fid.
    listings: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// Per-PATH `stat` memo, keyed by the path's qid hash and so shared across
    /// every fid that names the file (14b review; 16b item 3). See `statOf`.
    stat_memo: std.AutoHashMapUnmanaged(u64, FsRecord.StatReply) = .empty,
    /// Fids with a write sequence outstanding: the browser is holding a
    /// `createWritable` stream open for their path, and their clunk is what
    /// tells it to close (record version 2; 16b item 4). See `clunkOp`.
    writers: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Scratch for building one child path (never held across a call).
    path_buf: [tree.max_path]u8 = undefined,
    /// Scratch the outgoing record is encoded into; grows to the largest
    /// write payload the session sees and is never shrunk.
    rec_buf: std.ArrayList(u8) = .empty,
    /// The `unavailable_line` is printed at most once per session.
    warned: bool = false,

    pub fn init(allocator: std.mem.Allocator, req: Requester) Self {
        return .{ .allocator = allocator, .req = req };
    }

    pub fn deinit(self: *Self) void {
        var it = self.listings.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.listings.deinit(self.allocator);
        self.stat_memo.deinit(self.allocator);
        self.writers.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.rec_buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// Land one browser answer. Caching ONLY — the caller (`opfs_glue`) then
    /// calls `Server.retryParked()`, which is what actually produces replies.
    /// An unknown ticket is dropped silently (R-P14b-3).
    pub fn complete(self: *Self, ticket: u32, status: FsRecord.Status, payload: []const u8) void {
        if (status == .io and !self.warned) {
            self.warned = true;
            if (self.log) |l| l.write(l.ctx, unavailable_line);
        }
        _ = self.pending.complete(self.allocator, ticket, status, payload);
    }

    /// How many `fsOp`s this device is holding state for — in flight plus
    /// cached-but-unconsumed. Test/adapter observability, like `parkedCount`.
    pub fn inflight(self: *const Self) usize {
        return self.pending.count();
    }

    // -- the browser round trip ---------------------------------------------

    /// Ask for `rec`, or collect the answer to an identical earlier ask.
    /// `key` disambiguates slots on one fid: the byte offset for read/write,
    /// the target path's qid hash for everything else (R-P14b-3).
    pub fn request(self: *Self, fid: u32, rec: FsRecord, key: u64) OpBlockError!Completion {
        if (self.pending.take(fid, rec.op, key)) |c| return c;
        if (self.pending.find(fid, rec.op, key) != null) return error.WouldBlock; // asked, no answer yet
        const n = rec.encodedSize();
        self.rec_buf.resize(self.allocator, n) catch return error.IoError;
        _ = rec.encode(self.rec_buf.items) catch return error.IoError;
        const ticket = self.pending.issue(self.allocator, fid, rec.op, key) catch return error.IoError;
        self.req.issue(self.req.ctx, ticket, self.rec_buf.items);
        return error.WouldBlock;
    }

    /// Every `Ops` entry point ends here: a blocked op hands its consumed
    /// answers back to the retry, a finished one lets them go (see
    /// `opfs_slots.zig`'s header for why this is the whole trick).
    fn finish(self: *Self, r: anytype) @TypeOf(r) {
        const blocked = if (r) |_| false else |e| isBlock(e);
        self.pending.endOp(self.allocator, blocked);
        return r;
    }

    fn isBlock(e: anyerror) bool {
        return e == error.WouldBlock or e == error.WouldBlockRead;
    }

    pub fn pathOf(self: *Self, qid: Qid) OpError![]const u8 {
        return self.paths.get(qid.path) orelse error.FileDoesNotExist;
    }

    fn dropListing(self: *Self, fid: u32) void {
        if (self.listings.fetchRemove(fid)) |kv| self.allocator.free(kv.value);
    }

    /// The per-path `stat` memo and the write-sequence bookkeeping live in
    /// `opfs_cache.zig` (size seam, S-07 §2). Decl aliases, so `self.statOf(…)`
    /// / `self.forgetStat(…)` / `self.markWriter(…)` resolve as methods and the
    /// `Ops` bodies read exactly as they did.
    const statOf = opfs_cache.statOf;
    pub const forgetStat = opfs_cache.forgetStat;
    pub const forgetChildren = opfs_cache.forgetChildren;
    pub const markWriter = opfs_cache.markWriter;
    const issueUnwatched = opfs_cache.issueUnwatched;

    // -- Ops vtable ---------------------------------------------------------

    pub const ops: ninep.server.Ops = .{
        .attach = attachOp,
        .walk1 = walk1Op,
        .open = openOp,
        .read = readOp,
        .write = writeOp,
        .clunk = clunkOp,
        .stat = statOp,
        .create = createOp,
        .remove = removeOp,
        .wstat = wstatOp,
    };

    fn devOf(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    /// The root is named without asking the browser: it always exists (OPFS
    /// hands out a root directory even when it is empty), and an attach that
    /// parked would make the mount itself asynchronous for no gain.
    fn attachOp(ctx: *anyopaque, _: *Server, _: *Fid, _: []const u8) OpError!Qid {
        const self = devOf(ctx);
        const key = try self.paths.intern(self.allocator, tree.root);
        return tree.qidOf(key, true, 0);
    }

    fn walk1Op(ctx: *anyopaque, _: *Server, fid: *Fid, name: []const u8) OpBlockError!Qid {
        const self = devOf(ctx);
        return self.finish(self.walk1(fid, name));
    }

    /// One component. `..` is pure arithmetic (the parent of an existing path
    /// exists, and the root's parent is the root); every other name costs one
    /// `stat` round trip, issued once and reused across retries.
    fn walk1(self: *Self, fid: *Fid, name: []const u8) OpBlockError!Qid {
        if (!fid.qid.qtype.dir) return error.WalkNoDir;
        const dir = try self.pathOf(fid.qid);
        if (std.mem.eql(u8, name, "..")) {
            const key = try self.paths.intern(self.allocator, tree.parentPath(dir));
            return tree.qidOf(key, true, 0);
        }
        if (!tree.validName(name)) return error.FileDoesNotExist;
        const child = try tree.joinInto(&self.path_buf, dir, name);
        const key = tree.hashPath(child);
        const sr = try self.statOf(fid.fid, child, key);
        _ = try self.paths.intern(self.allocator, child);
        return tree.qidOf(key, sr.is_dir, sr.mtime_ms);
    }

    fn openOp(ctx: *anyopaque, _: *Server, fid: *Fid, mode: u8) OpBlockError!Qid {
        const self = devOf(ctx);
        return self.finish(self.open(fid, mode));
    }

    /// Directories open for free — the walk that reached one already proved it
    /// exists, and the framework has already refused a write mode on a dir
    /// (`5/open`). Files are confirmed with a `stat`, and OTRUNC costs one
    /// more round trip (`truncate 0`) before the open reports success.
    fn open(self: *Self, fid: *Fid, mode: u8) OpBlockError!Qid {
        const path = try self.pathOf(fid.qid);
        if (fid.qid.qtype.dir) {
            self.dropListing(fid.fid); // a re-open re-reads the directory
            return fid.qid;
        }
        const sr = try self.statOf(fid.fid, path, fid.qid.path);
        if (sr.is_dir) return error.FileIsDirectory; // it changed under us
        if ((mode & msg.OTRUNC) != 0) {
            const t = try self.request(fid.fid, .{ .op = .truncate, .path = path, .arg0 = 0 }, fid.qid.path);
            if (t.status != .ok) return tree.statusError(t.status);
            self.forgetStat(path); // length 0 now
            return tree.qidOf(fid.qid.path, false, 0);
        }
        return tree.qidOf(fid.qid.path, false, sr.mtime_ms);
    }

    fn readOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, buf: []u8) ReadError!usize {
        const self = devOf(ctx);
        return self.finish(self.read(fid, offset, buf));
    }

    /// `read`/`write` bodies live in `opfs_io.zig` since phase 16a; decl
    /// aliases, so `self.read(...)` resolves exactly as before.
    const read = opfs_io.read;
    const write = opfs_io.write;

    fn writeOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, data: []const u8) OpBlockError!usize {
        const self = devOf(ctx);
        return self.finish(self.write(fid, offset, data));
    }

    fn createOp(ctx: *anyopaque, _: *Server, fid: *Fid, name: []const u8, perm: u32, _: u8) OpBlockError!CreateResult {
        const self = devOf(ctx);
        return self.finish(self.create(fid, name, perm));
    }

    /// `5/open`: DMDIR in `perm` selects a directory, the rest is masked
    /// against the parent's permissions, and the framework re-points the fid
    /// onto the result from the `CreateResult` we return.
    fn create(self: *Self, fid: *Fid, name: []const u8, perm: u32) OpBlockError!CreateResult {
        const dir = try self.pathOf(fid.qid);
        if (!tree.validName(name)) return error.FileDoesNotExist; // framework checked; belt and braces
        const child = try tree.joinInto(&self.path_buf, dir, name);
        const is_dir = (perm & Stat.DMDIR) != 0;
        const key = tree.hashPath(child);
        const c = try self.request(fid.fid, .{
            .op = if (is_dir) .create_dir else .create_file,
            .path = child,
            .arg1 = tree.maskPerm(perm, is_dir),
        }, key);
        if (c.status != .ok) return tree.statusError(c.status);
        _ = try self.paths.intern(self.allocator, child);
        self.forgetStat(child); // the child is new and the parent has grown
        self.dropListing(fid.fid); // the fid now names the new file, not the directory
        return .{ .qid = tree.qidOf(key, is_dir, 0) };
    }

    fn removeOp(ctx: *anyopaque, _: *Server, fid: *Fid) OpBlockError!void {
        const self = devOf(ctx);
        return self.finish(self.remove(fid));
    }

    /// `5/remove`. A non-empty directory comes back as `not_empty` — 9P has no
    /// recursive remove, and neither does `removeEntry` without `{recursive}`,
    /// which the shim deliberately never passes (R-P14b-4).
    fn remove(self: *Self, fid: *Fid) OpBlockError!void {
        const path = try self.pathOf(fid.qid);
        if (std.mem.eql(u8, path, tree.root)) return error.PermissionDenied;
        const c = try self.request(fid.fid, .{ .op = .remove, .path = path }, fid.qid.path);
        if (c.status != .ok) return tree.statusError(c.status);
        self.forgetStat(path);
    }

    fn statOp(ctx: *anyopaque, _: *Server, fid: *Fid) OpBlockError!Stat {
        const self = devOf(ctx);
        return self.finish(self.stat(fid));
    }

    fn stat(self: *Self, fid: *Fid) OpBlockError!Stat {
        const path = try self.pathOf(fid.qid);
        const sr = try self.statOf(fid.fid, path, fid.qid.path);
        return tree.statOf(
            tree.baseName(path),
            tree.qidOf(fid.qid.path, sr.is_dir, sr.mtime_ms),
            sr.size,
            sr.mtime_ms,
        );
    }

    fn wstatOp(ctx: *anyopaque, _: *Server, fid: *Fid, st: Stat) OpBlockError!void {
        const self = devOf(ctx);
        return self.finish(self.wstat(fid, st));
    }

    /// LENGTH ONLY (R-P14b-4). A wstat that would rename, chmod or re-time is
    /// refused with the framework's own `"wstat prohibited"`; an all-"don't
    /// touch" wstat is the conventional no-op and succeeds.
    fn wstat(self: *Self, fid: *Fid, st: Stat) OpBlockError!void {
        if (st.name.len != 0 or st.uid.len != 0 or st.gid.len != 0) return error.WstatProhibited;
        if (st.mode != 0xFFFF_FFFF or st.atime != 0xFFFF_FFFF or st.mtime != 0xFFFF_FFFF) {
            return error.WstatProhibited;
        }
        if (st.length == std.math.maxInt(u64)) return; // nothing asked for
        if (fid.qid.qtype.dir) return error.FileIsDirectory;
        const path = try self.pathOf(fid.qid);
        const c = try self.request(fid.fid, .{
            .op = .truncate,
            .path = path,
            .arg0 = st.length,
        }, fid.qid.path);
        if (c.status != .ok) return tree.statusError(c.status);
        self.forgetStat(path);
    }

    /// `5/clunk`. Besides forgetting the fid's slots and listing, this is where
    /// a write sequence ENDS: the backend has kept one
    /// `FileSystemWritableFileStream` open for the path since the first Twrite
    /// (a stream writes to a swap file until closed, so opening one per write
    /// cost three platform round trips per Twrite), and `close` is what commits
    /// it. FIRE AND FORGET: the record goes out under ticket 0, which matches
    /// no slot, so the completion is dropped exactly as a completion for an
    /// already-clunked fid is (R-P14b-3). `Ops.clunk` returns void and may not
    /// park, so there is nothing to wait for — and nothing needs to: the
    /// backend also closes the stream before any operation that must see the
    /// file's committed contents, making `close` an optimisation, not a fence.
    fn clunkOp(ctx: *anyopaque, _: *Server, fid: *Fid) void {
        const self = devOf(ctx);
        if (self.writers.remove(fid.fid)) {
            if (self.paths.get(fid.qid.path)) |path| self.issueUnwatched(.{ .op = .close, .path = path });
        }
        self.pending.dropFid(self.allocator, fid.fid);
        self.dropListing(fid.fid);
    }
};

// ===========================================================================
// Tests — SMOKE ONLY. The named battery (T2-T11: scripted out-of-order
// completion over a real Pipe + Client, chunked reads, OTRUNC, create/remove,
// every status string) is the test author's, per contract §4. Their shared
// harness (`Script`, `Wire`, `drive`) lives in `opfs_testsrv.zig` since
// phase 16a.
// ===========================================================================
const testing = std.testing;
const testsrv = @import("opfs_testsrv.zig");
const Script = testsrv.Script;
const Answer = testsrv.Answer;
const Wire = testsrv.Wire;
const drive = testsrv.drive;
const chan = ninep.chan;

test "devopfs: a walk parks once per component and reuses its answers on retry" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    var dev = DevOpfs.init(a, sc.requester());
    defer dev.deinit();
    sc.dev = &dev;

    var fid = Fid{ .fid = 3, .qid = undefined, .uname = @constCast("larry") };
    fid.qid = try DevOpfs.ops.attach(&dev, undefined, &fid, "");
    try testing.expect(fid.qid.qtype.dir);

    // First component: one `stat /a`, then park.
    try testing.expectError(error.WouldBlock, DevOpfs.ops.walk1(&dev, undefined, &fid, "a"));
    try testing.expectEqual(@as(usize, 1), sc.log.items.len);
    try testing.expectEqual(FsRecord.Op.stat, sc.last().op);
    try testing.expectEqualStrings("/a", sc.last().path);

    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = true }).encode(&sb);
    sc.answer(0, .ok, &sb);

    // The retry re-runs the WHOLE walk: component 0 is served from its slot
    // (no second `stat /a`), component 1 issues exactly one new record.
    fid.qid = try DevOpfs.ops.walk1(&dev, undefined, &fid, "a");
    try testing.expectEqual(@as(usize, 1), sc.log.items.len);
    try testing.expectError(error.WouldBlock, DevOpfs.ops.walk1(&dev, undefined, &fid, "b.txt"));
    try testing.expectEqual(@as(usize, 2), sc.log.items.len);
    try testing.expectEqualStrings("/a/b.txt", sc.last().path);

    (FsRecord.StatReply{ .is_dir = false, .size = 12, .mtime_ms = 5_000 }).encode(&sb);
    sc.answer(1, .ok, &sb);
    const q = try DevOpfs.ops.walk1(&dev, undefined, &fid, "b.txt");
    try testing.expect(!q.qtype.dir);
    try testing.expectEqual(@as(u32, 5), q.vers); // ms → s
    try testing.expectEqual(@as(usize, 0), dev.inflight()); // nothing left over

    // `..` and bad names cost no round trip at all.
    fid.qid = q;
    try testing.expectError(error.WalkNoDir, DevOpfs.ops.walk1(&dev, undefined, &fid, ".."));
    try testing.expectEqual(@as(usize, 2), sc.log.items.len);
}

test "devopfs: errors map to Plan 9 strings and the unavailable line prints once" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    var dev = DevOpfs.init(a, sc.requester());
    defer dev.deinit();
    sc.dev = &dev;

    const Rec = struct {
        var lines: usize = 0;
        fn write(_: ?*anyopaque, line: []const u8) void {
            std.debug.assert(std.mem.eql(u8, line, unavailable_line));
            lines += 1;
        }
    };
    Rec.lines = 0;
    dev.log = .{ .write = Rec.write };

    var fid = Fid{ .fid = 1, .qid = undefined, .uname = @constCast("larry") };
    fid.qid = try DevOpfs.ops.attach(&dev, undefined, &fid, "");

    try testing.expectError(error.WouldBlock, DevOpfs.ops.walk1(&dev, undefined, &fid, "gone"));
    sc.answer(0, .not_found, "");
    try testing.expectError(error.FileDoesNotExist, DevOpfs.ops.walk1(&dev, undefined, &fid, "gone"));

    try testing.expectError(error.WouldBlock, DevOpfs.ops.walk1(&dev, undefined, &fid, "boom"));
    sc.answer(1, .io, "");
    try testing.expectError(error.IoError, DevOpfs.ops.walk1(&dev, undefined, &fid, "boom"));
    try testing.expectEqual(@as(usize, 1), Rec.lines);

    try testing.expectError(error.WouldBlock, DevOpfs.ops.walk1(&dev, undefined, &fid, "boom2"));
    sc.answer(2, .io, "");
    try testing.expectError(error.IoError, DevOpfs.ops.walk1(&dev, undefined, &fid, "boom2"));
    try testing.expectEqual(@as(usize, 1), Rec.lines); // still once
}

test "devopfs: a clunked fid's late completion is dropped" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    var dev = DevOpfs.init(a, sc.requester());
    defer dev.deinit();
    sc.dev = &dev;

    var fid = Fid{ .fid = 9, .qid = undefined, .uname = @constCast("larry") };
    fid.qid = try DevOpfs.ops.attach(&dev, undefined, &fid, "");
    try testing.expectError(error.WouldBlock, DevOpfs.ops.walk1(&dev, undefined, &fid, "x"));
    try testing.expectEqual(@as(usize, 1), dev.inflight());

    DevOpfs.ops.clunk.?(&dev, undefined, &fid);
    try testing.expectEqual(@as(usize, 0), dev.inflight());
    sc.answer(0, .ok, ""); // nobody is waiting: dropped, not stored
    try testing.expectEqual(@as(usize, 0), dev.inflight());
}

test "devopfs wire T2: a walk over the pipe parks on one stat and completes on the answer" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = false, .size = 3, .mtime_ms = 9_000 }).encode(&sb);
    const r = try drive(
        h,
        &sc,
        .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"f"}) } },
        &.{.{ .status = .ok, .payload = &sb }},
    );
    try testing.expect(r.body == .rwalk);
    try testing.expectEqual(@as(usize, 1), r.body.rwalk.nwqid);
    try testing.expectEqual(@as(usize, 1), sc.log.items.len); // exactly one round trip
    const rec = try FsRecord.decode(sc.log.items[0]);
    try testing.expectEqual(FsRecord.Op.stat, rec.op);
    try testing.expectEqualStrings("/f", rec.path);
}

test "devopfs wire T3: two fids' walks park independently and complete out of order" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    try h.send(.{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"a"}) } });
    try testing.expectEqual(@as(?msg.Message, null), try h.recv());
    try h.send(.{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 2, &.{"b"}) } });
    try testing.expectEqual(@as(?msg.Message, null), try h.recv());
    try testing.expectEqual(@as(usize, 2), h.dev.inflight());

    // Answer "b"'s ticket (issued SECOND) first: only fid 2 unparks.
    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = true }).encode(&sb);
    sc.answer(1, .ok, &sb);
    _ = try h.srv.retryParked();
    const rb = (try h.recv()).?;
    try testing.expect(rb.body == .rwalk);
    try testing.expectEqual(@as(usize, 1), h.dev.inflight()); // "a" still parked

    (FsRecord.StatReply{ .is_dir = false, .size = 1 }).encode(&sb);
    sc.answer(0, .ok, &sb);
    _ = try h.srv.retryParked();
    const ra = (try h.recv()).?;
    try testing.expect(ra.body == .rwalk);
    try testing.expectEqual(@as(usize, 0), h.dev.inflight());
}

test "devopfs wire T4: a 20000-byte file reads byte-exact via chunked Tread" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    const data = try a.alloc(u8, 20_000);
    defer a.free(data);
    for (data, 0..) |*b, i| b.* = @intCast('a' + (i % 26));

    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = false, .size = data.len, .mtime_ms = 1 }).encode(&sb);
    const rw = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"big"}) } }, &.{.{ .status = .ok, .payload = &sb }});
    try testing.expect(rw.body == .rwalk);
    const ro = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .topen = .{ .fid = 1, .mode = msg.OREAD } } }, &.{.{ .status = .ok, .payload = &sb }});
    try testing.expect(ro.body == .ropen);

    const got = try a.alloc(u8, data.len);
    defer a.free(got);
    var off: u64 = 0;
    while (off < data.len) {
        const want: u32 = 4096;
        const end = @min(off + want, data.len);
        const r = try drive(
            h,
            &sc,
            .{ .tag = h.nextTag(), .body = .{ .tread = .{ .fid = 1, .offset = off, .count = want } } },
            &.{.{ .status = .ok, .payload = data[off..end] }},
        );
        try testing.expect(r.body == .rread);
        const n = r.body.rread.data.len;
        try testing.expect(n > 0);
        @memcpy(got[off..][0..n], r.body.rread.data);
        off += n;
    }
    try testing.expectEqual(@as(u64, data.len), off);
    try testing.expectEqualSlices(u8, data, got);
}

test "devopfs wire T5: OTRUNC open issues stat then truncate(0); the write after it works" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = false, .size = 9, .mtime_ms = 1 }).encode(&sb);
    const rw = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"f"}) } }, &.{.{ .status = .ok, .payload = &sb }});
    try testing.expect(rw.body == .rwalk);

    const ro = try drive(
        h,
        &sc,
        .{ .tag = h.nextTag(), .body = .{ .topen = .{ .fid = 1, .mode = msg.OWRITE | msg.OTRUNC } } },
        &.{ .{ .status = .ok, .payload = &sb }, .{ .status = .ok } },
    );
    try testing.expect(ro.body == .ropen);
    // [0] the walk's own stat, [1] OTRUNC's truncate. Since 16b item 3 the
    // per-path stat memo answers `open`'s confirming stat with the walk's
    // reply, so this used to be three records and is now two.
    try testing.expectEqual(@as(usize, 2), sc.log.items.len);
    const trunc = try FsRecord.decode(sc.log.items[1]);
    try testing.expectEqual(FsRecord.Op.truncate, trunc.op);
    try testing.expectEqual(@as(u64, 0), trunc.arg0);

    var wc: [4]u8 = undefined;
    std.mem.writeInt(u32, &wc, 5, .little);
    const wr = try drive(
        h,
        &sc,
        .{ .tag = h.nextTag(), .body = .{ .twrite = .{ .fid = 1, .offset = 0, .data = "hello" } } },
        &.{.{ .status = .ok, .payload = &wc }},
    );
    try testing.expect(wr.body == .rwrite);
    try testing.expectEqual(@as(u32, 5), wr.body.rwrite.count);
    try testing.expectEqual(FsRecord.Op.write, (try FsRecord.decode(sc.log.items[2])).op);
}

test "devopfs wire T6: create masks the perm, re-points the fid, and a following Twrite works" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    // A second untouched root fid, cloned via a bare Twalk (no fsOp at all).
    const clone = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 2, &.{}) } }, &.{});
    try testing.expect(clone.body == .rwalk);
    try testing.expectEqual(@as(usize, 0), sc.log.items.len);

    const rc = try drive(
        h,
        &sc,
        .{ .tag = h.nextTag(), .body = .{ .tcreate = .{ .fid = 0, .name = "new.txt", .perm = 0o666, .mode = msg.OWRITE } } },
        &.{.{ .status = .ok }},
    );
    try testing.expect(rc.body == .rcreate);
    const rec = try FsRecord.decode(sc.log.items[sc.log.items.len - 1]);
    try testing.expectEqual(FsRecord.Op.create_file, rec.op);
    try testing.expectEqualStrings("/new.txt", rec.path);
    try testing.expectEqual(@as(u32, 0o644), rec.arg1); // 0666 masked by the 0755 dir_mode

    var wc: [4]u8 = undefined;
    std.mem.writeInt(u32, &wc, 2, .little);
    const wr = try drive(
        h,
        &sc,
        .{ .tag = h.nextTag(), .body = .{ .twrite = .{ .fid = 0, .offset = 0, .data = "hi" } } },
        &.{.{ .status = .ok, .payload = &wc }},
    );
    try testing.expect(wr.body == .rwrite);
    try testing.expectEqual(@as(u32, 2), wr.body.rwrite.count); // the fid now IS the new file

    const rd = try drive(
        h,
        &sc,
        .{ .tag = h.nextTag(), .body = .{ .tcreate = .{ .fid = 2, .name = "sub", .perm = Stat.DMDIR | 0o777, .mode = msg.OREAD } } },
        &.{.{ .status = .ok }},
    );
    try testing.expect(rd.body == .rcreate);
    const recd = try FsRecord.decode(sc.log.items[sc.log.items.len - 1]);
    try testing.expectEqual(FsRecord.Op.create_dir, recd.op);
    try testing.expectEqualStrings("/sub", recd.path);
    // The DMDIR bit rides through untouched (maskPerm's `~0o777` leaves every
    // bit above the low 9 alone); only the permission bits are masked.
    try testing.expectEqual(@as(u32, Stat.DMDIR | 0o755), recd.arg1);
}

test "devopfs wire T7: remove — ok and 'directory not empty', the fid clunked either way" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = false }).encode(&sb);
    const w1 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"gone"}) } }, &.{.{ .status = .ok, .payload = &sb }});
    try testing.expect(w1.body == .rwalk);
    const rr1 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tremove = .{ .fid = 1 } } }, &.{.{ .status = .ok }});
    try testing.expect(rr1.body == .rremove);
    const after1 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tstat = .{ .fid = 1 } } }, &.{});
    try testing.expect(after1.body == .rerror);
    try testing.expectEqualStrings("unknown fid", after1.body.rerror.ename);

    (FsRecord.StatReply{ .is_dir = true }).encode(&sb);
    const w2 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 2, &.{"full"}) } }, &.{.{ .status = .ok, .payload = &sb }});
    try testing.expect(w2.body == .rwalk);
    const rr2 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tremove = .{ .fid = 2 } } }, &.{.{ .status = .not_empty }});
    try testing.expect(rr2.body == .rerror);
    try testing.expectEqualStrings("directory not empty", rr2.body.rerror.ename);
    const after2 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tstat = .{ .fid = 2 } } }, &.{});
    try testing.expect(after2.body == .rerror);
    try testing.expectEqualStrings("unknown fid", after2.body.rerror.ename); // R-P14a-3: clunked even on failure
}

test "devopfs wire T8: dir read serves the cached listing, continues by offset, rejects a misaligned one" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    // Root (fid 0) is already a dir: opening it issues NO fsOp.
    const ro = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .topen = .{ .fid = 0, .mode = msg.OREAD } } }, &.{});
    try testing.expect(ro.body == .ropen);
    try testing.expectEqual(@as(usize, 0), sc.log.items.len);

    var payload: [64]u8 = undefined;
    var p: usize = 0;
    p += try (FsRecord.ListEntry{ .is_dir = true, .name = "sub" }).encode(payload[p..]);
    p += try (FsRecord.ListEntry{ .is_dir = false, .name = "f.txt" }).encode(payload[p..]);

    const r1 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tread = .{ .fid = 0, .offset = 0, .count = 4096 } } }, &.{.{ .status = .ok, .payload = payload[0..p] }});
    try testing.expect(r1.body == .rread);
    const first = try Stat.decode(r1.body.rread.data);
    try testing.expectEqualStrings("sub", first.name);
    try testing.expectEqual(@as(usize, 1), sc.log.items.len); // one `list`, cached

    // Continuation from the offset the first read reported: no new fsOp.
    const r2 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tread = .{ .fid = 0, .offset = @intCast(first.encodedSize()), .count = 4096 } } }, &.{});
    try testing.expect(r2.body == .rread);
    const second = try Stat.decode(r2.body.rread.data);
    try testing.expectEqualStrings("f.txt", second.name);
    try testing.expectEqual(@as(usize, 1), sc.log.items.len); // still one — served from cache

    // A misaligned offset: "bad offset" (lib9p/srv.c:474 sread), not a crash,
    // not garbage, and no longer the generic "bad message" (16b item 2).
    const bad = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tread = .{ .fid = 0, .offset = 1, .count = 4096 } } }, &.{});
    try testing.expect(bad.body == .rerror);
    try testing.expectEqualStrings("bad offset", bad.body.rerror.ename);
}

test "devopfs wire T9: every fsOp status maps to its exact Rerror string" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    const cases = [_]struct { status: FsRecord.Status, want: []const u8 }{
        .{ .status = .not_found, .want = "file does not exist" },
        .{ .status = .exists, .want = "file already exists" },
        .{ .status = .not_dir, .want = "not a directory" },
        .{ .status = .is_dir, .want = "file is a directory" }, // kernel Eisdir, not the contract's shorthand
        .{ .status = .permission, .want = "permission denied" },
        .{ .status = .quota, .want = "no space on device" },
        .{ .status = .not_empty, .want = "directory not empty" },
        .{ .status = .io, .want = "i/o error" },
    };
    var fid: u32 = 1;
    for (cases) |c| {
        const r = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, fid, &.{"x"}) } }, &.{.{ .status = c.status }});
        try testing.expect(r.body == .rerror);
        try testing.expectEqualStrings(c.want, r.body.rerror.ename);
        fid += 1;
    }
}

test "devopfs wire T10: an always-io backend maps every op to 'i/o error' and logs the unavailable line once" {
    const a = testing.allocator;
    const AutoIo = struct {
        dev: *DevOpfs = undefined,
        fn issue(ctx: ?*anyopaque, ticket: u32, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.dev.complete(ticket, .io, ""); // exactly what a browser missing OPFS does (§3a)
        }
        fn requester(self: *@This()) Requester {
            return .{ .ctx = self, .issue = issue };
        }
    };
    var air = AutoIo{};
    const h = try Wire.create(a, air.requester());
    defer h.destroy();
    air.dev = &h.dev;

    const Rec = struct {
        var n: usize = 0;
        fn write(_: ?*anyopaque, line: []const u8) void {
            std.debug.assert(std.mem.eql(u8, line, unavailable_line));
            n += 1;
        }
    };
    Rec.n = 0;
    h.dev.log = .{ .write = Rec.write };
    try h.connect(); // attach never asks the backend anything

    try h.send(.{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"x"}) } });
    try testing.expectEqual(@as(?msg.Message, null), try h.recv()); // parked once, though already answered
    _ = try h.srv.retryParked();
    const r1 = (try h.recv()).?;
    try testing.expect(r1.body == .rerror);
    try testing.expectEqualStrings("i/o error", r1.body.rerror.ename);
    try testing.expectEqual(@as(usize, 1), Rec.n);

    try h.send(.{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 2, &.{"y"}) } });
    _ = try h.srv.retryParked();
    const r2 = (try h.recv()).?;
    try testing.expect(r2.body == .rerror);
    try testing.expectEqual(@as(usize, 1), Rec.n); // still once (R-9P-10-style absence)
}

test "devopfs wire T11: clunking a fid mid-flight drops its late fsOp completion silently" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = false, .size = 100 }).encode(&sb);
    const w = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"f"}) } }, &.{.{ .status = .ok, .payload = &sb }});
    try testing.expect(w.body == .rwalk);
    const o = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .topen = .{ .fid = 1, .mode = msg.OREAD } } }, &.{.{ .status = .ok, .payload = &sb }});
    try testing.expect(o.body == .ropen);

    // A Tread parks; note its ticket's slot before the fid disappears under it.
    try h.send(.{ .tag = h.nextTag(), .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 64 } } });
    try testing.expectEqual(@as(?msg.Message, null), try h.recv());
    try testing.expectEqual(@as(usize, 1), h.dev.inflight());
    const late_index = sc.tickets.items.len - 1;

    // Tclunk: the framework interrupts the parked Tread (R-P6-5) before it
    // answers the clunk itself, and `DevOpfs.clunkOp` drops the read's slot.
    try h.send(.{ .tag = h.nextTag(), .body = .{ .tclunk = .{ .fid = 1 } } });
    const interrupted = (try h.recv()).?;
    try testing.expect(interrupted.body == .rerror);
    try testing.expectEqualStrings("interrupted", interrupted.body.rerror.ename);
    const rc = (try h.recv()).?;
    try testing.expect(rc.body == .rclunk);
    try testing.expectEqual(@as(usize, 0), h.dev.inflight()); // the slot went with the fid

    // The late browser answer for the abandoned read: dropped, no crash, no leak.
    sc.answer(late_index, .ok, "stale");
    try testing.expectEqual(@as(usize, 0), h.dev.inflight());
    try testing.expectEqual(@as(usize, 0), try h.srv.retryParked());
}

test "devopfs: the per-path stat memo is shared across fids and dropped by a write (16b item 3)" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = false, .size = 9, .mtime_ms = 1 }).encode(&sb);

    // Walk fid 1 to "f": one stat, memoised under hash("/f").
    try testing.expect((try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"f"}) } }, &.{.{ .status = .ok, .payload = &sb }})).body == .rwalk);
    try testing.expectEqual(@as(usize, 1), sc.log.items.len);

    // A SECOND fid onto the same file, and a Tstat through it: neither costs a
    // round trip — the memo is keyed by path, not by fid.
    try testing.expect((try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 2, &.{"f"}) } }, &.{})).body == .rwalk);
    const st = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tstat = .{ .fid = 2 } } }, &.{});
    try testing.expect(st.body == .rstat);
    try testing.expectEqual(@as(u64, 9), (try Stat.decode(st.body.rstat.stat)).length);
    try testing.expectEqual(@as(usize, 1), sc.log.items.len);

    // A write through fid 1 changes the length, so the memo goes: the next
    // Tstat pays for a fresh one, and reports the new size.
    try testing.expect((try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .topen = .{ .fid = 1, .mode = msg.OWRITE } } }, &.{})).body == .ropen);
    var wc: [4]u8 = undefined;
    std.mem.writeInt(u32, &wc, 5, .little);
    try testing.expect((try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twrite = .{ .fid = 1, .offset = 0, .data = "hello" } } }, &.{.{ .status = .ok, .payload = &wc }})).body == .rwrite);

    (FsRecord.StatReply{ .is_dir = false, .size = 5, .mtime_ms = 2 }).encode(&sb);
    const st2 = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tstat = .{ .fid = 2 } } }, &.{.{ .status = .ok, .payload = &sb }});
    try testing.expect(st2.body == .rstat);
    try testing.expectEqual(@as(u64, 5), (try Stat.decode(st2.body.rstat.stat)).length);
    try testing.expectEqual(FsRecord.Op.stat, (try FsRecord.decode(sc.log.items[sc.log.items.len - 1])).op);
}

test "devopfs: a write sequence is closed once, at the clunk of the fid that wrote (16b item 4)" {
    const a = testing.allocator;
    var sc = Script{ .alloc = a };
    defer sc.deinit();
    const h = try Wire.create(a, sc.requester());
    defer h.destroy();
    sc.dev = &h.dev;
    try h.connect();

    var sb: [FsRecord.StatReply.len]u8 = undefined;
    (FsRecord.StatReply{ .is_dir = false, .size = 0, .mtime_ms = 1 }).encode(&sb);
    try testing.expect((try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"f"}) } }, &.{.{ .status = .ok, .payload = &sb }})).body == .rwalk);
    try testing.expect((try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .topen = .{ .fid = 1, .mode = msg.OWRITE } } }, &.{})).body == .ropen);

    // Two sequential writes: two `write` records, no `close` between them —
    // the browser keeps ONE createWritable open across the sequence.
    var wc: [4]u8 = undefined;
    std.mem.writeInt(u32, &wc, 2, .little);
    for (0..2) |i| {
        const w = try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .twrite = .{ .fid = 1, .offset = @intCast(i * 2), .data = "hi" } } }, &.{.{ .status = .ok, .payload = &wc }});
        try testing.expect(w.body == .rwrite);
    }
    for (sc.log.items) |r| try testing.expect((try FsRecord.decode(r)).op != .close);

    // The clunk ends it: exactly one `close`, naming the path, fire and forget
    // under ticket 0 (no slot, so `inflight` does not grow).
    try testing.expect((try drive(h, &sc, .{ .tag = h.nextTag(), .body = .{ .tclunk = .{ .fid = 1 } } }, &.{})).body == .rclunk);
    var closes: usize = 0;
    for (sc.log.items, sc.tickets.items) |r, t| {
        const rec = try FsRecord.decode(r);
        if (rec.op != .close) continue;
        closes += 1;
        try testing.expectEqualStrings("/f", rec.path);
        try testing.expectEqual(@as(u32, 0), t);
    }
    try testing.expectEqual(@as(usize, 1), closes);
    try testing.expectEqual(@as(usize, 0), h.dev.inflight());
}
