//! Frame layout/measurement — the pure geometry half of libframe: `frutil.c`
//! (canFit/ckLineWrap/advance/newWid/clean) and `frptofchar.c` (ptOfChar family
//! + charOfPt), plus `runeByteIndex` (frbox.c:86-101 `runeindex`) and
//! `stringNWidth` (`stringnwidth`). Cite as `frutil.c:NN` / `frptofchar.c:NN`
//! (larryr/plan9port@337c6ac). All i32 pixel math over the box list; only `clean`
//! mutates. Font height/ascent are u8 — widened via `fontHeight`. Rune widths
//! route through `runeAt` (mirrors `Font.nextGlyph`: invalid ⇒ slot 0), so a run
//! box's per-rune widths always sum to its `wid` (invariant I-2).
const std = @import("std");
const proto = @import("../proto.zig");
const Font = @import("../Font.zig");
const Frame = @import("Frame.zig");

const Box = Frame.Box;
const Point = proto.Point;

/// Font line height as i32 (Font.height is u8; frame math is signed).
pub fn fontHeight(f: *const Frame) i32 {
    return f.font.height;
}

/// One UTF-8 rune's cache width + byte length at `s[i..]`. Mirrors
/// `Font.nextGlyph` (R-P3-3): an invalid/truncated sequence maps to slot 0 and
/// advances one byte, so widths agree with `Font.stringWidth` byte-for-byte.
pub fn runeAt(font: *const Font, s: []const u8, i: usize) struct { w: i32, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .w = font.charWidth(0), .len = 1 };
    if (i + len > s.len) return .{ .w = font.charWidth(0), .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .w = font.charWidth(0), .len = 1 };
    return .{ .w = font.charWidth(cp), .len = len };
}

/// Byte offset of the `n`-th rune in UTF-8 `s` (frbox.c:86-101 `runeindex`).
/// e.g. `runeByteIndex("café", 4) == 5` (the closing 2-byte é).
pub fn runeByteIndex(s: []const u8, n: usize) usize {
    var i: usize = 0;
    var k: usize = 0;
    while (k < n and i < s.len) : (k += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += if (i + len <= s.len) len else 1;
    }
    return i;
}

/// Width of the first `nr` runes of UTF-8 `s` (`stringnwidth`, frame contract
/// §util): `font.stringWidth(s[0..runeByteIndex(s, nr)])`.
pub fn stringNWidth(font: *const Font, s: []const u8, nr: usize) i32 {
    return font.stringWidth(s[0..runeByteIndex(s, nr)]);
}

/// `_frcanfit` (frutil.c:7-31): how many runes of `b` fit to the right of `pt`.
/// Break ⇒ 1 if `minwid` fits else 0. Run ⇒ all runes if the box fits, else a
/// per-rune walk (0 if not even one fits; the caller decides if that is fatal).
pub fn canFit(f: *const Frame, pt: Point, b: *const Box) usize {
    const left = f.r.max.x - pt.x;
    switch (b.kind) {
        .brk => |brk| return if (brk.minwid <= left) 1 else 0,
        .run => |run| {
            if (left >= b.wid) return run.nrune;
            var nr: usize = 0;
            var i: usize = 0;
            var rem = left;
            while (i < run.text.len) {
                const g = runeAt(f.font, run.text, i);
                rem -= g.w;
                if (rem < 0) return nr;
                i += g.len;
                nr += 1;
            }
            @panic("_frcanfit can't"); // frutil.c:29 — unreachable (sum wid > left)
        },
    }
}

/// `_frcklinewrap` (frutil.c:33-40): wrap `p` to the next line if `b`'s claim
/// (brk ⇒ minwid, run ⇒ wid) overhangs the right edge.
pub fn ckLineWrap(f: *const Frame, p: *Point, b: *const Box) void {
    const w = switch (b.kind) {
        .brk => |brk| brk.minwid,
        .run => b.wid,
    };
    if (w > f.r.max.x - p.x) {
        p.x = f.r.min.x;
        p.y += fontHeight(f);
    }
}

/// `_frcklinewrap0` (frutil.c:42-49): wrap when not even one rune of `b` fits.
pub fn ckLineWrap0(f: *const Frame, p: *Point, b: *const Box) void {
    if (canFit(f, p.*, b) == 0) {
        p.x = f.r.min.x;
        p.y += fontHeight(f);
    }
}

/// `_fradvance` (frutil.c:51-59): step `p` past `b`. A '\n' does CR+LF; anything
/// else advances by `wid` (tabs carry their layout-time wid).
pub fn advance(f: *const Frame, p: *Point, b: *const Box) void {
    if (b.kind == .brk and b.kind.brk.bc == '\n') {
        p.x = f.r.min.x;
        p.y += fontHeight(f);
    } else {
        p.x += b.wid;
    }
}

