//! `HostTree` — a `HostFs` served as a whole 9P tree: the export directory IS
//! the root (phase 20, R-P20-1/2). This is what native mounts at `/` (and the
//! `/mnt/host` alias) so `Put`, `Get`, B3 and the boot directory window reach
//! the real host file system through the namespace, exactly as acme's
//! open/read/write reach the kernel's (S-02 §4).
//!
//! The origin server keeps its own tree (`tools/origin/tree.zig`, which puts
//! the same `HostFs` under `fs/` beside `version` and `bin/`); both share
//! `HostFs` for the host calls and `Replace` for the atomic Put.
//!
//! `..` at the root stays at the root (walk(5)): with the export rooted at the
//! real `/` there is nothing above it to escape to.
const HostTree = @This();
const std = @import("std");
const ninep = @import("ninep");
const server = ninep.server;
const msg = ninep.msg;
const Qid = ninep.Qid;
const Stat = ninep.stat;
const OpError = ninep.errors.OpError;
const HostFs = @import("HostFs.zig");
const Replace = @import("Replace.zig");

gpa: std.mem.Allocator,
fs: *HostFs,
/// Set by `endSession`: the client is gone, so a clunk is the session's
/// teardown, not the client's "done writing" — a Put still in flight is
/// DISCARDED rather than committed (#58; see `endSession`).
hung_up: bool = false,
/// Where `endSession` reports each Put it discards (PM ruling 2026-10-31,
/// SnarfProdd): set only for the duration of `endSession`.
discard_log: ?*std.Io.Writer = null,

/// Per-fid state (`fid.ctx`): the path relative to the export root ("" is
/// the root) and, between an OTRUNC open and the clunk, the Put in flight.
const Node = struct {
    rel: []u8,
    put: ?Replace = null,
};

pub fn init(gpa: std.mem.Allocator, fs: *HostFs) HostTree {
    return .{ .gpa = gpa, .fs = fs };
}

/// The session is over (the editor is shutting down, or its peer vanished):
/// release every fid `srv` still holds through `clunk`, freeing its `Node`.
/// An atomic Put that never saw its client's Tclunk is discarded — the
/// original stays as it was and the temp is deleted — because a half-written
/// buffer must never be renamed over a user's file (PM Q5's promise: readers
/// see the old bytes or the new ones). Call before `srv.deinit`.
///
/// Each Put discarded HERE is reported to `log`, one line naming the file
/// (PM ruling 2026-10-31, SnarfProdd: the user must know the save did not
/// happen): `snarf: Put of /path not finished at exit; file left unchanged`.
/// The path is the export-root path, i.e. the namespace path under the `/`
/// mount (the real path on native, where the root is `/`). Nothing is written
/// when nothing is discarded, nor for a Put that had already failed (the
/// editor reported that failure itself). `log` is flushed before returning.
pub fn endSession(self: *HostTree, srv: *server.Server, log: ?*std.Io.Writer) void {
    self.hung_up = true;
    self.discard_log = log;
    defer self.discard_log = null;
    srv.releaseFids();
    if (log) |w| w.flush() catch {};
}

/// The one-line discard notice (see `endSession`). Best-effort: a failing
/// log never stops the teardown.
fn reportDiscard(self: *HostTree, rel: []const u8) void {
    const w = self.discard_log orelse return;
    w.print("snarf: Put of /{s} not finished at exit; file left unchanged\n", .{rel}) catch {};
}

pub const ops: server.Ops = .{
    .attach = attach,
    .walk1 = walk1,
    .clone = clone,
    .open = open,
    .read = read,
    .write = write,
    .clunk = clunk,
    .stat = statOp,
    .create = create,
};

fn self_(ctx: *anyopaque) *HostTree {
    return @ptrCast(@alignCast(ctx));
}

fn nodeOf(fid: *server.Fid) *Node {
    return @ptrCast(@alignCast(fid.ctx.?));
}

fn setNode(self: *HostTree, fid: *server.Fid, rel: []const u8) OpError!void {
    const p = self.gpa.create(Node) catch return error.IoError;
    errdefer self.gpa.destroy(p);
    p.* = .{ .rel = self.gpa.dupe(u8, rel) catch return error.IoError };
    fid.ctx = p;
}

