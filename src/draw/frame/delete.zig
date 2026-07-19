//! Rune deletion — libframe `frdelete.c` IN FULL (larryr/plan9port@337c6ac;
//! cite as `frdelete.c:NN`). Delete the rune range `[p0, p1)` from the frame,
//! sliding the surviving text up/left to close the gap and repainting only the
//! disturbed region (delta painting). Returns the number of text lines removed.
//!
//! Ownership discipline (leak-checked by testing.allocator): the doomed run
//! boxes `[n0, n1-1]` have their text freed by `freeBox` (KEEPING the slots),
//! then the compaction walk overwrites those slots by struct copy from the
//! surviving boxes `[n1..]` — the copies ALIAS the survivors' text. `closeBox`
//! at the end drops the now-duplicate trailing slots WITHOUT freeing, so every
//! owned slice is freed exactly once. `_frclean` then merges adjacencies.
//!
//! I-4 re-fetch: every `splitBox`/`findBox` may realloc the box list, so a `*Box`
//! is never held across one — the walk re-indexes `f.boxes.items[n1]` each step.
//! I-5: the C's `drawerror` calls become `@panic` (internal invariants only).
const std = @import("std");
const proto = @import("../proto.zig");
const Frame = @import("Frame.zig");
const util = @import("util.zig");
const drawmod = @import("draw.zig");

const Point = proto.Point;
const Rect = proto.Rect;

