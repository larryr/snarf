//! A loaded bitmap font — the libdraw `Font`/`Subfont` pair (font.c, subfont.c),
//! file-as-struct (S-07 P-1): this file *is* the `Font`. A `Font` owns one
//! server-side glyph-cache image plus a host-side copy of the per-glyph metrics
//! (`Fontchar[]`), and draws UTF-8 strings by emitting 's' verbs through its
//! `Display` (ADR-0003; the core never touches a browser API).
//!
//! Phase 3 loads exactly ONE subfont (`image(6)` strip + `font(6)` trailer) with
//! the identity cache layout of R-P3-5: the cache image *is* the strip's rect,
//! and each 'l' names the glyph's strip coordinates verbatim (no repacking), so
//! the device renders bit-identically to libdraw's drawchar (G19). Multi-subfont
//! `.font` files, cache aging/eviction and runes past the subfont are deferred.
//!
//! Pinned C (larryr/plan9@ed1a9c2 unless noted): subfont parse
//! `libdraw/readsubfont.c:5-54`; `_unpackinfo` `libdraw/defont.c:388-402`;
//! image(6) header `libdraw/{readimage.c,creadimage.c}`; the LZ77 block
//! decompressor `libmemdraw/cload.c:6-67`; string emission `libdraw/string.c`;
//! cache build `libdraw/font.c:280-317`.
const std = @import("std");
const proto = @import("proto.zig");
const Display = @import("Display.zig");
const Image = @import("Image.zig");

const Font = @This();

/// One glyph's on-strip metrics (defont.c:388-402 `_unpackinfo`). `x` is the
/// glyph's left edge on the strip; the next Fontchar's `x` closes it. `top`/
/// `bottom` bound the glyph vertically; `left` (SIGNED) is the pen-relative
/// bearing; `width` is the pen advance (0 ⇒ the slot is unloaded).
pub const Fontchar = struct { x: u16, top: u8, bottom: u8, left: i8, width: u8 };

pub const ParseError = error{ BadHeader, BadChan, BadCompression, ShortData, OutOfMemory };

// image(6) LZ77 window/run parameters (draw.h:516-519).
const NMEM: usize = 1024; // sliding-window size
const NMATCH: usize = 3; // shortest copy run
const NCBLOCK: usize = 6000; // largest compressed block

