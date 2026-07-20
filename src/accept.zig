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

    // White ground, black text. The Text rect starts at x=4 (phase-8 harness
    // shift, R-P8-12): the 12px scrollbar + 4px gap carve leaves the FRAME at
    // x=20 — 11 chars wide, byte-identical geometry to before, so the frozen
    // hash below still holds (BACK==white, so the scrollbar back-fill is a
    // redundant white-on-white paint over an already-white ground).
    try d.image.draw(draw.proto.Rect.make(0, 0, 640, 480), &d.white, null, .{});
    var black = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DBlack);
    var text = try core.Text.init(&file, alloc, draw.proto.Rect.make(4, 20, 119, 470), &font, &d.image, .{ &d.white, &d.white, &black, &black, &black });
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

test "phase-5: canvas backend reproduces the frozen phase-2 scene and blits it" {
    const alloc = testing.allocator;

    // Same scene as phase-2, but through CanvasBackend: pixel-identity with the
    // frozen hash is BY CONSTRUCTION (R-P5-1) — this test pins that claim.
    const Rec = struct {
        var calls: usize = 0;
        var last_ptr: usize = 0;
        fn blit(ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void {
            _ = fb_w;
            _ = fb_h;
            _ = x;
            _ = y;
            _ = w;
            _ = h;
            calls += 1;
            last_ptr = @intFromPtr(ptr);
        }
    };
    const shim = @import("shim");
    Rec.calls = 0;
    shim.abi.test_blit = Rec.blit;
    defer shim.abi.test_blit = null;

    var canvas = try dev.draw_canvas.CanvasBackend.init(alloc, 640, 480);
    defer canvas.deinit();
    var dd = dev.draw.DevDraw.init(alloc, canvas.backend());
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

    try d.image.draw(draw.proto.Rect.make(0, 0, 640, 480), &d.white, null, .{});
    var red = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DRed);
    try d.image.draw(draw.proto.Rect.make(100, 100, 300, 200), &red, null, .{});
    try d.flush();

    try testing.expectEqual(@as(usize, 1), Rec.calls);
    try testing.expectEqual(@intFromPtr(canvas.headless.fb.ptr), Rec.last_ptr);
    // The load-bearing assertion: byte-identical to the phase-2 frozen scene.
    try testing.expectEqual(@as(u64, 0x1a99dc0d115ae2bf), canvas.headless.hash());
}

