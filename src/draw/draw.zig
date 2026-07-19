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
pub const Font = @import("Font.zig");
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

// ==========================================================================
// Phase-3 font integration (§5). Same fake devdraw, now driving Font.init +
// drawString and asserting the emitted write stream. R-P2-3 test-only server.
// ==========================================================================

/// The hand-built 116-byte tiny subfont (client §5): GREY1 4×2 strip
/// r=(0,0,4,2), rows {0xA0,0x50}; trailer n=2 height=2 ascent=1; two width-2
/// glyphs closed by a third Fontchar.
fn tinySubfont() [116]u8 {
    var f: [116]u8 = undefined;
    const putCell = struct {
        fn put(data: []u8, base: usize, i: usize, s: []const u8) void {
            const dst = data[base + i * 12 ..][0..12];
            @memset(dst, ' ');
            @memcpy(dst[0..s.len], s);
        }
    }.put;
    putCell(&f, 0, 0, "k1");
    putCell(&f, 0, 1, "0");
    putCell(&f, 0, 2, "0");
    putCell(&f, 0, 3, "4");
    putCell(&f, 0, 4, "2");
    f[60] = 0xA0;
    f[61] = 0x50;
    putCell(&f, 62, 0, "2");
    putCell(&f, 62, 1, "2");
    putCell(&f, 62, 2, "1");
    const fc = [_][6]u8{
        .{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x02 },
        .{ 0x02, 0x00, 0x00, 0x02, 0x00, 0x02 },
        .{ 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 },
    };
    var i: usize = 0;
    while (i < 3) : (i += 1) @memcpy(f[98 + i * 6 ..][0..6], &fc[i]);
    return f;
}

/// A live `Display` over a heap `FakeDrawTree` for the font tests (640×480,
/// r == clipr). Mirrors the phase-2 setup; the caller drives it then `finish`es.
const FontFixture = struct {
    pipe: *ninep.chan.Pipe,
    tree: *FakeDrawTree,
    srv: *server.Server,
    cl: *ninep.Client,
    disp: *Display,
    baseline: usize,

    fn init() !FontFixture {
        const a = testing.allocator;
        const pipe = try ninep.chan.Pipe.init(a, 16384);
        const tree = try a.create(FakeDrawTree);
        tree.* = .{ .alloc = a, .conn_line = undefined };
        tree.buildConnLine(.{ "1", "0", "x8r8g8b8", "0", "0", "0", "640", "480", "0", "0", "640", "480" });
        const srv = try a.create(server.Server);
        srv.* = try server.Server.init(a, pipe.serverEnd(), &FakeDrawTree.ops, tree, 8192);
        const cl = try a.create(ninep.Client);
        cl.* = try ninep.Client.init(a, pipe.clientEnd(), 8192);
        cl.pump = .{ .ctx = srv, .run = fakePump };
        _ = try cl.version(8192);
        const root = try cl.attach("glenda", "");
        const baseline = srv.fids.count();
        const disp = try Display.init(a, cl, root.fid);
        return .{ .pipe = pipe, .tree = tree, .srv = srv, .cl = cl, .disp = disp, .baseline = baseline };
    }

    fn deinit(self: *FontFixture) void {
        const a = testing.allocator;
        self.cl.deinit();
        self.srv.deinit();
        self.tree.deinitTree();
        a.destroy(self.cl);
        a.destroy(self.srv);
        a.destroy(self.tree);
        self.pipe.deinit();
    }
};

