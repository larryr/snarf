//! Rune insertion — libframe `frinsert.c` IN FULL (larryr/plan9port@337c6ac;
//! cite as `frinsert.c:NN`). Three phases: `bxscan` builds the new boxes and
//! lays them out in a scratch frame; the forward pass finds where the old and
//! new pen positions realign, splitting boxes and recording point pairs; the
//! reverse pass slides the displaced old text down with `draw` copies. Then the
//! new boxes are ADOPTED (their owned text moves into `f`, no re-dup), the region
//! is repainted (selectPaint + drawText), and `_frclean` merges/settles.
//!
//! DIVERGENCES from C: the file-static scratch `Frame` (frinsert.c:9) is a
//! caller-local sharing `f`'s allocator/font/display/b/r/maxtab/cols (P-3); the
//! static `pts` array (frinsert.c:106-109) is a local ArrayList; input is UTF-8
//! + a rune offset (not `Rune*`). Selection (p0==p1) and tick are inert in P4.
const std = @import("std");
const proto = @import("../proto.zig");
const Image = @import("../Image.zig");
const Frame = @import("Frame.zig");
const util = @import("util.zig");
const drawmod = @import("draw.zig");

const Box = Frame.Box;
const Point = proto.Point;
const Rect = proto.Rect;
const PtPair = struct { pt0: Point, pt1: Point };

/// `bxscan` (frinsert.c:11-74): scan UTF-8 `s` into `scratch`'s box list — runs
/// capped at `run_byte_cap` BYTES (breaks when the next rune would reach the cap,
/// frinsert.c:54-56), '\t'/'\n' each a break box seeded to wid 5000 — stopping
/// after `f.maxlines` newlines. Then `ckLineWrap0` the caller point and lay out
/// via `draw0` (which truncates the scratch to what fits). Returns the terminal
/// pen point; `ppt` is advanced past any leading wrap.
fn bxscan(f: *Frame, scratch: *Frame, s: []const u8, ppt: *Point) Frame.Error!Point {
    var nl: usize = 0;
    var i: usize = 0;
    while (i < s.len and nl <= f.maxlines) {
        const c = s[i];
        if (c == '\t' or c == '\n') {
            const minwid: i32 = if (c == '\n') 0 else f.font.stringWidth(" ");
            try scratch.boxes.append(scratch.allocator, .{
                .wid = 5000,
                .kind = .{ .brk = .{ .bc = c, .minwid = minwid } },
            });
            if (c == '\n') nl += 1;
            scratch.nchars += 1;
            i += 1;
        } else {
            const start = i;
            var nr: usize = 0;
            var w: i32 = 0;
            while (i < s.len) {
                const cc = s[i];
                if (cc == '\t' or cc == '\n') break;
                const g = util.runeAt(f.font, s, i);
                if ((i - start) + g.len >= Frame.run_byte_cap) break; // frinsert.c:55
                w += g.w;
                i += g.len;
                nr += 1;
            }
            const text = try scratch.allocator.dupe(u8, s[start..i]);
            errdefer scratch.allocator.free(text);
            try scratch.boxes.append(scratch.allocator, .{
                .wid = w,
                .kind = .{ .run = .{ .text = text, .nrune = @intCast(nr) } },
            });
            scratch.nchars += nr;
        }
    }
    util.ckLineWrap0(f, ppt, &scratch.boxes.items[0]);
    return drawmod.draw0(scratch, ppt.*);
}

/// `chopframe` (frinsert.c:76-95): after an insertion overflows `maxlines`, walk
/// from box `bn` counting runes until the pen passes `r.max.y`, then delete the
/// tail. The `/* BUG */` (frinsert.c:93) is faithfully preserved: on reaching
/// this point `b` is always a valid box, so the guarded delete always fires.
fn chopFrame(f: *Frame, pt0: Point, p0: usize, bn: usize) void {
    var pt = pt0;
    var p = p0;
    var b = bn;
    while (true) {
        if (b >= f.boxes.items.len) @panic("endofframe"); // frinsert.c:84 (I-5)
        util.ckLineWrap(f, &pt, &f.boxes.items[b]);
        if (pt.y >= f.r.max.y) break;
        p += f.boxes.items[b].nrune();
        util.advance(f, &pt, &f.boxes.items[b]);
        b += 1;
    }
    f.nchars = p;
    f.nlines = f.maxlines;
    if (b < f.boxes.items.len) // /* BUG */ frinsert.c:93
        f.delBox(b, f.boxes.items.len - 1);
}

