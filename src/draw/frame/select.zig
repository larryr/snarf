//! Incremental mouse selection — libframe `frselect.c:7-103` (larryr/plan9port@
//! 337c6ac; cite as `frselect.c:NN`) recast as an explicit state machine. The C
//! `frselect` runs its own `readmouse` loop and calls `scroll`/`flushimage`;
//! R-P6-9 (F-1/F-7) mandates an INCREMENTAL `SelectState` driven one mouse event
//! at a time by the editor, with scrolling dropped (org is fixed). So the loop
//! body (frselect.c:58-96) becomes `selectUpdate`, the pre-loop setup
//! (frselect.c:28-36) becomes `selectBegin`, and `flushimage`/`readmouse`/the
//! `scroll` block (frselect.c:38-57,96-101) are dropped.
//!
//! The gesture repaints only the DELTA between the old and new sweep endpoints
//! (each `drawSel` extends or retracts one wing), never the whole selection.
const std = @import("std");
const proto = @import("../proto.zig");
const Image = @import("../Image.zig");
const Frame = @import("Frame.zig");
const util = @import("util.zig");
const drawmod = @import("draw.zig");

const Point = proto.Point;

/// `region` (frselect.c:7-16): sign of `a - b`, in {-1, 0, 1}.
fn region(a: usize, b: usize) i8 {
    if (a < b) return -1;
    if (a == b) return 0;
    return 1;
}

/// The live sweep state. `p0` is the fixed anchor (where B1 went down); `p1` is
/// the moving end; `pt0`/`pt1` are their device points; `reg == region(p1, p0)`
/// records which side of the anchor the sweep is on (frselect.c:8-16,36).
pub const SelectState = struct {
    f: *Frame,
    p0: usize,
    p1: usize,
    pt0: Point,
    pt1: Point,
    reg: i8,
};

/// `frselect` setup (frselect.c:28-36, minus the mouse read): un-draw the old
/// selection, drop the caret at the click point, and show the tick there. B1 is
/// assumed already down. Returns the initial `SelectState` (`reg = 0`).
pub fn selectBegin(f: *Frame, mp: Point) Frame.Error!SelectState {
    f.modified = false; // frselect.c:28
    try drawmod.drawSel(f, util.ptOfChar(f, f.p0), f.p0, f.p1, false); // frselect.c:29 un-draw old
    const p = util.charOfPt(f, mp); // frselect.c:30
    f.p0 = p; // frselect.c:31-32
    f.p1 = p;
    const pt = util.ptOfChar(f, p); // frselect.c:33-34 (pt0 == pt1, p0 == p1)
    try drawmod.drawSel(f, pt, p, p, true); // frselect.c:35 shows the tick
    return .{ .f = f, .p0 = p, .p1 = p, .pt0 = pt, .pt1 = pt, .reg = 0 }; // frselect.c:36
}

/// One iteration of the `frselect` loop body (frselect.c:58-96, minus scroll):
/// map `mp` to a char `q`, and if the moving end changed, repaint the delta —
/// resetting across the anchor (frselect.c:61-70), then extending or retracting
/// the appropriate wing (forward frselect.c:73-77, backward :78-83). Finally
/// commit the ordered selection into `f.p0`/`f.p1` (frselect.c:87-95).
pub fn selectUpdate(s: *SelectState, mp: Point) Frame.Error!void {
    const f = s.f;
    const q = util.charOfPt(f, mp); // frselect.c:59
    if (s.p1 != q) { // frselect.c:60
        if (s.reg != region(q, s.p0)) { // frselect.c:61 crossed the anchor; reset
            if (s.reg > 0) {
                try drawmod.drawSel(f, s.pt0, s.p0, s.p1, false); // frselect.c:63
            } else if (s.reg < 0) {
                try drawmod.drawSel(f, s.pt1, s.p1, s.p0, false); // frselect.c:65
            }
            s.p1 = s.p0; // frselect.c:66-67
            s.pt1 = s.pt0;
            s.reg = region(q, s.p0); // frselect.c:68
            if (s.reg == 0) try drawmod.drawSel(f, s.pt0, s.p0, s.p1, true); // frselect.c:69-70
        }
        const qt = util.ptOfChar(f, q); // frselect.c:72
        if (s.reg > 0) { // frselect.c:73 forward wing
            if (q > s.p1) {
                try drawmod.drawSel(f, s.pt1, s.p1, q, true); // frselect.c:75 extend
            } else if (q < s.p1) {
                try drawmod.drawSel(f, qt, q, s.p1, false); // frselect.c:77 retract
            }
        } else if (s.reg < 0) { // frselect.c:78 backward wing
            if (q > s.p1) {
                try drawmod.drawSel(f, s.pt1, s.p1, q, false); // frselect.c:80 retract
            } else {
                try drawmod.drawSel(f, qt, q, s.p1, true); // frselect.c:82 extend
            }
        }
        s.p1 = q; // frselect.c:84-85
        s.pt1 = qt;
    }
    f.modified = false; // frselect.c:87
    if (s.p0 < s.p1) { // frselect.c:88-95 ordered commit
        f.p0 = s.p0;
        f.p1 = s.p1;
    } else {
        f.p0 = s.p1;
        f.p1 = s.p0;
    }
}

