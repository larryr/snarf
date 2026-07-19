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
    /// 'y' load whose rect is not contained in the image (devdraw.c:2094).
    WriteOutside,
    /// 'y' payload shorter than `Dy*bytesperline` (load.c:14-16).
    ShortData,
};

pub const DisplayInfo = struct { chan: u32, r: Rect, clipr: Rect };

/// Read-only introspection for the 's' verb's clipr save/restore and for id
/// validation (devdraw.c:1960-1962).
pub const ImageInfo = struct { chan: u32, r: Rect, clipr: Rect, repl: bool };

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
        /// 'y': raw pixel upload into `id`'s rectangle `r`. `r ⊄ image.r` ⇒
        /// WriteOutside (devdraw.c:2094); `data.len < Dy*bpl` ⇒ ShortData
        /// (load.c:14-16). Returns bytes CONSUMED (`Dy*bpl`) so the verb loop
        /// advances past the payload; trailing bytes belong to the next verb.
        loadPixels: *const fn (ctx: *anyopaque, id: u32, r: Rect, data: []const u8) Error!usize,
        /// op-S straight copy (bytes stored verbatim incl. alpha; a non-alpha
        /// dst forces A=0xFF). Used by 'l' (devdraw.c:1705). Case-B clip
        /// geometry. `dst == src` ⇒ Unsupported.
        copy: *const fn (ctx: *anyopaque, dst: u32, src: u32, r: Rect, sp: Point) Error!void,
        /// Replace an image's clipr (assignment, NOT intersection —
        /// devdraw.c:1976). id 0 sets the display's clipr.
        setClipr: *const fn (ctx: *anyopaque, id: u32, clipr: Rect) Error!void,
        /// Introspection for 's' (save/restore clipr; validate ids).
        imageInfo: *const fn (ctx: *anyopaque, id: u32) Error!ImageInfo,
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
    pub fn loadPixels(self: Backend, id: u32, r: Rect, data: []const u8) Error!usize {
        return self.vtable.loadPixels(self.ctx, id, r, data);
    }
    pub fn copy(self: Backend, dst: u32, src: u32, r: Rect, sp: Point) Error!void {
        return self.vtable.copy(self.ctx, dst, src, r, sp);
    }
    pub fn setClipr(self: Backend, id: u32, clipr: Rect) Error!void {
        return self.vtable.setClipr(self.ctx, id, clipr);
    }
    pub fn imageInfo(self: Backend, id: u32) Error!ImageInfo {
        return self.vtable.imageInfo(self.ctx, id);
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

/// `CALC12(a1,v1,a2,v2) = (t=a1*v1+a2*v2+128; (t+(t>>8))>>8)` — draw.c:23-24. ONE
/// combined rounding over the two weighted terms; not two CALC11s summed (G14).
fn calc12(a1: u32, v1: u32, a2: u32, v2: u32) u32 {
    const t = a1 * v1 + a2 * v2 + 128;
    return (t + (t >> 8)) >> 8;
}

/// NTSC luma `RGB2K(r,g,b) = (156763·r + 307758·g + 59769·b) >> 19` — draw.c:10.
/// `RGB2K(k,k,k) == k` exactly, so grey pixels relabel cleanly as alpha (G15).
fn rgb2k(r: u8, g: u8, b: u8) u8 {
    return @intCast((156763 * @as(u32, r) + 307758 * @as(u32, g) + 59769 * @as(u32, b)) >> 19);
}

/// Mask alpha (G15): an alpha channel supplies alpha directly (draw.c:697-699);
/// otherwise the grey value is relabeled as alpha (greymaskread draw.c:1307-1315).
/// Deviation (R-P3-6 §1, accepted): a buffered GREY image 'b'-filled with a
/// COLORED value stores rgb verbatim rather than pre-converting to grey; ma still
/// matches the kernel because RGB2K is applied here, at read time.
fn maskAlpha(chan: u32, p: Rgba) u8 {
    return if (chanHasAlpha(chan)) p.a else rgb2k(p.r, p.g, p.b);
}

/// Bits per pixel for a channel (draw.h): GREY1⇒1, GREY8⇒8, RGB24⇒24, {RGBA,XRGB}32⇒32.
fn chanDepth(chan: u32) u32 {
    return switch (chan) {
        GREY1 => 1,
        GREY8 => 8,
        RGB24 => 24,
        RGBA32, XRGB32 => 32,
        else => unreachable,
    };
}

/// Byte-aligned, absolute-x-anchored row stride (G11; libdraw/bytesperline.c:5-34).
/// NOT `ceil(Dx·d/8)`: the min.x<0 branch counts the two byte-runs separately.
fn bytesPerLine(r: Rect, depth: u32) usize {
    const d: i64 = @intCast(depth);
    if (r.min.x >= 0) {
        const l = @divTrunc(@as(i64, r.max.x) * d + 7, 8) - @divTrunc(@as(i64, r.min.x) * d, 8);
        return @intCast(l);
    }
    const t = @divTrunc(-@as(i64, r.min.x) * d + 7, 8);
    return @intCast(t + @divTrunc(@as(i64, r.max.x) * d + 7, 8));
}

/// Absolute bit index (from the row's leading byte) of pixel column x=min.x. The
/// negative-min row lays its byte-run so that column x=0 is a byte boundary.
fn bitBaseFor(minx: i32, depth: u32) i32 {
    const d: i32 = @intCast(depth);
    if (minx >= 0) return @divTrunc(minx * d, 8) * 8;
    const nb = @divTrunc(-minx * d + 7, 8);
    return -(nb * 8);
}

/// Decode one wire pixel at absolute column `x` from a row's bytes into RGBA
/// storage `[r,g,b,a]`. Sub-byte: HIGH bit is leftmost (G12). Byte order is
/// low-chan-byte-first (G13). Non-alpha channels store A=0xFF.
fn readWirePixel(chan: u32, r: Rect, rowbytes: []const u8, x: i32) Rgba {
    const d = chanDepth(chan);
    const bit: i32 = x * @as(i32, @intCast(d)) - bitBaseFor(r.min.x, d);
    const off: usize = @intCast(@divTrunc(bit, 8));
    if (d == 1) {
        const sh: u3 = @intCast(7 - @mod(bit, 8));
        const k: u8 = if ((rowbytes[off] >> sh) & 1 != 0) 0xFF else 0x00;
        return .{ .r = k, .g = k, .b = k, .a = 0xFF };
    }
    const pb = rowbytes[off..];
    return switch (chan) {
        GREY8 => .{ .r = pb[0], .g = pb[0], .b = pb[0], .a = 0xFF },
        RGB24, XRGB32 => .{ .r = pb[2], .g = pb[1], .b = pb[0], .a = 0xFF },
        RGBA32 => .{ .r = pb[3], .g = pb[2], .b = pb[1], .a = pb[0] },
        else => unreachable,
    };
}

/// Pack an RGBA quad into the storage word `0xRRGGBBAA`.
fn pack(p: Rgba) u32 {
    return (@as(u32, p.r) << 24) | (@as(u32, p.g) << 16) | (@as(u32, p.b) << 8) | @as(u32, p.a);
}

fn rectInRect(a: Rect, b: Rect) bool {
    return a.min.x >= b.min.x and a.min.y >= b.min.y and
        a.max.x <= b.max.x and a.max.y <= b.max.y;
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
const View = struct { pixels: ?[]const u8, r: Rect, clipr: Rect, repl: bool, fill: u32, chan: u32 };

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

/// General SoverD-with-mask per-pixel blend (G14; alphacalc11 draw.c:1022-1071).
/// `ma` is the mask alpha (0<ma<255 here; the 0 and 255 cases are handled by the
/// caller — ma==0 is a no-op, ma==255 takes the phase-2 `composite` fast path).
fn blend(dst: Dst, x: i32, y: i32, s: Rgba, ma: u32) void {
    const w: usize = @intCast(dst.r.dx());
    const col: usize = @intCast(x - dst.r.min.x);
    const row: usize = @intCast(y - dst.r.min.y);
    const p = dst.pixels[(row * w + col) * 4 ..][0..4];
    const sa: u32 = s.a;
    const fd: u32 = 255 - calc11(sa, ma); // draw.c:1037
    p[0] = @intCast(@min(255, calc12(ma, s.r, fd, p[0])));
    p[1] = @intCast(@min(255, calc12(ma, s.g, fd, p[1])));
    p[2] = @intCast(@min(255, calc12(ma, s.b, fd, p[2])));
    p[3] = @intCast(@min(255, calc12(ma, sa, fd, p[3])));
    if (!chanHasAlpha(dst.chan)) p[3] = 0xFF; // draw.c:1063
}

/// op-S straight store of `src` (through `delta`) into `dst`'s rectangle `r`.
/// Bytes copied verbatim (no SoverD); a non-alpha dst keeps A=0xFF.
fn storeRect(dst: Dst, r: Rect, src: View, delta: Point) void {
    const dw: usize = @intCast(dst.r.dx());
    const sw: usize = @intCast(src.r.dx());
    const buf = src.pixels.?;
    var y = r.min.y;
    while (y < r.max.y) : (y += 1) {
        var x = r.min.x;
        while (x < r.max.x) : (x += 1) {
            const scol: usize = @intCast(x - delta.x - src.r.min.x);
            const srow: usize = @intCast(y - delta.y - src.r.min.y);
            const sp = buf[(srow * sw + scol) * 4 ..][0..4];
            const dcol: usize = @intCast(x - dst.r.min.x);
            const drow: usize = @intCast(y - dst.r.min.y);
            const dp = dst.pixels[(drow * dw + dcol) * 4 ..][0..4];
            dp.* = sp.*;
            if (!chanHasAlpha(dst.chan)) dp[3] = 0xFF;
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
    /// The display's clip rectangle (id 0). Assignable via `setClipr(0,·)`; the
    /// 's' verb save/restores it around a string op (devdraw.c:1976). Init = bounds.
    display_clipr: Rect = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Error!Self {
        const fb = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
        @memset(fb, 0);
        const b = Rect.init(0, 0, @intCast(width), @intCast(height));
        return .{ .allocator = allocator, .width = width, .height = height, .fb = fb, .display_clipr = b };
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
            return .{ .pixels = self.fb, .r = self.bounds(), .clipr = self.display_clipr, .chan = XRGB32 };
        const img = self.images.getPtr(id) orelse return Error.UnknownImage;
        const px = img.pixels orelse return Error.Unsupported; // can't paint onto a solid
        return .{ .pixels = px, .r = img.r, .clipr = img.clipr, .chan = img.chan };
    }

    fn view(self: *Self, id: u32) Error!View {
        if (id == display_id)
            return .{ .pixels = self.fb, .r = self.bounds(), .clipr = self.display_clipr, .repl = false, .fill = 0, .chan = XRGB32 };
        const img = self.images.get(id) orelse return Error.UnknownImage;
        return .{ .pixels = img.pixels, .r = img.r, .clipr = img.clipr, .repl = img.repl, .fill = img.fill, .chan = img.chan };
    }

    /// SoverD `src` through `mask` into `dst`'s `r` (drawclip draw.c:226-306 +
    /// alphacalc11 draw.c:1022-1071). Generalized from phase 2: real non-repl
    /// masks with per-pixel alpha, and both `sp` and `mp` tracked through every
    /// clip (G16). The ma==255 pixels still take the phase-2 `composite` path
    /// verbatim, so all phase-2 frozen hashes are preserved by construction.
    fn drawImpl(self: *Self, dstid: u32, srcid: u32, maskid: u32, r_in: Rect, sp_in: Point, mp_in: Point) Error!void {
        const dst = try self.dstSurface(dstid);
        const src = try self.view(srcid);
        const mask = try self.view(maskid);

        // Step 1 — clip r to dst.r ∩ dst.clipr, dragging BOTH sp and mp along by
        // the min shift (drawclip draw.c:236-245). Empty ⇒ successful no-op.
        var r = r_in;
        var sp = sp_in;
        var mp = mp_in;
        const rmin = r.min;
        if (!r.clip(dst.r)) return;
        if (!r.clip(dst.clipr)) return;
        sp.x += r.min.x - rmin.x;
        sp.y += r.min.y - rmin.y;
        mp.x += r.min.x - rmin.x;
        mp.y += r.min.y - rmin.y;

        // Step 2 — source geometry. Case A: 1×1 repl solid (constant fill; sp
        // irrelevant). Case B: non-repl buffer (map r into src, clip, reflect the
        // shrink back into r, and slide mp with the source min). Repl non-1×1 ⇒ Unsupported.
        const src_solid = src.repl and src.r.is1x1();
        if (!src_solid) {
            if (src.repl or src.pixels == null) return Error.Unsupported;
            var sr = Rect.init(sp.x, sp.y, sp.x + r.dx(), sp.y + r.dy());
            if (!sr.clip(src.r)) return;
            if (!sr.clip(src.clipr)) return;
            const ds = Point{ .x = sr.min.x - sp.x, .y = sr.min.y - sp.y };
            r = Rect.init(r.min.x + ds.x, r.min.y + ds.y, r.min.x + ds.x + sr.dx(), r.min.y + ds.y + sr.dy());
            sp = sr.min;
            mp.x += ds.x;
            mp.y += ds.y;
        }

        // Step 3 — mask geometry. (a) 1×1 repl solid ⇒ constant ma. (b) non-repl
        // buffer ⇒ clip mr=(mp,mp+Δr) to mask.r ∩ mask.clipr and reflect the shrink
        // back into r (and sp), mp=mr.min. (c) repl non-solid ⇒ Unsupported.
        const mask_solid = mask.repl and mask.r.is1x1();
        var const_ma: u32 = 0;
        if (mask_solid) {
            const_ma = maskAlpha(mask.chan, unpack(mask.fill));
        } else {
            if (mask.repl or mask.pixels == null) return Error.Unsupported;
            var mr = Rect.init(mp.x, mp.y, mp.x + r.dx(), mp.y + r.dy());
            if (!mr.clip(mask.r)) return;
            if (!mr.clip(mask.clipr)) return;
            const dm = Point{ .x = mr.min.x - mp.x, .y = mr.min.y - mp.y };
            r = Rect.init(r.min.x + dm.x, r.min.y + dm.y, r.min.x + dm.x + mr.dx(), r.min.y + dm.y + mr.dy());
            sp.x += dm.x;
            sp.y += dm.y;
            mp = mr.min;
        }

        // Step 4 — composite. srcCoord=(x,y)−r.min+sp, maskCoord=(x,y)−r.min+mp.
        const src_fill = unpack(src.fill);
        const sw: usize = if (src_solid) 0 else @intCast(src.r.dx());
        const mw: usize = if (mask_solid) 0 else @intCast(mask.r.dx());
        var y = r.min.y;
        while (y < r.max.y) : (y += 1) {
            var x = r.min.x;
            while (x < r.max.x) : (x += 1) {
                const ma: u32 = if (mask_solid) const_ma else blk: {
                    const mx: usize = @intCast(x - r.min.x + mp.x - mask.r.min.x);
                    const my: usize = @intCast(y - r.min.y + mp.y - mask.r.min.y);
                    const q = mask.pixels.?[(my * mw + mx) * 4 ..][0..4];
                    break :blk maskAlpha(mask.chan, .{ .r = q[0], .g = q[1], .b = q[2], .a = q[3] });
                };
                if (ma == 0) continue; // CALC12(0,s,255,d)=d — true no-op (G15)
                const s: Rgba = if (src_solid) src_fill else blk: {
                    const scol: usize = @intCast(x - r.min.x + sp.x - src.r.min.x);
                    const srow: usize = @intCast(y - r.min.y + sp.y - src.r.min.y);
                    const q = src.pixels.?[(srow * sw + scol) * 4 ..][0..4];
                    break :blk .{ .r = q[0], .g = q[1], .b = q[2], .a = q[3] };
                };
                if (ma == 255) composite(dst, x, y, s) else blend(dst, x, y, s, ma);
            }
        }

        if (dstid == display_id) self.markDirty(r);
    }

    /// 'y' raw pixel upload (devdraw.c:2082-2101; load.c:12-41). Decodes the
    /// wire payload into RGBA storage; returns bytes CONSUMED so the verb loop
    /// can advance. Trailing bytes belong to the next verb.
    fn loadPixelsImpl(self: *Self, id: u32, r: Rect, data: []const u8) Error!usize {
        var buf: []u8 = undefined;
        var img_r: Rect = undefined;
        var chan: u32 = undefined;
        var solid: ?*Image = null;
        if (id == display_id) {
            img_r = self.bounds();
            chan = XRGB32;
            buf = self.fb;
        } else {
            const img = self.images.getPtr(id) orelse return Error.UnknownImage;
            img_r = img.r;
            chan = img.chan;
            if (img.pixels) |px| buf = px else solid = img; // 1×1 repl solid has no buffer
        }
        if (!rectInRect(r, img_r)) return Error.WriteOutside;
        const depth = chanDepth(chan);
        const bpl = bytesPerLine(r, depth);
        const need = bpl * @as(usize, @intCast(r.dy()));
        if (data.len < need) return Error.ShortData;

        if (solid) |img| {
            // Its storage IS the fill word — decode the one pixel and update it.
            img.fill = pack(readWirePixel(chan, r, data[0..bpl], r.min.x));
            return need;
        }

        const w: usize = @intCast(img_r.dx());
        var row: usize = 0;
        var y = r.min.y;
        while (y < r.max.y) : ({
            y += 1;
            row += 1;
        }) {
            const rb = data[row * bpl ..][0..bpl];
            var x = r.min.x;
            while (x < r.max.x) : (x += 1) {
                const px = readWirePixel(chan, r, rb, x);
                const col: usize = @intCast(x - img_r.min.x);
                const rr: usize = @intCast(y - img_r.min.y);
                const p = buf[(rr * w + col) * 4 ..][0..4];
                p.* = .{ px.r, px.g, px.b, px.a };
            }
        }
        if (id == display_id) self.markDirty(r);
        return need;
    }

    /// op-S straight copy, Case-B clip geometry (devdraw.c:1705). `dst == src`
    /// ⇒ Unsupported; solid sources are out of scope for 'l'.
    fn copyImpl(self: *Self, dstid: u32, srcid: u32, r_in: Rect, sp_in: Point) Error!void {
        if (dstid == srcid) return Error.Unsupported;
        const dst = try self.dstSurface(dstid);
        const src = try self.view(srcid);
        if (src.pixels == null or src.repl) return Error.Unsupported;

        var r = r_in;
        var sp = sp_in;
        const rmin = r.min;
        if (!r.clip(dst.r)) return;
        if (!r.clip(dst.clipr)) return;
        sp.x += r.min.x - rmin.x;
        sp.y += r.min.y - rmin.y;

        var sr = Rect.init(sp.x, sp.y, sp.x + r.dx(), sp.y + r.dy());
        if (!sr.clip(src.r)) return;
        if (!sr.clip(src.clipr)) return;
        const delta = Point{ .x = r.min.x - sp.x, .y = r.min.y - sp.y };
        r = sr.translate(delta);
        storeRect(dst, r, src, delta);
        if (dstid == display_id) self.markDirty(r);
    }

    fn setCliprImpl(self: *Self, id: u32, clipr: Rect) Error!void {
        if (id == display_id) {
            self.display_clipr = clipr;
            return;
        }
        const img = self.images.getPtr(id) orelse return Error.UnknownImage;
        img.clipr = clipr; // assignment, NOT intersection (devdraw.c:1976)
    }

    fn imageInfoImpl(self: *Self, id: u32) Error!ImageInfo {
        if (id == display_id)
            return .{ .chan = XRGB32, .r = self.bounds(), .clipr = self.display_clipr, .repl = false };
        const img = self.images.get(id) orelse return Error.UnknownImage;
        return .{ .chan = img.chan, .r = img.r, .clipr = img.clipr, .repl = img.repl };
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
    fn vLoadPixels(ctx: *anyopaque, id: u32, r: Rect, data: []const u8) Error!usize {
        return ctxCast(ctx).loadPixelsImpl(id, r, data);
    }
    fn vCopy(ctx: *anyopaque, dst: u32, src: u32, r: Rect, sp: Point) Error!void {
        return ctxCast(ctx).copyImpl(dst, src, r, sp);
    }
    fn vSetClipr(ctx: *anyopaque, id: u32, clipr: Rect) Error!void {
        return ctxCast(ctx).setCliprImpl(id, clipr);
    }
    fn vImageInfo(ctx: *anyopaque, id: u32) Error!ImageInfo {
        return ctxCast(ctx).imageInfoImpl(id);
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

// ===================================================================
// Phase-3 tests (device §4, tests 1-10). Fixture 64×48. All pixel
// expectations are hand-derived from G14/G15 (CALC12/RGB2K) in comments;
// no new frozen hashes (R-P3-6: phase-2 hashes above are untouched).
// ===================================================================

/// Read packed 0xRRGGBBAA at (x,y) from buffered image `id`'s raster.
fn imgPixel(hb: *HeadlessBackend, id: u32, x: i32, y: i32) u32 {
    const img = hb.images.get(id).?;
    const w: usize = @intCast(img.r.dx());
    const col: usize = @intCast(x - img.r.min.x);
    const row: usize = @intCast(y - img.r.min.y);
    const i = (row * w + col) * 4;
    const b = img.pixels.?;
    return (@as(u32, b[i]) << 24) | (@as(u32, b[i + 1]) << 16) |
        (@as(u32, b[i + 2]) << 8) | @as(u32, b[i + 3]);
}

test "headless: GREY8 gradient mask blend" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 2, RED, RGBA32); // src RED (sa=255)
    try allocSolid(be, 5, WHITE, RGBA32);
    // White ground over the 4-pixel strip, then RED through a GREY8 gradient mask.
    try be.draw(display_id, 5, 1, Rect.init(0, 0, 4, 1), .{}, .{});
    try be.allocImage(3, Rect.init(0, 0, 4, 1), GREY8, false, Rect.init(0, 0, 4, 1), 0);
    try testing.expectEqual(@as(usize, 4), try be.loadPixels(3, Rect.init(0, 0, 4, 1), &[_]u8{ 0x00, 0x40, 0x80, 0xFF }));
    try be.draw(display_id, 2, 3, Rect.init(0, 0, 4, 1), .{}, .{});

    // ma=0x00 ⇒ no-op ⇒ white. ma=0x40: fd=255-CALC11(255,64)=255-64=191;
    //   R=CALC12(64,255,191,255)=255, G=B=CALC12(64,0,191,255)=191 ⇒ 0xFFBFBFFF.
    // ma=0x80: fd=127; G=B=CALC12(128,0,127,255)=127 ⇒ 0xFF7F7FFF.
    // ma=0xFF ⇒ opaque store ⇒ 0xFF0000FF.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0xFFBFBFFF), hb.pixelAt(1, 0));
    try testing.expectEqual(@as(u32, 0xFF7F7FFF), hb.pixelAt(2, 0));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(3, 0));
}

test "headless: GREY1 mask bit order" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocSolid(be, 2, RED, RGBA32);
    // One byte 0b10100000: HIGH bit leftmost (G12) ⇒ pixels x=0 and x=2 set.
    try be.allocImage(3, Rect.init(0, 0, 8, 1), GREY1, false, Rect.init(0, 0, 8, 1), 0);
    try testing.expectEqual(@as(usize, 1), try be.loadPixels(3, Rect.init(0, 0, 8, 1), &[_]u8{0b10100000}));
    try be.draw(display_id, 2, 3, Rect.init(0, 0, 8, 1), .{}, .{});

    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(0, 0)); // bit 0 set
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(1, 0)); // bit 1 clear
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(2, 0)); // bit 2 set
    var x: u32 = 3;
    while (x < 8) : (x += 1) try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(x, 0));
}