/// A parsed subfont: the decompressed GREY strip plus `n+1` Fontchars.
/// `info[n].x` closes the last glyph. `bits` is `bytesPerLine(r,depth)*Dy(r)`
/// bytes, top row first (image(6) row order, G11/G12).
pub const Subfont = struct {
    chan: proto.Chan,
    r: proto.Rect,
    n: u32,
    height: u8,
    ascent: u8,
    info: []Fontchar,
    bits: []u8,

    /// Parse a subfont file: an `image(6)` (optionally `"compressed\n"`) strip
    /// followed by the `font(6)` trailer (readsubfont.c:5-54; the image is
    /// consumed by readimage/creadimage, then 3×12B n/height/ascent + 6·(n+1)
    /// Fontchar bytes). The caller owns the result — `deinit` frees it.
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!Subfont {
        var cur: usize = 0;

        // image(6) header. "compressed\n" (11B magic; readimage.c:20-23) selects
        // the block-compressed body; otherwise raw rows follow the header.
        const compressed = data.len >= 11 and std.mem.eql(u8, data[0..11], "compressed\n");
        if (compressed) cur = 11;
        if (data.len < cur + 5 * 12) return error.ShortData;
        // Field 0 is the channel descriptor (creadimage.c:34-47). An old
        // single-digit ldepth has no channel letter, so strToChan rejects it.
        const chan = proto.strToChan(cell(data, cur, 0)) orelse return error.BadChan;
        const depth = proto.chanDepth(chan) orelse return error.BadChan;
        const x0 = decCell(data, cur, 1) orelse return error.BadHeader;
        const y0 = decCell(data, cur, 2) orelse return error.BadHeader;
        const x1 = decCell(data, cur, 3) orelse return error.BadHeader;
        const y1 = decCell(data, cur, 4) orelse return error.BadHeader;
        if (x1 < x0 or y1 < y0) return error.BadHeader;
        const r = proto.Rect.make(x0, y0, x1, y1);
        cur += 5 * 12;

        const bpl = proto.bytesPerLine(r, depth);
        const dy: usize = @intCast(y1 - y0);
        const nbits = bpl * dy;

        var bits = try allocator.alloc(u8, nbits);
        errdefer allocator.free(bits);

        if (compressed) {
            // creadimage.c:75-119: blocks of `maxy nbytes <data>` until the last
            // row. Each block decompresses independently from a FRESH window.
            var y: i32 = y0;
            while (y != y1) {
                if (cur + 2 * 12 > data.len) return error.ShortData;
                const maxy = decCell(data, cur, 0) orelse return error.BadCompression;
                const nb_i = decCell(data, cur, 1) orelse return error.BadCompression;
                cur += 2 * 12;
                if (maxy <= y or maxy > y1) return error.BadCompression; // creadimage.c:90
                if (nb_i <= 0 or nb_i > @as(i32, @intCast(NCBLOCK))) return error.BadCompression;
                const nb: usize = @intCast(nb_i);
                if (cur + nb > data.len) return error.ShortData;
                const row0: usize = @intCast(y - y0);
                const row1: usize = @intCast(maxy - y0);
                try decompressBlock(bits[row0 * bpl .. row1 * bpl], data[cur .. cur + nb]);
                cur += nb;
                y = maxy;
            }
        } else {
            if (cur + nbits > data.len) return error.ShortData;
            @memcpy(bits, data[cur .. cur + nbits]);
            cur += nbits;
        }

        // font(6) trailer: 3×12B decimal n/height/ascent (readsubfont.c:21-27).
        if (cur + 3 * 12 > data.len) return error.ShortData;
        const n_i = decCell(data, cur, 0) orelse return error.BadHeader;
        const height_i = decCell(data, cur, 1) orelse return error.BadHeader;
        const ascent_i = decCell(data, cur, 2) orelse return error.BadHeader;
        cur += 3 * 12;
        if (n_i <= 0 or n_i > 4095 or height_i <= 0) return error.BadHeader; // subfont n∈[1,4095]
        if (height_i > 255 or ascent_i < 0 or ascent_i > 255) return error.BadHeader;
        const n: u32 = @intCast(n_i);

        // 6·(n+1) Fontchar bytes, unpacked per _unpackinfo (defont.c:388-402).
        const pack_len = 6 * (@as(usize, n) + 1);
        if (cur + pack_len > data.len) return error.ShortData;
        var info = try allocator.alloc(Fontchar, @as(usize, n) + 1);
        errdefer allocator.free(info);
        var j: usize = 0;
        while (j <= n) : (j += 1) {
            const p = data[cur + j * 6 ..][0..6];
            info[j] = .{
                .x = @as(u16, p[0]) | (@as(u16, p[1]) << 8),
                .top = p[2],
                .bottom = p[3],
                .left = @bitCast(p[4]),
                .width = p[5],
            };
        }

        return .{
            .chan = chan,
            .r = r,
            .n = n,
            .height = @intCast(height_i),
            .ascent = @intCast(ascent_i),
            .info = info,
            .bits = bits,
        };
    }

    pub fn deinit(self: *Subfont, allocator: std.mem.Allocator) void {
        allocator.free(self.info);
        allocator.free(self.bits);
    }
};

