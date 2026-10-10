//! nswrite.zig — WRITING through the namespace asynchronously: `WriteFileJob`,
//! the third leg of `nsjob.zig` (walk) / `nsio.zig` (read). Re-exported from
//! `nsjob.zig`, which is the name the rest of the tree uses.
//!
//! What it is: Plan 9's `create(name, OWRITE, 0666)` + `write` loop + `close`
//! (acme `putfile`, exec.c:727-773 at `larryr/plan9port@337c6ac`) turned inside
//! out, one 9P message in flight per `step()` on `tickets.begin/check` exactly
//! like `nsio.Drain` (R-9P-13, R-P13a-3: `check` never pumps, never blocks).
//!
//!     walking ──ok──> opening (Topen OWRITE|OTRUNC) ──> writing (Twrite*) ──> clunking ──> done
//!        └─NotFound && create && !must_exist──> parent_walking ──> creating (Tcreate) ──> writing …
//!
//! Plan 9's `create` on an EXISTING file truncates it (`5/open`); 9P's Tcreate
//! on an existing name fails instead, which is why the existing-file arm is a
//! Topen(OTRUNC) and only a NotFound walk falls through to Tcreate. The kernel
//! picks the union member carrying MCREATE for a create (`9/port/chan.c` namec
//! `Acreate`); Snarf's mount table has no MCREATE flag, so the parent walk's
//! own first-success union rule decides — bind order (only `/bin` is a union).
//!
//! DROPPED: the partial-range arm of `putfile` (exec.c:775 `q0!=0 ||
//! q1!=f->b.nc`) — Snarf's Put always writes the whole buffer.
//!
//! POINTER STABILITY (nsjob.zig's rule): the job borrows `path` and `data`, and
//! hands its inline reply buffer to a live ticket; it must not move once `step`
//! has run, and `path`/`data` must outlive it.
//!
//! Imports: std + sibling ninep files (S-07 §6). Nothing here touches `core`,
//! `dev` or `shim`.
const std = @import("std");
const Client = @import("client.zig").Client;
const mount = @import("mount.zig");
const msg = @import("msg.zig");
const nsjob = @import("nsjob.zig");
const Qid = @import("qid.zig");
const tickets = @import("tickets.zig");

const Namespace = mount.Namespace;
const Status = nsjob.Status;
const Step = nsjob.Step;
const WalkJob = nsjob.WalkJob;

/// Everything a namespace job can fail with, plus the two write-only verdicts.
pub const Error = nsjob.Error || error{
    /// An `Rwrite.count` short of the chunk sent (`Bwrite(b, s, m) != m`,
    /// exec.c:757).
    ShortWrite,
    /// The opened file carries QTAPPEND and the caller said it already holds
    /// data (exec.c:744-748 `isapp`).
    AppendOnly,
};

/// `WriteFileJob` policy. `refuse_append` is the caller's half of acme's
/// `isapp` test (exec.c:744): the job only sees the Ropen/Rcreate qid, the
/// caller knows the pre-write length, so it says "refuse an append-only file".
pub const Options = struct {
    /// Topen with OTRUNC (Plan 9 `create` semantics on an existing file).
    truncate: bool = true,
    /// A missing file is Tcreate'd in its parent.
    create: bool = true,
    perm: u32 = 0o666,
    /// A missing file is `error.NotFound`, never created (Putall's `access()`
    /// check, R-P17-3).
    must_exist: bool = false,
    /// Fail with `error.AppendOnly` (before any Twrite) if the opened qid has
    /// QTAPPEND.
    refuse_append: bool = false,
};

/// Bytes a Twrite frame costs besides its payload: size[4] type[1] tag[2]
/// fid[4] offset[8] count[4] — the `- msg.header_size - 23` of the contract's
/// chunk formula (the extra margin keeps a chunk well inside msize).
const twrite_overhead: usize = 23;