/// `_frnewwid` (frutil.c:61-66): compute AND store the layout width of `b`.
pub fn newWid(f: *const Frame, pt: Point, b: *Box) i32 {
    b.wid = newWid0(f, pt, b);
    return b.wid;
}

/// `_frnewwid0` (frutil.c:68-84): the TAB RULE. Only a '\t' break recomputes.
/// Snap to the next `maxtab` grid stop from `r.min.x` (resetting the local origin
/// to the line start first if the box must wrap); fall back to `minwid` if that
/// advance is under `minwid` or overshoots the right edge. (fixed 9x18: maxtab 72
/// ⇒ tab after 1 char ⇒ 63; tab after 10 chars ⇒ clamped to minwid 9.)
pub fn newWid0(f: *const Frame, pt: Point, b: *const Box) i32 {
    switch (b.kind) {
        .run => return b.wid,
        .brk => |brk| {
            if (brk.bc != '\t') return b.wid;
            const c = f.r.max.x;
            var x = pt.x;
            var ptx = pt.x;
            if (x + brk.minwid > c) {
                x = f.r.min.x;
                ptx = f.r.min.x;
            }
            x += f.maxtab;
            x -= @rem(x - f.r.min.x, f.maxtab);
            if (x - ptx < brk.minwid or x > c) x = ptx + brk.minwid;
            return x - ptx;
        },
    }
}

fn isRun(f: *const Frame, i: usize) bool {
    return f.boxes.items[i].kind == .run;
}

/// `_frclean` (frutil.c:86-111): merge adjacent run boxes that fit together on a
/// line (indices `[lo, hi)`), then walk to the end to set `lastlinefull`. `hi`
/// shrinks as merges consume boxes (mirrors the C's `n1--`).
pub fn clean(f: *Frame, pt0: Point, lo: usize, hi0: usize) Frame.Error!void {
    const c = f.r.max.x;
    var pt = pt0;
    var hi = hi0;
    var nb = lo;
    while (nb + 1 < hi) : (nb += 1) {
        ckLineWrap(f, &pt, &f.boxes.items[nb]);
        while (isRun(f, nb) and nb + 1 < hi and isRun(f, nb + 1) and
            pt.x + f.boxes.items[nb].wid + f.boxes.items[nb + 1].wid < c)
        {
            try f.mergeBox(nb);
            hi -= 1;
        }
        advance(f, &pt, &f.boxes.items[nb]);
    }
    while (nb < f.boxes.items.len) : (nb += 1) {
        ckLineWrap(f, &pt, &f.boxes.items[nb]);
        advance(f, &pt, &f.boxes.items[nb]);
    }
    f.lastlinefull = pt.y >= f.r.max.y;
}

/// `_frptofcharptb` (frptofchar.c:7-34): the point of rune `p0`, starting from
/// point `pt0` at box `bn0`, scanning at most `limit` boxes. Walks lines via
/// `ckLineWrap`/`advance`, then steps into the containing run box rune-by-rune.
fn ptOfCharLimited(f: *const Frame, p0: usize, pt0: Point, bn0: usize, limit: usize) Point {
    var pt = pt0;
    var p = p0;
    var bn = bn0;
    while (bn < limit) : (bn += 1) {
        const b = &f.boxes.items[bn];
        ckLineWrap(f, &pt, b);
        const l = b.nrune();
        if (p < l) {
            if (b.kind == .run and b.kind.run.nrune > 0) {
                const text = b.kind.run.text;
                var i: usize = 0;
                var rem = p;
                while (rem > 0) : (rem -= 1) {
                    const g = runeAt(f.font, text, i);
                    pt.x += g.w;
                    i += g.len;
                    if (pt.x > f.r.max.x) @panic("frptofchar"); // frptofchar.c:26 (I-5)
                }
            }
            break;
        }
        p -= l;
        advance(f, &pt, b);
    }
    return pt;
}

/// `_frptofcharptb` (frptofchar.c:7-34): full-box-list variant.
pub fn ptOfCharPtB(f: *const Frame, p: usize, pt: Point, bn: usize) Point {
    return ptOfCharLimited(f, p, pt, bn, f.boxes.items.len);
}

/// `frptofchar` (frptofchar.c:36-40).
pub fn ptOfChar(f: *const Frame, p: usize) Point {
    return ptOfCharLimited(f, p, f.r.min, 0, f.boxes.items.len);
}

