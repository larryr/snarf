//! Selection reconciliation + the B1 mouse gesture — `textsetselect`
//! (text.c:1192-1249) IN FULL, and the `textselect` sweep (text.c:1005-1061)
//! minus scrolling. Ported from larryr/plan9port@337c6ac; cite as `text.c:NN`.
//! Attached to `Text` as `t.setSelect(...)`, `t.selectBegin/Move/End(...)`.
//!
//! `setSelect` moves the *screen* selection `fr.p0`/`fr.p1` to match a desired
//! *file* selection `[q0,q1)`, painting only the delta between the old and new
//! shapes. `fr.p0`/`fr.p1` "are always right"; `t.q0`/`t.q1` may be off (text.c:
//! 1196), so this is the one place they are reconciled. All painting is done via
//! the frame's `drawSel` alias (frdrawsel): a zero-length range routes to the
//! tick, so the C's direct `frtick` fast path (text.c:1217) is expressed as a
//! `drawSel` of an empty range — identical single tick op.
const std = @import("std");
const draw = @import("draw");
const Text = @import("Text.zig");

const Point = draw.Point;

/// `textsetselect` (text.c:1192-1249). Set the file selection to `[q0,q1)` and
/// repaint the minimal delta.
pub fn setSelect(t: *Text, q0: usize, q1: usize) Text.Error!void {
    const f = &t.fr;
    t.q0 = q0; // text.c:1197-1198
    t.q1 = q1;

    // Desired screen offsets p0,p1 = q-org, clamped to [0, nchars]; `ticked`
    // records whether the caret is on-screen (text.c:1200-1214). Compute signed
    // because q-org can go negative (the off-top scroll case, dead here).
    const org: i64 = @intCast(t.org);
    const nchars: i64 = @intCast(f.nchars);
    var p0i: i64 = @as(i64, @intCast(q0)) - org;
    var p1i: i64 = @as(i64, @intCast(q1)) - org;
    var ticked = true;
    if (p0i < 0) {
        ticked = false;
        p0i = 0;
    }
    if (p1i < 0) p1i = 0;
    if (p0i > nchars) p0i = nchars;
    if (p1i > nchars) {
        ticked = false;
        p1i = nchars;
    }
    const p0: usize = @intCast(p0i);
    const p1: usize = @intCast(p1i);

    // Screen already agrees: only the tick visibility might need a flip
    // (text.c:1215-1219). drawSel over an empty range == frtick.
    if (p0 == f.p0 and p1 == f.p1) {
        if (p0 == p1 and ticked != f.ticked)
            try f.drawSel(f.ptOfChar(p0), p0, p1, ticked);
        return;
    }
    if (p0 > p1) @panic("textsetselect p0>p1"); // text.c:1220-1221 (I-5)

    if (f.p1 <= p0 or p1 <= f.p0 or p0 == p1 or f.p1 == f.p0) {
        // No overlap, or too easy to bother: un-draw the old, draw the new
        // (text.c:1223-1228).
        try f.drawSel(f.ptOfChar(f.p0), f.p0, f.p1, false);
        if (p0 != p1 or ticked)
            try f.drawSel(f.ptOfChar(p0), p0, p1, true);
    } else {
        // Overlap: repaint only the four possible fringes (text.c:1230-1244).
        if (p0 < f.p0) {
            try f.drawSel(f.ptOfChar(p0), p0, f.p0, true); // extend back
        } else if (p0 > f.p0) {
            try f.drawSel(f.ptOfChar(f.p0), f.p0, p0, false); // trim front
        }
        if (p1 > f.p1) {
            try f.drawSel(f.ptOfChar(f.p1), f.p1, p1, true); // extend forward
        } else if (p1 < f.p1) {
            try f.drawSel(f.ptOfChar(p1), p1, f.p1, false); // trim tail
        }
    }
    f.p0 = p0; // text.c:1246-1248 (Return)
    f.p1 = p1;
}

/// `textselect` setup (text.c:1017-1037, minus scroll): drop the anchor at `mp`
/// and begin a live sweep. Double-click word/line expansion is driven at
/// press-time by the Editor via `doubleClick` (below) keyed on `Text.last_click`.
pub fn selectBegin(t: *Text, mp: Point) Text.Error!void {
    t.sel = try t.fr.selectBegin(mp);
}

/// One sweep step (frselect loop body via the frame `SelectState`).
pub fn selectMove(t: *Text, mp: Point) Text.Error!void {
    if (t.sel) |*s| try draw.Frame.selectUpdate(s, mp);
}

/// B1 up: finish the sweep and map the committed frame selection back to file
/// coordinates (text.c:1042-1049 with the off-frame `selectq` arms dead — org is
/// fixed, R-P6-9).
pub fn selectEnd(t: *Text, mp: Point) Text.Error!void {
    if (t.sel) |*s| {
        try draw.Frame.selectEnd(s, mp);
        t.q0 = t.org + t.fr.p0;
        t.q1 = t.org + t.fr.p1;
        t.sel = null;
    }
}