test "phase-6: click, type, sweep — editing through the full stack" {
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

    // Acme palette (R-P6-9/F-10), empty buffer, 11-col frame.
    var back = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, 0xFFFFEAFF);
    var high = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, 0xEEEE9EFF);
    var black = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DBlack);
    try d.image.draw(draw.proto.Rect.make(0, 0, 640, 480), &back, null, .{});

    var file = core.File.init(alloc, core.Buffer.initEmpty(alloc));
    defer file.deinit();
    var text = try core.Text.init(&file, alloc, draw.proto.Rect.make(4, 20, 119, 470), &font, &d.image, .{ &back, &high, &black, &black, &black });
    defer text.deinit();

    var ed = core.Editor.init(alloc);
    defer ed.deinit();
    ed.text = &text;

    // (1) Type "ab\ncd" — one typing run, one transaction.
    for ([_]u21{ 'a', 'b', '\n', 'c', 'd' }) |r| try ed.handleKey(r);
    try ed.frameEnd(d);
    try testing.expectEqual(@as(usize, 5), file.buffer.len());
    try testing.expectEqual(@as(usize, 5), text.q0);
    try testing.expectEqual(@as(usize, 5), text.q1);

    // (2) B1 sweep from 'b' (char 1) down to line-2 char 4.
    try ed.handleMouse(.{ .x = 33, .y = 25, .buttons = 1, .msec = 100 });
    try ed.handleMouse(.{ .x = 33, .y = 43, .buttons = 1, .msec = 120 });
    try ed.handleMouse(.{ .x = 33, .y = 43, .buttons = 0, .msec = 140 });
    try ed.frameEnd(d);
    try testing.expectEqual(@as(usize, 1), text.q0);
    try testing.expectEqual(@as(usize, 4), text.q1);
    // Spot checks: 'b' cell highlighted, 'd' cell plain, no tick when p0!=p1.
    try testing.expectEqual(@as(u32, 0xEEEE9EFF), hb.pixelAt(31, 22)); // 'b' cell bg (avoid glyph ink)
    try testing.expectEqual(@as(u32, 0xEEEE9EFF), hb.pixelAt(24, 40)); // 'c' cell bg (L2)
    try testing.expectEqual(@as(u32, 0xFFFFEAFF), hb.pixelAt(31, 40)); // 'd' cell bg — outside selection
    // FROZEN-ACCEPT-6a: 640x480, acme palette, "ab\ncd" typed, B1 sweep [1,4)
    // highlighted. Frozen 2026-07-19 after spot-checks; re-freeze only with
    // orchestrator sign-off (R-P2-7).
    try testing.expectEqual(@as(u64, 0x722dca39c32500b2), hb.hash());

    // (3) Type 'X' over the selection; (4) backspace.
    try ed.handleKey('X');
    try ed.handleKey(0x08); // Kbs
    try ed.frameEnd(d);
    var rbuf: [32]u8 = undefined;
    try testing.expectEqualStrings("ad", file.buffer.read(0, file.buffer.len(), &rbuf));

    // (5) B1 click past end of L1 -> caret at end (char 2).
    try ed.handleMouse(.{ .x = 50, .y = 25, .buttons = 1, .msec = 200 });
    try ed.handleMouse(.{ .x = 50, .y = 25, .buttons = 0, .msec = 220 });
    try ed.frameEnd(d);
    try testing.expectEqual(@as(usize, 2), text.q0);
    try testing.expectEqual(@as(usize, 2), text.q1);
    // Tick pins at ptOfChar(2) = (38,20): vertical line x=38, boxes at top/bottom.
    try testing.expectEqual(@as(u32, 0x000000FF), hb.pixelAt(38, 28)); // vertical line
    try testing.expectEqual(@as(u32, 0x000000FF), hb.pixelAt(37, 21)); // top box
    try testing.expectEqual(@as(u32, 0x000000FF), hb.pixelAt(39, 36)); // bottom box
    try testing.expectEqual(@as(u32, 0xFFFFEAFF), hb.pixelAt(41, 28)); // right of tick
    // FROZEN-ACCEPT-6b: after type-over + backspace ("ad") and a B1 click, the
    // typing tick visible at char 2. Frozen 2026-07-19 after the tick-pixel
    // pins passed (R-P2-7).
    try testing.expectEqual(@as(u64, 0x89e8596ac03dd172), hb.hash());

    // (6) Undo/redo round-trip: two typing runs = two transactions.
    _ = try file.undo();
    try testing.expectEqualStrings("ab\ncd", file.buffer.read(0, file.buffer.len(), &rbuf));
    _ = try file.undo();
    try testing.expectEqual(@as(usize, 0), file.buffer.len());
    _ = try file.redo();
    _ = try file.redo();
    try testing.expectEqualStrings("ad", file.buffer.read(0, file.buffer.len(), &rbuf));
    // Undo/redo mutate the FILE only — frame resync on undo is deferred (the
    // future Text-observer hook), so pixels still match FROZEN-ACCEPT-6b.
    try testing.expectEqual(@as(u64, 0x89e8596ac03dd172), hb.hash());
}