test "headless: general mask formula pin" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 5, WHITE, RGBA32);
    try allocSolid(be, 2, HALF_RED, RGBA32); // src 0x7F00007F (sa=127)
    try allocSolid(be, 6, 0x808080FF, GREY8); // solid grey mask ⇒ ma=RGB2K(128,128,128)=128
    try be.draw(display_id, 5, 1, Rect.init(0, 0, 1, 1), .{}, .{});
    try be.draw(display_id, 2, 6, Rect.init(0, 0, 1, 1), .{}, .{});

    // sa=127, ma=128 ⇒ CALC11(127,128)=64 ⇒ fd=191.
    //   R=CALC12(128,127,191,255)=255=0xFF; G=B=CALC12(128,0,191,255)=191=0xBF;
    //   A=CALC12(128,127,191,255)=255=0xFF  ⇒  EXACTLY 0xFFBFBFFF. Pins CALC12
    //   (one combined rounding, NOT two CALC11s summed).
    try testing.expectEqual(@as(u32, 0xFFBFBFFF), hb.pixelAt(0, 0));
}

test "headless: solid grey mask constant alpha" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocWhiteMask(be, 1);
    try allocSolid(be, 5, WHITE, RGBA32);
    try allocSolid(be, 2, RED, RGBA32);
    try allocSolid(be, 6, 0x808080FF, GREY8); // ma=128

    // (a) RED through the grey-128 mask over white ⇒ 0xFF7F7FFF (as in test 1, ma=0x80).
    try be.draw(display_id, 5, 1, Rect.init(0, 0, 1, 1), .{}, .{});
    try be.draw(display_id, 2, 6, Rect.init(0, 0, 1, 1), .{}, .{});
    try testing.expectEqual(@as(u32, 0xFF7F7FFF), hb.pixelAt(0, 0));

    // (b) a black GREY1 solid mask (RGB2K=0 ⇒ ma=0) is a true no-op: hash unchanged.
    const h = hb.hash();
    try allocSolid(be, 7, 0x000000FF, GREY1);
    try allocSolid(be, 3, BLUE, RGBA32);
    try be.draw(display_id, 3, 7, hb.bounds(), .{}, .{});
    try testing.expectEqual(h, hb.hash());

    // (c) a white GREY1 solid mask (ma=255) takes the phase-2 opaque path exactly.
    try be.draw(display_id, 3, 1, Rect.init(5, 5, 6, 6), .{}, .{});
    try testing.expectEqual(@as(u32, 0x0000FFFF), hb.pixelAt(5, 5));
}

