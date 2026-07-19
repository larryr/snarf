//! draw_canvas — the browser-facing draw backend (R-P5-1, R-P5-7).
//!
//! v1 canvas backend = a software-composite wrapper around `HeadlessBackend`
//! plus one `blit` import (R-P5-1). Every pixel and every geometry decision is
//! made by the wrapped headless compositor; this file adds ZERO pixel logic
//! (R-P5-5) — the eight non-flush ops are one-line delegations, and `flush`
//! merely presents the headless dirty rect through `abi.blit` before delegating
//! the reset. Per-image OffscreenCanvas compositing (S-03 §3) would break golden
//! fidelity (canvas compositing can't reproduce CALC11/12 +128 rounding), so it
//! is deferred to a later performance phase.
//!
//! Byte-exactness (R-P5-1): the display is XRGB32, whose store path forces
//! A=0xFF (draw_backend composite/storeRect). With alpha pinned to 255,
//! premultiplied == straight, so handing the raw RGBA8888 bytes to `putImageData`
//! is byte-exact — no un-premultiply step is needed on the JS side.
//!
//! SAB caveat (R-P5-1): `ImageData` rejects a `SharedArrayBuffer`-backed view.
//! Phase 5 runs on the main thread (R-P5-2) with plain linear memory, so this is
//! fine; when the module moves to a Worker with a shared ring, `blit` will need
//! a copy into a non-shared buffer before `putImageData`.
//!
//! Imports: `shim` (for the abi seam) and the sibling `draw_backend` — std-only
//! transitively, no browser API touched here (ADR-0003; the browser is reached
//! only through `abi.blit`).
const std = @import("std");
const abi = @import("shim").abi;
const draw_backend = @import("draw_backend.zig");

const Backend = draw_backend.Backend;
const Error = draw_backend.Error;
const Rect = draw_backend.Rect;
const Point = draw_backend.Point;
const DisplayInfo = draw_backend.DisplayInfo;
const ImageInfo = draw_backend.ImageInfo;

pub const CanvasBackend = struct {
    /// The wrapped compositor. Public so the boot code (and Wave-C acceptance)
    /// can hash it and read `fb`/`dirty`/`flush_count` directly (R-P5-7).
    headless: draw_backend.HeadlessBackend,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Error!Self {
        return .{ .headless = try draw_backend.HeadlessBackend.init(allocator, width, height) };
    }

    pub fn deinit(self: *Self) void {
        self.headless.deinit();
    }

    /// Wrap as a `Backend`. `self` must stay pinned for the vtable's lifetime.
    pub fn backend(self: *Self) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // ---- vtable trampolines: eight one-line delegations + the blitting flush ----

    fn ctxCast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
    fn vAlloc(ctx: *anyopaque, id: u32, r: Rect, chan: u32, repl: bool, clipr: Rect, color: u32) Error!void {
        return ctxCast(ctx).headless.backend().allocImage(id, r, chan, repl, clipr, color);
    }
    fn vFree(ctx: *anyopaque, id: u32) Error!void {
        return ctxCast(ctx).headless.backend().freeImage(id);
    }
    fn vDraw(ctx: *anyopaque, dst: u32, src: u32, mask: u32, r: Rect, sp: Point, mp: Point) Error!void {
        return ctxCast(ctx).headless.backend().draw(dst, src, mask, r, sp, mp);
    }
    fn vDisplayInfo(ctx: *anyopaque) DisplayInfo {
        return ctxCast(ctx).headless.backend().displayInfo();
    }
    fn vLoadPixels(ctx: *anyopaque, id: u32, r: Rect, data: []const u8) Error!usize {
        return ctxCast(ctx).headless.backend().loadPixels(id, r, data);
    }
    fn vCopy(ctx: *anyopaque, dst: u32, src: u32, r: Rect, sp: Point) Error!void {
        return ctxCast(ctx).headless.backend().copy(dst, src, r, sp);
    }
    fn vSetClipr(ctx: *anyopaque, id: u32, clipr: Rect) Error!void {
        return ctxCast(ctx).headless.backend().setClipr(id, clipr);
    }
    fn vImageInfo(ctx: *anyopaque, id: u32) Error!ImageInfo {
        return ctxCast(ctx).headless.backend().imageInfo(id);
    }

    /// Present the accumulated damage, then delegate the reset. The dirty rect is
    /// invariantly within `[0,width)×[0,height)`: every `markDirty` call in
    /// draw_backend passes an already-clipped rect (drawImpl/copyImpl clip r to
    /// dst.r = display bounds; loadPixelsImpl guards with rectInRect), so the
    /// i32→u32 `@intCast`s below cannot underflow.
    fn vFlush(ctx: *anyopaque) void {
        const self = ctxCast(ctx);
        if (self.headless.dirty) |r| {
            abi.blit(
                self.headless.fb.ptr,
                self.headless.width,
                self.headless.height,
                @intCast(r.min.x),
                @intCast(r.min.y),
                @intCast(r.dx()),
                @intCast(r.dy()),
            );
        }
        self.headless.backend().flush();
    }

    const vtable: Backend.VTable = .{
        .allocImage = vAlloc,
        .freeImage = vFree,
        .draw = vDraw,
        .flush = vFlush,
        .displayInfo = vDisplayInfo,
        .loadPixels = vLoadPixels,
        .copy = vCopy,
        .setClipr = vSetClipr,
        .imageInfo = vImageInfo,
    };
};