/// Decompress ONE image(6) block (cloadmemimage, cload.c:6-67) into `dst`,
/// treated as a flat run of rows (the caller sized `dst` to the block's rows).
/// A control byte `c >= 0x80` is a literal run of `c-128+1` bytes; otherwise a
/// copy run of `(c>>2)+NMATCH` bytes starting `((c&3)<<8 | next)+1` back in the
/// `NMEM`-byte wrap-around window (overlapping copies are legal). Any overshoot
/// or truncation ⇒ `BadCompression` (cload.c's "phase error"/"short buffer").
fn decompressBlock(dst: []u8, src: []const u8) error{BadCompression}!void {
    var mem: [NMEM]u8 = undefined;
    var memp: usize = 0;
    var d: usize = 0;
    var s: usize = 0;
    while (d < dst.len) {
        if (s >= src.len) return error.BadCompression; // cload.c:29 buffer too small
        const c = src[s];
        s += 1;
        if (c >= 128) {
            var cnt: usize = @as(usize, c - 128) + 1;
            while (cnt != 0) : (cnt -= 1) {
                if (s >= src.len) return error.BadCompression; // cload.c:35
                if (d >= dst.len) return error.BadCompression; // cload.c:38 phase error
                dst[d] = src[s];
                mem[memp] = src[s];
                d += 1;
                s += 1;
                memp += 1;
                if (memp == NMEM) memp = 0;
            }
        } else {
            if (s >= src.len) return error.BadCompression; // cload.c:48
            const offs: usize = @as(usize, src[s]) + (@as(usize, c & 3) << 8) + 1;
            s += 1;
            var omemp: usize = if (memp < offs) memp + NMEM - offs else memp - offs;
            var cnt: usize = @as(usize, c >> 2) + NMATCH;
            while (cnt != 0) : (cnt -= 1) {
                if (d >= dst.len) return error.BadCompression; // cload.c:56 phase error
                const v = mem[omemp];
                dst[d] = v;
                mem[memp] = v;
                d += 1;
                omemp += 1;
                if (omemp == NMEM) omemp = 0;
                memp += 1;
                if (memp == NMEM) memp = 0;
            }
        }
    }
}

/// The default monospace font embedded at build time (R-P3-1): `fixed/9x18.0000`
/// verbatim (public domain), a compressed GREY1 strip r=(0,0,1728,18), 256
/// glyphs, height 18, ascent 13. Reachable in the draw module + its test roots.
pub const default_subfont: []const u8 = @embedFile("font_fixed9x18");

/// libdraw batches at most this many glyph indices per 's' verb (string.c:7
/// `Max = 100`); `drawString` advances the pen between chunks.
pub const string_chunk: usize = 100;

allocator: std.mem.Allocator,
/// Borrowed; the caller owns the display's lifetime.
display: *Display,
/// Server-side glyph cache image (identity strip layout, R-P3-5).
cache: Image,
n: u32,
height: u8,
ascent: u8,
/// Owned copy of the per-glyph metrics, `n+1` entries (info[n].x closes the
/// last glyph). Freed by `deinit`.
info: []Fontchar,

pub const InitError = Display.Error || Image.LoadError || ParseError;

/// Parse `subfont_data` and build the server-side glyph cache (R-P3-5 identity
/// layout; font.c:280-317). Allocates a cache image whose rect *is* the strip's,
/// uploads the strip into a temporary image, then for each non-zero-width glyph
/// emits an 'l' naming the glyph's strip coordinates verbatim; the temporary is
/// freed ('l' has copied the pixels) and the batch flushed without a visible
/// 'v' so a build error is attributed here (font.c:301,372).
pub fn init(allocator: std.mem.Allocator, display: *Display, subfont_data: []const u8) InitError!Font {
    var sub = try Subfont.parse(allocator, subfont_data);
    defer sub.deinit(allocator);

    // Strip first (own 'b' + 'y'), then the cache image, matching libdraw's
    // load order — the string test pins this write sequence.
    var strip = try display.allocImage(sub.r, sub.chan, false, 0);
    try strip.load(sub.r, sub.bits);
    const cache = try display.allocImage(sub.r, sub.chan, false, 0);

    // 'i' initialises the glyph-metrics table on the cache (G18); each 'l'
    // copies one glyph's pixels from the strip via op-S (font.c:305-316).
    try display.emit(.{ .init_font = .{ .id = cache.id, .nchars = sub.n, .ascent = sub.ascent } });
    var i: u32 = 0;
    while (i < sub.n) : (i += 1) {
        const fi = sub.info[i];
        if (fi.width == 0) continue; // unloaded slot — the kernel leaves it empty
        try display.emit(.{
            .load_char = .{
                .fontid = cache.id,
                .srcid = strip.id,
                .index = @intCast(i),
                // Identity rect: (x, top)-(next.x, bottom) on the strip (R-P3-5).
                .r = proto.Rect.make(fi.x, fi.top, sub.info[i + 1].x, fi.bottom),
                .sp = .{ .x = fi.x, .y = fi.top },
                .left = fi.left,
                .width = fi.width,
            },
        });
    }
    try strip.free(); // 'l' has copied the pixels
    try display.doFlush(); // flush the i/l…/f batch without a visible 'v'

    const info = try allocator.dupe(Fontchar, sub.info);
    return .{
        .allocator = allocator,
        .display = display,
        .cache = cache,
        .n = sub.n,
        .height = sub.height,
        .ascent = sub.ascent,
        .info = info,
    };
}