test "headless: loadPixels round-trip" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    // RGBA32 2×2, wire byte order [a,b,g,r] per pixel (G13).
    try be.allocImage(2, Rect.init(0, 0, 2, 2), RGBA32, false, Rect.init(0, 0, 2, 2), 0);
    const rgba = [_]u8{
        0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55, // row 0: 0x11223344, 0x55667788
        0xCC, 0xBB, 0xAA, 0x99, 0x00, 0xFF, 0xEE, 0xDD, // row 1: 0x99AABBCC, 0xDDEEFF00
    };
    try testing.expectEqual(@as(usize, 16), try be.loadPixels(2, Rect.init(0, 0, 2, 2), &rgba));
    try testing.expectEqual(@as(u32, 0x11223344), imgPixel(&hb, 2, 0, 0));
    try testing.expectEqual(@as(u32, 0x55667788), imgPixel(&hb, 2, 1, 0));
    try testing.expectEqual(@as(u32, 0x99AABBCC), imgPixel(&hb, 2, 0, 1));
    try testing.expectEqual(@as(u32, 0xDDEEFF00), imgPixel(&hb, 2, 1, 1));

    // GREY8 2×2: each byte k ⇒ [k,k,k,FF].
    try be.allocImage(3, Rect.init(0, 0, 2, 2), GREY8, false, Rect.init(0, 0, 2, 2), 0);
    try testing.expectEqual(@as(usize, 4), try be.loadPixels(3, Rect.init(0, 0, 2, 2), &[_]u8{ 0x10, 0x20, 0x30, 0x40 }));
    try testing.expectEqual(@as(u32, 0x101010FF), imgPixel(&hb, 3, 0, 0));
    try testing.expectEqual(@as(u32, 0x404040FF), imgPixel(&hb, 3, 1, 1));

    // XRGB32 straight to display id 0 (marks dirty). Wire [b,g,r,x] ⇒ [r,g,b,FF].
    const xrgb = [_]u8{ 0x33, 0x22, 0x11, 0xAA, 0x66, 0x55, 0x44, 0xBB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try testing.expectEqual(@as(usize, 16), try be.loadPixels(display_id, Rect.init(0, 0, 2, 2), &xrgb));
    try testing.expectEqual(@as(u32, 0x112233FF), hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0x445566FF), hb.pixelAt(1, 0));
    try testing.expect(hb.dirty != null);

    // A 1×1 repl solid has no buffer: loadPixels updates its fill word.
    try allocSolid(be, 8, 0x00000000, RGBA32);
    try testing.expectEqual(@as(usize, 4), try be.loadPixels(8, unit, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD }));
    const s8 = hb.images.get(8).?;
    try testing.expectEqual(@as(u32, 0xDDCCBBAA), s8.fill);
    try testing.expect(s8.pixels == null);
}