test "phase-7: double-click, chord cut, chord paste — through the full stack" {
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
    var back = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, 0xFFFFEAFF);
    var high = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, 0xEEEE9EFF);
    var black = try d.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DBlack);
    try d.image.draw(draw.proto.Rect.make(0, 0, 640, 480), &back, null, .{});

    var file = core.File.init(alloc, core.Buffer.initEmpty(alloc));
    defer file.deinit();
    var text = try core.Text.init(&file, alloc, draw.proto.Rect.make(4, 20, 119, 470), &font, &d.image, .{ &back, &high, &black, &black, &black });
    defer text.deinit();
    var ed = core.Editor.init(alloc);
    defer ed.deinit();
    ed.text = &text;

    // Type "cut me now"; double-click "me" (chars 4..6): click twice at (60,25)
    // within 500ms — char 4 is 'm' (x cell [56,65)).
    for ("cut me now") |ch| try ed.handleKey(ch);
    try ed.handleMouse(.{ .x = 60, .y = 25, .buttons = 1, .msec = 100 });
    try ed.handleMouse(.{ .x = 60, .y = 25, .buttons = 0, .msec = 120 });
    try ed.handleMouse(.{ .x = 60, .y = 25, .buttons = 1, .msec = 300 });
    try testing.expectEqual(@as(usize, 4), text.q0);
    try testing.expectEqual(@as(usize, 6), text.q1);

    // Chord: with B1 still down, join B2 -> cut "me" into snarf.
    try ed.handleMouse(.{ .x = 60, .y = 25, .buttons = 1 | 2, .msec = 340 });
    try ed.handleMouse(.{ .x = 60, .y = 25, .buttons = 0, .msec = 380 });
    try ed.frameEnd(d);
    var rbuf: [64]u8 = undefined;
    try testing.expectEqualStrings("cut  now", file.buffer.read(0, file.buffer.len(), &rbuf));
    try testing.expectEqualStrings("me", ed.snarf.items);

    // Click at end of text (char 8 cell x [92,101)... end is q=8: click far right),
    // then chord-paste: B1 down + B3 join.
    try ed.handleMouse(.{ .x = 110, .y = 25, .buttons = 1, .msec = 1000 });
    try ed.handleMouse(.{ .x = 110, .y = 25, .buttons = 1 | 4, .msec = 1040 });
    try ed.handleMouse(.{ .x = 110, .y = 25, .buttons = 0, .msec = 1080 });
    try ed.frameEnd(d);
    try testing.expectEqualStrings("cut  nowme", file.buffer.read(0, file.buffer.len(), &rbuf));
    // Pasted text ends selected (selectall=TRUE): q0/q1 cover "me".
    try testing.expectEqual(@as(usize, 8), text.q0);
    try testing.expectEqual(@as(usize, 10), text.q1);
    // Selection highlight visible at the pasted cells (x [92,110), row 1).
    try testing.expectEqual(@as(u32, 0xEEEE9EFF), hb.pixelAt(93, 22));

    // Undo chain: paste, cut, typing run -> empty.
    _ = try file.undo();
    try testing.expectEqualStrings("cut  now", file.buffer.read(0, file.buffer.len(), &rbuf));
    _ = try file.undo();
    try testing.expectEqualStrings("cut me now", file.buffer.read(0, file.buffer.len(), &rbuf));
    _ = try file.undo();
    try testing.expectEqual(@as(usize, 0), file.buffer.len());

    // FROZEN-ACCEPT-7: acme palette, "cut  nowme" with the pasted word
    // selected. Frozen 2026-07-19 after spot-checks (R-P2-7).
    try testing.expectEqual(@as(u64, 0x5b816c29a0ad026f), hb.hash());
}

test "phase-8: boot chrome scene — two windows, tags, scrollbars" {
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

    var tree = try core.boot.boot(alloc, d, &font, draw.proto.Rect.make(0, 0, 640, 480), .{ .win_name = "scratch", .body = "hello, acme\nsecond line\n" });
    defer tree.deinit();
    var ed = core.Editor.init(alloc);
    defer ed.deinit();
    ed.row = tree.row;
    try ed.frameEnd(d);

    // Chrome spot-checks: row tag pale blue at (30,2); black band below the
    // row tag; window tag pale blue; body ivory; scrollbar bord (yellowgreen).
    try testing.expectEqual(@as(u32, 0xEAFFFFFF), hb.pixelAt(30, 2));
    const h: u32 = font.height; // 18
    try testing.expectEqual(@as(u32, 0x000000FF), hb.pixelAt(30, h)); // border band
    // Row tag literal in its File:
    var tbuf: [128]u8 = undefined;
    try testing.expectEqualStrings("Newcol Kill Putall Dump Exit ", tree.row.tag.file.buffer.read(0, tree.row.tag.file.buffer.len(), &tbuf));

    // Second window; type into each body via point-to-type (pointer position).
    const w2 = try tree.addWindow("notes", "");
    _ = w2;
    try ed.frameEnd(d);
    const w1 = tree.row.col.items[0].w.items[0];
    const win2 = tree.row.col.items[0].w.items[1];
    // Point into w1's body and type:
    const p1 = w1.body.fr.r;
    ed.mouse_pt = .{ .x = p1.min.x + 5, .y = p1.min.y + 5 };
    try ed.handleKey('A');
    // Point into w2's body and type:
    const p2 = win2.body.fr.r;
    ed.mouse_pt = .{ .x = p2.min.x + 5, .y = p2.min.y + 5 };
    try ed.handleKey('B');
    try ed.frameEnd(d);
    var rbuf: [128]u8 = undefined;
    try testing.expectEqual(@as(u21, 'A'), w1.body.file.buffer.runeAt(0));
    try testing.expectEqualStrings("B", win2.body.file.buffer.read(0, win2.body.file.buffer.len(), &rbuf));

    // R-P9-4 live tags: the final frameEnd's tag sweep saw w1's body dirtied by
    // the point-to-type edit and recomposed its tag with the live " Undo" word.
    // (w2 shares the SAME global typing run started in w1, so only w1's File was
    // filemark'd — R-P6-8 — leaving w2 undirtied and its tag unchanged.)
    var tgbuf: [128]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, w1.tag.file.buffer.read(0, w1.tag.file.buffer.len(), &tgbuf), " Undo") != null);
    try testing.expect(std.mem.indexOf(u8, win2.tag.file.buffer.read(0, win2.tag.file.buffer.len(), &tgbuf), " Undo") == null);

    // FROZEN-ACCEPT-8: full acme chrome — row tag, column tag+button, two
    // windows with tags/buttons/scrollbars, point-to-type edits in both.
    // Re-frozen 2026-07-20 (phase 9d): the frameEnd tag sweep (R-P9-4) now adds
    // the live " Undo" word to each edited window's tag, changing the write
    // stream from the phase-8 freeze. Spot-checks above still hold (R-P2-7).
    try testing.expectEqual(@as(u64, 0x9816211a7aca91d7), hb.hash());
}