/// Best-effort teardown: free the cache image ('f', flushed) and release the
/// owned metrics. Errors are ignored — nothing is recoverable at teardown.
pub fn deinit(self: *Font) void {
    self.cache.free() catch {};
    self.display.doFlush() catch {};
    self.allocator.free(self.info);
}

/// Map a codepoint to its cache slot: identity if `c < n` and the glyph is
/// loaded (width != 0), else slot 0 (R-P3-3 — invalid/absent ⇒ the .notdef
/// glyph). Phase 3 has one subfont, so latin1 maps directly.
pub fn cacheIndex(self: *const Font, c: u21) u16 {
    if (c < self.n and self.info[@intCast(c)].width != 0) return @intCast(c);
    return 0;
}

/// The pen advance for codepoint `c` (the cache slot's Fontchar.width). PURE.
pub fn charWidth(self: *const Font, c: u21) i32 {
    return self.info[self.cacheIndex(c)].width;
}

/// Total pen advance for UTF-8 `s`. PURE; invalid sequences map to slot 0
/// (R-P3-3). Never touches the wire — the acceptance test cross-checks the
/// device against this.
pub fn stringWidth(self: *const Font, s: []const u8) i32 {
    var total: i32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const g = self.nextGlyph(s, i);
        total += self.info[g.idx].width;
        i += g.adv;
    }
    return total;
}

const Glyph = struct { idx: u16, adv: usize };

/// Decode the UTF-8 codepoint at `s[i..]` into its cache slot and byte length.
/// An invalid/truncated sequence maps to slot 0 and advances one byte (R-P3-3).
fn nextGlyph(self: *const Font, s: []const u8, i: usize) Glyph {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .idx = 0, .adv = 1 };
    if (i + len > s.len) return .{ .idx = 0, .adv = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .idx = 0, .adv = 1 };
    return .{ .idx = self.cacheIndex(cp), .adv = len };
}

/// Draw UTF-8 `s` from `src` through this font onto `dst`. `pt` is the line's
/// TOP-LEFT: the wire baseline is `pt.y + ascent` (string.c:105-107) and the
/// clip rect is `dst.clipr` (string.c:13). Batches ≤ `string_chunk` glyph
/// indices per 's', advancing the pen by the chunk's width between messages.
/// Buffered — pixels appear on the next `Display.flush()`. Returns the pen
/// position after the last glyph (top-left, x advanced).
pub fn drawString(self: *Font, dst: *Image, pt: proto.Point, src: *Image, s: []const u8) Display.Error!proto.Point {
    var indices: [string_chunk]u16 = undefined;
    var p = pt;
    var i: usize = 0;
    while (i < s.len) {
        var n: usize = 0;
        var chunk_width: i32 = 0;
        while (i < s.len and n < string_chunk) {
            const g = self.nextGlyph(s, i);
            indices[n] = g.idx;
            chunk_width += self.info[g.idx].width;
            n += 1;
            i += g.adv;
        }
        try self.display.emit(.{
            .string = .{
                .dstid = dst.id,
                .srcid = src.id,
                .fontid = self.cache.id,
                .p = .{ .x = p.x, .y = p.y + self.ascent }, // baseline (string.c:105)
                .clipr = dst.clipr,
                .sp = .{},
                .indices = indices[0..n],
            },
        });
        p.x += chunk_width;
    }
    return p;
}