test "headless: loadPixels bytes-per-line math" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    // GREY1 r=(1,0,3,1): min.x>=0 ⇒ bpl = ceil(3/8)-floor(1/8) = 1. Byte 0b01100000
    // (bits anchored to absolute x) sets x=1,2.
    try be.allocImage(2, Rect.init(1, 0, 3, 1), GREY1, false, Rect.init(1, 0, 3, 1), 0);
    try testing.expectEqual(@as(usize, 1), try be.loadPixels(2, Rect.init(1, 0, 3, 1), &[_]u8{0b01100000}));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), imgPixel(&hb, 2, 1, 0));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), imgPixel(&hb, 2, 2, 0));

    // GREY1 r=(-3,0,2,1): negative-min branch ⇒ bpl = ceil(3/8)+ceil(2/8) = 2.
    try be.allocImage(3, Rect.init(-3, 0, 2, 1), GREY1, false, Rect.init(-3, 0, 2, 1), 0);
    try testing.expectEqual(@as(usize, 2), try be.loadPixels(3, Rect.init(-3, 0, 2, 1), &[_]u8{ 0x00, 0x00 }));

    // GREY8 r=(0,0,3,2): bpl=3, two rows ⇒ 6 bytes.
    try be.allocImage(4, Rect.init(0, 0, 3, 2), GREY8, false, Rect.init(0, 0, 3, 2), 0);
    try testing.expectEqual(@as(usize, 6), try be.loadPixels(4, Rect.init(0, 0, 3, 2), &[_]u8{ 0, 0, 0, 0, 0, 0 }));
}