/// Terminal event (B1 up): the C loop simply exits after its final `selectUpdate`
/// has already committed `f.p0`/`f.p1`, so the release point is one last update.
pub fn selectEnd(s: *SelectState, mp: Point) Frame.Error!void {
    try selectUpdate(s, mp);
}

// ==========================================================================
// The B2/B3 colored sweep — `xselect`/`selrestore` (acme/text.c:1160-1341).
// Unlike `SelectState` (B1's frselect port), this sweep NEVER writes `f.p0`/
// `f.p1`: the real selection is left in place and the swept range is painted as
// a TEMPORARY overlay (colored background, WHITE glyphs) that is fully un-painted
// via `selRestore` at exit. One machine serves both buttons, parameterized by
// `col` (but2col red / but3col green), exactly as the C's `textselect23`
// (text.c:1343-1359) parameterizes `xselect` by `high`. R-P9-1/R-P9-2.
// ==========================================================================

/// Release the button in less than `DELAY` ms with less than `MINMOVE` px of
/// travel and it is treated as a null selection (text.c:1255-1258).
const DELAY: u32 = 2;
const MINMOVE: u32 = 4;

/// `xselect`'s live colored sweep state (text.c:1260-1341). `p0` is the fixed
/// anchor, `p1` the moving end (both FRAME coords); `pt0`/`pt1` are their device
/// points; `reg == region(p1, p0)`. `col` is the sweep-highlight image (glyphs
/// paint in `f.display.white`). `start_pt`/`start_msec` drive the DELAY/MINMOVE
/// null-click test at exit (text.c:1268-1270, 1317-1325).
pub const Select23State = struct {
    f: *Frame,
    col: *Image,
    p0: usize,
    p1: usize,
    pt0: Point,
    pt1: Point,
    reg: i8,
    start_pt: Point,
    start_msec: u32,
};

/// `xselect` setup (text.c:1268-1279): record the press point/time, lift the real
/// caret tick if the selection is a caret, drop the anchor at the click point, and
/// tick the anchor. The button is assumed already down. Returns `reg = 0`.
pub fn select23Begin(f: *Frame, mp: Point, col: *Image, msec: u32) Frame.Error!Select23State {
    if (f.p0 == f.p1) try drawmod.tick(f, util.ptOfChar(f, f.p0), false); // text.c:1272-1274
    const p = util.charOfPt(f, mp); // text.c:1275
    const pt = util.ptOfChar(f, p); // text.c:1276-1277 (pt0 == pt1, p0 == p1)
    try drawmod.tick(f, pt, true); // text.c:1279 tick the anchor
    return .{
        .f = f,
        .col = col,
        .p0 = p,
        .p1 = p,
        .pt0 = pt,
        .pt1 = pt,
        .reg = 0, // text.c:1278
        .start_pt = mp,
        .start_msec = msec,
    };
}