/// `frinsert` (frinsert.c:97-291): insert UTF-8 `s` at rune offset `p0`.
pub fn insert(f: *Frame, s: []const u8, p0: usize) Frame.Error!void {
    if (p0 > f.nchars or s.len == 0) return; // frinsert.c:112 (b==nil impossible here)

    const h = util.fontHeight(f);
    var n0 = try f.findBox(0, 0, p0);
    var cn0: usize = p0;
    const nn0_init = n0;
    var pt0 = util.ptOfCharN(f, p0, n0);
    var ppt0 = pt0;
    const opt0 = pt0;

    // The scratch frame (frinsert.c:9,20-26): shares f's context, own box list.
    var scratch = Frame{
        .allocator = f.allocator,
        .font = f.font,
        .display = f.display,
        .b = f.b,
        .cols = f.cols,
        .r = f.r,
        .entire = f.entire,
        .boxes = .empty,
        .maxtab = f.maxtab,
        .nchars = 0,
        .nlines = 0,
        .maxlines = f.maxlines,
        .lastlinefull = false,
        .modified = false,
        .noredraw = f.noredraw,
    };
    var adopted = false;
    defer {
        if (!adopted) {
            for (scratch.boxes.items) |*bx| {
                if (bx.kind == .run) scratch.allocator.free(bx.kind.run.text);
            }
        }
        scratch.boxes.deinit(scratch.allocator);
    }

    var pt1 = try bxscan(f, &scratch, s, &ppt0);
    var ppt1 = pt1;

    if (n0 < f.boxes.items.len) {
        util.ckLineWrap(f, &pt0, &f.boxes.items[n0]); // for drawsel (frinsert.c:123)
        util.ckLineWrap0(f, &ppt1, &f.boxes.items[n0]);
    }
    f.modified = true;
    // (f->p0==f->p1) lift the tick before the surgery (frinsert.c:132-133).
    if (f.p0 == f.p1) try drawmod.tick(f, util.ptOfChar(f, f.p0), false);

    // Forward pass (frinsert.c:142-168): find where old (pt0) and new (pt1) pen
    // positions realign, splitting boxes to fit and recording point pairs. The
    // break entry (frinsert.c:163) is unused by the reverse pass, so we simply
    // stop without recording it.
    var pts = std.ArrayList(PtPair).empty;
    defer pts.deinit(f.allocator);

    while (pt1.x != pt0.x and pt1.y != f.r.max.y and n0 < f.boxes.items.len) {
        util.ckLineWrap(f, &pt0, &f.boxes.items[n0]);
        util.ckLineWrap0(f, &pt1, &f.boxes.items[n0]);
        if (f.boxes.items[n0].kind == .run and f.boxes.items[n0].kind.run.nrune > 0) {
            const n = util.canFit(f, pt1, &f.boxes.items[n0]);
            if (n == 0) @panic("_frcanfit==0"); // frinsert.c:149 (I-5)
            if (n != f.boxes.items[n0].kind.run.nrune) try f.splitBox(n0, n);
        }
        if (pt1.y == f.r.max.y) break; // frinsert.c:163 (entry unused by reverse)
        try pts.append(f.allocator, .{ .pt0 = pt0, .pt1 = pt1 });
        util.advance(f, &pt0, &f.boxes.items[n0]);
        pt1.x += util.newWid(f, pt1, &f.boxes.items[n0]);
        cn0 += f.boxes.items[n0].nrune();
        n0 += 1;
    }

    if (pt1.y > f.r.max.y) @panic("frinsert pt1 too far"); // frinsert.c:170 (I-5)
    if (pt1.y == f.r.max.y and n0 < f.boxes.items.len) {
        f.nchars -= f.strLen(n0);
        f.delBox(n0, f.boxes.items.len - 1);
    }
    if (n0 == f.boxes.items.len) {
        f.nlines = @intCast(@divTrunc(pt1.y - f.r.min.y, h) + @as(i32, @intFromBool(pt1.x > f.r.min.x)));
    } else if (pt1.y != pt0.y) {
        const y = f.r.max.y;
        const q0 = pt0.y + h;
        const q1 = pt1.y + h;
        f.nlines += @intCast(@divTrunc(q1 - q0, h));
        if (f.nlines > f.maxlines) chopFrame(f, ppt1, p0, nn0_init);
        if (pt1.y < y) {
            var r = f.r;
            r.min.y = q1;
            r.max.y = y;
            if (q1 < y)
                try f.b.draw(r, f.b, null, .{ .x = f.r.min.x, .y = q0 });
            r.min = pt1;
            r.max.x = pt1.x + (f.r.max.x - pt0.x);
            r.max.y = q1;
            try f.b.draw(r, f.b, null, pt0);
        }
    }

    // Reverse pass (frinsert.c:203-260): slide the displaced old boxes down,
    // clearing the fragments that hang off the right on line wraps. Selection
    // colors are inert in P4 (p0==p1 ⇒ the HIGH branches never fire).
    {
        var y2: i32 = if (pt1.y == f.r.max.y) pt1.y else 0;
        var k = pts.items.len;
        var bi = n0;
        while (k > 0) {
            k -= 1;
            bi -= 1;
            const b = &f.boxes.items[bi];
            const pt = pts.items[k].pt1;
            if (b.kind == .run and b.kind.run.nrune > 0) {
                var r = Rect{ .min = pt, .max = pt };
                r.max.x += b.wid;
                r.max.y += h;
                try f.b.draw(r, f.b, null, pts.items[k].pt0);
                if (k == 0 and pt.y > pt0.y) {
                    var r2 = Rect{ .min = opt0, .max = opt0 };
                    r2.max.x = f.r.max.x;
                    r2.max.y += h;
                    const c = if (f.p0 <= cn0 and cn0 < f.p1) f.col(.high) else f.col(.back);
                    try f.b.draw(r2, c, null, r2.min);
                } else if (pt.y < y2) {
                    var r2 = Rect{ .min = pt, .max = pt };
                    r2.min.x += b.wid;
                    r2.max.x = f.r.max.x;
                    r2.max.y += h;
                    const c = if (f.p0 <= cn0 and cn0 < f.p1) f.col(.high) else f.col(.back);
                    try f.b.draw(r2, c, null, r2.min);
                }
                y2 = pt.y;
                cn0 -= b.kind.run.nrune;
            } else {
                var r = Rect{ .min = pt, .max = pt };
                r.max.x += b.wid;
                r.max.y += h;
                if (r.max.x >= f.r.max.x) r.max.x = f.r.max.x;
                cn0 -= 1;
                const c = if (f.p0 <= cn0 and cn0 < f.p1) f.col(.high) else f.col(.back);
                try f.b.draw(r, c, null, r.min);
                y2 = 0;
                if (pt.x == f.r.min.x) y2 = pt.y;
            }
        }
    }

    // Repaint the inserted region (frinsert.c:262-270). p0==p1 ⇒ BACK/TEXT.
    const col: *Image = if (f.p0 < p0 and p0 <= f.p1) f.col(.high) else f.col(.back);
    const tcol: *Image = if (f.p0 < p0 and p0 <= f.p1) f.col(.htext) else f.col(.text);
    try f.selectPaint(ppt0, ppt1, col);
    try drawmod.drawText(&scratch, ppt0, tcol, col);

    // Adopt the scratch boxes (frinsert.c:271-273): MOVE the owned text into f.
    const slots = try f.addBox(nn0_init, scratch.boxes.items.len);
    @memcpy(slots, scratch.boxes.items);
    adopted = true;

    var nn0 = nn0_init;
    if (nn0 > 0 and f.boxes.items[nn0 - 1].kind == .run and
        ppt0.x - f.boxes.items[nn0 - 1].wid >= f.r.min.x)
    {
        nn0 -= 1;
        ppt0.x -= f.boxes.items[nn0].wid;
    }
    n0 += scratch.boxes.items.len;
    try f.clean(ppt0, nn0, if (n0 + 1 < f.boxes.items.len) n0 + 1 else n0);
    f.nchars += scratch.nchars;
    if (f.p0 >= p0) f.p0 += scratch.nchars;
    if (f.p0 > f.nchars) f.p0 = f.nchars;
    if (f.p1 >= p0) f.p1 += scratch.nchars;
    if (f.p1 > f.nchars) f.p1 = f.nchars;
    // (f->p0==f->p1) restore the tick after the p0/p1 adjustment (frinsert.c:289-290).
    if (f.p0 == f.p1) try drawmod.tick(f, util.ptOfChar(f, f.p0), true);
}

