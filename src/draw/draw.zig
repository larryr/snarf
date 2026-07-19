//! libdraw-like client + frame. Imports: `ninep` (client|msg), `std` (S-07 §6).
//! The editor core draws ONLY by emitting draw-protocol messages here (ADR-0003).
//!
//! Namespace root: re-exports the wire encoder (`proto`), the connection
//! (`Display`), the image handle (`Image`), and the geometry vocabulary
//! (`Point`/`Rect`) so callers write `draw.Rect` rather than `draw.proto.Rect`.
const std = @import("std");

pub const proto = @import("proto.zig");
pub const Display = @import("Display.zig");
pub const Image = @import("Image.zig");
pub const Point = proto.Point;
pub const Rect = proto.Rect;

test {
    std.testing.refAllDecls(@This());
}

// ==========================================================================
// Phase-2 integration test (§C): drive a `Display`/`Image` client through the
// real `ninep.Client` over a chan.Pipe into a minimal fake devdraw server.
//
// R-P2-3: the namespace root MAY use `ninep.server` in TEST BLOCKS ONLY, the
// same precedent as ninep.zig's acceptance test. Non-test draw code stays
// client-only (S-07 §6).
// ==========================================================================
const testing = std.testing;
const ninep = @import("ninep");
const server = ninep.server;
const OpError = ninep.errors.OpError;
const Qid = ninep.Qid;
const Stat = ninep.stat;

