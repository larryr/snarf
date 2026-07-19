//! draw_backend — the pixel-plane behind /dev/draw, with a headless framebuffer.
//!
//! `devdraw` (src/dev/draw.zig) parses the Plan 9 draw wire protocol and drives a
//! `Backend`: a runtime vtable — shaped exactly like `ninep.transport.Transport` —
//! that owns image storage and does the actual compositing. Phase 2 ships one
//! implementation, `HeadlessBackend`, an in-memory RGBA8888 raster the tests
//! golden-hash; the OffscreenCanvas backend (`draw_canvas.zig`) is Phase 5 and is
//! the only place the browser is touched. This file therefore imports **std only**
//! (ADR-0003, S-07 §6): no shim, no ninep.
//!
//! The compositor is a faithful, integer-exact port of the SoverD path in
//! plan9port `libmemdraw/draw.c` — clipping (`drawclip`, draw.c:236-298), the
//! opaque-mask fast path (`boolcopyfn`, draw.c:1952), and the per-channel alpha
//! arithmetic `CALC11` (draw.c:20-21, alphadraw draw.c:1035-1058). Getting that
//! arithmetic bit-exact is the whole point: every golden image downstream rests
//! on it (see the "SoverD translucent fill" test, which pins it by hand).
//!
//! Coordinates are half-open, top-left origin, y increasing downward (draw(3)).

const std = @import("std");

// ===================================================================
// Geometry — signed i32, half-open rectangles (devdraw.c:871-877).
// ===================================================================

pub const Point = struct { x: i32 = 0, y: i32 = 0 };

pub const Rect = struct {
    min: Point = .{},
    max: Point = .{},

    pub fn init(x0: i32, y0: i32, x1: i32, y1: i32) Rect {
        return .{ .min = .{ .x = x0, .y = y0 }, .max = .{ .x = x1, .y = y1 } };
    }

    pub fn dx(self: Rect) i32 {
        return self.max.x - self.min.x;
    }

    pub fn dy(self: Rect) i32 {
        return self.max.y - self.min.y;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.min.x >= self.max.x or self.min.y >= self.max.y;
    }

    /// Intersect-in-place with `b`; return false (leaving self unchanged) if the
    /// result is empty. Mirrors `rectclip` — clamp each edge inward to `b`
    /// (plan9port libgeometry/rectclip.c; used throughout drawclip).
    pub fn clip(self: *Rect, b: Rect) bool {
        var r = self.*;
        if (r.min.x < b.min.x) r.min.x = b.min.x;
        if (r.min.y < b.min.y) r.min.y = b.min.y;
        if (r.max.x > b.max.x) r.max.x = b.max.x;
        if (r.max.y > b.max.y) r.max.y = b.max.y;
        if (r.isEmpty()) return false;
        self.* = r;
        return true;
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.min.x and p.x < self.max.x and
            p.y >= self.min.y and p.y < self.max.y;
    }

    pub fn translate(self: Rect, d: Point) Rect {
        return .{
            .min = .{ .x = self.min.x + d.x, .y = self.min.y + d.y },
            .max = .{ .x = self.max.x + d.x, .y = self.max.y + d.y },
        };
    }

    fn is1x1(self: Rect) bool {
        return self.dx() == 1 and self.dy() == 1;
    }
};

// ===================================================================
// Channel descriptors (draw.h:112-146). See G9 / R-P2-5: both the client
// and this backend define their own constants, each re-deriving them from
// the `__DC` bit arithmetic at comptime so the two copies can never drift.
// ===================================================================

pub const GREY1: u32 = 0x31;
pub const RGB24: u32 = 0x00081828;
pub const RGBA32: u32 = 0x08182848;
pub const XRGB32: u32 = 0x68081828;
pub const GREY8: u32 = 0x38;

/// `__DC(type,nbits) = ((type&15)<<4) | (nbits&15)` (draw.h:123). Color types:
/// CRed=0 CGreen=1 CBlue=2 CGrey=3 CAlpha=4 CIgnore=6 (draw.h:113-119).
fn dc(comptime ty: u32, comptime nbits: u32) u32 {
    return ((ty & 15) << 4) | (nbits & 15);
}