/// One iteration of the `xselect` loop body (text.c:1280-1313, minus flushimage/
/// readmouse): map `mp` to char `q`; if the moving end changed, lift the anchor
/// tick, reset across the anchor (repainting via `selRestore`), then extend the
/// wing with `drawSel0(.., col, white)` or retract it with `selRestore`; re-show
/// the anchor tick when the sweep collapses back to the caret.
pub fn select23Update(s: *Select23State, mp: Point) Frame.Error!void {
    const f = s.f;
    const white = &f.display.white; // text.c:1294 frdrawsel0(.., col, display->white)
    const q = util.charOfPt(f, mp); // text.c:1281
    if (s.p1 != q) { // text.c:1282
        if (s.p0 == s.p1) try drawmod.tick(f, s.pt0, false); // text.c:1283-1284
        if (s.reg != region(q, s.p0)) { // text.c:1285 crossed the anchor; reset
            if (s.reg > 0) {
                try selRestore(f, s.pt0, s.p0, s.p1); // text.c:1287
            } else if (s.reg < 0) {
                try selRestore(f, s.pt1, s.p1, s.p0); // text.c:1289
            }
            s.p1 = s.p0; // text.c:1290-1291
            s.pt1 = s.pt0;
            s.reg = region(q, s.p0); // text.c:1292
            if (s.reg == 0) _ = try drawmod.drawSel0(f, s.pt0, s.p0, s.p1, s.col, white); // text.c:1293-1294
        }
        const qt = util.ptOfChar(f, q); // text.c:1296
        if (s.reg > 0) { // text.c:1297 forward wing
            if (q > s.p1) {
                _ = try drawmod.drawSel0(f, s.pt1, s.p1, q, s.col, white); // text.c:1299 extend
            } else if (q < s.p1) {
                try selRestore(f, qt, q, s.p1); // text.c:1302 retract
            }
        } else if (s.reg < 0) { // text.c:1303 backward wing
            if (q > s.p1) {
                try selRestore(f, s.pt1, s.p1, q); // text.c:1305 retract
            } else {
                _ = try drawmod.drawSel0(f, qt, q, s.p1, s.col, white); // text.c:1307 extend
            }
        }
        s.p1 = q; // text.c:1309-1310
        s.pt1 = qt;
    }
    if (s.p0 == s.p1) try drawmod.tick(f, s.pt0, true); // text.c:1312-1313
}

/// `xselect` exit tail (text.c:1317-1340). Folds the final (button-change) sample
/// into the sweep first (R-P9-2), then applies the <DELAY ms/<MINMOVE px null-
/// click collapse, orders `p0 <= p1`, un-paints the WHOLE swept range with
/// `selRestore` (the overlay vanishes), and restores the tick if the REAL
/// selection is a caret. `f.p0`/`f.p1` are byte-identically untouched. Returns
/// the swept FRAME range; the caller decides commit vs cancel.
pub fn select23End(s: *Select23State, mp: Point, msec: u32) Frame.Error!struct { p0: usize, p1: usize } {
    try select23Update(s, mp); // fold the final sample in (R-P9-2)
    const f = s.f;
    // text.c:1317-1325: released < DELAY ms after the press with < MINMOVE px of
    // travel ⇒ collapse the accidental micro-sweep back to the anchor.
    if (msec -% s.start_msec < DELAY and s.p0 != s.p1 and
        @abs(s.start_pt.x - mp.x) < MINMOVE and @abs(s.start_pt.y - mp.y) < MINMOVE)
    {
        if (s.reg > 0) {
            try selRestore(f, s.pt0, s.p0, s.p1); // text.c:1321
        } else if (s.reg < 0) {
            try selRestore(f, s.pt1, s.p1, s.p0); // text.c:1323
        }
        s.p1 = s.p0; // text.c:1324
    }
    if (s.p1 < s.p0) { // text.c:1326-1330 order p0 <= p1
        const tmp = s.p0;
        s.p0 = s.p1;
        s.p1 = tmp;
    }
    s.pt0 = util.ptOfChar(f, s.p0); // text.c:1331
    if (s.p0 == s.p1) try drawmod.tick(f, s.pt0, false); // text.c:1332-1333
    try selRestore(f, s.pt0, s.p0, s.p1); // text.c:1334 the overlay vanishes
    if (f.p0 == f.p1) try drawmod.tick(f, util.ptOfChar(f, f.p0), true); // text.c:1336-1337
    return .{ .p0 = s.p0, .p1 = s.p1 };
}