fn join(self: *HostTree, rel: []const u8, name: []const u8) OpError![]u8 {
    if (rel.len == 0) return self.gpa.dupe(u8, name) catch return error.IoError;
    return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ rel, name }) catch return error.IoError;
}

fn basename(rel: []const u8) []const u8 {
    if (rel.len == 0) return "/";
    const cut = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return rel;
    return rel[cut + 1 ..];
}

fn attach(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, _: []const u8) OpError!Qid {
    const self = self_(ctx);
    try self.setNode(fid, "");
    return self.fs.qidOf("");
}

fn walk1(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) OpError!Qid {
    const self = self_(ctx);
    const node = nodeOf(fid);
    const next: []u8 = blk: {
        if (std.mem.eql(u8, name, "..")) {
            const cut = std.mem.lastIndexOfScalar(u8, node.rel, '/') orelse 0;
            break :blk self.gpa.dupe(u8, node.rel[0..cut]) catch return error.IoError;
        }
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.indexOfScalar(u8, name, '/') != null)
            return error.FileDoesNotExist;
        if (!(try self.fs.qidOf(node.rel)).qtype.dir) return error.WalkNoDir;
        break :blk try self.join(node.rel, name);
    };
    errdefer self.gpa.free(next);
    const qid = try self.fs.qidOf(next);
    self.gpa.free(node.rel);
    node.rel = next;
    return qid;
}

fn clone(ctx: *anyopaque, _: *server.Server, old: *server.Fid, new: *server.Fid) OpError!void {
    // The framework refuses to clone an OPEN fid, so `old.put` is always null.
    try self_(ctx).setNode(new, nodeOf(old).rel);
}

fn open(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, mode: u8) OpError!Qid {
    const self = self_(ctx);
    const node = nodeOf(fid);
    const acc = mode & 3;
    const wants_write = acc == msg.OWRITE or acc == msg.ORDWR or (mode & msg.OTRUNC) != 0;
    const qid = try self.fs.qidOf(node.rel);
    if (qid.qtype.dir) {
        if (wants_write) return error.PermissionDenied;
    } else if ((mode & msg.OTRUNC) != 0) {
        node.put = try Replace.begin(self.fs, self.gpa, node.rel); // atomic Put
    }
    return qid;
}

/// Tcreate of a plain file: exclusive (an existing name is `file already
/// exists`; the client's open-OTRUNC path handles that case), mode
/// `0666 & ~umask` (PM Q5). Directories are refused.
fn create(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8, perm: u32, _: u8) server.OpBlockError!server.CreateResult {
    const self = self_(ctx);
    if (perm & Stat.DMDIR != 0) return error.PermissionDenied;
    const node = nodeOf(fid);
    const child = try self.join(node.rel, name);
    errdefer self.gpa.free(child);
    try self.fs.createFile(child);
    const qid = try self.fs.qidOf(child);
    self.gpa.free(node.rel);
    node.rel = child;
    return .{ .qid = qid };
}

fn read(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, buf: []u8) server.ReadError!usize {
    const self = self_(ctx);
    const node = nodeOf(fid);
    if (node.put) |*p| return p.read(self.fs, offset, buf);
    if ((try self.fs.qidOf(node.rel)).qtype.dir) return self.fs.readDir(node.rel, offset, buf);
    return self.fs.readFile(node.rel, offset, buf);
}

fn write(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, data: []const u8) OpError!usize {
    const self = self_(ctx);
    const node = nodeOf(fid);
    if (node.put) |*p| return p.write(self.fs, offset, data);
    return self.fs.writeFile(node.rel, offset, data);
}

fn clunk(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) void {
    const self = self_(ctx);
    const node: *Node = @ptrCast(@alignCast(fid.ctx orelse return));
    if (node.put) |*p| {
        if (self.hung_up) { // endSession: discard, never commit
            if (!p.failed) self.reportDiscard(node.rel);
            p.failed = true;
        }
        p.end(self.fs, self.gpa); // commit or discard
    }
    self.gpa.free(node.rel);
    self.gpa.destroy(node);
    fid.ctx = null;
}