comptime {
    const CRed = 0;
    const CGreen = 1;
    const CBlue = 2;
    const CGrey = 3;
    const CAlpha = 4;
    const CIgnore = 6;
    std.debug.assert(GREY1 == dc(CGrey, 1)); // 0x31
    std.debug.assert(GREY8 == dc(CGrey, 8)); // 0x38
    std.debug.assert(RGB24 == (dc(CRed, 8) << 16) | (dc(CGreen, 8) << 8) | dc(CBlue, 8));
    std.debug.assert(RGBA32 == (dc(CRed, 8) << 24) | (dc(CGreen, 8) << 16) | (dc(CBlue, 8) << 8) | dc(CAlpha, 8));
    std.debug.assert(XRGB32 == (dc(CIgnore, 8) << 24) | (dc(CRed, 8) << 16) | (dc(CGreen, 8) << 8) | dc(CBlue, 8));
}

/// Image id 0 is the display, pre-installed at connection (devdraw.c:1078, G6).
pub const display_id: u32 = 0;

pub const Error = error{
    UnknownImage,
    ImageExists,
    BadChan,
    BadRect,
    Unsupported,
    OutOfMemory,
};

pub const DisplayInfo = struct { chan: u32, r: Rect, clipr: Rect };

// ===================================================================
// Backend — runtime vtable (mirrors ninep.transport.Transport).
// ===================================================================

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Allocate image `id`. `!repl` stores `clipr ∩ r`; `repl` stores `clipr`
        /// verbatim (devdraw.c:1532-1535). Errors: ImageExists / BadChan / BadRect.
        allocImage: *const fn (ctx: *anyopaque, id: u32, r: Rect, chan: u32, repl: bool, clipr: Rect, color: u32) Error!void,
        /// Free image `id`. Unknown ⇒ UnknownImage; id 0 (display) ⇒ Unsupported.
        freeImage: *const fn (ctx: *anyopaque, id: u32) Error!void,
        /// SoverD `src` (through opaque `mask`) into `dst`'s rectangle `r`.
        draw: *const fn (ctx: *anyopaque, dst: u32, src: u32, mask: u32, r: Rect, sp: Point, mp: Point) Error!void,
        /// Present accumulated damage; clears the dirty rect, bumps flush_count.
        flush: *const fn (ctx: *anyopaque) void,
        displayInfo: *const fn (ctx: *anyopaque) DisplayInfo,
    };

    pub fn allocImage(self: Backend, id: u32, r: Rect, chan: u32, repl: bool, clipr: Rect, color: u32) Error!void {
        return self.vtable.allocImage(self.ctx, id, r, chan, repl, clipr, color);
    }
    pub fn freeImage(self: Backend, id: u32) Error!void {
        return self.vtable.freeImage(self.ctx, id);
    }
    pub fn draw(self: Backend, dst: u32, src: u32, mask: u32, r: Rect, sp: Point, mp: Point) Error!void {
        return self.vtable.draw(self.ctx, dst, src, mask, r, sp, mp);
    }
    pub fn flush(self: Backend) void {
        return self.vtable.flush(self.ctx);
    }
    pub fn displayInfo(self: Backend) DisplayInfo {
        return self.vtable.displayInfo(self.ctx);
    }
};

// ===================================================================
// Pixel helpers. Storage is always RGBA8888 `[R,G,B,A]` holding
// alpha-premultiplied values (G2). Colors on the wire are packed
// `0xRRGGBBAA` (red in the high byte, alpha in the low byte).
// ===================================================================

const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

fn unpack(c: u32) Rgba {
    return .{
        .r = @intCast((c >> 24) & 0xFF),
        .g = @intCast((c >> 16) & 0xFF),
        .b = @intCast((c >> 8) & 0xFF),
        .a = @intCast(c & 0xFF),
    };
}

fn chanKnown(c: u32) bool {
    return c == GREY1 or c == GREY8 or c == RGB24 or c == RGBA32 or c == XRGB32;
}

/// Only RGBA32 carries alpha; the rest are opaque and force A=0xFF on store.
fn chanHasAlpha(c: u32) bool {
    return c == RGBA32;
}

/// `CALC11(a,v) = (t = a*v + 128; (t + (t>>8)) >> 8)` — draw.c:20-21. Approximates
/// `round(a*v/255)` for 8-bit a,v; the +128 rounds to nearest instead of trunc.
fn calc11(a: u32, v: u32) u32 {
    const t = a * v + 128;
    return (t + (t >> 8)) >> 8;
}