/// `_frptofcharnb` (frptofchar.c:42-53): like `ptOfChar` but only the first
/// `nbox_limit` boxes count. DIVERGENCE (frame contract §util): the limit is a
/// PARAMETER rather than a temporary mutation of `f.nbox`, so `f` stays const.
pub fn ptOfCharN(f: *const Frame, p: usize, nbox_limit: usize) Point {
    return ptOfCharLimited(f, p, f.r.min, 0, nbox_limit);
}

/// `_frgrid` (frptofchar.c:55-65): snap `p` down to the line grid and clamp x.
fn grid(f: *const Frame, p0: Point) Point {
    var p = p0;
    p.y -= f.r.min.y;
    p.y -= @rem(p.y, fontHeight(f));
    p.y += f.r.min.y;
    if (p.x > f.r.max.x) p.x = f.r.max.x;
    return p;
}

/// `frcharofpt` (frptofchar.c:67-115): the rune index nearest device point `pt`
/// — advance whole lines, then advance within the target line. A break box's huge
/// `wid` (the '\n' 5000 seed) keeps `qt.x+wid > pt.x`, so a click at/past a break
/// lands ON it, not after (the overshoot the contract forbids "fixing").
pub fn charOfPt(f: *const Frame, pt0: Point) usize {
    const pt = grid(f, pt0);
    var qt = f.r.min;
    var p: usize = 0;
    var bn: usize = 0;
    const n = f.boxes.items.len;
    while (bn < n and qt.y < pt.y) : (bn += 1) {
        const b = &f.boxes.items[bn];
        ckLineWrap(f, &qt, b);
        if (qt.y >= pt.y) break;
        advance(f, &qt, b);
        p += b.nrune();
    }
    while (bn < n and qt.x <= pt.x) : (bn += 1) {
        const b = &f.boxes.items[bn];
        ckLineWrap(f, &qt, b);
        if (qt.y > pt.y) break;
        if (qt.x + b.wid > pt.x) {
            if (b.kind == .brk) {
                advance(f, &qt, b);
            } else {
                const text = b.kind.run.text;
                var i: usize = 0;
                while (true) {
                    if (i >= text.len) @panic("frcharofpt end of string"); // I-5
                    const g = runeAt(f.font, text, i);
                    qt.x += g.w;
                    i += g.len;
                    if (qt.x > pt.x) break;
                    p += 1;
                }
            }
        } else {
            p += b.nrune();
            advance(f, &qt, b);
        }
    }
    return p;
}

// ==========================================================================
// Tests (frame contract §"Named tests"): the ptofchar/charofpt round-trip. The
// FakeDrawTree+Pipe fixture is defined ONCE in Frame.zig (R-P4-5) and shared.
// ==========================================================================
const testing = std.testing;

test "frame: ptofchar/charofpt round-trip" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    try f.insert("hello, acme wraps\nsecond line\ttab", 0);
    try testing.expectEqual(@as(usize, 33), f.nchars);

    // Contract pins: p -> ptOfChar(p).
    try testing.expectEqual(Point{ .x = 20, .y = 20 }, ptOfChar(&f, 0));
    try testing.expectEqual(Point{ .x = 20, .y = 38 }, ptOfChar(&f, 11));
    try testing.expectEqual(Point{ .x = 74, .y = 38 }, ptOfChar(&f, 17));
    try testing.expectEqual(Point{ .x = 20, .y = 56 }, ptOfChar(&f, 18));
    try testing.expectEqual(Point{ .x = 20, .y = 74 }, ptOfChar(&f, 29));
    try testing.expectEqual(Point{ .x = 92, .y = 74 }, ptOfChar(&f, 30));
    try testing.expectEqual(Point{ .x = 119, .y = 74 }, ptOfChar(&f, 33));

    // Round-trip: the left edge of every rune's cell maps back to its index,
    // including the two break positions (17 '\n', 29 '\t') that rely on the
    // break-box overshoot.
    var p: usize = 0;
    while (p <= 33) : (p += 1) {
        try testing.expectEqual(p, charOfPt(&f, ptOfChar(&f, p)));
    }

    // Mid-cell rounding: a click 4px into a cell floors to that cell's char.
    const p11 = ptOfChar(&f, 11);
    try testing.expectEqual(@as(usize, 11), charOfPt(&f, .{ .x = p11.x + 4, .y = p11.y }));
    const p30 = ptOfChar(&f, 30);
    try testing.expectEqual(@as(usize, 30), charOfPt(&f, .{ .x = p30.x + 4, .y = p30.y }));

    // Below-text clamp: a click below the last line returns nchars.
    try testing.expectEqual(@as(usize, 33), charOfPt(&f, .{ .x = 20, .y = 460 }));
    // Clamp past the right edge on the first line lands on the wrap boundary (11).
    try testing.expectEqual(@as(usize, 11), charOfPt(&f, .{ .x = 500, .y = 20 }));
}
