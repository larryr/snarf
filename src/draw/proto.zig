//! Draw-protocol wire encoder (client → /dev/draw). [ref: S-03 §2,
//! 9/port/devdraw.c]. Pure: std only, no ninep import (this module is used by
//! both `src/draw` (client) and, indirectly via shared vocabulary, the dev-side
//! backend — but it never touches a transport itself).
//!
//! Wire format is little-endian throughout (G1; devdraw.c:871-877 for signed
//! coordinates, draw.h:508-511 BGSHORT/BGLONG despite the "big" name, draw(3)
//! man page "low order byte first"). Verb layouts are normative per the phase-2
//! contract §P/G7 (agents/contracts/phase2-draw.md) and are re-derived here
//! from devdraw.c's own comments so a reviewer can diff the two directly.
const std = @import("std");

/// A device-space point. Half-open, top-left origin, y down (S-03 §1).
pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,

    /// Wire size: x[4le] y[4le]. (devdraw.c drawpoint, "P" = 2*4)
    pub const wire_size: usize = 8;

    /// Encode x then y, each signed little-endian 32-bit.
    pub fn encode(self: Point, buf: *[wire_size]u8) void {
        std.mem.writeInt(i32, buf[0..4], self.x, .little);
        std.mem.writeInt(i32, buf[4..8], self.y, .little);
    }
};

/// A device-space rectangle: min inclusive, max exclusive (half-open).
pub const Rect = struct {
    min: Point = .{},
    max: Point = .{},

    /// Wire size: min[8] max[8]. (devdraw.c drawrectangle, "R" = 4*4)
    pub const wire_size: usize = 16;

    /// Encode min then max, each a Point.
    pub fn encode(self: Rect, buf: *[wire_size]u8) void {
        self.min.encode(buf[0..8]);
        self.max.encode(buf[8..16]);
    }

    pub fn make(x0: i32, y0: i32, x1: i32, y1: i32) Rect {
        return .{ .min = .{ .x = x0, .y = y0 }, .max = .{ .x = x1, .y = y1 } };
    }
};

/// The clip rect libdraw installs on a repl (tiled) image: as close to "all of
/// device space" as fits while leaving headroom for translation arithmetic
/// elsewhere not to overflow i32 (G10; alloc.c:58-62).
pub const repl_clipr: Rect = Rect.make(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);

/// Image channel descriptor (draw.h:112-146 CHANn / __DC macros).
pub const Chan = u32;

pub const GREY1: Chan = 0x31;
pub const GREY8: Chan = 0x38;
pub const XRGB32: Chan = 0x68081828;
pub const RGBA32: Chan = 0x08182848;

/// `__DC(type, nbits)`: pack a single channel descriptor. (draw.h:121)
fn dc(t: u32, n: u32) u32 {
    return ((t & 15) << 4) | (n & 15);
}

/// `CHAN2(a,b,c,d) = CHAN1(a,b)<<8 | __DC(c,d)`. (draw.h:123)
fn chan2(a: u32, b: u32, c: u32, d: u32) u32 {
    return (dc(a, b) << 8) | dc(c, d);
}

/// `CHAN3(...) = CHAN2(...)<<8 | __DC(e,f)`. (draw.h:124)
fn chan3(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) u32 {
    return (chan2(a, b, c, d) << 8) | dc(e, f);
}

/// `CHAN4(...) = CHAN3(...)<<8 | __DC(g,h)`. (draw.h:125)
fn chan4(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) u32 {
    return (chan3(a, b, c, d, e, f) << 8) | dc(g, h);
}

// Channel "type" values from the CRed..CIgnore enum (draw.h:109-118); also the
// index order of `channames = "rgbkamx"` used by strtochan (chan.c:6).
const t_red: u32 = 0;
const t_green: u32 = 1;
const t_blue: u32 = 2;
const t_grey: u32 = 3;
const t_alpha: u32 = 4;
const t_ignore: u32 = 6;

