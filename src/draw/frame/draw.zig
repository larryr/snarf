//! Frame painting + the pure layout pass — libframe `frdraw.c` (drawText/draw0/
//! drawSel0/drawSel/redraw) plus `frselect.c:105-132` (selectPaint, moved here
//! because insert.zig needs it). Ported from larryr/plan9port@337c6ac; cite as
//! `frdraw.c:NN` / `frselect.c:NN`.
//!
//! `stringbg`/`stringnbg` (C draws background+glyphs in one call) DECOMPOSE into
//! two draw-client ops (ADR-0003 §S-03): a background rectangle via `Image.draw`
//! ('d') followed by `Font.drawString` ('s'), which draws only the glyphs. The
//! 's' baseline is `pt.y + ascent` (Font.drawString handles that). Break boxes
//! paint no glyphs; the pen still advances by `wid`.
const std = @import("std");
const proto = @import("../proto.zig");
const Image = @import("../Image.zig");
const Frame = @import("Frame.zig");
const util = @import("util.zig");

const Point = proto.Point;
const Rect = proto.Rect;

/// `_frdrawtext` (frdraw.c:7-19): paint each box at its wrapped position with
/// (`text` fg, `back` bg). `noredraw` suppresses the glyphs/background but the
/// pen still advances (frdraw.c:15-18). Used by insert to paint freshly inserted
/// runs; `f` may be the scratch frame (its `b`/`font`/`r` alias the real one).
pub fn drawText(f: *Frame, pt0: Point, text: *Image, back: *Image) Frame.Error!void {
    const h = util.fontHeight(f);
    var pt = pt0;
    for (f.boxes.items) |*b| {
        util.ckLineWrap(f, &pt, b);
        if (!f.noredraw and b.kind == .run) {
            try f.b.draw(Rect.make(pt.x, pt.y, pt.x + b.wid, pt.y + h), back, null, .{});
            _ = try f.font.drawString(f.b, pt, text, b.kind.run.text);
        }
        pt.x += b.wid;
    }
}

/// `_frdraw` (frdraw.c:174-205): the PURE layout pass — walk the boxes, wrap and
/// split runs at `canFit`, resolve tab widths via `newWid`, and truncate (delBox)
/// everything from the first box that would fall on the line past `r.max.y`.
/// Emits nothing; returns the pen point after the last laid-out box.
pub fn draw0(f: *Frame, pt0: Point) Frame.Error!Point {
    const h = util.fontHeight(f);
    var pt = pt0;
    var nb: usize = 0;
    while (nb < f.boxes.items.len) {
        util.ckLineWrap0(f, &pt, &f.boxes.items[nb]);
        if (pt.y == f.r.max.y) {
            f.nchars -= f.strLen(nb);
            f.delBox(nb, f.boxes.items.len - 1);
            break;
        }
        const b = &f.boxes.items[nb];
        if (b.kind == .run and b.kind.run.nrune > 0) {
            const n = util.canFit(f, pt, b);
            if (n == 0) break;
            if (n != b.kind.run.nrune) try f.splitBox(nb, n); // I-4: b invalid now
            pt.x += f.boxes.items[nb].wid;
        } else if (b.kind.brk.bc == '\n') {
            pt.x = f.r.min.x;
            pt.y += h;
        } else {
            pt.x += util.newWid(f, pt, &f.boxes.items[nb]);
        }
        nb += 1;
    }
    return pt;
}