/// `selrestore` (text.c:1160-1189): repaint `[p0, p1)` split against the REAL
/// `f.p0`/`f.p1` — (BACK, TEXT) outside the selection, (HIGH, HTEXT) inside. This
/// is how the colored sweep is un-painted without ever disturbing `f.p0`/`f.p1`.
fn selRestore(f: *Frame, pt0: Point, p0: usize, p1: usize) Frame.Error!void {
    if (p1 <= f.p0 or p0 >= f.p1) { // text.c:1163-1167 no overlap
        _ = try drawmod.drawSel0(f, pt0, p0, p1, f.col(.back), f.col(.text));
        return;
    }
    if (p0 >= f.p0 and p1 <= f.p1) { // text.c:1168-1172 entirely inside
        _ = try drawmod.drawSel0(f, pt0, p0, p1, f.col(.high), f.col(.htext));
        return;
    }
    // text.c:1174-1188: known to overlap.
    var lp0 = p0;
    var lpt0 = pt0;
    if (lp0 < f.p0) { // before the selection
        _ = try drawmod.drawSel0(f, lpt0, lp0, f.p0, f.col(.back), f.col(.text));
        lp0 = f.p0;
        lpt0 = util.ptOfChar(f, lp0);
    }
    var lp1 = p1;
    if (lp1 > f.p1) { // after the selection
        _ = try drawmod.drawSel0(f, util.ptOfChar(f, f.p1), f.p1, lp1, f.col(.back), f.col(.text));
        lp1 = f.p1;
    }
    _ = try drawmod.drawSel0(f, lpt0, lp0, lp1, f.col(.high), f.col(.htext)); // inside
}

// ==========================================================================
// Tests (editing side contract §"A4 named tests"). Fixture per R-P4-5
// (Frame.TestFixture); expectations hand-computed from fixed-9x18 metrics.
// ==========================================================================
const testing = std.testing;

/// Count the draw-ish verbs ('d', 's') in one flushed write, ignoring 'v'. Used
/// to prove the sweep repaints only the DELTA, not the whole selection.
fn countOps(buf: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < buf.len) {
        switch (buf[i]) {
            'v' => i += 1,
            'd' => {
                i += 45;
                n += 1;
            },
            's' => {
                const ni = std.mem.readInt(u16, buf[i + 45 ..][0..2], .little);
                i += 47 + 2 * ni;
                n += 1;
            },
            else => return n,
        }
    }
    return n;
}

test "frame: select begin places tick and clears old selection" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);
    try f.insert("abcde", 0);
    try f.initTick();
    // Establish and paint an old selection [1,3).
    f.p0 = 1;
    f.p1 = 3;
    try f.redraw();

    try fx.disp.flush(); // drain insert/initTick/redraw draws before the baseline
    const base = fx.tree.writes.items.len;
    // Click at char 4 (ptOfChar(4) == (56,20)).
    const s = try selectBegin(&f, f.ptOfChar(4));
    try fx.disp.flush();

    try testing.expectEqual(@as(usize, 4), s.p0);
    try testing.expectEqual(@as(usize, 4), s.p1);
    try testing.expectEqual(@as(usize, 4), f.p0);
    try testing.expectEqual(@as(usize, 4), f.p1);
    try testing.expect(f.ticked); // caret tick placed
    try testing.expect(!f.modified);

    // First op un-draws the old [1,3) selection: a BACK background 'd' over
    // ptOfChar(1)=(29,20) .. two cells .. (47,38).
    const w = fx.tree.writes.items[base];
    const white = fx.disp.white.id;
    var exp: [45]u8 = undefined;
    _ = try proto.encode(.{ .draw = .{ .dstid = 0, .srcid = white, .maskid = white, .r = proto.Rect.make(29, 20, 47, 38) } }, exp[0..45]);
    try testing.expectEqualSlices(u8, &exp, w[0..45]);
}