comptime {
    // G9: re-derive every required chan constant from the __DC arithmetic
    // independently of the literal above, so the two can never silently drift.
    std.debug.assert(GREY1 == dc(t_grey, 1));
    std.debug.assert(GREY8 == dc(t_grey, 8));
    std.debug.assert(XRGB32 == chan4(t_ignore, 8, t_red, 8, t_green, 8, t_blue, 8));
    std.debug.assert(RGBA32 == chan4(t_red, 8, t_green, 8, t_blue, 8, t_alpha, 8));
}

/// `channames` index-to-letter table for strtochan/chantostr (chan.c:6).
/// Index == channel "type" value (CRed=0 .. CIgnore=6).
const channames = "rgbkamx";

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

/// Mirrors `strtochan` (chan.c:40-66): parse a channel descriptor string like
/// "x8r8g8b8" into its packed `Chan` code. Returns null on any malformed
/// descriptor (unknown letter, missing/non-digit width, or a total bit depth
/// that fails the `8 % d` / `d % 8` divisibility check chan.c:60 applies).
pub fn strToChan(s: []const u8) ?Chan {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;

    var c: u32 = 0;
    var depth: u32 = 0;
    while (i < s.len and !isSpace(s[i])) {
        const t = std.mem.indexOfScalar(u8, channames, s[i]) orelse return null;
        if (i + 1 >= s.len or s[i + 1] < '0' or s[i + 1] > '9') return null;
        const n: u32 = s[i + 1] - '0';
        depth += n;
        c = (c << 8) | dc(@intCast(t), n);
        i += 2;
    }
    if (depth == 0) return null;
    if (depth > 8 and depth % 8 != 0) return null;
    if (depth < 8 and 8 % depth != 0) return null;
    return c;
}

/// 32-bit `rrggbbaa`, alpha-premultiplied (G2; devdraw.c:1480).
pub const Color = u32;

pub const DOpaque: Color = 0xFFFFFFFF;
pub const DTransparent: Color = 0x00000000;
pub const DBlack: Color = 0x000000FF;
pub const DWhite: Color = 0xFFFFFFFF;
pub const DRed: Color = 0xFF0000FF;
pub const DGreen: Color = 0x00FF00FF;
pub const DBlue: Color = 0x0000FFFF;
pub const DCyan: Color = 0x00FFFFFF;
pub const DMagenta: Color = 0xFF00FFFF;
pub const DYellow: Color = 0xFFFF00FF;
pub const DPaleyellow: Color = 0xFFFFAAFF;
pub const DNotacolor: Color = 0xFFFFFF00;
pub const DNofill: Color = DNotacolor;

/// Refresh method for a backed (screen) image (draw.h:69-71). Phase 2 only
/// ever emits `.backup`; the others are wire-complete for later phases.
pub const Refresh = enum(u8) { backup = 0, none = 1, mesg = 2 };

/// A single draw-protocol verb, ready to encode. The full verb set is S-03
/// §2; Phase 2 needs exactly these four (alloc/draw/free/flush).
pub const Op = union(enum) {
    alloc: Alloc,
    draw: Draw,
    free: Free,
    flush,

    /// 'b': allocate an image. (devdraw.c:1467-1540 comment + body; alloc.c:43-67)
    pub const Alloc = struct {
        id: u32,
        screenid: u32 = 0,
        refresh: Refresh = .backup,
        chan: Chan,
        repl: bool = false,
        r: Rect,
        clipr: Rect,
        color: Color,
    };

    /// 'd': SoverD a rectangle from src (through mask) onto dst.
    /// (devdraw.c:1578-1594; libmemdraw/draw.c:26-45)
    pub const Draw = struct {
        dstid: u32,
        srcid: u32,
        maskid: u32,
        r: Rect,
        sp: Point = .{},
        mp: Point = .{},
    };

    /// 'f': free (uninstall) an image. (devdraw.c:1640-1650)
    pub const Free = struct { id: u32 };
};

