//! `Server.releaseFids` — the end-of-session fid sweep (#58, lib9p
//! `freefidpool`). A file server that hangs heap state off `Fid.ctx` must get
//! every live fid back through `Ops.clunk` when the session ends without the
//! client clunking them; `std.testing.allocator` fails the test on any leak.
const std = @import("std");
const testing = std.testing;
const server = @import("server.zig");
const chan = @import("chan.zig");
const Client = @import("client.zig").Client;
const Qid = @import("qid.zig");
const errors = @import("errors.zig");
const msg = @import("msg.zig");

/// A one-directory tree whose every fid owns a heap node, freed on clunk.
const CtxTree = struct {
    gpa: std.mem.Allocator,
    live: usize = 0,
    clunks: usize = 0,

    fn self_(ctx: *anyopaque) *CtxTree {
        return @ptrCast(@alignCast(ctx));
    }
    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 } };
    }
    fn give(self: *CtxTree, fid: *server.Fid, path: u64) errors.OpError!void {
        const n = self.gpa.create(u64) catch return error.IoError;
        n.* = path;
        fid.ctx = n;
        self.live += 1;
    }
    fn attach(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, _: []const u8) errors.OpError!Qid {
        try self_(ctx).give(fid, 1);
        return qidOf(1);
    }
    fn walk1(_: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) errors.OpError!Qid {
        if (fid.qid.path == 1 and std.mem.eql(u8, name, "f")) {
            @as(*u64, @ptrCast(@alignCast(fid.ctx.?))).* = 2;
            return qidOf(2);
        }
        return error.FileDoesNotExist;
    }
    fn clone(ctx: *anyopaque, _: *server.Server, old: *server.Fid, new: *server.Fid) errors.OpError!void {
        try self_(ctx).give(new, @as(*u64, @ptrCast(@alignCast(old.ctx.?))).*);
    }
    fn open(_: *anyopaque, _: *server.Server, fid: *server.Fid, _: u8) errors.OpError!Qid {
        return fid.qid;
    }
    fn read(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u64, _: []u8) server.ReadError!usize {
        return error.WouldBlock; // every read parks: the session ends with one in flight
    }
    fn write(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u64, data: []const u8) errors.OpError!usize {
        return data.len;
    }
    fn stat(_: *anyopaque, _: *server.Server, fid: *server.Fid) errors.OpError!@import("stat.zig") {
        return .{ .qid = fid.qid, .mode = 0o644, .length = 0, .name = "f" };
    }
    fn clunk(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) void {
        const self = self_(ctx);
        const n: *u64 = @ptrCast(@alignCast(fid.ctx orelse return));
        self.gpa.destroy(n);
        fid.ctx = null;
        self.live -= 1;
        self.clunks += 1;
    }
    const ops: server.Ops = .{
        .attach = attach,
        .walk1 = walk1,
        .clone = clone,
        .open = open,
        .read = read,
        .write = write,
        .stat = stat,
        .clunk = clunk,
    };
};

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "server: releaseFids clunks every live fid and drops parked requests (#58)" {
    const a = testing.allocator;
    var tree: CtxTree = .{ .gpa = a };
    const pipe = try chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try server.Server.init(a, pipe.serverEnd(), &CtxTree.ops, &tree, 8192);
    defer srv.deinit();
    var cl = try Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pump };

    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");
    const f1 = try cl.walk(root.fid, &.{"f"});
    const f2 = try cl.walk(root.fid, &.{"f"});
    _ = try cl.open(f2.fid, msg.OREAD);
    var buf: [16]u8 = undefined;
    _ = try cl.beginRead(f2.fid, 0, &buf); // parks server-side
    _ = try srv.poll();
    try testing.expectEqual(@as(usize, 3), tree.live);
    try testing.expectEqual(@as(usize, 1), srv.parkedCount());
    _ = f1;

    // The peer goes away without a single Tclunk.
    srv.releaseFids();
    try testing.expectEqual(@as(usize, 0), tree.live);
    try testing.expectEqual(@as(usize, 3), tree.clunks);
    try testing.expectEqual(@as(usize, 0), srv.parkedCount());
    try testing.expect(srv.lookupFid(root.fid) == null);

    srv.releaseFids(); // idempotent
    try testing.expectEqual(@as(usize, 3), tree.clunks);
}