// ==========================================================================
// Tests (client §5). Pure parse/metrics/decompress cases plus two that drive a
// real `Display` over a minimal fake `/dev/draw` (ninep.server in TEST BLOCKS
// only — the R-P2-3 precedent). All use `testing.allocator`.
// ==========================================================================
const testing = std.testing;

/// Write `s` into the 12-byte header/trailer cell at `data[base + i*12 ..]`,
/// left-justified and space-padded (parses under both plan9 `%-11d`/`%11d`).
fn putCell(data: []u8, base: usize, i: usize, s: []const u8) void {
    const dst = data[base + i * 12 ..][0..12];
    @memset(dst, ' ');
    @memcpy(dst[0..s.len], s);
}

fn cell(data: []const u8, base: usize, i: usize) []const u8 {
    return std.mem.trim(u8, data[base + i * 12 ..][0..12], " ");
}

fn decCell(data: []const u8, base: usize, i: usize) ?i32 {
    return std.fmt.parseInt(i32, cell(data, base, i), 10) catch null;
}

/// The hand-built 116-byte uncompressed tiny subfont (client §5): a GREY1
/// 4×2 strip r=(0,0,4,2), rows {0xA0,0x50}; trailer n=2 height=2 ascent=1;
/// three Fontchars closing two width-2 glyphs.
fn tinySubfont() [116]u8 {
    var f: [116]u8 = undefined;
    // image(6) header: chan "k1", r=(0,0,4,2).
    putCell(&f, 0, 0, "k1");
    putCell(&f, 0, 1, "0");
    putCell(&f, 0, 2, "0");
    putCell(&f, 0, 3, "4");
    putCell(&f, 0, 4, "2");
    // 2 rows × bpl 1.
    f[60] = 0xA0;
    f[61] = 0x50;
    // trailer n/height/ascent.
    putCell(&f, 62, 0, "2");
    putCell(&f, 62, 1, "2");
    putCell(&f, 62, 2, "1");
    // 3 Fontchars (6B each): {x,top,bottom,left,width}.
    const fc = [_][6]u8{
        .{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x02 },
        .{ 0x02, 0x00, 0x00, 0x02, 0x00, 0x02 },
        .{ 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 },
    };
    var i: usize = 0;
    while (i < 3) : (i += 1) @memcpy(f[98 + i * 6 ..][0..6], &fc[i]);
    return f;
}

test "font: parse tiny subfont" {
    const data = tinySubfont();
    var sub = try Subfont.parse(testing.allocator, &data);
    defer sub.deinit(testing.allocator);

    try testing.expectEqual(proto.GREY1, sub.chan);
    try testing.expectEqual(proto.Rect.make(0, 0, 4, 2), sub.r);
    try testing.expectEqual(@as(u32, 2), sub.n);
    try testing.expectEqual(@as(u8, 2), sub.height);
    try testing.expectEqual(@as(u8, 1), sub.ascent);
    try testing.expectEqual(@as(usize, 3), sub.info.len);
    try testing.expectEqual(Fontchar{ .x = 2, .top = 0, .bottom = 2, .left = 0, .width = 2 }, sub.info[1]);
    try testing.expectEqual(@as(u16, 4), sub.info[2].x);
    try testing.expectEqualSlices(u8, &.{ 0xA0, 0x50 }, sub.bits);
}