// ==========================================================================
// Double-click expansion (textdoubleclick/textclickmatch, text.c:1386-1482).
// Word / bracket-pair / quote-pair / line selection from a caret click.
// ==========================================================================

// The bracket, newline and quote match tables (text.c:1386-1404). Index i pairs
// `left_tab[i][k]` with `right_tab[i][k]`: brackets open↔close, and newline and
// each quote character self-match.
const left1 = [_]u21{ '{', '[', '(', '<', 0xAB };
const right1 = [_]u21{ '}', ']', ')', '>', 0xBB };
const left2 = [_]u21{'\n'};
const left3 = [_]u21{ '\'', '"', '`' };
const left_tab = [_][]const u21{ &left1, &left2, &left3 };
const right_tab = [_][]const u21{ &right1, &left2, &left3 };

fn indexOf(set: []const u21, c: u21) ?usize {
    for (set, 0..) |s, i| if (s == c) return i;
    return null;
}

/// `textdoubleclick` (text.c:1407-1454), MINUS `textclickhtmlmatch` (p9p-only,
/// R-P7-7). Expand the caret `[*q0,*q1)` (q0==q1 on entry) to the enclosing
/// bracket/quote interior, the whole line, or the surrounding alphanumeric word.
pub fn doubleClick(t: *Text, q0: *usize, q1: *usize) void {
    // text.c:1413-1414 textclickhtmlmatch — DEFERRED (p9p-only, R-P7-7).
    const nc = t.file.buffer.len();
    for (left_tab, right_tab) |l, r| { // text.c:1416
        var q = q0.*; // text.c:1417
        // try matching the character to the left, looking right (text.c:1420-1430).
        const cl: u21 = if (q == 0) '\n' else t.file.buffer.runeAt(q - 1); // text.c:1421-1424
        if (indexOf(l, cl)) |idx| { // text.c:1425-1426
            if (clickMatch(t, cl, r[idx], 1, &q))
                q1.* = q - @intFromBool(cl != '\n'); // text.c:1427-1428
            return; // text.c:1429
        }
        // try matching the character to the right, looking left (text.c:1431-1445).
        const cr: u21 = if (q == nc) '\n' else t.file.buffer.runeAt(q); // text.c:1432-1435
        if (indexOf(r, cr)) |idx| { // text.c:1436-1437
            if (clickMatch(t, cr, l[idx], -1, &q)) {
                q1.* = q0.* + @intFromBool(q0.* < nc and cr == '\n'); // text.c:1439
                q0.* = q; // text.c:1440
                if (cr != '\n' or q != 0 or t.file.buffer.runeAt(0) == '\n')
                    q0.* += 1; // text.c:1441-1442
            }
            return; // text.c:1444
        }
    }
    // fill out the word to the right, then to the left (text.c:1448-1453).
    while (q1.* < nc and isAlnum(t.file.buffer.runeAt(q1.*))) q1.* += 1;
    while (q0.* > 0 and isAlnum(t.file.buffer.runeAt(q0.* - 1))) q0.* -= 1;
}

/// `textclickmatch` (text.c:1457-1482): scan from `*q` in `dir` counting nesting
/// of `cl`/`cr`, stopping when the count returns to zero on `cr`. Runs off the
/// buffer end return true only for the newline (line-select) case.
fn clickMatch(t: *Text, cl: u21, cr: u21, dir: i8, q: *usize) bool {
    const nc = t.file.buffer.len();
    var nest: i32 = 1; // text.c:1462
    while (true) { // text.c:1463
        var c: u21 = undefined;
        if (dir > 0) { // text.c:1464-1468
            if (q.* == nc) break;
            c = t.file.buffer.runeAt(q.*);
            q.* += 1;
        } else { // text.c:1469-1473
            if (q.* == 0) break;
            q.* -= 1;
            c = t.file.buffer.runeAt(q.*);
        }
        if (c == cr) { // text.c:1475-1477
            nest -= 1;
            if (nest == 0) return true;
        } else if (c == cl) { // text.c:1478-1479
            nest += 1;
        }
    }
    return cl == '\n' and nest == 1; // text.c:1481
}

/// `isalnum` (util.c:328-342): permissive word-character test — everything above
/// the Latin-1 controls counts, so ALL runes >= 0xA1 are word chars. (This is the
/// full-rune port; `Text.bsWidth`'s ASCII-only `isalnum` is a separate, narrower
/// helper and is left as-is.)
pub fn isAlnum(c: u21) bool {
    if (c <= ' ') return false; // util.c:335-336
    if (0x7F <= c and c <= 0xA0) return false; // util.c:337-338
    const punct = "!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~"; // util.c:339
    for (punct) |p| if (@as(u21, p) == c) return false;
    return true; // util.c:341
}