/// `frdrawsel0` (frdraw.c:57-119): paint the rune range `[p0, p1)` with
/// (`text`, `back`), handling partial start/end boxes (byte-sliced via
/// `runeByteIndex`), the x clamp at the right edge (frdraw.c:100-102), and both
/// wrapped-line back-fills (frdraw.c:80-84, 111-117). Returns the pen after the
/// last painted box. Phase-4 redraw drives the whole-frame case.
pub fn drawSel0(f: *Frame, pt0: Point, p0: usize, p1: usize, back: *Image, text: *Image) Frame.Error!Point {
    if (p0 > p1) @panic("frdrawsel0 p0>p1"); // frdraw.c:67 (I-5)
    const h = util.fontHeight(f);
    var pt = pt0;
    var p: usize = 0;
    var nb: usize = 0;
    var trim = false;
    const nboxes = f.boxes.items.len;
    while (nb < nboxes and p < p1) : (nb += 1) {
        const b = &f.boxes.items[nb];
        var nr = b.nrune();
        if (p + nr <= p0) { // wholly before the region
            p += nr;
            continue;
        }
        if (p >= p0) { // start of a (possibly wrapped) region line
            const qt = pt;
            util.ckLineWrap(f, &pt, b);
            if (pt.y > qt.y)
                try f.b.draw(Rect.make(qt.x, qt.y, f.r.max.x, pt.y), back, null, .{});
        }
        var byteoff: usize = 0;
        if (p < p0) { // advance into the box to p0
            byteoff = util.runeByteIndex(b.kind.run.text, p0 - p);
            nr -= (p0 - p);
            p = p0;
        }
        trim = false;
        if (p + nr > p1) { // trim the box to the region end
            nr -= (p + nr) - p1;
            trim = true;
        }
        const w = if (b.kind == .brk or nr == b.nrune())
            b.wid
        else
            util.stringNWidth(f.font, b.kind.run.text[byteoff..], nr);
        var x = pt.x + w;
        if (x > f.r.max.x) x = f.r.max.x; // frdraw.c:100-102
        try f.b.draw(Rect.make(pt.x, pt.y, x, pt.y + h), back, null, .{});
        if (b.kind == .run) {
            const end = byteoff + util.runeByteIndex(b.kind.run.text[byteoff..], nr);
            _ = try f.font.drawString(f.b, pt, text, b.kind.run.text[byteoff..end]);
        }
        pt.x += w;
        p += nr;
    }
    // Trailing back-fill for the last plain-text box on a wrapped line.
    if (p1 > p0 and nb > 0 and nb < nboxes and
        f.boxes.items[nb - 1].kind == .run and f.boxes.items[nb - 1].kind.run.nrune > 0 and !trim)
    {
        const qt = pt;
        util.ckLineWrap(f, &pt, &f.boxes.items[nb]);
        if (pt.y > qt.y)
            try f.b.draw(Rect.make(qt.x, qt.y, f.r.max.x, pt.y), back, null, .{});
    }
    return pt;
}

/// `frdrawsel` (frdraw.c:33-55): the selection-shape entry. Phase-4 callers pass
/// `issel = false`; a zero-length range routes to the no-op tick.
pub fn drawSel(f: *Frame, pt: Point, p0: usize, p1: usize, issel: bool) Frame.Error!void {
    if (p0 == p1) {
        tick(f, pt, issel);
        return;
    }
    const back = if (issel) f.col(.high) else f.col(.back);
    const text = if (issel) f.col(.htext) else f.col(.text);
    _ = try drawSel0(f, pt, p0, p1, back, text);
}

/// `frredraw` (frdraw.c:121-141): repaint the frame. Phase-4 exercises the
/// `p0==p1` arm — a full-frame `drawSel0` with (back, text).
pub fn redraw(f: *Frame) Frame.Error!void {
    if (f.p0 == f.p1) {
        _ = try drawSel0(f, util.ptOfChar(f, 0), 0, f.nchars, f.col(.back), f.col(.text));
        return;
    }
    var pt = util.ptOfChar(f, 0);
    pt = try drawSel0(f, pt, 0, f.p0, f.col(.back), f.col(.text));
    pt = try drawSel0(f, pt, f.p0, f.p1, f.col(.high), f.col(.htext));
    pt = try drawSel0(f, pt, f.p1, f.nchars, f.col(.back), f.col(.text));
}