// ===================================================================
// Tests. The canvas backend owns no pixel logic, so these assert only the two
// things it adds: that the eight ops reach the wrapped headless backend, and
// that flush blits the dirty rect (through the native test_blit seam) then
// resets it.
// ===================================================================

const testing = std.testing;

const display_id = draw_backend.display_id;
const RGBA32 = draw_backend.RGBA32;
const XRGB32 = draw_backend.XRGB32;
const GREY1 = draw_backend.GREY1;
const unit = Rect.init(0, 0, 1, 1);
const WHITE: u32 = 0xFFFFFFFF;
const RED: u32 = 0xFF0000FF;
const GREEN: u32 = 0x00FF00FF;

/// Recorder installed into `abi.test_blit` for the flush test.
const BlitRec = struct {
    var count: u32 = 0;
    var last_ptr: ?[*]const u8 = null;
    var last_args: [6]u32 = .{ 0, 0, 0, 0, 0, 0 }; // fb_w, fb_h, x, y, w, h

    fn record(ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void {
        count += 1;
        last_ptr = ptr;
        last_args = .{ fb_w, fb_h, x, y, w, h };
    }
    fn reset() void {
        count = 0;
        last_ptr = null;
        last_args = .{ 0, 0, 0, 0, 0, 0 };
    }
};

test "canvas: eight ops delegate to the wrapped headless backend" {
    var cb = try CanvasBackend.init(testing.allocator, 64, 48);
    defer cb.deinit();
    const be = cb.backend();

    // allocImage (mask + solid) → draw: the fill must land in the wrapped fb.
    try be.allocImage(1, unit, GREY1, true, unit, WHITE); // white mask
    try be.allocImage(2, unit, RGBA32, true, unit, RED); // red solid
    try be.draw(display_id, 2, 1, Rect.init(0, 0, 10, 10), .{}, .{});
    try testing.expectEqual(@as(u32, RED), cb.headless.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, RED), cb.headless.pixelAt(9, 9));

    // imageInfo: introspection reaches the wrapped record.
    const info = try be.imageInfo(2);
    try testing.expect(info.repl);
    try testing.expectEqual(@as(u32, RGBA32), info.chan);

    // displayInfo: the display is XRGB32 at full bounds.
    const di = be.displayInfo();
    try testing.expectEqual(@as(u32, XRGB32), di.chan);
    try testing.expectEqual(Rect.init(0, 0, 64, 48), di.r);

    // setClipr: assignment reflected in the wrapped display_clipr.
    try be.setClipr(display_id, Rect.init(4, 4, 20, 20));
    try testing.expectEqual(Rect.init(4, 4, 20, 20), cb.headless.display_clipr);
    try be.setClipr(display_id, Rect.init(0, 0, 64, 48)); // restore

    // copy: a non-repl green source copied onto the display.
    try be.allocImage(5, Rect.init(0, 0, 16, 16), RGBA32, false, Rect.init(0, 0, 16, 16), GREEN);
    try be.copy(display_id, 5, Rect.init(20, 20, 36, 36), .{});
    try testing.expectEqual(@as(u32, GREEN), cb.headless.pixelAt(20, 20));

    // loadPixels: raw XRGB upload of one blue pixel into an image, bytes consumed.
    try be.allocImage(6, Rect.init(0, 0, 2, 1), XRGB32, false, Rect.init(0, 0, 2, 1), 0);
    const consumed = try be.loadPixels(6, Rect.init(0, 0, 1, 1), &[_]u8{ 0xFF, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(usize, 4), consumed);

    // freeImage: removal reaches the wrapped map.
    try be.freeImage(2);
    try testing.expectError(Error.UnknownImage, be.freeImage(2));
}

test "canvas: flush blits the dirty rect then resets it" {
    BlitRec.reset();
    abi.test_blit = &BlitRec.record;
    defer abi.test_blit = null;

    var cb = try CanvasBackend.init(testing.allocator, 640, 480);
    defer cb.deinit();
    const be = cb.backend();

    try be.allocImage(1, unit, GREY1, true, unit, WHITE);
    try be.allocImage(2, unit, RGBA32, true, unit, RED);
    // Damage rect (20,20)-(50,40): dx=30, dy=20.
    try be.draw(display_id, 2, 1, Rect.init(20, 20, 50, 40), .{}, .{});
    try testing.expect(cb.headless.dirty != null);

    be.flush();

    // Exactly one blit, framebuffer pointer + full display dims + the dirty rect.
    try testing.expectEqual(@as(u32, 1), BlitRec.count);
    try testing.expect(BlitRec.last_ptr.? == cb.headless.fb.ptr);
    try testing.expectEqual([6]u32{ 640, 480, 20, 20, 30, 20 }, BlitRec.last_args);
    // Delegated reset: dirty cleared, flush_count bumped.
    try testing.expect(cb.headless.dirty == null);
    try testing.expectEqual(@as(u32, 1), cb.headless.flush_count);

    // A no-damage flush blits nothing but still bumps the count.
    be.flush();
    try testing.expectEqual(@as(u32, 1), BlitRec.count);
    try testing.expectEqual(@as(u32, 2), cb.headless.flush_count);
}