// ==========================================================================
// Tests (editing side contract §"B2 named tests"). Frame.TestFixture + real File.
// ==========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");

// Harness rect shifted (x 20→4) for the phase-8 scrollbar strip: the 12px
// scrollbar + 4px gap carve leaves the FRAME at (20,20)-(119,470), byte-identical
// to the pre-scrollbar geometry (chrome contract §2).
const rect = proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

/// Count the draw-ish verbs ('d','s') in one flushed write, skipping 'v' — the
/// delta-only proof (mirrors frame/select.zig's countOps).
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

const Harness = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,

    fn init(seed: []const u8, org: usize) !*Harness {
        const a = testing.allocator;
        const h = try a.create(Harness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.text = try Text.init(&h.file, a, rect, h.fx.font, &h.fx.disp.image, h.fx.cols());
        h.text.org = org;
        try h.text.fill();
        return h;
    }
    fn deinit(h: *Harness) void {
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
};

test "select: setselect easy path and tick" {
    const h = try Harness.init("abcde", 0);
    defer h.deinit();
    const t = &h.text;

    // Fill left a collapsed caret with the tick showing at fr.p0==0.
    try testing.expect(t.fr.ticked);

    // Easy path: no overlap with [0,0) — un-draw old, highlight [1,3).
    try t.setSelect(1, 3);
    try testing.expectEqual(@as(usize, 1), t.fr.p0);
    try testing.expectEqual(@as(usize, 3), t.fr.p1);
    try testing.expectEqual(@as(usize, 1), t.q0);
    try testing.expectEqual(@as(usize, 3), t.q1);
    try testing.expect(!t.fr.ticked); // a range selection hides the caret

    // Collapse to a caret at 2: easy path again, and since p0==p1 && ticked the
    // tick is redrawn.
    try t.setSelect(2, 2);
    try testing.expectEqual(@as(usize, 2), t.fr.p0);
    try testing.expectEqual(@as(usize, 2), t.fr.p1);
    try testing.expect(t.fr.ticked);

    // Fast path: same p0==p1 but the caret is (artificially) not shown — the
    // one op is a tick flip (text.c:1215-1218).
    t.fr.ticked = false;
    try h.fx.disp.flush();
    const base = h.fx.tree.writes.items.len;
    try t.setSelect(2, 2);
    try h.fx.disp.flush();
    try testing.expect(t.fr.ticked);
    try testing.expectEqual(@as(usize, 2), t.fr.p0);
    // Just the tick, no range repaint: turning the tick ON is save-under + blit
    // (frdraw.c:156-157) == 2 draw ops.
    try testing.expectEqual(@as(usize, 2), countOps(h.fx.tree.writes.items[base]));
}

test "select: setselect incremental arms" {
    const h = try Harness.init("abcdefghij", 0);
    defer h.deinit();
    const t = &h.text;

    // Establish [3,7) (clears the tick, so later deltas are clean to count).
    try t.setSelect(3, 7);
    try testing.expect(!t.fr.ticked);

    // extend-back: p0 3->1, p1 unchanged. One drawSel over [1,3) == 2 ops.
    try h.fx.disp.flush();
    var base = h.fx.tree.writes.items.len;
    try t.setSelect(1, 7);
    try h.fx.disp.flush();
    try testing.expectEqual(@as(usize, 1), t.fr.p0);
    try testing.expectEqual(@as(usize, 7), t.fr.p1);
    try testing.expectEqual(@as(usize, 2), countOps(h.fx.tree.writes.items[base]));

    // trim-front: p0 1->4 (< p1). Un-highlight [1,4).
    try h.fx.disp.flush();
    base = h.fx.tree.writes.items.len;
    try t.setSelect(4, 7);
    try h.fx.disp.flush();
    try testing.expectEqual(@as(usize, 4), t.fr.p0);
    try testing.expectEqual(@as(usize, 7), t.fr.p1);
    try testing.expectEqual(@as(usize, 2), countOps(h.fx.tree.writes.items[base]));

    // extend-forward: p1 7->9.
    try t.setSelect(4, 9);
    try testing.expectEqual(@as(usize, 4), t.fr.p0);
    try testing.expectEqual(@as(usize, 9), t.fr.p1);

    // trim-tail: p1 9->6.
    try t.setSelect(4, 6);
    try testing.expectEqual(@as(usize, 4), t.fr.p0);
    try testing.expectEqual(@as(usize, 6), t.fr.p1);
}

test "select: click collapses to caret" {
    const h = try Harness.init("abcde", 0);
    defer h.deinit();
    const t = &h.text;

    // Press and release at the same point (char 2) => a caret, no range.
    try t.selectBegin(t.fr.ptOfChar(2));
    try t.selectEnd(t.fr.ptOfChar(2));
    try testing.expectEqual(@as(usize, 2), t.q0);
    try testing.expectEqual(@as(usize, 2), t.q1);
    try testing.expectEqual(@as(usize, 2), t.fr.p0);
    try testing.expectEqual(@as(usize, 2), t.fr.p1);
    try testing.expect(t.sel == null);
}

test "select: sweep sets q0/q1 with org" {
    // org=18 => the frame shows "second line\ttab"; the gesture must add org
    // back when mapping fr.p0/p1 to file coords.
    const h = try Harness.init("hello, acme wraps\nsecond line\ttab", 18);
    defer h.deinit();
    const t = &h.text;

    try t.selectBegin(t.fr.ptOfChar(0));
    try t.selectMove(t.fr.ptOfChar(2));
    try t.selectEnd(t.fr.ptOfChar(4)); // sweep [0,4) on screen
    try testing.expectEqual(@as(usize, 0), t.fr.p0);
    try testing.expectEqual(@as(usize, 4), t.fr.p1);
    try testing.expectEqual(@as(usize, 18), t.q0); // 18 + 0
    try testing.expectEqual(@as(usize, 22), t.q1); // 18 + 4
}

test "select: double-click selects a word" {
    // ASCII: "foo bar" — a click inside "bar" fills the alnum word both ways.
    {
        const h = try Harness.init("foo bar", 0);
        defer h.deinit();
        var q0: usize = 5; // inside "bar"
        var q1: usize = 5;
        h.text.doubleClick(&q0, &q1);
        try testing.expectEqual(@as(usize, 4), q0);
        try testing.expectEqual(@as(usize, 7), q1);
    }
    // Non-ASCII: "café x" is c a f é(U+00E9) sp x — 'é' (>= 0xA1) is a word char,
    // so the word spans all four runes (util.c's permissive isalnum).
    {
        const h = try Harness.init("café x", 0);
        defer h.deinit();
        var q0: usize = 1; // inside "café"
        var q1: usize = 1;
        h.text.doubleClick(&q0, &q1);
        try testing.expectEqual(@as(usize, 0), q0);
        try testing.expectEqual(@as(usize, 4), q1); // c,a,f,é
    }
}

test "select: double-click on bracket pairs selects the nested interior" {
    // Brackets: "a(bcd)e" — a click just past '(' matches ')' and selects "bcd".
    {
        const h = try Harness.init("a(bcd)e", 0);
        defer h.deinit();
        var q0: usize = 2; // just inside '('
        var q1: usize = 2;
        h.text.doubleClick(&q0, &q1);
        try testing.expectEqual(@as(usize, 2), q0);
        try testing.expectEqual(@as(usize, 5), q1); // ')' is at 5, interior [2,5)
    }
    // Nesting: "((x))" — from just past the outer '(' the match skips the inner pair.
    {
        const h = try Harness.init("((x))", 0);
        defer h.deinit();
        var q0: usize = 1; // just past the outer '('
        var q1: usize = 1;
        h.text.doubleClick(&q0, &q1);
        try testing.expectEqual(@as(usize, 1), q0);
        try testing.expectEqual(@as(usize, 4), q1); // interior "(x)"
    }
    // Quotes: `x"hi"y` — a click just past the opening quote selects "hi".
    {
        const h = try Harness.init("x\"hi\"y", 0);
        defer h.deinit();
        var q0: usize = 2; // just past the opening quote
        var q1: usize = 2;
        h.text.doubleClick(&q0, &q1);
        try testing.expectEqual(@as(usize, 2), q0);
        try testing.expectEqual(@as(usize, 4), q1); // interior "hi"
    }
}

test "select: double-click at line boundaries selects the line" {
    // "ab\ncd\nef": a0 b1 \n2 c3 d4 \n5 e6 f7.
    const h = try Harness.init("ab\ncd\nef", 0);
    defer h.deinit();

    // At a line START (char to the left is '\n'): look right to the next '\n',
    // keeping it — the whole line "cd\n" = [3,6).
    {
        var q0: usize = 3;
        var q1: usize = 3;
        h.text.doubleClick(&q0, &q1);
        try testing.expectEqual(@as(usize, 3), q0);
        try testing.expectEqual(@as(usize, 6), q1);
    }
    // At a line END (char AT q is '\n'): the backward mirror selects the same
    // line "cd\n" = [3,6).
    {
        var q0: usize = 5;
        var q1: usize = 5;
        h.text.doubleClick(&q0, &q1);
        try testing.expectEqual(@as(usize, 3), q0);
        try testing.expectEqual(@as(usize, 6), q1);
    }
}