test "phase-9: B2 exec scene — snarf from tag, two-strike Del, neighbor grows" {
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

    var tree = try core.boot.boot(alloc, d, &font, draw.proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "one",
        .body = "snarfme rest\n",
    });
    defer tree.deinit();
    var ed = core.Editor.init(alloc);
    defer ed.deinit();
    ed.row = tree.row;
    ed.but2col = tree.chrome.but2col; // acme.c:1084-1085, as main_wasm binds them
    ed.but3col = tree.chrome.but3col;
    try ed.frameEnd(d);

    const col = tree.row.col.items[0];
    const w1 = col.w.items[0];

    // B1-select "snarfme" ([0,7)) in body-1 — sets seltext/argtext (acme.c:656-657).
    const b1p0 = w1.body.fr.ptOfChar(0);
    const b1p7 = w1.body.fr.ptOfChar(7);
    try ed.handleMouse(.{ .x = b1p0.x, .y = b1p0.y, .buttons = 1, .msec = 0 });
    try ed.handleMouse(.{ .x = b1p7.x, .y = b1p7.y, .buttons = 1, .msec = 20 });
    try ed.handleMouse(.{ .x = b1p7.x, .y = b1p7.y, .buttons = 0, .msec = 40 });
    try testing.expectEqual(@as(usize, 0), w1.body.q0);
    try testing.expectEqual(@as(usize, 7), w1.body.q1);
    try testing.expect(ed.seltext == &w1.body);

    // B2-click "Snarf" in w1's tag ("one Del Snarf | Look ", 'a' of Snarf at 10):
    // the cut wrapper routes to the window's BODY selection (exec.c:961-963).
    // Snarf never marks (exec.c:124 mark=F) so ed.seq stays 0.
    const tag_snarf = w1.tag.fr.ptOfChar(10);
    try ed.handleMouse(.{ .x = tag_snarf.x, .y = tag_snarf.y, .buttons = 2, .msec = 1000 });
    try ed.handleMouse(.{ .x = tag_snarf.x, .y = tag_snarf.y, .buttons = 0, .msec = 1000 });
    try testing.expectEqualStrings("snarfme", ed.snarf.items);
    try testing.expectEqual(@as(u32, 0), ed.seq);
    var rbuf: [64]u8 = undefined;
    try testing.expectEqualStrings("snarfme rest\n", w1.body.file.buffer.read(0, w1.body.file.buffer.len(), &rbuf));

    // Second window; point-to-type an 'X' into it (dirties it, R-P6-8 typing run).
    const w2 = try tree.addWindow("notes", "");
    try ed.frameEnd(d);
    ed.mouse_pt = .{ .x = w2.body.fr.r.min.x + 5, .y = w2.body.fr.r.min.y + 5 };
    try ed.handleKey('X');
    try ed.frameEnd(d); // the tag sweep adds " Undo" to w2's tag (after "Snarf")
    try testing.expect(w2.dirty);

    // B2-click "Del" in w2's tag ("notes Del Snarf ...", 'e' of Del at 7).
    // FIRST strike: the two-strike clean (wind.c:666-685) warns once, clears
    // dirty (file.mod stays — the mod dot survives), and the window lives on.
    const tag_del = w2.tag.fr.ptOfChar(7);
    try ed.handleMouse(.{ .x = tag_del.x, .y = tag_del.y, .buttons = 2, .msec = 2000 });
    try ed.handleMouse(.{ .x = tag_del.x, .y = tag_del.y, .buttons = 0, .msec = 2000 });
    try testing.expectEqual(@as(usize, 2), col.w.items.len);
    try testing.expect(std.mem.indexOf(u8, ed.warnings.items, "notes modified") != null);
    try testing.expect(!w2.dirty);
    try testing.expect(w2.body.file.mod);

    // SECOND strike: the window closes and w1 grows back over the whole column
    // body (colclose neighbor geometry, cols.c:189-207).
    try ed.handleMouse(.{ .x = tag_del.x, .y = tag_del.y, .buttons = 2, .msec = 3000 });
    try ed.handleMouse(.{ .x = tag_del.x, .y = tag_del.y, .buttons = 0, .msec = 3000 });
    try testing.expectEqual(@as(usize, 1), col.w.items.len);
    try testing.expectEqual(w1, col.w.items[0]);
    try testing.expectEqual(col.r.max.y, w1.r.max.y);
    try ed.frameEnd(d);

    // FROZEN-ACCEPT-9: B2 exec scene — tag Snarf against the body selection,
    // live-tag Undo, two-strike Del, neighbor regrowth. NEW freeze (R-P2-7),
    // spot-checks above.
    try testing.expectEqual(@as(u64, 0xb52b86b54d50d100), hb.hash());
}