// ===================================================================
// Internal image record. A 1×1 repl solid carries no pixel buffer — just its
// fill color (devdraw.c:1527-1539; O4 §1.3). Everything else gets a heap raster.
// ===================================================================

const Image = struct {
    r: Rect,
    clipr: Rect,
    chan: u32,
    repl: bool,
    /// RGBA8888 row-major over `r`; null iff this is a 1×1 repl solid.
    pixels: ?[]u8,
    /// Packed 0xRRGGBBAA premultiplied fill (solids; also the memfill seed).
    fill: u32,
};

/// A mutable draw target: display framebuffer or a buffered image.
const Dst = struct { pixels: []u8, r: Rect, clipr: Rect, chan: u32 };
/// A read-only draw source/mask view (may be a bufferless solid).
const View = struct { pixels: ?[]const u8, r: Rect, clipr: Rect, repl: bool, fill: u32 };

fn composite(dst: Dst, x: i32, y: i32, s: Rgba) void {
    const w: usize = @intCast(dst.r.dx());
    const col: usize = @intCast(x - dst.r.min.x);
    const row: usize = @intCast(y - dst.r.min.y);
    const p = dst.pixels[(row * w + col) * 4 ..][0..4];
    if (s.a == 0xFF) {
        // Opaque source ⇒ store (short-circuit, draw.c:2128-2134).
        p.* = .{ s.r, s.g, s.b, s.a };
    } else {
        // SoverD, mask opaque (ma=255): out_c = src_c + CALC11(255-src_a, dst_c).
        // draw.c:1035-1058 with ma folded out. src_c is premultiplied, so for a
        // valid color the sum never exceeds 255; @min guards regardless.
        const fd: u32 = 255 - @as(u32, s.a);
        p[0] = @intCast(@min(255, @as(u32, s.r) + calc11(fd, p[0])));
        p[1] = @intCast(@min(255, @as(u32, s.g) + calc11(fd, p[1])));
        p[2] = @intCast(@min(255, @as(u32, s.b) + calc11(fd, p[2])));
        p[3] = @intCast(@min(255, @as(u32, s.a) + calc11(fd, p[3])));
    }
    // XRGB/RGB/GREY targets have no stored alpha; keep them opaque (draw.c:1063).
    if (!chanHasAlpha(dst.chan)) p[3] = 0xFF;
}

fn fillRect(dst: Dst, r: Rect, color: u32) void {
    const s = unpack(color);
    var y = r.min.y;
    while (y < r.max.y) : (y += 1) {
        var x = r.min.x;
        while (x < r.max.x) : (x += 1) composite(dst, x, y, s);
    }
}

fn copyRect(dst: Dst, r: Rect, src: View, delta: Point) void {
    const sw: usize = @intCast(src.r.dx());
    const buf = src.pixels.?;
    var y = r.min.y;
    while (y < r.max.y) : (y += 1) {
        var x = r.min.x;
        while (x < r.max.x) : (x += 1) {
            const scol: usize = @intCast(x - delta.x - src.r.min.x);
            const srow: usize = @intCast(y - delta.y - src.r.min.y);
            const sp = buf[(srow * sw + scol) * 4 ..][0..4];
            composite(dst, x, y, .{ .r = sp[0], .g = sp[1], .b = sp[2], .a = sp[3] });
        }
    }
}

// ===================================================================
// HeadlessBackend — RGBA8888 raster with a hashable framebuffer.
// ===================================================================

