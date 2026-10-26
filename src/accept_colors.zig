//! Phase 19 acceptance (R-P19-8c): a non-default scheme reaches the pixels.
//! Pulled into the `accept.zig` test root (same module imports); no golden
//! hash — the dark scheme is pinned by spot-checks only.
const std = @import("std");
const core = @import("core");
const draw = @import("draw");
const ninep = @import("ninep");
const dev = @import("dev");

const testing = std.testing;

fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// Does any pixel of `r` equal `color`?
fn anyPixel(hb: *dev.draw_backend.HeadlessBackend, r: draw.Rect, color: u32) bool {
    var y: u32 = @intCast(r.min.y);
    while (y < r.max.y) : (y += 1) {
        var x: u32 = @intCast(r.min.x);
        while (x < r.max.x) : (x += 1) {
            if (hb.pixelAt(x, y) == color) return true;
        }
    }
    return false;
}

test "phase-19: monadnock boot scene — dark backs, light text, dark ground" {
    const alloc = testing.allocator;
    const pal = &core.Palette.monadnock;

    var hb = try dev.draw_backend.HeadlessBackend.init(alloc, 640, 480);
    defer hb.deinit();
    var dd = dev.draw.DevDraw.init(alloc, hb.backend());
    defer dd.deinit();
    const pipe = try ninep.chan.Pipe.init(alloc, 16384);
    defer pipe.deinit();
    var srv = try ninep.server.Server.init(alloc, pipe.serverEnd(), &dev.draw.DevDraw.ops, &dd, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(alloc, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pumpServer };
    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");
    const d = try draw.Display.init(alloc, &cl, root.fid);
    defer d.deinit();
    var font = try draw.Font.init(alloc, d, draw.Font.default_subfont);
    defer font.deinit();

    // The one-window boot, then an empty second column (rowadd, rows.c:87-90)
    // so the ground shows.
    var tree = try core.boot.boot(alloc, d, &font, draw.proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "scratch",
        .body = "hello, acme\nsecond line\n",
        .palette = pal,
    });
    defer tree.deinit();
    _ = (try tree.row.add(-1)).?;
    const w = tree.row.col.items[0].w.items[0];
    var ed = core.Editor.init(alloc);
    defer ed.deinit();
    ed.row = tree.row;
    try ed.frameEnd(d);

    try testing.expectEqual(pal, tree.chrome.pal);
    // Row tag back at (30,2); the rule band under it (rows.c:45).
    try testing.expectEqual(@as(u32, pal.tag_back), hb.pixelAt(30, 2));
    try testing.expectEqual(@as(u32, pal.rule), hb.pixelAt(30, font.height));
    // The empty right column below its tag + band: ground (cols.c:32).
    const c1 = tree.row.col.items[1].r;
    try testing.expectEqual(@as(u32, pal.ground), hb.pixelAt(@intCast(c1.min.x + 30), @intCast(c1.max.y - 10)));
    // The window: body back, body scrollbar BORD edge (scrl.c:75-76), tag back.
    const br = w.body.fr.r;
    try testing.expectEqual(@as(u32, pal.body_back), hb.pixelAt(@intCast(br.max.x - 1), @intCast(br.max.y - 1)));
    const sr = w.body.scrollr;
    try testing.expectEqual(@as(u32, pal.body_bord), hb.pixelAt(@intCast(sr.max.x - 1), @intCast(sr.min.y)));
    const tr = w.tag.fr.r;
    try testing.expectEqual(@as(u32, pal.tag_back), hb.pixelAt(@intCast(tr.max.x - 1), @intCast(tr.min.y)));
    // Text is the scheme's light ink, never black-on-dark.
    try testing.expect(anyPixel(&hb, br, pal.body_text));
    try testing.expect(!anyPixel(&hb, br, 0x000000FF));
    try testing.expect(anyPixel(&hb, tr, pal.tag_text));
    try testing.expect(!anyPixel(&hb, tr, 0x000000FF));
}
