//! Bold and oblique copies of a GREY1 subfont strip.
//!
//! The preview needs a heavier face and a slanted face (ADR-0008). The embedded
//! misc-fixed fonts are public domain and have no bold or italic companion, so
//! both are built here from the parsed strip. Edit windows never load the
//! copies. GREY1 only: the leftmost pixel of a byte is its high bit, the same
//! order image(6) stores.
//!
//! Imports: `std` and `Font` (S-07 §6).
const std = @import("std");
const Font = @import("Font.zig");
const proto = @import("proto.zig");

pub const Error = error{ OutOfMemory, NotGrey, TooWide };

/// A one-pixel smear to the right. Advance grows by 1 for every loaded glyph.
pub fn bold(allocator: std.mem.Allocator, src: Font.Subfont) Error!Font.Subfont {
    return transform(allocator, src, .bold);
}

/// A right lean: upper rows shift right by up to `height/4` pixels.
pub fn oblique(allocator: std.mem.Allocator, src: Font.Subfont) Error!Font.Subfont {
    return transform(allocator, src, .oblique);
}

const Kind = enum { bold, oblique };

fn transform(allocator: std.mem.Allocator, src: Font.Subfont, kind: Kind) Error!Font.Subfont {
    const depth = proto.chanDepth(src.chan) orelse return error.NotGrey;
    if (depth != 1) return error.NotGrey;
    if (src.r.min.x != 0 or src.r.min.y != 0) return error.NotGrey;

    const slant: i32 = if (kind == .oblique) @as(i32, src.height) >> 2 else 0;
    const n = src.n;
    var extra_total: i32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (src.info[i].width == 0) continue;
        extra_total += if (kind == .bold) 1 else slant;
    }
    const old_w: i32 = src.r.max.x;
    const new_w: i32 = old_w + extra_total;
    if (new_w <= 0 or new_w > 65535) return error.TooWide;

    const height: i32 = src.height;
    const new_r = proto.Rect.make(0, 0, new_w, height);
    const bpl = proto.bytesPerLine(new_r, 1);
    const bits = try allocator.alloc(u8, bpl * @as(usize, @intCast(height)));
    errdefer allocator.free(bits);
    @memset(bits, 0);

    const info = try allocator.alloc(Font.Fontchar, @as(usize, n) + 1);
    errdefer allocator.free(info);

    const src_bpl = proto.bytesPerLine(src.r, 1);
    var x: i32 = 0;
    i = 0;
    while (i < n) : (i += 1) {
        const fc = src.info[i];
        const x0: i32 = fc.x;
        const x1: i32 = src.info[i + 1].x;
        const cell: i32 = x1 - x0;
        const extra: i32 = if (fc.width == 0) 0 else if (kind == .bold) 1 else slant;
        const new_cell = cell + extra;
        var row: i32 = 0;
        while (row < height) : (row += 1) {
            const shift: i32 = if (kind == .oblique and row < src.ascent)
                (@as(i32, src.ascent) - row) >> 2
            else
                0;
            var col: i32 = 0;
            while (col < new_cell) : (col += 1) {
                const on = switch (kind) {
                    .bold => (col < cell and bit(src.bits, src_bpl, x0 + col, row)) or
                        (col > 0 and col - 1 < cell and bit(src.bits, src_bpl, x0 + col - 1, row)),
                    .oblique => blk: {
                        const sx = x0 + col - shift;
                        if (sx < x0 or sx >= x1) break :blk false;
                        break :blk bit(src.bits, src_bpl, sx, row);
                    },
                };
                if (on) setBit(bits, bpl, x + col, row);
            }
        }
        const adv: u16 = fc.width;
        const new_adv: u16 = adv + @as(u16, @intCast(extra));
        info[i] = .{
            .x = @intCast(x),
            .top = fc.top,
            .bottom = fc.bottom,
            .left = if (kind == .oblique) saturateLeft(fc.left, extra) else fc.left,
            .width = if (new_adv > 255) 255 else @intCast(new_adv),
        };
        x += new_cell;
    }
    info[n] = .{ .x = @intCast(x), .top = 0, .bottom = 0, .left = 0, .width = 0 };

    return .{
        .chan = src.chan,
        .r = proto.Rect.make(0, 0, x, height),
        .n = n,
        .height = src.height,
        .ascent = src.ascent,
        .info = info,
        .bits = bits,
    };
}

fn saturateLeft(left: i8, extra: i32) i8 {
    const v = @as(i32, left) - extra;
    if (v < -128) return -128;
    if (v > 127) return 127;
    return @intCast(v);
}

fn bit(bits: []const u8, bpl: usize, x: i32, y: i32) bool {
    if (x < 0 or y < 0) return false;
    const xi: usize = @intCast(x);
    const yi: usize = @intCast(y);
    const off = yi * bpl + xi / 8;
    if (off >= bits.len) return false;
    const sh: u3 = @intCast(7 - (xi % 8));
    return (bits[off] >> sh) & 1 == 1;
}

fn setBit(bits: []u8, bpl: usize, x: i32, y: i32) void {
    if (x < 0 or y < 0) return;
    const xi: usize = @intCast(x);
    const yi: usize = @intCast(y);
    const off = yi * bpl + xi / 8;
    if (off >= bits.len) return;
    const sh: u3 = @intCast(7 - (xi % 8));
    bits[off] |= @as(u8, 1) << sh;
}

const testing = std.testing;

test "fontsynth: bold widens a loaded glyph by one pixel" {
    var src = try Font.Subfont.parse(testing.allocator, Font.default_subfont);
    defer src.deinit(testing.allocator);
    const a: u8 = 'A';
    const before = src.info[a].width;
    var out = try bold(testing.allocator, src);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(src.height, out.height);
    try testing.expectEqual(src.n, out.n);
    try testing.expectEqual(before + 1, out.info[a].width);
    try testing.expect(out.r.max.x > src.r.max.x);
}

test "fontsynth: oblique keeps the height and widens the advance" {
    var src = try Font.Subfont.parse(testing.allocator, Font.default_subfont);
    defer src.deinit(testing.allocator);
    var out = try oblique(testing.allocator, src);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(src.height, out.height);
    try testing.expect(out.info['A'].width > src.info['A'].width);
}