pub const HeadlessBackend = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    /// RGBA8888 row-major, width*height*4, zero-initialized. Image id 0.
    fb: []u8,
    images: std.AutoHashMapUnmanaged(u32, Image) = .empty,
    dirty: ?Rect = null,
    flush_count: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Error!Self {
        const fb = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
        @memset(fb, 0);
        return .{ .allocator = allocator, .width = width, .height = height, .fb = fb };
    }

    pub fn deinit(self: *Self) void {
        var it = self.images.valueIterator();
        while (it.next()) |img| if (img.pixels) |px| self.allocator.free(px);
        self.images.deinit(self.allocator);
        self.allocator.free(self.fb);
        self.* = undefined;
    }

    fn bounds(self: *const Self) Rect {
        return Rect.init(0, 0, @intCast(self.width), @intCast(self.height));
    }

    /// Wrap as a `Backend`. `self` must stay pinned for the vtable's lifetime.
    pub fn backend(self: *Self) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn pixels(self: *const Self) []const u8 {
        return self.fb;
    }

    /// Packed 0xRRGGBBAA at (x,y).
    pub fn pixelAt(self: *const Self, x: u32, y: u32) u32 {
        const i = (@as(usize, y) * self.width + x) * 4;
        return (@as(u32, self.fb[i]) << 24) | (@as(u32, self.fb[i + 1]) << 16) |
            (@as(u32, self.fb[i + 2]) << 8) | @as(u32, self.fb[i + 3]);
    }

    pub fn hash(self: *const Self) u64 {
        return std.hash.Wyhash.hash(0, self.fb);
    }

    /// Binary PPM (P6): header then RGB triples (alpha dropped).
    pub fn writePpm(self: *const Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("P6\n{d} {d}\n255\n", .{ self.width, self.height });
        var i: usize = 0;
        while (i < self.fb.len) : (i += 4) try w.writeAll(self.fb[i..][0..3]);
    }

    // ---- backend operations (bodies behind the vtable trampolines) ----

    fn allocImageImpl(self: *Self, id: u32, r: Rect, chan: u32, repl: bool, clipr: Rect, color: u32) Error!void {
        if (id == display_id or self.images.contains(id)) return Error.ImageExists; // G6
        if (!chanKnown(chan)) return Error.BadChan;
        if (r.dx() <= 0 or r.dy() <= 0) return Error.BadRect;

        var cr = clipr;
        if (!repl) _ = cr.clip(r); // devdraw.c:1533-1534
        var img = Image{ .r = r, .clipr = cr, .chan = chan, .repl = repl, .pixels = null, .fill = color };

        if (!(repl and r.is1x1())) {
            // Buffered image: allocmemimage + memfillcolor (devdraw.c:1527-1539).
            const n = @as(usize, @intCast(r.dx())) * @as(usize, @intCast(r.dy())) * 4;
            const buf = try self.allocator.alloc(u8, n);
            errdefer self.allocator.free(buf);
            const c = unpack(color);
            const a: u8 = if (chanHasAlpha(chan)) c.a else 0xFF;
            var i: usize = 0;
            while (i < n) : (i += 4) {
                buf[i] = c.r;
                buf[i + 1] = c.g;
                buf[i + 2] = c.b;
                buf[i + 3] = a;
            }
            img.pixels = buf;
        }
        try self.images.put(self.allocator, id, img);
    }

    fn freeImageImpl(self: *Self, id: u32) Error!void {
        if (id == display_id) return Error.Unsupported; // display is not freeable (G6)
        const removed = self.images.fetchRemove(id) orelse return Error.UnknownImage;
        if (removed.value.pixels) |px| self.allocator.free(px);
    }

    fn dstSurface(self: *Self, id: u32) Error!Dst {
        if (id == display_id)
            return .{ .pixels = self.fb, .r = self.bounds(), .clipr = self.bounds(), .chan = XRGB32 };
        const img = self.images.getPtr(id) orelse return Error.UnknownImage;
        const px = img.pixels orelse return Error.Unsupported; // can't paint onto a solid
        return .{ .pixels = px, .r = img.r, .clipr = img.clipr, .chan = img.chan };
    }

    fn view(self: *Self, id: u32) Error!View {
        if (id == display_id)
            return .{ .pixels = self.fb, .r = self.bounds(), .clipr = self.bounds(), .repl = false, .fill = 0 };
        const img = self.images.get(id) orelse return Error.UnknownImage;
        return .{ .pixels = img.pixels, .r = img.r, .clipr = img.clipr, .repl = img.repl, .fill = img.fill };
    }

    fn drawImpl(self: *Self, dstid: u32, srcid: u32, maskid: u32, r_in: Rect, sp_in: Point, mp_in: Point) Error!void {
        _ = mp_in; // mask is opaque-equivalent below ⇒ its geometry never bites.
        const dst = try self.dstSurface(dstid);
        const src = try self.view(srcid);
        const mask = try self.view(maskid);

        // Mask must be the opaque substitute: 1×1 repl filled all-ones (G4;
        // boolcopyfn draw.c:1952). Anything else is out of Phase-2 scope.
        if (!(mask.repl and mask.r.is1x1() and mask.fill == 0xFFFFFFFF)) return Error.Unsupported;

        // Clip r to dst.r ∩ dst.clipr, dragging the source point along by the same
        // min shift (drawclip, draw.c:236-245). Empty ⇒ successful no-op.
        var r = r_in;
        var sp = sp_in;
        const rmin = r.min;
        if (!r.clip(dst.r)) return;
        if (!r.clip(dst.clipr)) return;
        sp.x += r.min.x - rmin.x;
        sp.y += r.min.y - rmin.y;

        if (src.repl and src.r.is1x1()) {
            // Case A — solid fill; sp irrelevant (drawreplxy, draw.c:292-298).
            fillRect(dst, r, src.fill);
        } else if (!src.repl and src.pixels != null) {
            // Case B — non-repl copy. Map r into source (sr), clip sr to src.r ∩
            // src.clipr, then reflect the shrink back into r (draw.c:246-290).
            var sr = Rect.init(sp.x, sp.y, sp.x + r.dx(), sp.y + r.dy());
            if (!sr.clip(src.r)) return;
            if (!sr.clip(src.clipr)) return;
            const delta = Point{ .x = r.min.x - sp.x, .y = r.min.y - sp.y };
            r = sr.translate(delta);
            copyRect(dst, r, src, delta);
        } else {
            // Case C — replicated tiles, image masks, etc.: not in Phase 2.
            return Error.Unsupported;
        }

        if (dstid == display_id) self.markDirty(r);
    }

    fn markDirty(self: *Self, r: Rect) void {
        if (self.dirty) |d| {
            self.dirty = Rect.init(
                @min(d.min.x, r.min.x),
                @min(d.min.y, r.min.y),
                @max(d.max.x, r.max.x),
                @max(d.max.y, r.max.y),
            );
        } else self.dirty = r;
    }

    fn flushImpl(self: *Self) void {
        self.dirty = null;
        self.flush_count += 1;
    }

    fn displayInfoImpl(self: *Self) DisplayInfo {
        return .{ .chan = XRGB32, .r = self.bounds(), .clipr = self.bounds() };
    }

    // ---- vtable trampolines ----

    fn ctxCast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
    fn vAlloc(ctx: *anyopaque, id: u32, r: Rect, chan: u32, repl: bool, clipr: Rect, color: u32) Error!void {
        return ctxCast(ctx).allocImageImpl(id, r, chan, repl, clipr, color);
    }
    fn vFree(ctx: *anyopaque, id: u32) Error!void {
        return ctxCast(ctx).freeImageImpl(id);
    }
    fn vDraw(ctx: *anyopaque, dst: u32, src: u32, mask: u32, r: Rect, sp: Point, mp: Point) Error!void {
        return ctxCast(ctx).drawImpl(dst, src, mask, r, sp, mp);
    }
    fn vFlush(ctx: *anyopaque) void {
        ctxCast(ctx).flushImpl();
    }
    fn vDisplayInfo(ctx: *anyopaque) DisplayInfo {
        return ctxCast(ctx).displayInfoImpl();
    }

    const vtable: Backend.VTable = .{
        .allocImage = vAlloc,
        .freeImage = vFree,
        .draw = vDraw,
        .flush = vFlush,
        .displayInfo = vDisplayInfo,
    };
};

