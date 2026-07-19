//! Cross-module acceptance tests (orchestrator-owned, ruling R-P2-2).
//!
//! This is a TEST-ONLY root wired in build.zig with imports {draw, ninep, dev}
//! — the one place the client stack and the device stack meet natively, no
//! browser, no shim (R-CON-02). Each phase adds its end-to-end scene here.
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");
const dev = @import("dev");

const testing = std.testing;

fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "phase-2: red rectangle over 9P onto a headless display" {
    const alloc = testing.allocator;

    // Device side: headless 640x480 display behind devdraw behind a 9P server.
    var hb = try dev.draw_backend.HeadlessBackend.init(alloc, 640, 480);
    defer hb.deinit();
    var dd = dev.draw.DevDraw.init(alloc, hb.backend());
    defer dd.deinit();

    const pipe = try ninep.chan.Pipe.init(alloc, 16384);
    defer pipe.deinit();
    var srv = try ninep.server.Server.init(alloc, pipe.serverEnd(), &dev.draw.DevDraw.ops, &dd, 8192);
    defer srv.deinit();

    // Client side: 9P client, pump wired to the server, draw Display on top.
    var cl = try ninep.Client.init(alloc, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pumpServer };
    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");

    // DevDraw's root IS the draw directory (R-P2-1/R-P2-6): hand its fid over.
    const d = try draw.Display.init(alloc, &cl, root.fid);
    defer d.deinit();

    // Client-side view of the connection: N=1, display image 0, 640x480 XRGB32.
    try testing.expectEqual(@as(u32, 1), d.conn.conn);
    try testing.expectEqual(@as(u32, 0), d.conn.image_id);
    try testing.expectEqual(draw.proto.XRGB32, d.conn.chan);
    try testing.expectEqual(draw.proto.Rect.make(0, 0, 640, 480), d.conn.r);

    // Scene: white full-fill, then a red SoverD rect (100,100)-(300,200), one 'v'.
    try d.image.draw(draw.proto.Rect.make(0, 0, 640, 480), &d.white, null, .{});
    var red = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DRed);
    try d.image.draw(draw.proto.Rect.make(100, 100, 300, 200), &red, null, .{});
    try d.flush();

    // Spot-checks anchor the semantics (R-P2-7): corners/borders white,
    // interior red, exactly one presented frame.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(99, 99));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(99, 100));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(100, 99));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(300, 200));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(639, 479));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(100, 100));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(299, 199));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(200, 150));
    try testing.expectEqual(@as(u32, 1), hb.flush_count);

    // FROZEN-ACCEPT: 640x480 XRGB32, white full-fill, red (0xFF0000FF) SoverD
    // rect (100,100)-(300,200), RGBA8888 row-major, Wyhash seed 0. Frozen
    // 2026-07-19 from a spot-check-verified render (all nine pixel checks
    // above passed first); re-freeze ONLY with orchestrator sign-off (R-P2-7).
    try testing.expectEqual(@as(u64, 0x1a99dc0d115ae2bf), hb.hash());
}

test "phase-3: hello acme in misc-fixed over 9P onto a headless display" {
    const alloc = testing.allocator;

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

    // The embedded public-domain misc-fixed 9x18 font, through the real stack:
    // subfont decompress + parse, strip 'y' upload, cache 'b'/'i'/'l' preload.
    var font = try draw.Font.init(alloc, d, draw.Font.default_subfont);
    defer font.deinit();
    try testing.expectEqual(@as(u32, 256), font.n);
    try testing.expectEqual(@as(u8, 13), font.ascent);

    // Scene: white ground; "hello, acme" in black at top-left (20,20).
    const text = "hello, acme";
    try d.image.draw(draw.proto.Rect.make(0, 0, 640, 480), &d.white, null, .{});
    var black = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DBlack);
    const end = try font.drawString(&d.image, .{ .x = 20, .y = 20 }, &black, text);
    try d.flush();

    // Client-side metrics: 11 monospace glyphs x 9 px = 99 px advance.
    try testing.expectEqual(@as(i32, 99), font.stringWidth(text));
    try testing.expectEqual(@as(i32, 20 + 99), end.x);

    // Spot-checks anchor semantics (R-P2-7). Line box is y in [20, 38).
    // Above and below the line box: untouched white.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(20, 19));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(20, 38));
    // Left of the text and right of the last glyph: white.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(19, 28));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(20 + 99, 28));
    // The comma cell (glyph 5, x in [65,74)) must contain black below the
    // baseline (y=33 is the descender row band) — and the space cell (glyph 6)
    // must be entirely white.
    var comma_black = false;
    var y_scan: u32 = 20;
    while (y_scan < 38) : (y_scan += 1) {
        var x_scan: u32 = 65;
        while (x_scan < 74) : (x_scan += 1) {
            if (hb.pixelAt(x_scan, y_scan) == 0x000000FF) comma_black = true;
        }
    }
    try testing.expect(comma_black);
    var space_all_white = true;
    y_scan = 20;
    while (y_scan < 38) : (y_scan += 1) {
        var x_scan: u32 = 74;
        while (x_scan < 83) : (x_scan += 1) {
            if (hb.pixelAt(x_scan, y_scan) != 0xFFFFFFFF) space_all_white = false;
        }
    }
    try testing.expect(space_all_white);
    // Every glyph cell of "hello" and "acme" contains at least one black pixel.
    var cell: u32 = 0;
    while (cell < 11) : (cell += 1) {
        if (cell == 5 or cell == 6) continue; // comma/space handled above
        var any_black = false;
        y_scan = 20;
        while (y_scan < 38) : (y_scan += 1) {
            var x_scan: u32 = 20 + cell * 9;
            while (x_scan < 20 + (cell + 1) * 9) : (x_scan += 1) {
                if (hb.pixelAt(x_scan, y_scan) == 0x000000FF) any_black = true;
            }
        }
        try testing.expect(any_black);
    }
    try testing.expectEqual(@as(u32, 1), hb.flush_count);

    // FROZEN-ACCEPT-2: 640x480 XRGB32, white ground, "hello, acme" in black
    // misc-fixed 9x18 at top-left (20,20), RGBA8888 row-major, Wyhash seed 0.
    // Frozen 2026-07-19 from a spot-check-verified render; re-freeze ONLY with
    // orchestrator sign-off (R-P2-7).
    try testing.expectEqual(@as(u64, 0x4389e512acce6f36), hb.hash());
}

