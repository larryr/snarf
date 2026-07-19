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