test "phase-3: font draws a string through a fake devdraw" {
    var fx = try FontFixture.init();
    defer fx.deinit();
    const disp = fx.disp;
    const tree = fx.tree;

    // white(1), black(2) already flushed by Display.init.
    try testing.expectEqual(@as(usize, 2), tree.writes.items.len);

    var red = try disp.allocImage(proto.Rect.make(0, 0, 1, 1), proto.RGBA32, true, proto.DRed);
    try testing.expectEqual(@as(usize, 3), tree.writes.items.len); // red 'b'

    // Font.init own writes: 'b' strip, 'y', 'b' cache, then one i/l…/f batch.
    var font = try Font.init(testing.allocator, disp, &tinySubfont());
    try testing.expectEqual(@as(usize, 7), tree.writes.items.len);
    try testing.expectEqual(@as(u8, 'b'), tree.writes.items[3][0]); // strip
    try testing.expectEqual(@as(u8, 'y'), tree.writes.items[4][0]);
    try testing.expectEqual(@as(u8, 'b'), tree.writes.items[5][0]); // cache

    // The i/l/l/f batch: 'i'(nchars=2, ascent=1) + two identity 'l's + 'f' strip.
    const batch = tree.writes.items[6];
    try testing.expectEqual(@as(u8, 'i'), batch[0]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, batch[5..9], .little));
    try testing.expectEqual(@as(u8, 1), batch[9]);
    try testing.expectEqual(@as(u8, 'l'), batch[10]);
    try testing.expectEqual(proto.Rect.make(0, 0, 2, 2), readRect(batch, 10 + 11));
    try testing.expectEqual(@as(u8, 'l'), batch[47]);
    try testing.expectEqual(proto.Rect.make(2, 0, 4, 2), readRect(batch, 47 + 11));
    try testing.expectEqual(@as(u8, 'f'), batch[84]);
    try testing.expectEqual(@as(usize, 89), batch.len);

    // drawString buffers a single 's'; flush appends the bare 'v'.
    const end = try font.drawString(&disp.image, .{ .x = 10, .y = 10 }, &red, "\x00\x01");
    try testing.expectEqual(@as(i32, 14), end.x); // 10 + 2 + 2
    try testing.expectEqual(@as(i32, 10), end.y); // top-left y unchanged
    try testing.expectEqual(@as(usize, 7), tree.writes.items.len); // still buffered
    try disp.flush();
    try testing.expectEqual(@as(usize, 8), tree.writes.items.len);

    const s = tree.writes.items[7];
    try testing.expectEqual(@as(u8, 's'), s[0]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, s[1..5], .little)); // dst = display
    try testing.expectEqual(red.id, std.mem.readInt(u32, s[5..9], .little)); // src = red
    try testing.expectEqual(font.cache.id, std.mem.readInt(u32, s[9..13], .little));
    try testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, s[13..17], .little)); // p.x
    try testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, s[17..21], .little)); // p.y = 10+ascent
    try testing.expectEqual(proto.Rect.make(0, 0, 640, 480), readRect(s, 21)); // clipr = dst.clipr
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, s[45..47], .little)); // ni
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, s[47..49], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, s[49..51], .little));
    try testing.expectEqual(@as(u8, 'v'), s[51]);

    // deinit ⇒ one 'f' cache write; then the display's fids clunk back.
    font.deinit();
    try testing.expectEqual(@as(usize, 9), tree.writes.items.len);
    const fcache = tree.writes.items[8];
    try testing.expectEqual(@as(u8, 'f'), fcache[0]);
    try testing.expectEqual(font.cache.id, std.mem.readInt(u32, fcache[1..5], .little));

    disp.deinit();
    try testing.expectEqual(fx.baseline, fx.srv.fids.count());
}

test "phase-3: string chunks at 100 indices" {
    var fx = try FontFixture.init();
    defer fx.deinit();
    const disp = fx.disp;
    const tree = fx.tree;

    var red = try disp.allocImage(proto.Rect.make(0, 0, 1, 1), proto.RGBA32, true, proto.DRed);
    var font = try Font.init(testing.allocator, disp, &tinySubfont());
    defer {
        font.deinit();
        disp.deinit();
    }

    // 150 ASCII 0x00 glyphs (each width 2) ⇒ two 's' verbs (100 + 50).
    const s150 = [_]u8{0} ** 150;
    const base = tree.writes.items.len;
    _ = try font.drawString(&disp.image, .{ .x = 0, .y = 0 }, &red, &s150);
    try disp.flush();
    try testing.expectEqual(base + 1, tree.writes.items.len); // both 's' + 'v' in one write

    const w = tree.writes.items[base];
    // First 's': ni=100, p.x=0.
    try testing.expectEqual(@as(u8, 's'), w[0]);
    try testing.expectEqual(@as(u16, 100), std.mem.readInt(u16, w[45..47], .little));
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, w[13..17], .little));
    // Second 's' begins at 47 + 2*100 = 247: ni=50, p.x advanced by 100*width.
    const off2: usize = 47 + 2 * 100;
    try testing.expectEqual(@as(u8, 's'), w[off2]);
    try testing.expectEqual(@as(u16, 50), std.mem.readInt(u16, w[off2 + 45 .. off2 + 47], .little));
    try testing.expectEqual(@as(i32, 200), std.mem.readInt(i32, w[off2 + 13 .. off2 + 17], .little));
    try testing.expectEqual(@as(u8, 'v'), w[off2 + 47 + 2 * 50]);
}

/// Decode a `proto.Rect` from a 16-byte little-endian field at `w[off..]`.
fn readRect(w: []const u8, off: usize) proto.Rect {
    return proto.Rect.make(
        std.mem.readInt(i32, w[off..][0..4], .little),
        std.mem.readInt(i32, w[off + 4 ..][0..4], .little),
        std.mem.readInt(i32, w[off + 8 ..][0..4], .little),
        std.mem.readInt(i32, w[off + 12 ..][0..4], .little),
    );
}