test "headless: loadPixels errors" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try be.allocImage(2, Rect.init(0, 0, 2, 2), GREY8, false, Rect.init(0, 0, 2, 2), 0);
    // Rect not contained in image ⇒ WriteOutside.
    try testing.expectError(Error.WriteOutside, be.loadPixels(2, Rect.init(0, 0, 3, 3), &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
    // Short payload (need bpl*Dy = 2*2 = 4) ⇒ ShortData.
    try testing.expectError(Error.ShortData, be.loadPixels(2, Rect.init(0, 0, 2, 2), &[_]u8{ 0, 0 }));
    // Extra bytes ⇒ consumes exactly the needed count.
    try testing.expectEqual(@as(usize, 4), try be.loadPixels(2, Rect.init(0, 0, 2, 2), &[_]u8{ 0, 0, 0, 0, 0xFF, 0xFF }));
}

test "headless: copy is a straight store" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    // Source: a 1×1 non-repl translucent red; dst: a 1×1 non-repl white RGBA32.
    try be.allocImage(2, unit, RGBA32, false, unit, 0x7F00007F);
    try be.allocImage(3, unit, RGBA32, false, unit, WHITE);
    try be.copy(3, 2, unit, .{});
    // Straight store keeps the src bytes verbatim (SoverD would blend to pink).
    try testing.expectEqual(@as(u32, 0x7F00007F), imgPixel(&hb, 3, 0, 0));
    // dst == src ⇒ Unsupported.
    try testing.expectError(Error.Unsupported, be.copy(2, 2, unit, .{}));
}