/// A minimal fake `/dev/draw` tree (R-P2-6 shape): root(1) → new(2), 1(3) dir
/// → data(4). It does NOT model the kernel connection state machine — `new`
/// reads back a canned connection line, and `1/data` records raw writes. This
/// isolates the client's Display/Image behavior from the real DevDraw server.
///
/// qid paths: root=1 (dir), new=2, "1"=3 (dir), data=4.
const FakeDrawTree = struct {
    alloc: std.mem.Allocator,
    /// The canned 144-byte connection line `new` reads back.
    conn_line: [Display.info_size]u8,
    /// Raw bytes of every `data` write, in order (each owned/duped).
    writes: std.ArrayList([]u8) = .empty,
    /// When set, the next `data` write fails once with BadDraw (R-P2-4).
    fail_next: bool = false,

    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 or path == 3 } };
    }

    fn deinitTree(self: *FakeDrawTree) void {
        for (self.writes.items) |w| self.alloc.free(w);
        self.writes.deinit(self.alloc);
    }

    fn attach(_: *anyopaque, _: *server.Server, _: *server.Fid, _: []const u8) OpError!Qid {
        return qidOf(1);
    }

    fn walk1(_: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) OpError!Qid {
        const eq = std.mem.eql;
        return switch (fid.qid.path) {
            1 => if (eq(u8, name, "new")) qidOf(2) else if (eq(u8, name, "1")) qidOf(3) else if (eq(u8, name, "..")) qidOf(1) else error.FileDoesNotExist,
            3 => if (eq(u8, name, "data")) qidOf(4) else if (eq(u8, name, "..")) qidOf(1) else error.FileDoesNotExist,
            else => error.WalkNoDir,
        };
    }

    fn open(_: *anyopaque, _: *server.Server, fid: *server.Fid, _: u8) OpError!Qid {
        return fid.qid;
    }

    fn read(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, buf: []u8) OpError!usize {
        const self: *FakeDrawTree = @ptrCast(@alignCast(ctx));
        if (fid.qid.path != 2) return 0; // only `new` yields the connection line
        if (offset >= self.conn_line.len) return 0;
        const n = @min(buf.len, self.conn_line.len - offset);
        @memcpy(buf[0..n], self.conn_line[@intCast(offset)..][0..n]);
        return n;
    }

    fn write(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, _: u64, data: []const u8) OpError!usize {
        const self: *FakeDrawTree = @ptrCast(@alignCast(ctx));
        if (fid.qid.path != 4) return error.PermissionDenied;
        if (self.fail_next) {
            self.fail_next = false;
            return error.BadDraw; // surfaces to the client as error.BadDraw (R-P2-4)
        }
        const copy = self.alloc.dupe(u8, data) catch return error.IoError;
        self.writes.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return error.IoError;
        };
        return data.len;
    }

    fn statOp(_: *anyopaque, _: *server.Server, fid: *server.Fid) OpError!Stat {
        return .{
            .qid = fid.qid,
            .mode = if (fid.qid.qtype.dir) (Stat.DMDIR | 0o555) else 0o666,
            .length = 0,
            .name = switch (fid.qid.path) {
                1 => "draw",
                2 => "new",
                3 => "1",
                4 => "data",
                else => "?",
            },
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

    /// Fill `conn_line` with 12 `%11s `-formatted fields (G8).
    fn buildConnLine(self: *FakeDrawTree, fields: [12][]const u8) void {
        for (fields, 0..) |f, i| {
            const cell = self.conn_line[i * 12 ..][0..12];
            @memset(cell, ' ');
            @memcpy(cell[11 - f.len ..][0..f.len], f);
        }
    }
};

fn fakePump(ctx: *anyopaque) anyerror!void {
    const s: *server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "phase-2: display draws a rect through a fake devdraw" {
    const alloc = testing.allocator;

    const pipe = try ninep.chan.Pipe.init(alloc, 16384);
    defer pipe.deinit();

    var tree = FakeDrawTree{ .alloc = alloc, .conn_line = undefined };
    // Connection number 1 (G3), XRGB32, 800×600 display (r == clipr).
    tree.buildConnLine(.{ "1", "0", "x8r8g8b8", "0", "0", "0", "800", "600", "0", "0", "800", "600" });
    defer tree.deinitTree();

    var srv = try server.Server.init(alloc, pipe.serverEnd(), &FakeDrawTree.ops, &tree, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(alloc, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = fakePump };

    _ = try cl.version(8192);
    const root = try cl.attach("glenda", "");
    const baseline = srv.fids.count(); // just the root fid

    // init: walks new + N/data, then allocates white(1) and black(2) as 1×1
    // repl GREY1 'b's, each eager-flushed ⇒ exactly two `data` writes.
    const disp = try Display.init(alloc, &cl, root.fid);
    try testing.expectEqual(@as(usize, 2), tree.writes.items.len);
    try testing.expectEqual(@as(usize, 51), tree.writes.items[0].len);
    try testing.expectEqual(@as(u8, 'b'), tree.writes.items[0][0]);
    try testing.expectEqual(@as(usize, 51), tree.writes.items[1].len);
    try testing.expectEqual(@as(u8, 'b'), tree.writes.items[1][0]);

    // The client parsed the connection line correctly.
    try testing.expectEqual(@as(u32, 1), disp.conn.conn);
    try testing.expectEqual(proto.XRGB32, disp.conn.chan);
    try testing.expectEqual(proto.Rect.make(0, 0, 800, 600), disp.conn.r);
    try testing.expectEqual(@as(u32, 0), disp.image.id);

    // A red RGBA32 repl solid: white=1, black=2, so this is id 3. Its eager
    // flush appends a third `data` write.
    var red = try disp.allocImage(proto.Rect.make(0, 0, 1, 1), proto.RGBA32, true, proto.DRed);
    try testing.expectEqual(@as(u32, 3), red.id);
    try testing.expectEqual(@as(usize, 3), tree.writes.items.len);

    // Draw the red solid onto the display over (10,10)-(20,20), nil mask ⇒
    // white(1) as the opaque mask. This buffers — no new write yet.
    try disp.image.draw(proto.Rect.make(10, 10, 20, 20), &red, null, .{});
    try testing.expectEqual(@as(usize, 3), tree.writes.items.len);

    // flush ⇒ one 46-byte write: the 'd' golden bytes (dstid 0, srcid 3,
    // maskid 1, r (10,10,20,20), sp/mp 0) followed by the bare 'v'.
    try disp.flush();
    try testing.expectEqual(@as(usize, 4), tree.writes.items.len);
    const w = tree.writes.items[3];
    var expected: [46]u8 = undefined;
    _ = try proto.encode(.{ .draw = .{
        .dstid = 0,
        .srcid = red.id,
        .maskid = disp.white.id,
        .r = proto.Rect.make(10, 10, 20, 20),
    } }, expected[0..45]);
    expected[45] = 'v';
    try testing.expectEqualSlices(u8, &expected, w);

    // Error surfacing (R-P2-4): the fake fails the next `data` write with
    // BadDraw; allocImage's eager flush must surface error.BadDraw.
    tree.fail_next = true;
    try testing.expectError(error.BadDraw, disp.allocImage(proto.Rect.make(0, 0, 1, 1), proto.RGBA32, true, proto.DGreen));

    // deinit clunks the ctl + data fids ⇒ server fid count back to baseline.
    disp.deinit();
    try testing.expectEqual(baseline, srv.fids.count());
}