// ==========================================================================
// Tests (frame contract §"Named tests"). Fixture per R-P4-5 (Frame.TestFixture).
// All expected values are hand-computed from the embedded fixed-9x18 metrics
// (width 9, height 18, ascent 13, maxtab 72) over the stated rect.
// ==========================================================================
const testing = std.testing;

fn runText(f: *const Frame, i: usize) []const u8 {
    return f.boxes.items[i].kind.run.text;
}

test "frame: bxscan boxes for nl and tab" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    // "ab\ncd\te": ab / \n / cd / \t / e. On line 1 "ab" ⇒ (20..38); \n wraps to
    // line 2; "cd" (20..38); \t at x=38 snaps to 92 ⇒ wid 54; "e" (92..101).
    try f.insert("ab\ncd\te", 0);
    try testing.expectEqual(@as(usize, 5), f.boxes.items.len);
    try testing.expectEqual(@as(usize, 7), f.nchars);
    try testing.expectEqual(@as(usize, 2), f.nlines);

    try testing.expectEqualStrings("ab", runText(&f, 0));
    try testing.expectEqual(@as(i32, 18), f.boxes.items[0].wid);
    try testing.expectEqual(@as(u8, '\n'), f.boxes.items[1].kind.brk.bc);
    try testing.expectEqual(@as(i32, 0), f.boxes.items[1].kind.brk.minwid);
    try testing.expectEqual(@as(i32, 5000), f.boxes.items[1].wid); // '\n' keeps seed
    try testing.expectEqualStrings("cd", runText(&f, 2));
    try testing.expectEqual(@as(u8, '\t'), f.boxes.items[3].kind.brk.bc);
    try testing.expectEqual(@as(i32, 9), f.boxes.items[3].kind.brk.minwid);
    try testing.expectEqual(@as(i32, 54), f.boxes.items[3].wid); // tab from x=38 ⇒ 92
    try testing.expectEqualStrings("e", runText(&f, 4));
    try testing.expectEqual(@as(i32, 9), f.boxes.items[4].wid);
}