/// `frdelete` (frdelete.c:7-131): delete `[p0, p1)`. Returns `old_nlines -
/// new_nlines`, the count of lines the deletion removed.
pub fn delete(f: *Frame, p0: usize, p1_in: usize) Frame.Error!usize {
    // Guard + clamp (frdelete.c:18-21). `f.b==nil` is impossible in this model.
    if (p0 >= f.nchars or p0 == p1_in) return 0;
    var p1 = p1_in;
    if (p1 > f.nchars) p1 = f.nchars;

    const h = util.fontHeight(f);

    // findBox n0/n1 — both may split, invalidating pointers (I-4), frdelete.c:22-25.
    const n0 = try f.findBox(0, 0, p0);
    if (n0 == f.boxes.items.len) @panic("off end in frdelete"); // frdelete.c:23-24 (I-5)
    var n1 = try f.findBox(n0, p0, p1);

    // pt0 = point of p0 within the first n0 boxes; pt1 = point of p1 (frdelete.c:26-27).
    var pt0 = util.ptOfCharN(f, p0, n0);
    var pt1 = util.ptOfChar(f, p1);

    // Lift the tick if the caret is showing (frdelete.c:28-29).
    if (f.p0 == f.p1) try drawmod.tick(f, util.ptOfChar(f, f.p0), false);

    var nn0 = n0;
    var ppt0 = pt0;

    // Free the doomed run text but KEEP the slots (frdelete.c:32).
    f.freeBox(n0, n1 - 1);
    f.modified = true;

    // Compaction walk (frdelete.c:36-84).
    //
    // Invariants:
    //  - pt0 points to the beginning (destination), pt1 to the end (source);
    //  - n0 is the box containing the beginning of the region being deleted;
    //  - n1 is the box containing the beginning of the text to keep;
    //  - cn1 is the char position of n1;
    //  - f.p0 and f.p1 are NOT adjusted until all deletion is done.
    var n0w = n0;
    var cn1: usize = p1;
    while (pt1.x != pt0.x and n1 < f.boxes.items.len) {
        // b == &f.boxes.items[n1] throughout; re-fetched after any split (I-4).
        util.ckLineWrap0(f, &pt0, &f.boxes.items[n1]); // frdelete.c:46
        util.ckLineWrap(f, &pt1, &f.boxes.items[n1]); // frdelete.c:47
        const n = util.canFit(f, pt0, &f.boxes.items[n1]); // frdelete.c:48
        if (n == 0) @panic("_frcanfit==0"); // frdelete.c:49-50 (I-5)
        var r = Rect{ .min = pt0, .max = pt0 }; // frdelete.c:51-53
        r.max.y += h;
        const b = &f.boxes.items[n1];
        if (b.kind == .run and b.kind.run.nrune > 0) {
            const w0 = b.wid; // frdelete.c:55
            if (n != b.kind.run.nrune) {
                try f.splitBox(n1, n); // frdelete.c:57 — b invalid now (I-4)
            }
            const bw = f.boxes.items[n1].wid; // frdelete.c:60 (re-fetched)
            r.max.x += bw;
            try f.b.draw(r, f.b, null, pt1); // frdelete.c:61 screen copy pt1 -> pt0
            cn1 += f.boxes.items[n1].nrune(); // frdelete.c:62
            // Blank the remainder of the vacated cell (frdelete.c:64-69).
            r.min.x = r.max.x;
            r.max.x += w0 - bw;
            if (r.max.x > f.r.max.x) r.max.x = f.r.max.x;
            try f.b.draw(r, f.col(.back), null, r.min);
        } else {
            // Break box (frdelete.c:70-79): repaint its cell in BACK, or HIGH if
            // it lies inside the surviving selection.
            r.max.x += util.newWid0(f, pt0, &f.boxes.items[n1]); // frdelete.c:71
            if (r.max.x > f.r.max.x) r.max.x = f.r.max.x;
            const col = if (f.p0 <= cn1 and cn1 < f.p1) f.col(.high) else f.col(.back); // frdelete.c:74-76
            try f.b.draw(r, col, null, pt0); // frdelete.c:77
            cn1 += 1;
        }
        util.advance(f, &pt1, &f.boxes.items[n1]); // frdelete.c:80
        pt0.x += util.newWid(f, pt0, &f.boxes.items[n1]); // frdelete.c:81
        f.boxes.items[n0w] = f.boxes.items[n1]; // frdelete.c:82 struct-copy (aliases)
        n0w += 1;
        n1 += 1;
    }

    // Deleting the last thing in the window: clean up the trailing sliver
    // (frdelete.c:85-86).
    if (n1 == f.boxes.items.len and pt0.x != pt1.x)
        try f.selectPaint(pt0, pt1, f.col(.back));

    // Multi-line close-up (frdelete.c:87-108): slide following lines up.
    if (pt1.y != pt0.y) {
        const pt2 = util.ptOfCharPtB(f, 32767, pt1, n1); // frdelete.c:90
        if (pt2.y > f.r.max.y) @panic("frptofchar in frdelete"); // frdelete.c:91-92 (I-5)
        if (n1 < f.boxes.items.len) {
            const q0 = pt0.y + h; // frdelete.c:96
            const q1 = pt1.y + h;
            var q2 = pt2.y + h;
            if (q2 > f.r.max.y) q2 = f.r.max.y; // frdelete.c:99-100
            // Copy the tail of the join line back to the caret line (frdelete.c:101-102).
            try f.b.draw(Rect.make(pt0.x, pt0.y, pt0.x + (f.r.max.x - pt1.x), q0), f.b, null, pt1);
            // Copy the block of following full lines up one (frdelete.c:103-104).
            try f.b.draw(Rect.make(f.r.min.x, q0, f.r.max.x, q0 + (q2 - q1)), f.b, null, .{ .x = f.r.min.x, .y = q1 });
            // Blank the vacated final line (frdelete.c:105).
            try f.selectPaint(.{ .x = pt2.x, .y = pt2.y - (pt1.y - pt0.y) }, pt2, f.col(.back));
        } else {
            // Nothing kept after: just blank down to the old end (frdelete.c:107).
            try f.selectPaint(pt0, pt2, f.col(.back));
        }
    }

    // Drop the now-duplicate/freed trailing slots without freeing (frdelete.c:109).
    f.closeBox(n0w, n1 - 1);

    // Back up over the box left of the caret so `clean` can re-merge it
    // (frdelete.c:110-113).
    if (nn0 > 0 and f.boxes.items[nn0 - 1].kind == .run and
        ppt0.x - f.boxes.items[nn0 - 1].wid >= f.r.min.x)
    {
        nn0 -= 1;
        ppt0.x -= f.boxes.items[nn0].wid;
    }
    const nbox = f.boxes.items.len;
    const hi = if (n0w + 1 < nbox) n0w + 1 else n0w; // frdelete.c:114 (n0<nbox-1? n0+1 : n0)
    try f.clean(ppt0, nn0, hi);

    // Selection adjustment (frdelete.c:115-122).
    if (f.p1 > p1) {
        f.p1 -= p1 - p0;
    } else if (f.p1 > p0) {
        f.p1 = p0;
    }
    if (f.p0 > p1) {
        f.p0 -= p1 - p0;
    } else if (f.p0 > p0) {
        f.p0 = p0;
    }

    f.nchars -= p1 - p0; // frdelete.c:123

    // Restore the tick (frdelete.c:124-125).
    if (f.p0 == f.p1) try drawmod.tick(f, util.ptOfChar(f, f.p0), true);

    // Recompute nlines and return how many were removed (frdelete.c:126-129).
    const end = util.ptOfChar(f, f.nchars);
    const old = f.nlines;
    f.nlines = @intCast(@divTrunc(end.y - f.r.min.y, h) + @as(i32, @intFromBool(end.x > f.r.min.x)));
    return old - f.nlines;
}