fn statOp(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) OpError!Stat {
    const self = self_(ctx);
    const rel = nodeOf(fid).rel;
    return self.fs.statOf(rel, basename(rel));
}

test "HostTree: root walk, '..' stays at root, atomic Put through 9P" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "d");
    try tmp.dir.writeFile(io, .{ .sub_path = "d/f", .data = "old" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var fs = try HostFs.open(io, path);
    defer fs.close();
    var tree = HostTree.init(a, &fs);

    const pipe = try ninep.chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try server.Server.init(a, pipe.serverEnd(), &HostTree.ops, &tree, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = struct {
        fn run(p: *anyopaque) anyerror!void {
            _ = try @as(*server.Server, @ptrCast(@alignCast(p))).poll();
        }
    }.run };
    _ = try cl.version(8192);
    const root = (try cl.attach("larry", "")).fid;
    defer cl.clunk(root) catch {};

    const up = try cl.walk(root, &.{ "..", "..", "d", "f" });
    _ = try cl.open(up.fid, msg.OWRITE | msg.OTRUNC);
    _ = try cl.write(up.fid, 0, "new");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("old", buf[0..try fs.readFile("d/f", 0, &buf)]);
    try cl.clunk(up.fid);
    try std.testing.expectEqualStrings("new", buf[0..try fs.readFile("d/f", 0, &buf)]);
}

test "HostTree: endSession frees every fid's node and discards an unfinished Put (#58)" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "old" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var fs = try HostFs.open(io, path);
    defer fs.close();
    var tree = HostTree.init(a, &fs);

    const pipe = try ninep.chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try server.Server.init(a, pipe.serverEnd(), &HostTree.ops, &tree, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = struct {
        fn run(p: *anyopaque) anyerror!void {
            _ = try @as(*server.Server, @ptrCast(@alignCast(p))).poll();
        }
    }.run };
    _ = try cl.version(8192);
    const root = (try cl.attach("larry", "")).fid;
    _ = try cl.walk(root, &.{}); // a cloned root, never clunked
    const f = try cl.walk(root, &.{"f"});
    _ = try cl.open(f.fid, msg.OWRITE | msg.OTRUNC);
    _ = try cl.write(f.fid, 0, "half");

    // No Tclunk ever arrives: the session just ends. The discard is reported
    // once, naming the file (PM ruling 2026-10-31, SnarfProdd).
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    tree.endSession(&srv, &log.writer);
    try std.testing.expectEqualStrings(
        "snarf: Put of /f not finished at exit; file left unchanged\n",
        log.written(),
    );
    try std.testing.expect(srv.lookupFid(root) == null);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("old", buf[0..try fs.readFile("f", 0, &buf)]);
    // The temp is gone: the directory holds exactly the original.
    var d = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "HostTree: endSession reports nothing when no Put is discarded (#58)" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/g", .data = "old" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var fs = try HostFs.open(io, path);
    defer fs.close();
    var tree = HostTree.init(a, &fs);

    const pipe = try ninep.chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try server.Server.init(a, pipe.serverEnd(), &HostTree.ops, &tree, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = struct {
        fn run(p: *anyopaque) anyerror!void {
            _ = try @as(*server.Server, @ptrCast(@alignCast(p))).poll();
        }
    }.run };
    _ = try cl.version(8192);
    const root = (try cl.attach("larry", "")).fid;
    // A finished Put (its Tclunk arrived: committed, nothing to report) …
    const done = try cl.walk(root, &.{ "sub", "g" });
    _ = try cl.open(done.fid, msg.OWRITE | msg.OTRUNC);
    _ = try cl.write(done.fid, 0, "new");
    try cl.clunk(done.fid);
    // … and fids still open for reading: released, but no Put among them.
    const rd = try cl.walk(root, &.{ "sub", "g" });
    _ = try cl.open(rd.fid, msg.OREAD);

    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    tree.endSession(&srv, &log.writer);
    try std.testing.expectEqualStrings("", log.written());
    try std.testing.expect(srv.lookupFid(root) == null);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("new", buf[0..try fs.readFile("sub/g", 0, &buf)]);
}
