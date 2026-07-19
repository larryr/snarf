//! 9P2000 protocol — pure, std-only. Imports: `std` only (S-07 §6).
//! Namespace root re-exporting the module's public surface.
const std = @import("std");

pub const Qid = @import("qid.zig");
pub const msg = @import("msg.zig");
pub const stat = @import("stat.zig");
pub const transport = @import("transport.zig");
pub const errors = @import("errors.zig");
pub const chan = @import("chan.zig");
pub const Client = @import("client.zig").Client;
pub const server = @import("server.zig");
pub const mount = @import("mount.zig");

test {
    std.testing.refAllDecls(@This());
}

// ===========================================================================
// Phase-1 acceptance test (contract §10): every ninep module composed —
// a Client walks/opens/reads/writes a served tree over a chan.Pipe, with the
// mount table resolving paths on top. Orchestrator-owned (Wave C).
// ===========================================================================
const testing = std.testing;

/// Contract §10 fixture tree:
///   / (qid 1, dir) ── index (2, "hello, snarf\n", read-only)
///                  ── notes (3, writable, ArrayList-backed)
///                  ── sub/  (4, dir) ── leaf (5, "leaf\n")
const AcceptTree = struct {
    notes: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 or path == 4 } };
    }

    fn attach(_: *anyopaque, _: *server.Server, _: *server.Fid, _: []const u8) errors.OpError!Qid {
        return qidOf(1);
    }

    fn walk1(_: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) errors.OpError!Qid {
        const eq = std.mem.eql;
        return switch (fid.qid.path) {
            1 => if (eq(u8, name, "index")) qidOf(2) else if (eq(u8, name, "notes")) qidOf(3) else if (eq(u8, name, "sub")) qidOf(4) else if (eq(u8, name, "..")) qidOf(1) else error.FileDoesNotExist,
            4 => if (eq(u8, name, "leaf")) qidOf(5) else if (eq(u8, name, "..")) qidOf(1) else error.FileDoesNotExist,
            else => error.WalkNoDir,
        };
    }

    fn open(_: *anyopaque, _: *server.Server, fid: *server.Fid, mode: u8) errors.OpError!Qid {
        const wants_write = (mode & 3) == msg.OWRITE or (mode & 3) == msg.ORDWR or (mode & msg.OTRUNC) != 0;
        if (fid.qid.path != 3 and wants_write) return error.PermissionDenied;
        return fid.qid;
    }

    fn read(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, buf: []u8) errors.OpError!usize {
        const self: *AcceptTree = @ptrCast(@alignCast(ctx));
        const content: []const u8 = switch (fid.qid.path) {
            2 => "hello, snarf\n",
            3 => self.notes.items,
            5 => "leaf\n",
            else => return if (fid.qid.qtype.dir) 0 else error.IoError, // dir reads: 0 (contract R7/OQ-4)
        };
        if (offset >= content.len) return 0; // EOF
        const n = @min(buf.len, content.len - offset);
        @memcpy(buf[0..n], content[offset..][0..n]);
        return n;
    }

    fn write(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, data: []const u8) errors.OpError!usize {
        const self: *AcceptTree = @ptrCast(@alignCast(ctx));
        if (fid.qid.path != 3) return error.PermissionDenied;
        const end = offset + data.len;
        self.notes.resize(self.alloc, @max(self.notes.items.len, end)) catch return error.IoError;
        @memcpy(self.notes.items[@intCast(offset)..][0..data.len], data);
        return data.len;
    }

    fn statOp(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) errors.OpError!stat {
        const self: *AcceptTree = @ptrCast(@alignCast(ctx));
        const info: struct { name: []const u8, len: u64 } = switch (fid.qid.path) {
            1 => .{ .name = "/", .len = 0 },
            2 => .{ .name = "index", .len = 13 },
            3 => .{ .name = "notes", .len = self.notes.items.len },
            4 => .{ .name = "sub", .len = 0 },
            5 => .{ .name = "leaf", .len = 5 },
            else => return error.FileDoesNotExist,
        };
        return .{
            .qid = fid.qid,
            .mode = if (fid.qid.qtype.dir) stat.DMDIR | 0o755 else 0o644,
            .length = info.len,
            .name = info.name,
        };
    }

    const ops = server.Ops{
        .attach = attach,
        .walk1 = walk1,
        .open = open,
        .read = read,
        .write = write,
        .stat = statOp,
    };
};