// ===================================================================
// Tests. Fixture is 64×48 RGBA8888. Frozen hashes follow R-P2-7: pixel
// spot-checks are authoritative and were verified first; the Wyhash literal
// is frozen only after they passed, with a scene comment, and must never be
// re-frozen alongside a render change without orchestrator re-verification.
// ===================================================================

const testing = std.testing;

const FIX_W: u32 = 64;
const FIX_H: u32 = 48;

// Packed 0xRRGGBBAA, alpha-premultiplied (G2).
const RED: u32 = 0xFF0000FF;
const BLUE: u32 = 0x0000FFFF;
const WHITE: u32 = 0xFFFFFFFF;
const HALF_RED: u32 = 0x7F00007F; // 50%-alpha premultiplied red

const unit = Rect.init(0, 0, 1, 1);

/// Allocate a 1×1 repl solid (source/mask) with id `id` and fill `color`.
fn allocSolid(be: Backend, id: u32, color: u32, chan: u32) !void {
    try be.allocImage(id, unit, chan, true, unit, color);
}

/// The opaque mask libdraw substitutes for a nil mask: 1×1 repl GREY1 all-ones.
fn allocWhiteMask(be: Backend, id: u32) !void {
    try allocSolid(be, id, WHITE, GREY1);
}

test "headless: fill full display red" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 2, RED, RGBA32);
    try be.draw(display_id, 2, 1, hb.bounds(), .{}, .{});

    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(FIX_W - 1, FIX_H - 1));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(32, 24));
    // Every pixel identical ⇒ dirty covers the whole display.
    try testing.expect(hb.dirty != null);
    try testing.expectEqual(@as(i32, 0), hb.dirty.?.min.x);
    try testing.expectEqual(@as(i32, @intCast(FIX_W)), hb.dirty.?.max.x);
}