pub const EncodeError = error{ShortBuffer};

/// The exact on-wire byte length of `op`, per G7: 'b' 51, 'd' 45, 'f' 5, 'v' 1.
pub fn encodedSize(op: Op) usize {
    return switch (op) {
        .alloc => 51,
        .draw => 45,
        .free => 5,
        .flush => 1,
    };
}

/// Encode `op` into the front of `buf`, returning the written sub-slice.
/// `error.ShortBuffer` if `buf` is smaller than `encodedSize(op)`; the buffer
/// is otherwise untouched beyond the written prefix.
///
/// Verb byte-offset layouts (G7, offsets counted from the verb byte itself):
///   'b' (0x62), 51 B: id[4]@1 screenid[4]@5 refresh[1]@9 chan[4]@10 repl[1]@14
///       r[16]@15 clipr[16]@31 color[4]@47.
///   'd' (0x64), 45 B: dstid[4]@1 srcid[4]@5 maskid[4]@9 r[16]@13 sp[8]@29 mp[8]@37.
///   'f' (0x66), 5 B: id[4]@1.
///   'v' (0x76), 1 B, bare (no plan9port 4-byte suffix; devdraw.c:2075-2080).
pub fn encode(op: Op, buf: []u8) EncodeError![]u8 {
    const size = encodedSize(op);
    if (buf.len < size) return error.ShortBuffer;
    switch (op) {
        .alloc => |a| {
            buf[0] = 'b';
            std.mem.writeInt(u32, buf[1..5], a.id, .little);
            std.mem.writeInt(u32, buf[5..9], a.screenid, .little);
            buf[9] = @intFromEnum(a.refresh);
            std.mem.writeInt(u32, buf[10..14], a.chan, .little);
            buf[14] = if (a.repl) 1 else 0;
            a.r.encode(buf[15..31]);
            a.clipr.encode(buf[31..47]);
            std.mem.writeInt(u32, buf[47..51], a.color, .little);
        },
        .draw => |d| {
            buf[0] = 'd';
            std.mem.writeInt(u32, buf[1..5], d.dstid, .little);
            std.mem.writeInt(u32, buf[5..9], d.srcid, .little);
            std.mem.writeInt(u32, buf[9..13], d.maskid, .little);
            d.r.encode(buf[13..29]);
            d.sp.encode(buf[29..37]);
            d.mp.encode(buf[37..45]);
        },
        .free => |f| {
            buf[0] = 'f';
            std.mem.writeInt(u32, buf[1..5], f.id, .little);
        },
        .flush => {
            buf[0] = 'v';
        },
    }
    return buf[0..size];
}

test "proto: point/rect wire encode" {
    var pbuf: [Point.wire_size]u8 = undefined;
    (Point{ .x = -1, .y = 2 }).encode(&pbuf);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0x00, 0x00, 0x00 }, &pbuf);

    var rbuf: [Rect.wire_size]u8 = undefined;
    Rect.make(0, 0, 1, 1).encode(&rbuf);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    }, &rbuf);
}

test "proto: encode b golden" {
    const op: Op = .{ .alloc = .{
        .id = 1,
        .chan = GREY1,
        .repl = true,
        .r = Rect.make(0, 0, 1, 1),
        .clipr = repl_clipr,
        .color = DWhite,
    } };
    var buf: [51]u8 = undefined;
    const got = try encode(op, &buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x62, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x31, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0xC0, 0x01, 0x00, 0x00, 0xC0, 0xFF,
        0xFF, 0xFF, 0x3F, 0xFF, 0xFF, 0xFF, 0x3F, 0xFF, 0xFF, 0xFF,
        0xFF,
    }, got);
}