test "frame: select sweep forward then retract" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);
    try f.insert("abcdefghij", 0);
    // No initTick: isolate the selection-delta draws (a tick would add noise).
    var s = try selectBegin(&f, f.ptOfChar(2));

    try fx.disp.flush(); // drain the insert draws before the baseline
    const base = fx.tree.writes.items.len;
    try selectUpdate(&s, f.ptOfChar(5)); // extend  [2,5)
    try selectUpdate(&s, f.ptOfChar(4)); // retract [2,4)
    try fx.disp.flush();

    try testing.expectEqual(@as(usize, 2), f.p0);
    try testing.expectEqual(@as(usize, 4), f.p1);
    // Delta-only: extend = bg+glyph, retract = bg+glyph ⇒ exactly 4 ops, NOT a
    // whole-selection repaint.
    try testing.expectEqual(@as(usize, 4), countOps(fx.tree.writes.items[base]));
}

test "frame: select crosses the anchor" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);
    try f.insert("abcdefghij", 0);
    var s = try selectBegin(&f, f.ptOfChar(5)); // anchor at 5

    try selectUpdate(&s, f.ptOfChar(7)); // forward [5,7), reg +1
    try testing.expectEqual(@as(i8, 1), s.reg);
    try testing.expectEqual(@as(usize, 5), f.p0);
    try testing.expectEqual(@as(usize, 7), f.p1);

    try selectUpdate(&s, f.ptOfChar(3)); // cross the anchor ⇒ [3,5), reg -1
    try testing.expectEqual(@as(i8, -1), s.reg);
    try testing.expectEqual(@as(usize, 3), f.p0);
    try testing.expectEqual(@as(usize, 5), f.p1);
}

test "frame: select across lines" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);
    try f.insert("hello, acme wraps\nsecond line\ttab", 0);
    var s = try selectBegin(&f, f.ptOfChar(0));
    try selectEnd(&s, f.ptOfChar(20)); // sweep over the wrap + newline to L3
    try testing.expectEqual(@as(usize, 0), f.p0);
    try testing.expectEqual(@as(usize, 20), f.p1);
    try testing.expectEqual(@as(i8, 1), s.reg);
}

/// Record the byte offset of every 'd' (draw) op in one flushed write, walking
/// past 's' (variable-length) and 'v' verbs. Returns the count.
fn drawOffsets(buf: []const u8, out: []usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < buf.len) {
        switch (buf[i]) {
            'v' => i += 1,
            'd' => {
                if (n < out.len) out[n] = i;
                n += 1;
                i += 45;
            },
            's' => {
                const ni = std.mem.readInt(u16, buf[i + 45 ..][0..2], .little);
                i += 47 + 2 * ni;
            },
            else => return n,
        }
    }
    return n;
}