fn acceptPump(ctx: *anyopaque) anyerror!void {
    const s: *server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "phase-1: client reads a served file over a chan pipe" {
    const alloc = testing.allocator;

    const pipe = try chan.Pipe.init(alloc, 16384);
    defer pipe.deinit();
    var tree = AcceptTree{ .alloc = alloc };
    defer tree.notes.deinit(alloc);
    var srv = try server.Server.init(alloc, pipe.serverEnd(), &AcceptTree.ops, &tree, 8192);
    defer srv.deinit();
    var cl = try Client.init(alloc, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = acceptPump };

    // 4-5: version + attach.
    try testing.expectEqual(@as(u32, 8192), try cl.version(8192));
    const root = try cl.attach("larry", "");
    try testing.expect(root.qid.qtype.dir);

    // 6-9: walk to index, open OREAD, full/offset/EOF reads.
    const f = try cl.walk(root.fid, &.{"index"});
    try testing.expectEqual(@as(u64, 2), f.qid.path);
    try testing.expect(!f.qid.qtype.dir);
    _ = try cl.open(f.fid, msg.OREAD);
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 13), try cl.read(f.fid, 0, &buf));
    try testing.expectEqualStrings("hello, snarf\n", buf[0..13]);
    try testing.expectEqual(@as(usize, 5), try cl.read(f.fid, 7, buf[0..5]));
    try testing.expectEqualStrings("snarf", buf[0..5]);
    try testing.expectEqual(@as(usize, 0), try cl.read(f.fid, 13, &buf)); // EOF

    // 10: clunk releases the fid server-side (root remains).
    try cl.clunk(f.fid);
    try testing.expectEqual(@as(u32, 1), srv.fids.count());

    // 11: missing name.
    try testing.expectError(error.FileDoesNotExist, cl.walk(root.fid, &.{"nope"}));

    // 12: nested walk + read.
    const leaf = try cl.walk(root.fid, &.{ "sub", "leaf" });
    try testing.expectEqual(@as(u64, 5), leaf.qid.path);
    _ = try cl.open(leaf.fid, msg.OREAD);
    try testing.expectEqual(@as(usize, 5), try cl.read(leaf.fid, 0, &buf));
    try testing.expectEqualStrings("leaf\n", buf[0..5]);
    try cl.clunk(leaf.fid);

    // 13: write path on notes.
    const notes = try cl.walk(root.fid, &.{"notes"});
    _ = try cl.open(notes.fid, msg.ORDWR);
    try testing.expectEqual(@as(usize, 3), try cl.write(notes.fid, 0, "abc"));
    try testing.expectEqual(@as(usize, 3), try cl.read(notes.fid, 0, &buf));
    try testing.expectEqualStrings("abc", buf[0..3]);
    try cl.clunk(notes.fid);

    // 14: flush of an idle tag returns cleanly (always Rflush).
    try cl.flushTag(12345);

    // 15: mount-table integration — resolve, walk the remainder, read.
    var ns = mount.Namespace.init(alloc);
    defer ns.deinit();
    try ns.mount("/", &cl, root.fid);
    const r = try ns.resolve("/sub/leaf");
    try testing.expectEqual(&cl, r.entry.target.client);
    try testing.expectEqualStrings("sub/leaf", r.remainder);
    var names: [8][]const u8 = undefined;
    var n_names: usize = 0;
    var it = std.mem.splitScalar(u8, r.remainder, '/');
    while (it.next()) |name| : (n_names += 1) names[n_names] = name;
    const via_ns = try cl.walk(r.entry.target.root_fid, names[0..n_names]);
    _ = try cl.open(via_ns.fid, msg.OREAD);
    try testing.expectEqual(@as(usize, 5), try cl.read(via_ns.fid, 0, &buf));
    try testing.expectEqualStrings("leaf\n", buf[0..5]);
    try cl.clunk(via_ns.fid);
}