test "font: parse compressed tiny subfont" {
    // "compressed\n" + header + one block (maxy=2, nbytes=3, data 81 A0 50) +
    // the same trailer/Fontchars, decompressing to the same {0xA0,0x50} rows.
    var data: [11 + 60 + 24 + 3 + 36 + 18]u8 = undefined;
    @memcpy(data[0..11], "compressed\n");
    putCell(&data, 11, 0, "k1");
    putCell(&data, 11, 1, "0");
    putCell(&data, 11, 2, "0");
    putCell(&data, 11, 3, "4");
    putCell(&data, 11, 4, "2");
    putCell(&data, 71, 0, "2"); // maxy
    putCell(&data, 71, 1, "3"); // nbytes
    @memcpy(data[95..98], &[_]u8{ 0x81, 0xA0, 0x50 }); // literal run of 2
    putCell(&data, 98, 0, "2");
    putCell(&data, 98, 1, "2");
    putCell(&data, 98, 2, "1");
    const fc = [_][6]u8{
        .{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x02 },
        .{ 0x02, 0x00, 0x00, 0x02, 0x00, 0x02 },
        .{ 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 },
    };
    var i: usize = 0;
    while (i < 3) : (i += 1) @memcpy(data[134 + i * 6 ..][0..6], &fc[i]);

    var sub = try Subfont.parse(testing.allocator, &data);
    defer sub.deinit(testing.allocator);
    try testing.expectEqual(proto.Rect.make(0, 0, 4, 2), sub.r);
    try testing.expectEqual(@as(u32, 2), sub.n);
    try testing.expectEqualSlices(u8, &.{ 0xA0, 0x50 }, sub.bits);
}

test "font: decompress copy run" {
    // Literal 1 (0xAA) then a copy run of 3 from offset 1 back ⇒ overlapping
    // fill: AA AA AA AA.
    var dst: [4]u8 = undefined;
    try decompressBlock(&dst, &[_]u8{ 0x80, 0xAA, 0x00, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xAA, 0xAA, 0xAA }, &dst);

    // Truncated source (literal wants a byte that is not there).
    try testing.expectError(error.BadCompression, decompressBlock(&dst, &[_]u8{0x80}));

    // Overshooting run: literal 1 then a 4-byte copy into a 3-slot remainder.
    try testing.expectError(error.BadCompression, decompressBlock(&dst, &[_]u8{ 0x80, 0xAA, 0x04, 0x00 }));
}

test "font: parse embedded fixed 9x18" {
    var sub = try Subfont.parse(testing.allocator, default_subfont);
    defer sub.deinit(testing.allocator);
    try testing.expectEqual(proto.GREY1, sub.chan);
    try testing.expectEqual(proto.Rect.make(0, 0, 1728, 18), sub.r);
    try testing.expectEqual(@as(u32, 256), sub.n);
    try testing.expectEqual(@as(u8, 18), sub.height);
    try testing.expectEqual(@as(u8, 13), sub.ascent);
    try testing.expectEqual(@as(u16, 594), sub.info[0x61].x);
    try testing.expectEqual(@as(u16, 1728), sub.info[256].x);
    // Strip is exactly bytesPerLine × Dy for a GREY1 1728-wide, 18-tall image.
    try testing.expectEqual(@as(usize, 216 * 18), sub.bits.len);
}

test "font: metrics width" {
    // Build a Font off the embedded subfont over a fake devdraw, then check the
    // pure metrics helpers (no further wire traffic).
    var fx = try Fixture.init(8192);
    defer fx.deinit();
    var font = try Font.init(testing.allocator, fx.disp, default_subfont);
    defer font.deinit();

    try testing.expectEqual(@as(i32, 9), font.charWidth('a'));
    try testing.expectEqual(@as(i32, 18), font.stringWidth("ab"));
    try testing.expectEqual(@as(i32, 0), font.stringWidth(""));
    // A control char and a CJK codepoint both fall back to slot 0 (width 9).
    try testing.expectEqual(@as(i32, 9), font.charWidth(0x01));
    try testing.expectEqual(@as(i32, 9), font.charWidth(0x4E00));
    try testing.expectEqual(@as(u16, 0), font.cacheIndex(0x4E00));
}