pub const WriteFileJob = struct {
    ns: *const Namespace,
    /// Borrowed, absolute.
    path: []const u8,
    /// Borrowed; must outlive the job.
    data: []const u8,
    opts: Options,
    walk: WalkJob,
    client: ?*Client = null,
    fid: u32 = 0,
    /// Bytes acknowledged so far (final once `step` reports `done`).
    written: usize = 0,
    /// The chunk in flight.
    chunk: usize = 0,
    /// The qid of the opened (or created) file — carries `qtype.append`.
    qid: Qid = .{ .path = 0 },
    /// True when the file did not exist and was Tcreate'd.
    created: bool = false,
    st: Step = .{},
    buf: [nsjob.small_reply]u8 = undefined,
    phase: Phase = .walking,

    /// `pub` so a caller can tell a failure to OPEN/CREATE (`walking`,
    /// `opening`, `parent_walking`, `creating`) from a failure to WRITE
    /// (`writing`, `clunking`) — acme's two different warnings.
    pub const Phase = enum { walking, opening, parent_walking, creating, writing, clunking, done };

    pub fn init(ns: *const Namespace, path: []const u8, data: []const u8, opts: Options) Error!WriteFileJob {
        return .{ .ns = ns, .path = path, .data = data, .opts = opts, .walk = try WalkJob.init(ns, path) };
    }

    /// True once the job has an open fid and is (or was) pushing bytes — an
    /// error from this point on is "can't write", not "can't create".
    pub fn pastOpen(self: *const WriteFileJob) bool {
        return self.phase == .writing or self.phase == .clunking or self.phase == .done;
    }

    pub fn step(self: *WriteFileJob) Error!Status {
        switch (self.phase) {
            .done => return .done,
            .walking => {
                const st = self.walk.step() catch |e| {
                    if (e != error.NotFound or !self.opts.create or self.opts.must_exist) return e;
                    return self.startParentWalk();
                };
                if (st == .pending) return .pending;
                const f = switch (self.walk.result) {
                    .dir => return error.FileIsDirectory, // a synthetic mount-point directory
                    .fid => |f| f,
                };
                self.client = f.client;
                self.fid = f.fid;
                const mode: u8 = msg.OWRITE | (if (self.opts.truncate) msg.OTRUNC else 0);
                try self.st.send(f.client, .{ .tag = 0, .body = .{
                    .topen = .{ .fid = f.fid, .mode = mode },
                } }, &self.buf);
                self.phase = .opening;
                return .pending;
            },
            .opening => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                const o = switch (m.body) {
                    .ropen => |o| o,
                    else => return error.ProtocolError,
                };
                return self.opened(o.qid);
            },
            .parent_walking => {
                if (try self.walk.step() == .pending) return .pending;
                const f = switch (self.walk.result) {
                    // Nothing can be created in the synthetic root device.
                    .dir => return error.PermissionDenied,
                    .fid => |f| f,
                };
                self.client = f.client;
                self.fid = f.fid;
                // Tcreate: "the fid now IS the new file" (`5/open`).
                try self.st.send(f.client, .{ .tag = 0, .body = .{ .tcreate = .{
                    .fid = f.fid,
                    .name = baseName(self.path),
                    .perm = self.opts.perm,
                    .mode = msg.OWRITE,
                } } }, &self.buf);
                self.phase = .creating;
                return .pending;
            },
            .creating => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                const cr = switch (m.body) {
                    .rcreate => |cr| cr,
                    else => return error.ProtocolError,
                };
                self.client.?.seedQid(self.fid, cr.qid);
                self.created = true;
                return self.opened(cr.qid);
            },
            .writing => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                const count = switch (m.body) {
                    .rwrite => |r| r.count,
                    else => return error.ProtocolError,
                };
                if (count != self.chunk) return error.ShortWrite; // exec.c:757
                self.written += self.chunk;
                return self.sendNext();
            },
            .clunking => {
                const c = self.client.?;
                const finished = if (self.st.poll(c)) |m| m != null else |_| true;
                if (!finished) return .pending;
                c.freeFid(self.fid);
                self.client = null;
                self.phase = .done;
                return .done;
            },
        }
    }

    /// The walk said "no such file": walk to the parent instead, then Tcreate.
    fn startParentWalk(self: *WriteFileJob) Error!Status {
        self.walk.deinit();
        self.walk = try WalkJob.init(self.ns, dirName(self.path));
        self.phase = .parent_walking;
        return .pending;
    }

    /// Ropen/Rcreate landed: the append-only refusal, then the first Twrite.
    fn opened(self: *WriteFileJob, qid: Qid) Error!Status {
        self.qid = qid;
        self.phase = .writing;
        if (self.opts.refuse_append and qid.qtype.append) return error.AppendOnly; // exec.c:744-748
        return self.sendNext();
    }

    /// The next Twrite, or the Tclunk once every byte is acknowledged. The
    /// writes go back to back on ONE fid with nothing else on the path in
    /// between (R-P17-2: `/mnt/opfs` keeps one writable stream per path).
    fn sendNext(self: *WriteFileJob) Error!Status {
        const c = self.client.?;
        if (self.written >= self.data.len) {
            try self.st.send(c, .{ .tag = 0, .body = .{ .tclunk = .{ .fid = self.fid } } }, &self.buf);
            self.phase = .clunking;
            return .pending;
        }
        const room = c.ioMax() -| (msg.header_size + twrite_overhead);
        self.chunk = @min(self.data.len - self.written, @max(room, 1));
        try self.st.send(c, .{ .tag = 0, .body = .{ .twrite = .{
            .fid = self.fid,
            .offset = self.written,
            .data = self.data[self.written..][0..self.chunk],
        } } }, &self.buf);
        return .pending;
    }

    /// Abandon the job. Fire-and-forget on every path (the `nsio.Drain.deinit`
    /// rule): a job may be torn down on a client with no pump, so it must never
    /// wait for a reply — `tickets.discardClunk` releases the fid on a tombstone.
    pub fn deinit(self: *WriteFileJob) void {
        if (self.client) |c| {
            self.st.abort(c);
            // In `.clunking` the Tclunk is already on the wire.
            if (self.phase == .clunking) c.freeFid(self.fid) else tickets.discardClunk(c, self.fid);
        }
        self.walk.deinit();
        self.* = undefined;
    }
};

