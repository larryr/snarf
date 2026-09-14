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
    fn request(self: *Self, fid: u32, rec: FsRecord, key: u64) OpBlockError!Completion {
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

    fn pathOf(self: *Self, qid: Qid) OpError![]const u8 {
        return self.paths.get(qid.path) orelse error.FileDoesNotExist;
    }

    fn dropListing(self: *Self, fid: u32) void {
        if (self.listings.fetchRemove(fid)) |kv| self.allocator.free(kv.value);
    }

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
        const c = try self.request(fid.fid, .{ .op = .stat, .path = child }, key);
        if (c.status != .ok) return tree.statusError(c.status);
        const sr = FsRecord.StatReply.decode(c.payload) catch return error.IoError;
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
        const c = try self.request(fid.fid, .{ .op = .stat, .path = path }, fid.qid.path);
        if (c.status != .ok) return tree.statusError(c.status);
        const sr = FsRecord.StatReply.decode(c.payload) catch return error.IoError;
        if (sr.is_dir) return error.FileIsDirectory; // it changed under us
        if ((mode & msg.OTRUNC) != 0) {
            const t = try self.request(fid.fid, .{ .op = .truncate, .path = path, .arg0 = 0 }, fid.qid.path);
            if (t.status != .ok) return tree.statusError(t.status);
            return tree.qidOf(fid.qid.path, false, 0);
        }
        return tree.qidOf(fid.qid.path, false, sr.mtime_ms);
    }

    fn readOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, buf: []u8) ReadError!usize {
        const self = devOf(ctx);
        return self.finish(self.read(fid, offset, buf));
    }

    fn read(self: *Self, fid: *Fid, offset: u64, buf: []u8) ReadError!usize {
        const path = try self.pathOf(fid.qid);
        if (fid.qid.qtype.dir) {
            if (self.listings.get(fid.fid) == null) {
                const c = try self.request(fid.fid, .{ .op = .list, .path = path }, fid.qid.path);
                if (c.status != .ok) return tree.statusError(c.status);
                const s = try tree.buildListing(self.allocator, path, c.payload, &self.path_buf);
                self.listings.put(self.allocator, fid.fid, s) catch {
                    self.allocator.free(s);
                    return error.IoError;
                };
            }
            return tree.readListing(self.listings.get(fid.fid).?, offset, buf);
        }
        if (buf.len == 0) return 0;
        const c = try self.request(fid.fid, .{
            .op = .read,
            .path = path,
            .arg0 = offset,
            .arg1 = @intCast(buf.len),
        }, offset);
        if (c.status != .ok) return tree.statusError(c.status);
        const n = @min(buf.len, c.payload.len);
        @memcpy(buf[0..n], c.payload[0..n]);
        return n;
    }

    fn writeOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, data: []const u8) OpBlockError!usize {
        const self = devOf(ctx);
        return self.finish(self.write(fid, offset, data));
    }

    fn write(self: *Self, fid: *Fid, offset: u64, data: []const u8) OpBlockError!usize {
        if (fid.qid.qtype.dir) return error.FileIsDirectory;
        const path = try self.pathOf(fid.qid);
        const c = try self.request(fid.fid, .{
            .op = .write,
            .path = path,
            .arg0 = offset,
            .payload = data,
        }, offset);
        if (c.status != .ok) return tree.statusError(c.status);
        return @min(data.len, FsRecord.decodeWriteCount(c.payload));
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
    }

    fn statOp(ctx: *anyopaque, _: *Server, fid: *Fid) OpBlockError!Stat {
        const self = devOf(ctx);
        return self.finish(self.stat(fid));
    }

    fn stat(self: *Self, fid: *Fid) OpBlockError!Stat {
        const path = try self.pathOf(fid.qid);
        const c = try self.request(fid.fid, .{ .op = .stat, .path = path }, fid.qid.path);
        if (c.status != .ok) return tree.statusError(c.status);
        const sr = FsRecord.StatReply.decode(c.payload) catch return error.IoError;
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
    }

    fn clunkOp(ctx: *anyopaque, _: *Server, fid: *Fid) void {
        const self = devOf(ctx);
        self.pending.dropFid(self.allocator, fid.fid);
        self.dropListing(fid.fid);
    }
};

// ===========================================================================
// Tests — SMOKE ONLY. The named battery (T2-T11: scripted out-of-order
// completion over a real Pipe + Client, chunked reads, OTRUNC, create/remove,
// every status string) is the test author's, per contract §4.
// ===========================================================================
const testing = std.testing;

/// The scripted backend the tests plug in for the browser: it RECORDS every
/// record it is handed and answers nothing until a test says so, which is what
/// makes park/complete ordering observable.
const Script = struct {
    alloc: std.mem.Allocator,
    dev: *DevOpfs = undefined,
    log: std.ArrayList([]u8) = .empty,
    tickets: std.ArrayList(u32) = .empty,

    fn requester(self: *Script) Requester {
        return .{ .ctx = self, .issue = issue };
    }

    fn issue(ctx: ?*anyopaque, ticket: u32, record: []const u8) void {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        self.log.append(self.alloc, self.alloc.dupe(u8, record) catch return) catch return;
        self.tickets.append(self.alloc, ticket) catch return;
    }

    fn deinit(self: *Script) void {
        for (self.log.items) |r| self.alloc.free(r);
        self.log.deinit(self.alloc);
        self.tickets.deinit(self.alloc);
    }

    fn last(self: *Script) FsRecord {
        return FsRecord.decode(self.log.items[self.log.items.len - 1]) catch unreachable;
    }

    fn answer(self: *Script, i: usize, status: FsRecord.Status, payload: []const u8) void {
        self.dev.complete(self.tickets.items[i], status, payload);
    }
};

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