test "image: chunked y load discipline" {
    // `min_msize` pins buf_size at 8000 (chunk 7936), so we force chunking with
    // a tall image rather than a small buffer: GREY8 100×100 ⇒ bpl 100, ~79
    // rows per chunk ⇒ two partial 'y' uploads.
    var fx = try Fixture.init(8192);
    defer fx.deinit();
    const bufsz = fx.disp.buf_size;

    var img = try fx.disp.allocImage(proto.Rect.make(0, 0, 100, 100), proto.GREY8, false, 0);
    const payload = try testing.allocator.alloc(u8, 100 * 100);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, k| b.* = @intCast(k & 0xFF);
    const base = fx.tree.writes.items.len;
    try img.load(proto.Rect.make(0, 0, 100, 100), payload);

    // Reassemble every 'y' verb written since the load: rows must partition the
    // rectangle in order and the payload must come back byte-exact.
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var y_count: usize = 0;
    for (fx.tree.writes.items[base..]) |w| {
        try testing.expect(w.len <= bufsz);
        var off: usize = 0;
        while (off < w.len) {
            try testing.expectEqual(@as(u8, 'y'), w[off]);
            const rmin_y = std.mem.readInt(i32, w[off + 9 ..][0..4], .little);
            const rmax_y = std.mem.readInt(i32, w[off + 17 ..][0..4], .little);
            const rows: usize = @intCast(rmax_y - rmin_y);
            const n = rows * 100;
            try testing.expectEqual(@as(i32, @intCast(y_count)), rmin_y);
            try got.appendSlice(testing.allocator, w[off + 21 .. off + 21 + n]);
            y_count += rows;
            off += 21 + n;
        }
    }
    try testing.expect(fx.tree.writes.items.len - base >= 2);
    try testing.expectEqual(@as(usize, 100), y_count);
    try testing.expectEqualSlices(u8, payload, got.items);

    // A single row wider than the chunk ⇒ BadRect (too wide for the buffer).
    var wide = try fx.disp.allocImage(proto.Rect.make(0, 0, 8000, 1), proto.GREY8, false, 0);
    try testing.expectError(error.BadRect, wide.load(proto.Rect.make(0, 0, 8000, 1), payload));
    // Too little data ⇒ ShortData.
    try testing.expectError(error.ShortData, img.load(proto.Rect.make(0, 0, 100, 100), payload[0..10]));
}

test "display: oversized op is an error" {
    // A hand-built display with a tiny buffer: emit's guard fires before any
    // flush (no client needed) and leaves the buffer untouched.
    var buf: [64]u8 = undefined;
    var disp: Display = undefined;
    disp.buf = &buf;
    disp.buf_size = 50;
    disp.bufn = 7;
    var data: [100]u8 = [_]u8{0} ** 100; // 'y' of 100 bytes ⇒ 121 > 50
    try testing.expectError(error.ShortBuffer, disp.emit(.{
        .load = .{ .id = 1, .r = proto.Rect.make(0, 0, 100, 1), .data = &data },
    }));
    try testing.expectEqual(@as(usize, 7), disp.bufn);
}

// --- minimal fake /dev/draw for the two Display-driven tests above ----------

const ninep = @import("ninep");
const nserver = ninep.server;
const OpError = ninep.errors.OpError;
const Qid = ninep.Qid;