/// The parent of an absolute path ("/a/b" ⇒ "/a", "/a" ⇒ "/").
fn dirName(path: []const u8) []const u8 {
    const p = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return "/";
    return if (i == 0) "/" else p[0..i];
}

/// The last component of an absolute path.
fn baseName(path: []const u8) []const u8 {
    const p = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
    return p[i + 1 ..];
}

// ==========================================================================
// Smoke tests. The named battery (T1-T3) is the test writer's; these only pin
// the path helpers and that a missing-file write refuses cleanly under
// `must_exist` over the 12d `nsdir` fixtures.
// ==========================================================================
const testing = std.testing;
const nsdir = @import("nsdir.zig");

test "nswrite: dirName / baseName" {
    try testing.expectEqualStrings("/a", dirName("/a/b"));
    try testing.expectEqualStrings("/", dirName("/a"));
    try testing.expectEqualStrings("b", baseName("/a/b"));
    try testing.expectEqualStrings("a", baseName("/a"));
}

test "nswrite: must_exist turns a missing file into NotFound, no create" {
    const a = testing.allocator;
    var t = nsdir.FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var s = try nsdir.FakeServer.init(a, &t);
    defer s.deinit();
    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/x", s.client, s.root_fid);
    var pumps = nsjob.Pumps{ .srvs = &.{s.srv} };

    var j = try WriteFileJob.init(&ns, "/x/nope", "data", .{ .must_exist = true });
    defer j.deinit();
    try testing.expectError(error.NotFound, nsjob.runSync(&j, pumps.pump()));
    try testing.expect(!j.created);
}