// ==========================================================================
// Tests (editing side contract §"A4 named tests"). Fixture per R-P4-5
// (Frame.TestFixture); all expectations hand-computed from fixed-9x18 metrics
// (width 9, height 18) over rect (20,20)-(119,470) = 11 cols × 25 lines.
// ==========================================================================
const testing = std.testing;

/// Concatenate the frame's box contents (run text + break chars) — the logical
/// text, independent of how layout split it into boxes.
fn expectText(f: *Frame, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    for (f.boxes.items) |*b| {
        switch (b.kind) {
            .run => |r| {
                @memcpy(buf[n..][0..r.text.len], r.text);
                n += r.text.len;
            },
            .brk => |brk| {
                buf[n] = brk.bc;
                n += 1;
            },
        }
    }
    try testing.expectEqualStrings(expected, buf[0..n]);
}

/// The box partition must round-trip: the left edge of every rune's cell maps
/// back to its index (the strongest single check that the box list is coherent).
fn expectRoundTrip(f: *Frame) !void {
    var p: usize = 0;
    while (p <= f.nchars) : (p += 1) {
        try testing.expectEqual(p, f.charOfPt(f.ptOfChar(p)));
    }
}

test "frame: delete mid-line run" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    try f.insert("abcde", 0);
    // delete(1,3) removes "bc" ⇒ "ade" (3 runes, one 27px run after _frclean).
    const removed = try f.delete(1, 3);
    try testing.expectEqual(@as(usize, 0), removed); // still one line
    try testing.expectEqual(@as(usize, 1), f.boxes.items.len);
    try expectText(&f, "ade");
    try testing.expectEqual(@as(i32, 27), f.boxes.items[0].wid);
    try testing.expectEqual(@as(usize, 3), f.nchars);
    try testing.expectEqual(@as(usize, 1), f.nlines);
    try expectRoundTrip(&f);
}

test "frame: delete across a wrap" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    try f.insert("hello, acme wraps\nsecond line\ttab", 0);
    try testing.expectEqual(@as(usize, 4), f.nlines);

    // delete(7,13) removes "acme w" ⇒ "hello, raps\nsecond line\ttab" (27 runes).
    const removed = try f.delete(7, 13);
    try testing.expectEqual(@as(usize, 1), removed); // 4 → 3 lines
    try expectText(&f, "hello, raps\nsecond line\ttab");
    try testing.expectEqual(@as(usize, 27), f.nchars);
    try testing.expectEqual(@as(usize, 3), f.nlines);

    // Hand-computed pins: "hello, raps" fills L1 exactly, '\n' rides its end.
    try testing.expectEqual(Point{ .x = 20, .y = 20 }, f.ptOfChar(0));
    try testing.expectEqual(Point{ .x = 119, .y = 20 }, f.ptOfChar(11)); // the '\n'
    try testing.expectEqual(Point{ .x = 20, .y = 38 }, f.ptOfChar(12)); // 's' on L2
    try testing.expectEqual(Point{ .x = 20, .y = 56 }, f.ptOfChar(23)); // the '\t' (wraps to L3)
    try testing.expectEqual(Point{ .x = 92, .y = 56 }, f.ptOfChar(24)); // 't' after the tab
    try testing.expectEqual(Point{ .x = 119, .y = 56 }, f.ptOfChar(27)); // end
    try expectRoundTrip(&f);
}