test "headless: fill sub-rect — spot checks + frozen hash" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 2, RED, RGBA32);
    // Scene: zeroed fb, opaque red into (10,10)-(30,25).
    try be.draw(display_id, 2, 1, Rect.init(10, 10, 30, 25), .{}, .{});

    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(10, 10)); // inside, top-left
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(29, 24)); // inside, bot-right
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(9, 10)); // just left, untouched
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(30, 24)); // just right, untouched
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(0, 0)); // corner, untouched

    // FROZEN-A — scene: 64×48 zeroed fb, opaque red 0xFF0000FF into (10,10)-(30,25).
    try testing.expectEqual(@as(u64, 0xfe503a5e74e711df), hb.hash());
}

test "headless: overlapping second fill — frozen hash" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 2, RED, RGBA32);
    try allocSolid(be, 3, BLUE, RGBA32);
    // Scene: red (10,10)-(30,25) then opaque blue (20,15)-(40,30) overlapping it.
    try be.draw(display_id, 2, 1, Rect.init(10, 10, 30, 25), .{}, .{});
    try be.draw(display_id, 3, 1, Rect.init(20, 15, 40, 30), .{}, .{});

    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(10, 10)); // red only
    try testing.expectEqual(@as(u32, 0x0000FFFF), hb.pixelAt(25, 20)); // overlap ⇒ blue on top
    try testing.expectEqual(@as(u32, 0x0000FFFF), hb.pixelAt(39, 29)); // blue only

    // FROZEN-B — scene: FROZEN-A then opaque blue 0x0000FFFF into (20,15)-(40,30).
    try testing.expectEqual(@as(u64, 0x1963cfd1efb1dcf7), hb.hash());
}

test "headless: repl solid ignores sp" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 2, RED, RGBA32);
    // A wild source point must not shift a 1×1 repl solid fill (Case A).
    try be.draw(display_id, 2, 1, Rect.init(5, 5, 15, 15), .{ .x = 999, .y = -999 }, .{});

    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(5, 5));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(14, 14));
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(15, 15));
}

test "headless: clip to display and clipr" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 2, RED, RGBA32);

    // (a) A rect straddling the display edges is clipped to the display; no OOB write.
    try be.draw(display_id, 2, 1, Rect.init(-10, -10, 100, 100), .{}, .{});
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(FIX_W - 1, FIX_H - 1));
    try testing.expectEqual(Rect.init(0, 0, @intCast(FIX_W), @intCast(FIX_H)), hb.dirty.?);

    // (b) dst.clipr narrower than dst.r: an off-display XRGB image with clipr
    //     (10,10)-(20,20). A full-image fill only paints inside clipr.
    try be.allocImage(4, Rect.init(0, 0, 32, 32), XRGB32, false, Rect.init(10, 10, 20, 20), 0x00000000);
    try be.draw(4, 2, 1, Rect.init(0, 0, 32, 32), .{}, .{});
    const img = hb.images.get(4).?;
    const px = img.pixels.?;
    const at = struct {
        fn f(buf: []const u8, w: usize, x: usize, y: usize) u32 {
            const i = (y * w + x) * 4;
            return (@as(u32, buf[i]) << 24) | (@as(u32, buf[i + 1]) << 16) |
                (@as(u32, buf[i + 2]) << 8) | @as(u32, buf[i + 3]);
        }
    }.f;
    try testing.expectEqual(@as(u32, 0xFF0000FF), at(px, 32, 10, 10)); // inside clipr
    try testing.expectEqual(@as(u32, 0xFF0000FF), at(px, 32, 19, 19)); // inside clipr
    try testing.expectEqual(@as(u32, 0x000000FF), at(px, 32, 9, 9)); // outside clipr: init (A forced FF)
    try testing.expectEqual(@as(u32, 0x000000FF), at(px, 32, 20, 20)); // outside clipr
}