/// `frselectpaint` (frselect.c:105-132): fill the selection region `[p0,p1]`
/// (device points) with `col` — one rectangle when it stays on a line, else a
/// head/middle/tail triple.
pub fn selectPaint(f: *Frame, p0: Point, p1: Point, col: *Image) Frame.Error!void {
    const h = util.fontHeight(f);
    var q0 = p0;
    q0.y += h;
    var q1 = p1;
    q1.y += h;
    const n = @divTrunc(p1.y - p0.y, h);
    if (p0.y == f.r.max.y) return; // frselect.c:118-119
    if (n == 0) {
        try f.b.draw(Rect.make(p0.x, p0.y, q1.x, q1.y), col, null, .{});
    } else {
        var pp0 = p0;
        if (pp0.x >= f.r.max.x) pp0.x = f.r.max.x - 1;
        try f.b.draw(Rect.make(pp0.x, pp0.y, f.r.max.x, q0.y), col, null, .{});
        if (n > 1)
            try f.b.draw(Rect.make(f.r.min.x, q0.y, f.r.max.x, p1.y), col, null, .{});
        try f.b.draw(Rect.make(f.r.min.x, p1.y, q1.x, q1.y), col, null, .{});
    }
}

/// `frtick` (frdraw.c:163-172): typing-tick — a no-op stub in phase 4 (tick
/// images are deferred to phase 6, R-P4-6).
pub fn tick(f: *Frame, pt: Point, ticked: bool) void {
    _ = f;
    _ = pt;
    _ = ticked;
}

// ==========================================================================
// Tests (frame contract §"Named tests"): the drawText write stream. Fixture per
// R-P4-5 (Frame.TestFixture).
// ==========================================================================
const testing = std.testing;

test "frame: drawtext write stream" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    // Insert "ab" into the empty frame: the only wire traffic is selectPaint's
    // 'd' then drawText's 'd' (background) + 's' (glyphs). Flush to inspect it.
    const base = fx.tree.writes.items.len;
    try f.insert("ab", 0);
    try fx.disp.flush();
    try testing.expectEqual(base + 1, fx.tree.writes.items.len);
    const w = fx.tree.writes.items[base];

    const white = fx.disp.white.id; // back = high = white (slot 0)
    const black = fx.disp.black.id; // text = black (slot 3)

    // [0] selectPaint 'd': dst=display(0), src=white, mask=white (nil), rect
    //     (20,20)-(38,38) [wid 18, height 18], sp=mp=ZP.
    var expect_sel: [45]u8 = undefined;
    _ = try proto.encode(.{ .draw = .{
        .dstid = 0,
        .srcid = white,
        .maskid = white,
        .r = proto.Rect.make(20, 20, 38, 38),
    } }, expect_sel[0..45]);
    try testing.expectEqualSlices(u8, &expect_sel, w[0..45]);

    // [45] drawText background 'd': identical rect/colors (same white fill).
    try testing.expectEqualSlices(u8, &expect_sel, w[45..90]);

    // [90] drawText glyphs 's': dst=0, src=black, font cache, baseline (20,33),
    //      clipr = display clipr, indices {'a','b'} (identity cache slots).
    const s = w[90..];
    try testing.expectEqual(@as(u8, 's'), s[0]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, s[1..5], .little));
    try testing.expectEqual(black, std.mem.readInt(u32, s[5..9], .little));
    try testing.expectEqual(fx.font.cache.id, std.mem.readInt(u32, s[9..13], .little));
    try testing.expectEqual(@as(i32, 20), std.mem.readInt(i32, s[13..17], .little)); // p.x
    try testing.expectEqual(@as(i32, 33), std.mem.readInt(i32, s[17..21], .little)); // baseline
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, s[45..47], .little)); // ni
    try testing.expectEqual(@as(u16, 'a'), std.mem.readInt(u16, s[47..49], .little));
    try testing.expectEqual(@as(u16, 'b'), std.mem.readInt(u16, s[49..51], .little));
    try testing.expectEqual(@as(u8, 'v'), s[51]); // flush verb

    // Box state after the insert.
    try testing.expectEqual(@as(usize, 1), f.boxes.items.len);
    try testing.expectEqual(@as(usize, 2), f.nchars);
    try testing.expectEqual(@as(usize, 1), f.nlines);
    try testing.expectEqual(false, f.lastlinefull);
}