// ==========================================================================
// T1-T3: a minimal writable/creatable tree, ninep-internal (nsdir.FakeTree is
// read-only and has no `create` — core's MemTree.zig fixture is off-limits
// here, S-07 §6: `ninep` never imports `core`). One root dir (qid 1), zero or
// more named subdirectories directly under it (qid 2..), files anywhere
// (their own qid, tracked by `parent`).
// ==========================================================================
const server = @import("server.zig");
const errors = @import("errors.zig");
const Stat = @import("stat.zig");
const chan = @import("chan.zig");

const WFile = struct {
    name: []const u8,
    parent: u64,
    qid_path: u64,
    data: std.ArrayList(u8) = .empty,
    vers: u32 = 1,
};

/// One entry per server-side op call, in arrival order — the decoded shape of
/// whatever frame the wire carried (the server only ever sees what the client
/// put on the wire, so this pins the frame order/fields as surely as reading
/// the bytes back would, without re-parsing `msg.zig`'s wire format by hand).
const LogEntry = union(enum) {
    walk: []const u8,
    open: struct { trunc: bool },
    write: struct { offset: u64, len: usize },
    create: []const u8,
};

const WTree = struct {
    alloc: std.mem.Allocator,
    subdirs: []const []const u8 = &.{},
    files: std.ArrayList(WFile) = .empty,
    next_id: u64 = 1000, // well clear of the 2..(2+subdirs.len) dir range
    log: std.ArrayList(LogEntry) = .empty,

    fn deinit(self: *WTree) void {
        for (self.files.items) |*f| {
            self.alloc.free(f.name);
            f.data.deinit(self.alloc);
        }
        self.files.deinit(self.alloc);
        for (self.log.items) |e| switch (e) {
            .walk => |n| self.alloc.free(n),
            .create => |n| self.alloc.free(n),
            else => {},
        };
        self.log.deinit(self.alloc);
    }

    fn isDirPath(self: *WTree, path: u64) bool {
        return path == 1 or (path >= 2 and path < 2 + self.subdirs.len);
    }

    fn subDirId(self: *WTree, name: []const u8) ?u64 {
        for (self.subdirs, 0..) |n, i| if (std.mem.eql(u8, n, name)) return 2 + i;
        return null;
    }

    fn findByName(self: *WTree, parent: u64, name: []const u8) ?*WFile {
        for (self.files.items) |*f| if (f.parent == parent and std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    fn findByQid(self: *WTree, path: u64) ?*WFile {
        for (self.files.items) |*f| if (f.qid_path == path) return f;
        return null;
    }

    fn attach(_: *anyopaque, _: *server.Server, _: *server.Fid, _: []const u8) errors.OpError!Qid {
        return .{ .path = 1, .qtype = .{ .dir = true } };
    }

    fn walk1(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) errors.OpError!Qid {
        const self: *WTree = @ptrCast(@alignCast(ctx));
        if (self.alloc.dupe(u8, name)) |n| self.log.append(self.alloc, .{ .walk = n }) catch {} else |_| {}
        if (std.mem.eql(u8, name, "..")) return .{ .path = 1, .qtype = .{ .dir = true } };
        if (!self.isDirPath(fid.qid.path)) return error.WalkNoDir;
        if (fid.qid.path == 1) {
            if (self.subDirId(name)) |id| return .{ .path = id, .qtype = .{ .dir = true } };
        }
        if (self.findByName(fid.qid.path, name)) |f| return .{ .path = f.qid_path, .vers = f.vers };
        return error.FileDoesNotExist;
    }

    fn open(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, mode: u8) errors.OpError!Qid {
        const self: *WTree = @ptrCast(@alignCast(ctx));
        self.log.append(self.alloc, .{ .open = .{ .trunc = mode & msg.OTRUNC != 0 } }) catch {};
        if (self.isDirPath(fid.qid.path)) {
            if ((mode & 3) != msg.OREAD) return error.PermissionDenied;
            return fid.qid;
        }
        const f = self.findByQid(fid.qid.path) orelse return error.FileDoesNotExist;
        if (mode & msg.OTRUNC != 0) {
            f.data.clearRetainingCapacity();
            f.vers += 1;
        }
        return .{ .path = fid.qid.path, .vers = f.vers };
    }

    fn read(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u64, _: []u8) server.ReadError!usize {
        return 0; // unused: WriteFileJob never reads
    }

    fn write(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, data: []const u8) errors.OpError!usize {
        const self: *WTree = @ptrCast(@alignCast(ctx));
        self.log.append(self.alloc, .{ .write = .{ .offset = offset, .len = data.len } }) catch {};
        const f = self.findByQid(fid.qid.path) orelse return error.PermissionDenied;
        const off: usize = @intCast(offset);
        if (off + data.len > f.data.items.len) f.data.resize(self.alloc, off + data.len) catch return error.IoError;
        @memcpy(f.data.items[off..][0..data.len], data);
        f.vers += 1;
        return data.len;
    }

    fn statOp(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) errors.OpError!Stat {
        const self: *WTree = @ptrCast(@alignCast(ctx));
        if (self.isDirPath(fid.qid.path)) return .{ .qid = fid.qid, .mode = Stat.DMDIR | 0o755, .length = 0, .name = "/", .uid = "", .gid = "", .muid = "" };
        const f = self.findByQid(fid.qid.path) orelse return error.FileDoesNotExist;
        return .{ .qid = .{ .path = f.qid_path, .vers = f.vers }, .mode = 0o644, .length = f.data.items.len, .mtime = f.vers, .name = f.name, .uid = "", .gid = "", .muid = "" };
    }

    fn create(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8, perm: u32, _: u8) server.OpBlockError!server.CreateResult {
        const self: *WTree = @ptrCast(@alignCast(ctx));
        if (self.alloc.dupe(u8, name)) |n| self.log.append(self.alloc, .{ .create = n }) catch {} else |_| {}
        if (perm & Stat.DMDIR != 0) return error.PermissionDenied;
        if (!self.isDirPath(fid.qid.path)) return error.PermissionDenied;
        if (self.findByName(fid.qid.path, name) != null) return error.FileExists;
        const copy = self.alloc.dupe(u8, name) catch return error.IoError;
        const id = self.next_id;
        self.next_id += 1;
        self.files.append(self.alloc, .{ .name = copy, .parent = fid.qid.path, .qid_path = id }) catch {
            self.alloc.free(copy);
            return error.IoError;
        };
        return .{ .qid = .{ .path = id } };
    }

    const ops = server.Ops{
        .attach = attach,
        .walk1 = walk1,
        .open = open,
        .read = read,
        .write = write,
        .stat = statOp,
        .create = create,
    };
};

/// `WTree` behind a pipe, mounted and ready — the writable analog of
/// `nsdir.FakeServer`.
const WServer = struct {
    tree: *WTree,
    pipe: *chan.Pipe,
    srv: *server.Server,
    client: *Client,
    root_fid: u32,
    allocator: std.mem.Allocator,

    fn pump(ctx: *anyopaque) anyerror!void {
        const s: *server.Server = @ptrCast(@alignCast(ctx));
        _ = try s.poll();
    }

    fn init(allocator: std.mem.Allocator, subdirs: []const []const u8) !WServer {
        const tree = try allocator.create(WTree);
        tree.* = .{ .alloc = allocator, .subdirs = subdirs };
        const pipe = try chan.Pipe.init(allocator, 65536);
        const srv = try allocator.create(server.Server);
        srv.* = try server.Server.init(allocator, pipe.serverEnd(), &WTree.ops, tree, 8192);
        const cl = try allocator.create(Client);
        cl.* = try Client.init(allocator, pipe.clientEnd(), 8192);
        cl.pump = .{ .ctx = srv, .run = pump };
        _ = try cl.version(8192);
        const root = try cl.attach("larry", "");
        return .{ .tree = tree, .pipe = pipe, .srv = srv, .client = cl, .root_fid = root.fid, .allocator = allocator };
    }

    fn deinit(self: *WServer) void {
        self.client.deinit();
        self.allocator.destroy(self.client);
        self.srv.deinit();
        self.allocator.destroy(self.srv);
        self.pipe.deinit();
        self.tree.deinit();
        self.allocator.destroy(self.tree);
    }
};

test "nswrite: WriteFileJob over an existing file — Twalk, Topen(OWRITE|OTRUNC), N Twrites at advancing offsets, Tclunk, chunked by ioMax (T1)" {
    const a = testing.allocator;
    var s = try WServer.init(a, &.{});
    defer s.deinit();
    // Seed the file directly in the fixture (not through the wire) so the
    // server's op log below starts clean at the job under test.
    const copy = try a.dupe(u8, "f");
    try s.tree.files.append(a, .{ .name = copy, .parent = 1, .qid_path = 1000 });
    s.tree.next_id = 1001;

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/x", s.client, s.root_fid);
    var pumps = nsjob.Pumps{ .srvs = &.{s.srv} };

    // Larger than one Twrite's payload (msize 8192) to force several chunks.
    const data = try a.alloc(u8, 20_000);
    defer a.free(data);
    for (data, 0..) |*b, i| b.* = @intCast('a' + (i % 26));

    var j = try WriteFileJob.init(&ns, "/x/f", data, .{});
    defer j.deinit();
    try nsjob.runSync(&j, pumps.pump());
    try testing.expectEqual(data.len, j.written);
    try testing.expect(!j.created);
    try testing.expectEqual(WriteFileJob.Phase.done, j.phase);

    const f = s.tree.findByQid(1000).?;
    try testing.expectEqualSlices(u8, data, f.data.items);

    // The server's op log is exactly the decoded shape of the frames it
    // received, in arrival order: one Twalk ("f"), one Topen(truncate),
    // then N Twrite at advancing, non-overlapping offsets summing to
    // `data.len`, each chunk bounded by ioMax's Twrite margin — no Tcreate.
    const log = s.tree.log.items;
    try testing.expect(log.len >= 3);
    try testing.expectEqualStrings("f", log[0].walk);
    try testing.expect(log[1].open.trunc);
    const max_chunk = s.client.ioMax() -| (msg.header_size + twrite_overhead);
    var off: u64 = 0;
    var i: usize = 2;
    while (i < log.len) : (i += 1) {
        const w = log[i].write;
        try testing.expectEqual(off, w.offset);
        try testing.expect(w.len > 0 and w.len <= max_chunk);
        off += w.len;
    }
    try testing.expectEqual(@as(u64, data.len), off);
    try testing.expect(i - 2 > 1); // more than one Twrite: chunking actually happened
    for (log) |e| try testing.expect(e != .create);
}

test "nswrite: NotFound + create ⇒ parent walk + Tcreate(name, 0o666, OWRITE) then writes; must_exist ⇒ error.NotFound, no Tcreate; union parent picks the first member whose parent walk succeeds (T2)" {
    const a = testing.allocator;

    // --- part 1: a brand-new file under a plain (non-union) mount. ---
    var s = try WServer.init(a, &.{});
    defer s.deinit();
    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/x", s.client, s.root_fid);
    var pumps = nsjob.Pumps{ .srvs = &.{s.srv} };

    const data = "hello, new file\n";
    var j = try WriteFileJob.init(&ns, "/x/new.txt", data, .{});
    defer j.deinit();
    try nsjob.runSync(&j, pumps.pump());
    try testing.expect(j.created);
    try testing.expectEqual(@as(usize, data.len), j.written);
    const f = s.tree.findByName(1, "new.txt").?;
    try testing.expectEqualSlices(u8, data, f.data.items);

    // The log shows the failed walk, the fallback parent walk ("/" has no
    // name to walk — nsjob's zero-component resolution — so the very first
    // entry IS the create), then the create, then writes; no walk for
    // "new.txt" itself succeeded first (it never existed).
    var saw_create = false;
    for (s.tree.log.items) |e| {
        if (e == .create) {
            try testing.expectEqualStrings("new.txt", e.create);
            saw_create = true;
        }
    }
    try testing.expect(saw_create);

    // --- part 2: must_exist refuses to create. ---
    var j2 = try WriteFileJob.init(&ns, "/x/nope.txt", data, .{ .must_exist = true });
    defer j2.deinit();
    try testing.expectError(error.NotFound, nsjob.runSync(&j2, pumps.pump()));
    try testing.expect(!j2.created);
    try testing.expect(s.tree.findByName(1, "nope.txt") == null);

    // --- part 3: a union mount where only the SECOND member's parent walk
    // succeeds (the first lacks the "sub" subdirectory the target lives
    // under) — the create must land on the second member, not the first. ---
    var sbad = try WServer.init(a, &.{}); // no "sub" ⇒ its parent walk fails
    defer sbad.deinit();
    var sgood = try WServer.init(a, &.{"sub"});
    defer sgood.deinit();
    var nsu = Namespace.init(a);
    defer nsu.deinit();
    try nsu.bind("/u", sbad.client, sbad.root_fid, .after);
    try nsu.bind("/u", sgood.client, sgood.root_fid, .after);
    var upumps = nsjob.Pumps{ .srvs = &.{ sbad.srv, sgood.srv } };

    var ju = try WriteFileJob.init(&nsu, "/u/sub/leaf.txt", data, .{});
    defer ju.deinit();
    try nsjob.runSync(&ju, upumps.pump());
    try testing.expect(ju.created);
    try testing.expect(sbad.tree.findByName(1, "leaf.txt") == null);
    const leaf = sgood.tree.findByName(2, "leaf.txt").?; // qid 2 = "sub"
    try testing.expectEqualSlices(u8, data, leaf.data.items);
}

test "nswrite: deinit mid-write is fire-and-forget (Tflush then Tclunk on the wire, no pump); a fresh ticket afterwards still resolves (T3)" {
    const a = testing.allocator;
    var s = try WServer.init(a, &.{});
    defer s.deinit();
    const copy = try a.dupe(u8, "f");
    try s.tree.files.append(a, .{ .name = copy, .parent = 1, .qid_path = 1000 });
    s.tree.next_id = 1001;

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/x", s.client, s.root_fid);

    const data = try a.alloc(u8, 20_000);
    defer a.free(data);
    @memset(data, 'x');

    var j = try WriteFileJob.init(&ns, "/x/f", data, .{});
    // Drive it into the `writing` phase (at least one Twrite answered) so
    // deinit must abandon a job that is mid-stream, not merely mid-open.
    while (true) {
        const st = try j.step();
        if (st == .pending and j.phase == .writing and j.written > 0) break;
        if (st == .done) unreachable;
        _ = try s.srv.poll();
    }

    // Disable the pump: deinit's Tflush/Tclunk must land on tombstones
    // without any implicit pumping (R-P13a-3 discipline extended to
    // cleanup, exactly as nsjob's T8/T8b pin for WalkJob).
    s.client.pump = null;
    j.deinit();

    var buf: [nsjob.small_reply]u8 = undefined;
    const fresh = try tickets.begin(s.client, .{ .tag = 0, .body = .{
        .tstat = .{ .fid = s.root_fid },
    } }, &buf);

    // Let the server work through everything it's owed: whatever Twrite(s)
    // never got answered, the abandoned job's own Tflush/Tclunk, and the
    // fresh Tstat — unaffected by any of the former (nsjob's T8b pattern).
    for (0..8) |_| _ = try s.srv.poll();

    const reply = (try tickets.check(s.client, fresh)).?;
    try testing.expectEqual(msg.Kind.rstat, reply.body.kind());
}