test "frame: delete across a newline joins lines" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    try f.insert("hello, acme wraps\nsecond line\ttab", 0);
    // delete(17,19) removes '\n' and the leading 's' of "second", joining the
    // lines ⇒ "hello, acme wrapsecond line\ttab" (31 runes).
    _ = try f.delete(17, 19);
    try expectText(&f, "hello, acme wrapsecond line\ttab");
    try testing.expectEqual(@as(usize, 31), f.nchars);
    try testing.expectEqual(@as(usize, 3), f.nlines);
    try expectRoundTrip(&f);
}

test "frame: delete to end cleans last line" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    try f.insert("ab\ncd", 0);
    try testing.expectEqual(@as(usize, 2), f.nlines);
    // delete(3,5) removes "cd", leaving "ab\n" — the caret drops to an empty L2.
    const removed = try f.delete(3, 5);
    try testing.expectEqual(@as(usize, 1), removed);
    try expectText(&f, "ab\n");
    try testing.expectEqual(@as(usize, 3), f.nchars);
    try testing.expectEqual(@as(usize, 2), f.boxes.items.len);
    try testing.expectEqual(@as(u8, '\n'), f.boxes.items[1].kind.brk.bc);
    try testing.expectEqual(@as(usize, 1), f.nlines);
    try expectRoundTrip(&f);
}

test "frame: delete adjusts selection endpoints" {
    // The four p0/p1 arms of frdelete.c:115-122 with a fixed delete(3,6) (delta 3).
    const Case = struct { p0: usize, p1: usize, want0: usize, want1: usize };
    const cases = [_]Case{
        .{ .p0 = 7, .p1 = 9, .want0 = 4, .want1 = 6 }, // wholly after: both shift by 3
        .{ .p0 = 4, .p1 = 8, .want0 = 3, .want1 = 5 }, // p0 inside ⇒ clamps to 3; p1 shifts
        .{ .p0 = 0, .p1 = 2, .want0 = 0, .want1 = 2 }, // wholly before: unchanged
        .{ .p0 = 5, .p1 = 9, .want0 = 3, .want1 = 6 }, // p0 inside clamps; p1 after shifts
    };
    for (cases) |c| {
        var fx = try Frame.TestFixture.init();
        defer fx.deinit();
        var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
        defer f.clear(true);
        try f.insert("abcdefghij", 0);
        f.p0 = c.p0;
        f.p1 = c.p1;
        _ = try f.delete(3, 6);
        try testing.expectEqual(c.want0, f.p0);
        try testing.expectEqual(c.want1, f.p1);
    }
}

test "frame: delete moves the tick" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    try f.insert("abcde", 0); // caret at 5, p0==p1==5
    try f.initTick();
    // Show the tick at the caret (ptOfChar(5) == (65,20)).
    try drawmod.tick(&f, f.ptOfChar(5), true);
    try testing.expect(f.ticked);

    const base = fx.tree.writes.items.len;
    _ = try f.delete(1, 3); // "ade"; caret shifts 5 → 3
    try fx.disp.flush();

    // The tick is restored at the new caret (ptOfChar(3) == (47,20)); it is lifted
    // one pixel left, so the final blit rect is (46,20)-(49,38) from the tick image.
    try testing.expectEqual(@as(usize, 3), f.p0);
    try testing.expectEqual(@as(usize, 3), f.p1);
    try testing.expect(f.ticked);

    const w = fx.tree.writes.items[base];
    var expect_blit: [45]u8 = undefined;
    _ = try proto.encode(.{ .draw = .{
        .dstid = 0,
        .srcid = f.tick.?.id,
        .maskid = fx.disp.white.id,
        .r = proto.Rect.make(46, 20, 49, 38),
    } }, expect_blit[0..45]);
    // Last op before the trailing 'v': the tick blit.
    try testing.expectEqualSlices(u8, &expect_blit, w[w.len - 46 .. w.len - 1]);
    try testing.expectEqual(@as(u8, 'v'), w[w.len - 1]);
}