test "headless: mask subrect via mp" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocSolid(be, 2, RED, RGBA32);
    // GREY1 4×1 mask, bits 1010 (byte 0b10100000): cols 0,2 set; 1,3 clear.
    try be.allocImage(3, Rect.init(0, 0, 4, 1), GREY1, false, Rect.init(0, 0, 4, 1), 0);
    _ = try be.loadPixels(3, Rect.init(0, 0, 4, 1), &[_]u8{0b10100000});
    // Draw 4-wide with mp=(2,0): maskCoord=(x+2). mr=(2,0,6,1) clips to mask.r
    // (0,0,4,1) ⇒ (2,0,4,1), so r shrinks to 2 wide and only cols 2,3 gate.
    try be.draw(display_id, 2, 3, Rect.init(0, 0, 4, 1), .{}, .{ .x = 2, .y = 0 });

    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(0, 0)); // mask col 2 = set
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(1, 0)); // mask col 3 = clear
    // cols 2,3 of dst never reached (r shrank) — pins the mp fix (col 2 would be
    // painted if mp were ignored and cols 0..3 gated instead).
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(2, 0));
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(3, 0));
}

test "headless: setClipr and imageInfo" {
    var hb = try HeadlessBackend.init(testing.allocator, FIX_W, FIX_H);
    defer hb.deinit();
    const be = hb.backend();

    try allocSolid(be, 2, RED, RGBA32);
    try allocWhiteMask(be, 1);
    // Narrow the display clipr; a full-display fill now only paints inside it.
    try be.setClipr(display_id, Rect.init(0, 0, 4, 4));
    try be.draw(display_id, 2, 1, hb.bounds(), .{}, .{});
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0xFF0000FF), hb.pixelAt(3, 3));
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(4, 4));
    try testing.expectEqual(@as(u32, 0x00000000), hb.pixelAt(10, 10));

    // imageInfo round-trips; clipr was intersected with r at alloc (non-repl).
    try be.allocImage(5, Rect.init(1, 2, 10, 12), RGBA32, false, Rect.init(1, 2, 8, 9), 0);
    const info = try be.imageInfo(5);
    try testing.expectEqual(RGBA32, info.chan);
    try testing.expectEqual(Rect.init(1, 2, 10, 12), info.r);
    try testing.expectEqual(Rect.init(1, 2, 8, 9), info.clipr);
    try testing.expectEqual(false, info.repl);
    // setClipr is assignment, not intersection.
    try be.setClipr(5, Rect.init(2, 3, 4, 5));
    try testing.expectEqual(Rect.init(2, 3, 4, 5), (try be.imageInfo(5)).clipr);

    // The display's own info reflects the new clipr.
    const info0 = try be.imageInfo(display_id);
    try testing.expectEqual(XRGB32, info0.chan);
    try testing.expectEqual(hb.bounds(), info0.r);
    try testing.expectEqual(Rect.init(0, 0, 4, 4), info0.clipr);

    // Unknown id ⇒ UnknownImage.
    try testing.expectError(Error.UnknownImage, be.imageInfo(999));
}