test "proto: encode d golden" {
    const op: Op = .{ .draw = .{
        .dstid = 0,
        .srcid = 3,
        .maskid = 1,
        .r = Rect.make(10, 10, 20, 20),
    } };
    var buf: [45]u8 = undefined;
    const got = try encode(op, &buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x64, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00,
        0x00, 0x14, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    }, got);
}

test "proto: encode f and v golden" {
    var fbuf: [5]u8 = undefined;
    const gotf = try encode(.{ .free = .{ .id = 1 } }, &fbuf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x66, 0x01, 0x00, 0x00, 0x00 }, gotf);

    var vbuf: [1]u8 = undefined;
    const gotv = try encode(.flush, &vbuf);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x76}, gotv);
}

test "proto: encodedSize matches encode" {
    var buf: [51]u8 = undefined;

    const alloc_op: Op = .{ .alloc = .{
        .id = 9,
        .chan = GREY1,
        .r = Rect.make(0, 0, 1, 1),
        .clipr = repl_clipr,
        .color = DWhite,
    } };
    try std.testing.expectEqual(@as(usize, 51), encodedSize(alloc_op));
    try std.testing.expectEqual(encodedSize(alloc_op), (try encode(alloc_op, &buf)).len);

    const draw_op: Op = .{ .draw = .{ .dstid = 0, .srcid = 1, .maskid = 2, .r = Rect.make(0, 0, 1, 1) } };
    try std.testing.expectEqual(@as(usize, 45), encodedSize(draw_op));
    try std.testing.expectEqual(encodedSize(draw_op), (try encode(draw_op, &buf)).len);

    const free_op: Op = .{ .free = .{ .id = 3 } };
    try std.testing.expectEqual(@as(usize, 5), encodedSize(free_op));
    try std.testing.expectEqual(encodedSize(free_op), (try encode(free_op, &buf)).len);

    try std.testing.expectEqual(@as(usize, 1), encodedSize(.flush));
    try std.testing.expectEqual(encodedSize(.flush), (try encode(.flush, &buf)).len);
}

test "proto: short buffer" {
    const op: Op = .{ .alloc = .{
        .id = 1,
        .chan = GREY1,
        .r = Rect.make(0, 0, 1, 1),
        .clipr = repl_clipr,
        .color = DWhite,
    } };
    var buf50: [50]u8 = undefined;
    try std.testing.expectError(error.ShortBuffer, encode(op, &buf50));

    var buf51: [51]u8 = undefined;
    _ = try encode(op, &buf51);
}

test "proto: strToChan" {
    try std.testing.expectEqual(@as(?Chan, GREY1), strToChan("k1"));
    try std.testing.expectEqual(@as(?Chan, GREY8), strToChan("k8"));
    try std.testing.expectEqual(@as(?Chan, XRGB32), strToChan("x8r8g8b8"));
    try std.testing.expectEqual(@as(?Chan, RGBA32), strToChan("r8g8b8a8"));

    try std.testing.expectEqual(@as(?Chan, null), strToChan("q8"));
    try std.testing.expectEqual(@as(?Chan, null), strToChan("k"));
    try std.testing.expectEqual(@as(?Chan, null), strToChan(""));
    // 5-channel descriptor: total depth 8+8+8+8+3=35 is >8 and not a multiple
    // of 8, failing the chan.c:60 divisibility check ⇒ rejected.
    try std.testing.expectEqual(@as(?Chan, null), strToChan("r8g8b8a8k3"));
}

test "proto: chan constants derive" {
    // Same G9 derivation as the module-level comptime block above, exercised
    // here as a named test per the phase-2 contract §P.
    comptime {
        std.debug.assert(GREY1 == dc(t_grey, 1));
        std.debug.assert(GREY8 == dc(t_grey, 8));
        std.debug.assert(XRGB32 == chan4(t_ignore, 8, t_red, 8, t_green, 8, t_blue, 8));
        std.debug.assert(RGBA32 == chan4(t_red, 8, t_green, 8, t_blue, 8, t_alpha, 8));
    }
}