/// A canned draw tree: root(1) → new(2); dir "1"(3) → data(4). `new` reads back
/// a fixed connection line; `data` records every write. Same shape as draw.zig's
/// FakeDrawTree (R-P2-6), duplicated compactly so Font's tests stand alone.
const FakeTree = struct {
    alloc: std.mem.Allocator,
    conn_line: [Display.info_size]u8,
    writes: std.ArrayList([]u8) = .empty,

    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 or path == 3 } };
    }
    fn attach(_: *anyopaque, _: *nserver.Server, _: *nserver.Fid, _: []const u8) OpError!Qid {
        return qidOf(1);
    }
    fn walk1(_: *anyopaque, _: *nserver.Server, fid: *nserver.Fid, name: []const u8) OpError!Qid {
        const eq = std.mem.eql;
        return switch (fid.qid.path) {
            1 => if (eq(u8, name, "new")) qidOf(2) else if (eq(u8, name, "1")) qidOf(3) else if (eq(u8, name, "..")) qidOf(1) else error.FileDoesNotExist,
            3 => if (eq(u8, name, "data")) qidOf(4) else if (eq(u8, name, "..")) qidOf(1) else error.FileDoesNotExist,
            else => error.WalkNoDir,
        };
    }
    fn open(_: *anyopaque, _: *nserver.Server, fid: *nserver.Fid, _: u8) OpError!Qid {
        return fid.qid;
    }
    fn read(ctx: *anyopaque, _: *nserver.Server, fid: *nserver.Fid, offset: u64, buf: []u8) OpError!usize {
        const self: *FakeTree = @ptrCast(@alignCast(ctx));
        if (fid.qid.path != 2 or offset >= self.conn_line.len) return 0;
        const n = @min(buf.len, self.conn_line.len - offset);
        @memcpy(buf[0..n], self.conn_line[@intCast(offset)..][0..n]);
        return n;
    }
    fn write(ctx: *anyopaque, _: *nserver.Server, fid: *nserver.Fid, _: u64, data: []const u8) OpError!usize {
        const self: *FakeTree = @ptrCast(@alignCast(ctx));
        if (fid.qid.path != 4) return error.PermissionDenied;
        const copy = self.alloc.dupe(u8, data) catch return error.IoError;
        self.writes.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return error.IoError;
        };
        return data.len;
    }
    fn statOp(_: *anyopaque, _: *nserver.Server, fid: *nserver.Fid) OpError!ninep.stat {
        return .{
            .qid = fid.qid,
            .mode = if (fid.qid.qtype.dir) (ninep.stat.DMDIR | 0o555) else 0o666,
            .length = 0,
            .name = "draw",
        };
    }
    const ops = nserver.Ops{ .attach = attach, .walk1 = walk1, .open = open, .read = read, .write = write, .stat = statOp };

    fn buildConnLine(self: *FakeTree, fields: [12][]const u8) void {
        for (fields, 0..) |f, i| {
            const c = self.conn_line[i * 12 ..][0..12];
            @memset(c, ' ');
            @memcpy(c[11 - f.len ..][0..f.len], f);
        }
    }
};

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *nserver.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// A live `Display` wired to a `FakeTree` over a chan.Pipe, with a chosen msize.
const Fixture = struct {
    pipe: *ninep.chan.Pipe,
    tree: *FakeTree,
    srv: *nserver.Server,
    cl: *ninep.Client,
    disp: *Display,

    fn init(msize: u32) !Fixture {
        const a = testing.allocator;
        const pipe = try ninep.chan.Pipe.init(a, 16384);
        const tree = try a.create(FakeTree);
        tree.* = .{ .alloc = a, .conn_line = undefined };
        tree.buildConnLine(.{ "1", "0", "x8r8g8b8", "0", "0", "0", "640", "480", "0", "0", "640", "480" });
        const srv = try a.create(nserver.Server);
        srv.* = try nserver.Server.init(a, pipe.serverEnd(), &FakeTree.ops, tree, msize);
        const cl = try a.create(ninep.Client);
        cl.* = try ninep.Client.init(a, pipe.clientEnd(), msize);
        cl.pump = .{ .ctx = srv, .run = pump };
        _ = try cl.version(msize);
        const root = try cl.attach("glenda", "");
        const disp = try Display.init(a, cl, root.fid);
        return .{ .pipe = pipe, .tree = tree, .srv = srv, .cl = cl, .disp = disp };
    }

    fn deinit(self: *Fixture) void {
        const a = testing.allocator;
        self.disp.deinit();
        self.cl.deinit();
        self.srv.deinit();
        for (self.tree.writes.items) |w| a.free(w);
        self.tree.writes.deinit(a);
        a.destroy(self.cl);
        a.destroy(self.srv);
        a.destroy(self.tree);
        self.pipe.deinit();
    }
};