test "headless: non-repl copy with source clipping" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    // Source: a 16×16 non-repl green (opaque) image at origin, clipr = full.
    try be.allocImage(5, Rect.init(0, 0, 16, 16), RGBA32, false, Rect.init(0, 0, 16, 16), 0x00FF00FF);

    // Ask to copy a 16×16 block onto the display starting at (4,4) but reading
    // from source point (8,8): source only has (8,8)-(16,16) ⇒ an 8×8 result,
    // reflected back to display (4,4)-(12,12).
    try be.draw(display_id, 5, 1, Rect.init(4, 4, 20, 20), .{ .x = 8, .y = 8 }, .{});

    try testing.expectEqual(@as(u32, 0x00FF00FF), hb.pixelAt(4, 4)); // painted
    try testing.expectEqual(@as(u32, 0x00FF00FF), hb.pixelAt(11, 11)); // last painted
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(12, 12)); // beyond shrunk rect
    try testing.expectEqual(Rect.init(4, 4, 12, 12), hb.dirty.?);
}

test "headless: SoverD translucent fill" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 2, WHITE, RGBA32);
    try allocSolid(be, 3, HALF_RED, RGBA32);

    // White ground, then 50%-alpha premultiplied red 0x7F00007F over it.
    // Hand derivation (the reason this test exists): fd = 255-0x7F = 128.
    //   CALC11(128,255) = (t=128*255+128=32768; (32768 + (32768>>8))>>8) = 128.
    //   out_R = 0x7F + 128 = 255 = 0xFF; out_G = 0 + 128 = 0x80; out_B = 0x80;
    //   out_A = 0x7F + 128 = 255 = 0xFF  ⇒  0xFF8080FF.
    try be.draw(display_id, 2, 1, hb.bounds(), .{}, .{});
    try be.draw(display_id, 3, 1, Rect.init(0, 0, 10, 10), .{}, .{});

    try testing.expectEqual(@as(u32, 0xFF8080FF), hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0xFF8080FF), hb.pixelAt(9, 9));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(10, 10)); // still white
}

test "headless: alloc/free lifecycle errors" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocSolid(be, 2, RED, RGBA32);
    try testing.expectError(Error.ImageExists, allocSolid(be, 2, RED, RGBA32)); // dup id
    try testing.expectError(Error.ImageExists, allocSolid(be, display_id, RED, RGBA32)); // id 0 = display
    try testing.expectError(Error.BadChan, allocSolid(be, 3, RED, 0xDEAD)); // bad chan
    try testing.expectError(Error.BadRect, be.allocImage(4, Rect.init(0, 0, 0, 5), RGBA32, false, unit, RED));

    try testing.expectError(Error.UnknownImage, be.freeImage(999)); // never allocated
    try testing.expectError(Error.Unsupported, be.freeImage(display_id)); // can't free display
    try be.freeImage(2); // ok
    try testing.expectError(Error.UnknownImage, be.freeImage(2)); // gone now

    // draw referencing a missing id ⇒ UnknownImage.
    try allocWhiteMask(be, 1);
    try testing.expectError(Error.UnknownImage, be.draw(display_id, 77, 1, unit, .{}, .{}));
}

test "headless: ppm dump shape" {
    var hb = try HeadlessBackend.init(testing.allocator, 4, 3);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 2, RED, RGBA32);
    try be.draw(display_id, 2, 1, hb.bounds(), .{}, .{});

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try hb.writePpm(&w);
    const out = w.buffered();

    const header = "P6\n4 3\n255\n";
    try testing.expect(std.mem.startsWith(u8, out, header));
    // 4*3 pixels * 3 bytes (RGB) of body after the header.
    try testing.expectEqual(header.len + 4 * 3 * 3, out.len);
    // First pixel's RGB is red.
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x00 }, out[header.len..][0..3]);
}