test "phase-4: wrapped buffer text through a frame onto a headless display" {
    const core = @import("core");
    const alloc = testing.allocator;

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

    // A REAL buffer/file: wrap + exact-fit line + newline + tab, 33 runes.
    var file = core.File.init(alloc, try core.Buffer.initFromBytes(alloc, "hello, acme wraps\nsecond line\ttab"));
    defer file.deinit();

    // White ground, black text; frame rect 11 chars wide (fixed 9x18 metrics).
    try d.image.draw(draw.proto.Rect.make(0, 0, 640, 480), &d.white, null, .{});
    var black = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DBlack);
    var text = core.Text.init(&file, alloc, draw.proto.Rect.make(20, 20, 119, 470), &font, &d.image, .{ &d.white, &d.white, &black, &black, &black });
    defer text.deinit();
    try text.fill();
    try d.flush();

    // Client-side layout cross-checks (frame contract §7).
    try testing.expectEqual(@as(usize, 33), text.fr.nchars);
    try testing.expectEqual(@as(usize, 4), text.fr.nlines);
    try testing.expect(!text.fr.lastlinefull);
    try testing.expectEqual(@as(i32, 92), text.fr.ptOfChar(30).x);
    try testing.expectEqual(@as(u32, 1), hb.flush_count);

    // Pixel spot-checks. Line boxes: L1 y[20,38) "hello, acme"; L2 y[38,56)
    // " wraps"; L3 y[56,74) "second line"; L4 y[74,92) tab gap then "tab"@x92.
    const white: u32 = 0xFFFFFFFF;
    try testing.expectEqual(white, hb.pixelAt(20, 19)); // above
    try testing.expectEqual(white, hb.pixelAt(20, 92)); // below L4
    try testing.expectEqual(white, hb.pixelAt(119, 28)); // right edge col
    const cellHasBlack = struct {
        fn f(h: *const dev.draw_backend.HeadlessBackend, x0: u32, y0: u32) bool {
            var y = y0;
            while (y < y0 + 18) : (y += 1) {
                var x = x0;
                while (x < x0 + 9) : (x += 1) {
                    if (h.pixelAt(x, y) == 0x000000FF) return true;
                }
            }
            return false;
        }
    }.f;
    const cellAllWhite = struct {
        fn f(h: *const dev.draw_backend.HeadlessBackend, x0: u32, x1: u32, y0: u32) bool {
            var y = y0;
            while (y < y0 + 18) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    if (h.pixelAt(x, y) != 0xFFFFFFFF) return false;
                }
            }
            return true;
        }
    }.f;
    try testing.expect(cellHasBlack(&hb, 20, 20)); // L1 'h'
    try testing.expect(cellHasBlack(&hb, 110, 20)); // L1 11th cell 'e' (wrap point)
    try testing.expect(cellAllWhite(&hb, 20, 29, 38)); // L2 leading space
    try testing.expect(cellHasBlack(&hb, 29, 38)); // L2 'w' — wrap landed
    try testing.expect(cellHasBlack(&hb, 20, 56)); // L3 's' — y = min+2*18
    try testing.expect(cellAllWhite(&hb, 20, 92, 74)); // L4 tab gap
    try testing.expect(cellHasBlack(&hb, 92, 74)); // L4 't' at the tab stop
    try testing.expect(cellHasBlack(&hb, 110, 74)); // L4 'b'

    // FROZEN-ACCEPT-3: 640x480 XRGB32, white ground, the 33-rune wrap/nl/tab
    // scene in black misc-fixed 9x18 through Buffer->File->Text->Frame->Font->
    // 9P->devdraw, RGBA8888 row-major, Wyhash seed 0. Frozen 2026-07-19 from a
    // spot-check-verified render; re-freeze ONLY with orchestrator sign-off.
    try testing.expectEqual(@as(u64, 0x7f16941423defd73), hb.hash());
}
