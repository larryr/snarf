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