test "frame: select23 colored sweep paints and restores (write-stream)" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);
    try f.insert("abcdefghij", 0);
    // A distinct sweep-highlight image so its id is unmistakable in the stream.
    var col = try fx.disp.allocImage(proto.Rect.make(0, 0, 1, 1), fx.disp.image.chan, true, 0xAA0000FF);
    defer col.free() catch {};
    const white = fx.disp.white.id;
    const black = fx.disp.black.id;

    // A REAL selection at [1,3) that the sweep must never disturb.
    f.p0 = 1;
    f.p1 = 3;
    try f.redraw();
    try fx.disp.flush();

    // Sweep [5,8) — a colored overlay far outside the real selection.
    var s = try select23Begin(&f, f.ptOfChar(5), &col, 100);
    try fx.disp.flush(); // begin emits no draws (no tick image); clean baseline
    const base_paint = fx.tree.writes.items.len;
    try select23Update(&s, f.ptOfChar(8));
    try fx.disp.flush();

    // The sweep paints [5,8) with `col` background + WHITE glyphs (text.c:1294).
    const wp = fx.tree.writes.items[base_paint];
    var offs: [8]usize = undefined;
    _ = drawOffsets(wp, &offs);
    var exp: [45]u8 = undefined;
    // background 'd': dst=display(0), src=col, mask=white(nil), rect
    // ptOfChar(5)=(65,20) .. 3 cells .. (92,38).
    _ = try proto.encode(.{ .draw = .{ .dstid = 0, .srcid = col.id, .maskid = white, .r = proto.Rect.make(65, 20, 92, 38) } }, exp[0..45]);
    try testing.expectEqualSlices(u8, &exp, wp[offs[0] .. offs[0] + 45]);
    // glyph 's': src is WHITE (the sweep text color), not black.
    try testing.expectEqual(@as(u8, 's'), wp[45]);
    try testing.expectEqual(white, std.mem.readInt(u32, wp[50..54], .little));

    // End with no null-click (far in time): the overlay is restored to BACK/TEXT
    // because [5,8) is entirely outside the real [1,3) selection.
    const base_restore = fx.tree.writes.items.len;
    const r = try select23End(&s, f.ptOfChar(8), 200);
    try fx.disp.flush();

    try testing.expectEqual(@as(usize, 5), r.p0);
    try testing.expectEqual(@as(usize, 8), r.p1);
    // The real selection is byte-identically untouched.
    try testing.expectEqual(@as(usize, 1), f.p0);
    try testing.expectEqual(@as(usize, 3), f.p1);

    const wr = fx.tree.writes.items[base_restore];
    _ = drawOffsets(wr, &offs);
    // restore 'd': BACK(white) background over the same (65,20)-(92,38) rect.
    _ = try proto.encode(.{ .draw = .{ .dstid = 0, .srcid = white, .maskid = white, .r = proto.Rect.make(65, 20, 92, 38) } }, exp[0..45]);
    try testing.expectEqualSlices(u8, &exp, wr[offs[0] .. offs[0] + 45]);
    // glyphs restored in TEXT(black).
    try testing.expectEqual(black, std.mem.readInt(u32, wr[offs[0] + 45 + 5 .. offs[0] + 45 + 9][0..4], .little));

    // Tick restore when the real selection IS a caret: a fresh frame with a live
    // tick, caret at 2. The sweep lifts it at begin and restores it at end.
    var g = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer g.clear(true);
    try g.insert("abcdefghij", 0);
    g.p0 = 2;
    g.p1 = 2;
    try g.initTick();
    try drawmod.tick(&g, g.ptOfChar(2), true);
    try testing.expect(g.ticked);
    var s2 = try select23Begin(&g, g.ptOfChar(5), &col, 100);
    try testing.expect(g.ticked); // begin lifts the real caret then ticks the anchor
    try select23Update(&s2, g.ptOfChar(8));
    try testing.expect(!g.ticked); // sweep left the anchor: no tick while p0 != p1
    _ = try select23End(&s2, g.ptOfChar(8), 200);
    try testing.expect(g.ticked); // restored: f.p0 == f.p1 (text.c:1336-1337)
}