test "frame: wrap layout hello-acme-wraps" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    try f.insert("hello, acme wraps\nsecond line\ttab", 0);
    try testing.expectEqual(@as(usize, 33), f.nchars);
    try testing.expectEqual(@as(usize, 4), f.nlines);
    try testing.expectEqual(false, f.lastlinefull);

    // Box list: "hello, acme"(L1) / " wraps"(L2) / '\n' / "second line"(L3) /
    // '\t' / "tab"(L4).
    try testing.expectEqual(@as(usize, 6), f.boxes.items.len);
    try testing.expectEqualStrings("hello, acme", runText(&f, 0));
    try testing.expectEqual(@as(i32, 99), f.boxes.items[0].wid);
    try testing.expectEqualStrings(" wraps", runText(&f, 1));
    try testing.expectEqual(@as(i32, 54), f.boxes.items[1].wid);
    try testing.expectEqual(@as(u8, '\n'), f.boxes.items[2].kind.brk.bc);
    try testing.expectEqualStrings("second line", runText(&f, 3));
    try testing.expectEqual(@as(u8, '\t'), f.boxes.items[4].kind.brk.bc);
    try testing.expectEqual(@as(i32, 72), f.boxes.items[4].wid); // tab from x=20 ⇒ 92
    try testing.expectEqualStrings("tab", runText(&f, 5));

    // ptOfChar pins (frame contract §"Named tests").
    try testing.expectEqual(Point{ .x = 20, .y = 20 }, f.ptOfChar(0));
    try testing.expectEqual(Point{ .x = 20, .y = 38 }, f.ptOfChar(11));
    try testing.expectEqual(Point{ .x = 74, .y = 38 }, f.ptOfChar(17));
    try testing.expectEqual(Point{ .x = 20, .y = 56 }, f.ptOfChar(18));
    try testing.expectEqual(Point{ .x = 20, .y = 74 }, f.ptOfChar(29));
    try testing.expectEqual(Point{ .x = 92, .y = 74 }, f.ptOfChar(30));
    try testing.expectEqual(Point{ .x = 119, .y = 74 }, f.ptOfChar(33));
}

test "frame: exact-fit line then newline" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    // "hello, acme" is exactly 11 chars ⇒ fills line 1 (20..119); the '\n' rides
    // the end of line 1 (minwid 0 never wraps) so "X" lands on line 2 — NO blank
    // line between them.
    try f.insert("hello, acme\nX", 0);
    try testing.expectEqual(@as(usize, 13), f.nchars);
    try testing.expectEqual(@as(usize, 2), f.nlines);
    try testing.expectEqual(Point{ .x = 20, .y = 38 }, f.ptOfChar(12)); // "X" on line 2
}