test "phase-9: B3 look scene — click cycles occurrences with wraparound" {
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

    // 60 lines with "needle" on lines 2, 30 and 50 — the latter two below the
    // fold of a ~22-line body frame.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var offs: [3]usize = undefined;
    var noff: usize = 0;
    var line: usize = 0;
    var runes: usize = 0;
    while (line < 60) : (line += 1) {
        if (line == 2 or line == 30 or line == 50) {
            offs[noff] = runes + 2; // past "x "
            noff += 1;
            try body.appendSlice(alloc, "x needle y\n");
            runes += 11;
        } else {
            try body.appendSlice(alloc, "filler\n");
            runes += 7;
        }
    }

    var tree = try core.boot.boot(alloc, d, &font, draw.proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "hay",
        .body = body.items,
    });
    defer tree.deinit();
    var ed = core.Editor.init(alloc);
    defer ed.deinit();
    ed.row = tree.row;
    ed.but2col = tree.chrome.but2col;
    ed.but3col = tree.chrome.but3col;
    try ed.frameEnd(d);

    const w = tree.row.col.items[0].w.items[0];
    const t = &w.body;

    // B3-click mid-"needle" on line 2 (visible from org=0): the alnum run is the
    // needle; the caret collapses past it and the forward search lands on the
    // line-30 occurrence, scrolled visible by textshow (look.c:208-218).
    const c1 = t.fr.ptOfChar(offs[0] + 2 - t.org);
    try ed.handleMouse(.{ .x = c1.x, .y = c1.y, .buttons = 4, .msec = 100 });
    try ed.handleMouse(.{ .x = c1.x, .y = c1.y, .buttons = 0, .msec = 100 });
    try testing.expectEqual(offs[1], t.q0);
    try testing.expectEqual(offs[1] + 6, t.q1);
    try testing.expect(t.org > 0); // scrolled
    try testing.expect(t.q0 >= t.org and t.q0 < t.org + t.fr.nchars); // visible
    try testing.expect(ed.seltext == t); // look.c:427

    // B3-click inside the CURRENT selection: the selection is the needle
    // (look.c:738-743); the search continues to the line-50 occurrence.
    const c2 = t.fr.ptOfChar(t.q0 + 2 - t.org);
    try ed.handleMouse(.{ .x = c2.x, .y = c2.y, .buttons = 4, .msec = 200 });
    try ed.handleMouse(.{ .x = c2.x, .y = c2.y, .buttons = 0, .msec = 200 });
    try testing.expectEqual(offs[2], t.q0);
    try testing.expectEqual(offs[2] + 6, t.q1);
    try testing.expect(t.q0 >= t.org and t.q0 < t.org + t.fr.nchars);

    // Third click: WRAPS around to the line-2 occurrence (look.c:385-389).
    const c3 = t.fr.ptOfChar(t.q0 + 2 - t.org);
    try ed.handleMouse(.{ .x = c3.x, .y = c3.y, .buttons = 4, .msec = 300 });
    try ed.handleMouse(.{ .x = c3.x, .y = c3.y, .buttons = 0, .msec = 300 });
    try testing.expectEqual(offs[0], t.q0);
    try testing.expectEqual(offs[0] + 6, t.q1);
    try testing.expect(t.q0 >= t.org and t.q0 < t.org + t.fr.nchars);
    try ed.frameEnd(d);
}