test "frame: select23 restore splits across the real selection" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    // Custom color slots so BACK and HIGH are DISTINGUISHABLE (the shared fixture
    // uses white for both): back=white, high=<red>, bord/text=black, htext=<blue>.
    var high = try fx.disp.allocImage(proto.Rect.make(0, 0, 1, 1), fx.disp.image.chan, true, 0xAA0000FF);
    defer high.free() catch {};
    var htext = try fx.disp.allocImage(proto.Rect.make(0, 0, 1, 1), fx.disp.image.chan, true, 0x0000AAFF);
    defer htext.free() catch {};
    const cols = [_]*Image{ &fx.disp.white, &high, &fx.disp.black, &fx.disp.black, &htext };
    var f = Frame.init(testing.allocator, proto.Rect.make(20, 20, 119, 470), fx.font, &fx.disp.image, cols);
    defer f.clear(true);
    try f.insert("abcdefghij", 0);
    // Real selection [1,3).
    f.p0 = 1;
    f.p1 = 3;

    try fx.disp.flush();
    const base = fx.tree.writes.items.len;
    // Restore a range [0,5) that straddles the selection on both sides.
    try selRestore(&f, f.ptOfChar(0), 0, 5);
    try fx.disp.flush();

    const w = fx.tree.writes.items[base];
    var offs: [8]usize = undefined;
    const nd = drawOffsets(w, &offs);
    try testing.expectEqual(@as(usize, 3), nd); // before, after, inside
    var exp: [45]u8 = undefined;
    const white = fx.disp.white.id;
    // [0] before-selection [0,1): BACK(white) over (20,20)-(29,38).
    _ = try proto.encode(.{ .draw = .{ .dstid = 0, .srcid = white, .maskid = white, .r = proto.Rect.make(20, 20, 29, 38) } }, exp[0..45]);
    try testing.expectEqualSlices(u8, &exp, w[offs[0] .. offs[0] + 45]);
    // [1] after-selection [3,5): BACK(white) over ptOfChar(3)=(47,20)-(65,38).
    _ = try proto.encode(.{ .draw = .{ .dstid = 0, .srcid = white, .maskid = white, .r = proto.Rect.make(47, 20, 65, 38) } }, exp[0..45]);
    try testing.expectEqualSlices(u8, &exp, w[offs[1] .. offs[1] + 45]);
    // [2] inside [1,3): HIGH(red) over ptOfChar(1)=(29,20)-(47,38), glyphs HTEXT(blue).
    _ = try proto.encode(.{ .draw = .{ .dstid = 0, .srcid = high.id, .maskid = white, .r = proto.Rect.make(29, 20, 47, 38) } }, exp[0..45]);
    try testing.expectEqualSlices(u8, &exp, w[offs[2] .. offs[2] + 45]);
    try testing.expectEqual(htext.id, std.mem.readInt(u32, w[offs[2] + 45 + 5 .. offs[2] + 45 + 9][0..4], .little));
}

test "frame: select23 null-click collapses under delay+minmove" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);
    try f.insert("abcdefghij", 0);
    f.p0 = 0; // insert leaves the caret at 10; reset to a clean caret at the start
    f.p1 = 0;
    var col = try fx.disp.allocImage(proto.Rect.make(0, 0, 1, 1), fx.disp.image.chan, true, 0x006600FF);
    defer col.free() catch {};

    // charOfPt: x=26 -> char 0, x=29 -> char 1 (a 3px move crosses a boundary).
    // Press at (26,20), release at (29,20): a boundary was crossed (p0 != p1) but
    // both the DELAY (<2ms) and MINMOVE (<4px) tests pass ⇒ collapse to the anchor.
    var s = try select23Begin(&f, .{ .x = 26, .y = 20 }, &col, 0);
    const r = try select23End(&s, .{ .x = 29, .y = 20 }, 1);
    try testing.expectEqual(r.p0, r.p1); // collapsed
    try testing.expectEqual(@as(usize, 0), r.p0);
    try testing.expectEqual(@as(usize, 0), f.p0); // real selection untouched
    try testing.expectEqual(@as(usize, 0), f.p1);

    // Same tiny move but released LATE (>= DELAY): no collapse — the crossed
    // boundary stands.
    var s2 = try select23Begin(&f, .{ .x = 26, .y = 20 }, &col, 0);
    const r2 = try select23End(&s2, .{ .x = 29, .y = 20 }, 10);
    try testing.expectEqual(@as(usize, 0), r2.p0);
    try testing.expectEqual(@as(usize, 1), r2.p1); // NOT collapsed

    // Fast release but a FAR move (>= MINMOVE): no collapse either.
    var s3 = try select23Begin(&f, .{ .x = 26, .y = 20 }, &col, 0);
    const r3 = try select23End(&s3, .{ .x = 44, .y = 20 }, 1); // x=44 -> char 2
    try testing.expectEqual(@as(usize, 0), r3.p0);
    try testing.expectEqual(@as(usize, 2), r3.p1); // NOT collapsed
}