test "frame: tab stops and edge wrap" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    // Case A: tab after 1 char (pen x=29) snaps to the 92 stop ⇒ wid 63.
    {
        var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
        defer f.clear(true);
        try f.insert("X\tY", 0);
        try testing.expectEqual(@as(i32, 63), f.boxes.items[1].wid);
        try testing.expectEqual(Point{ .x = 92, .y = 20 }, f.ptOfChar(2)); // "Y"
    }
    // Case B: tab after 10 chars (pen x=110) — next stop 164 overshoots 119, so
    // the tab clamps to minwid 9 ⇒ ends at 119.
    {
        var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
        defer f.clear(true);
        try f.insert("XXXXXXXXXX\tY", 0);
        try testing.expectEqual(@as(i32, 9), f.boxes.items[1].wid);
    }
    // Case C: a newline never wraps (minwid 0) — a line-length run then '\n'
    // keeps "Y" on the next line, not two lines down.
    {
        var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
        defer f.clear(true);
        try f.insert("XXXXXXXXXXX\nY", 0); // 11 X's fill line 1
        try testing.expectEqual(@as(usize, 2), f.nlines);
        try testing.expectEqual(Point{ .x = 20, .y = 38 }, f.ptOfChar(12));
    }
}

test "frame: lastlinefull and chop at maxlines" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    // A 3-line frame: (20,20)-(119,74), maxlines 3.
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 74));
    defer f.clear(true);
    try testing.expectEqual(@as(usize, 3), f.maxlines);

    // Four one-char lines "a\nb\nc\nd": lines a/b/c fit (each ending in '\n'); the
    // third '\n' advances the pen onto line 4's origin (y=74=r.max.y), so it is
    // kept while "d" is chopped. lastlinefull becomes true.
    try f.insert("a\nb\nc\nd", 0);
    try testing.expectEqual(@as(usize, 6), f.nchars); // a \n b \n c \n
    try testing.expectEqual(@as(usize, 3), f.nlines);
    try testing.expectEqual(true, f.lastlinefull);
    // The kept boxes: a \n b \n c \n (6 boxes); "d" was dropped.
    try testing.expectEqual(@as(usize, 6), f.boxes.items.len);
    try testing.expectEqualStrings("c", runText(&f, 4));
    try testing.expectEqual(@as(u8, '\n'), f.boxes.items[5].kind.brk.bc);
}

test "frame: mid-frame insert shifts and merges" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    try f.insert("abcde", 0);
    try testing.expectEqual(@as(usize, 1), f.boxes.items.len);

    // Insert "XY" at rune 2: split "abcde" -> "ab"|"cde", drop "XY" between, then
    // _frclean merges the three adjacent runs back into one "abXYcde".
    try f.insert("XY", 2);
    try testing.expectEqual(@as(usize, 7), f.nchars);
    try testing.expectEqual(@as(usize, 1), f.boxes.items.len);
    try testing.expectEqualStrings("abXYcde", runText(&f, 0));
    try testing.expectEqual(@as(i32, 63), f.boxes.items[0].wid); // 7 * 9
    try testing.expectEqual(@as(usize, 1), f.nlines);
}

test "frame: run cap at 256 bytes" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    // A 3-line frame: 11 chars/line ⇒ 33 runes max.
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 74));
    defer f.clear(true);

    // 2000 ASCII 'x' cross the 256-byte run cap (bxscan makes multiple boxes),
    // yet layout packs exactly 33 runes into the 3 lines. Mirror textfill: insert
    // until the frame reports full — the second insert (pen already at r.max.y)
    // adds nothing and trips lastlinefull.
    const data = [_]u8{'x'} ** 2000;
    try f.insert(&data, 0);
    try testing.expectEqual(@as(usize, 33), f.nchars);
    try testing.expectEqual(@as(usize, 3), f.nlines);

    var guard: usize = 0;
    while (!f.lastlinefull and guard < 4) : (guard += 1) {
        try f.insert(&data, f.nchars);
    }
    try testing.expectEqual(true, f.lastlinefull);
    try testing.expectEqual(@as(usize, 33), f.nchars); // still 33 — frame is full
}
