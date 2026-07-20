//! The scrollbar: elevator geometry (`scrPos`), the bar/elevator/edge repaint
//! (`scrDraw`), and one-shot scrollbar click actions (`scrollClick`). Ported from
//! larryr/plan9port@337c6ac acme/scrl.c; cite as `scrl.c:NN`. Attached to `Text`
//! as `t.scrDraw()` / `t.scrollClick(but, pt)` (the typing/select alias pattern).
//!
//! DIVERGENCE (R-P8-1, direct-draw): the C composes the bar into a scratch image
//! (`scrtmp`) in 0-based coordinates and blits it onto the frame; we draw the
//! three fills straight into `fr.b` at the scrollbar's own screen coordinates.
//! `lastsr` therefore memoizes the SCREEN-coordinate elevator rect (the C stores
//! the 0-based one) — behaviourally identical, since the memo only detects change.
//!
//! DIVERGENCE (R-P8-8): `textscroll`'s blocking `readmouse` follow-the-cursor loop
//! (scrl.c:119-156, with `moveto` mouse warping) collapses to a single click
//! action — the warp is permanently impossible in a browser (R-P8-7), and the
//! editor re-issues `scrollClick` per event rather than spinning.
const std = @import("std");
const draw = @import("draw");
const Text = @import("Text.zig");

const Rect = draw.Rect;
const Point = draw.Point;

/// `scrpos` (scrl.c:17-44): the elevator rect inside bar `r` for a view showing
/// `[p0, p1)` of a `tot`-rune text. Empty text ⇒ the whole bar; a huge text is
/// scaled down by 1024 to keep the `h*p` products in range; the elevator is
/// clamped to a 2px minimum inside `r`.
pub fn scrPos(r: Rect, p0_in: usize, p1_in: usize, tot_in: usize) Rect {
    var q = r;
    const h: i64 = r.max.y - r.min.y;
    if (tot_in == 0) return q; // scrl.c:26-27
    var tot: i64 = @intCast(tot_in);
    var p0: i64 = @intCast(p0_in);
    var p1: i64 = @intCast(p1_in);
    if (tot > 1024 * 1024) { // scrl.c:28-32
        tot >>= 10;
        p0 >>= 10;
        p1 >>= 10;
    }
    if (p0 > 0) q.min.y += @intCast(@divTrunc(h * p0, tot)); // scrl.c:33-34
    if (p1 < tot) q.max.y -= @intCast(@divTrunc(h * (tot - p1), tot)); // scrl.c:35-36
    if (q.max.y < q.min.y + 2) { // scrl.c:37-42
        if (q.min.y + 2 <= r.max.y)
            q.max.y = q.min.y + 2
        else
            q.min.y = q.max.y - 2;
    }
    return q;
}

/// `textscrdraw` (scrl.c:55-80): repaint the scrollbar for a body Text. No-op for
/// a tag or an unbound Text (scrl.c:61), and short-circuits via the `lastsr` memo
/// when the elevator hasn't moved. Three fills: BORD over the whole strip, BACK
/// over the elevator, then BORD over the elevator's rightmost 1px edge.
pub fn scrDraw(t: *Text) Text.Error!void {
    if (t.w == null or t.what != .body) return; // scrl.c:61
    const r2 = scrPos(t.scrollr, t.org, t.org + t.fr.nchars, t.file.buffer.len()); // scrl.c:70
    if (eqRect(r2, t.lastsr)) return; // scrl.c:71 !eqrect guard
    t.lastsr = r2; // scrl.c:72
    try t.fr.b.draw(t.scrollr, t.fr.col(.bord), null, .{}); // scrl.c:73 bar in BORD
    try t.fr.b.draw(r2, t.fr.col(.back), null, .{}); // scrl.c:74 elevator in BACK
    var edge = r2; // scrl.c:75-76 right edge in BORD
    edge.min.x = r2.max.x - 1;
    try t.fr.b.draw(edge, t.fr.col(.bord), null, .{});
}

/// `textscroll` (scrl.c:107-159) as ONE step (R-P8-8): move the origin per the
/// button held. B2 ⇒ absolute jump (proportional to `my` in the bar); B1 ⇒ back
/// up N lines from the top (N = rows above `my`); B3 ⇒ scroll the char under `my`
/// to the top. `but` is the 1-based button number.
pub fn scrollClick(t: *Text, but: u3, pt: Point) Text.Error!void {
    const s = insetRect(t.scrollr, 1); // scrl.c:114
    const h = s.max.y - s.min.y; // scrl.c:115
    var my = pt.y; // scrl.c:122
    if (my < s.min.y) my = s.min.y; // scrl.c:123-124
    if (my >= s.max.y) my = s.max.y; // scrl.c:125-126
    switch (but) {
        2 => { // scrl.c:130-139 absolute
            const nc: i64 = @intCast(t.file.buffer.len());
            var p0: usize = @intCast(@divTrunc(nc * (my - s.min.y), h)); // scrl.c:132
            if (p0 >= t.q1) p0 = t.backNL(p0, 2); // scrl.c:133-134
            try t.setOrigin(p0, false); // scrl.c:136
        },
        1 => { // scrl.c:141-142 back up by rows-above
            const rows: usize = @intCast(@divTrunc(my - s.min.y, @as(i32, t.fr.font.height)));
            try t.setOrigin(t.backNL(t.org, rows), true); // scrl.c:146
        },
        else => { // scrl.c:143-144 (but 3) char under the cursor to the top
            const p0 = t.org + t.fr.charOfPt(.{ .x = s.max.x, .y = my });
            try t.setOrigin(p0, true); // scrl.c:146
        },
    }
}

/// `eqrect` (rectclip.c): exact rectangle equality (the `lastsr` memo test).
fn eqRect(a: Rect, b: Rect) bool {
    return a.min.x == b.min.x and a.min.y == b.min.y and a.max.x == b.max.x and a.max.y == b.max.y;
}

/// `insetrect` (rectclip.c): shrink `r` by `n` on every side.
fn insetRect(r: Rect, n: i32) Rect {
    return .{ .min = .{ .x = r.min.x + n, .y = r.min.y + n }, .max = .{ .x = r.max.x - n, .y = r.max.y - n } };
}

// ===========================================================================
// Tests. 9x18 font, Scrollwid 12 / Scrollgap 4 / Border 2, hand-computed.
// A Text at (4,20)-(119,470) ⇒ scrollr (4,20)-(16,470), frame (20,20)-(119,470).
// ===========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");
const Window = @import("../Window.zig");

const r25 = proto.Rect.make(4, 20, 119, 470); // scrollr x∈[4,16), frame x∈[20,119)

/// `count` lines of "lineNN\n" (7 runes each). Caller frees.
fn genLines(a: std.mem.Allocator, count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var line: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&line, "line{d:0>2}\n", .{i}) catch unreachable;
        try buf.appendSlice(a, &line);
    }
    return buf.toOwnedSlice(a);
}

const ScrollHarness = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,

    fn init(seed: []const u8, org: usize) !*ScrollHarness {
        const a = testing.allocator;
        const h = try a.create(ScrollHarness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.text = try Text.init(&h.file, a, r25, h.fx.font, &h.fx.disp.image, h.fx.cols());
        h.text.org = org;
        try h.text.fill();
        return h;
    }
    fn deinit(h: *ScrollHarness) void {
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    /// Count draw ('d') verbs in one flushed write (mirrors select.zig).
    fn countDraws(buf: []const u8) usize {
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
                else => break,
            }
        }
        return n;
    }
};

test "scroll: scrPos elevator math" {
    const bar = proto.Rect.make(4, 20, 16, 470); // h = 450

    // (a) Empty text ⇒ the whole bar.
    try testing.expectEqual(bar, scrPos(bar, 0, 0, 0));

    // (b) Top of a 2× frame: p0=0, p1=half ⇒ top half of the bar.
    //     max.y -= 450*(100-50)/100 = 225 ⇒ (4,20)-(16,245).
    try testing.expectEqual(proto.Rect.make(4, 20, 16, 245), scrPos(bar, 0, 50, 100));

    // (c) Middle: p0=25,p1=75 of 100 ⇒ min.y += 450*25/100=112, max.y -= 112.
    try testing.expectEqual(proto.Rect.make(4, 132, 16, 358), scrPos(bar, 25, 75, 100));

    // (d) 2px clamp: a tiny window in a huge text. p0=p1=0 handled by (a); here
    //     p0=500,p1=501 of 1000 ⇒ min.y=20+225=245, max.y=470-450*499/1000=470-224=246
    //     ⇒ height 1 < 2, and min.y+2=247 <= 470, so max.y bumps to 247.
    try testing.expectEqual(proto.Rect.make(4, 245, 16, 247), scrPos(bar, 500, 501, 1000));
}

test "scroll: scrDraw paints bar+elevator+edge once" {
    const seed = try genLines(testing.allocator, 60); // 420 runes
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, 0);
    defer h.deinit();
    const t = &h.text;
    // Bind a window and mark body so scrDraw runs (never dereferenced — R-P8-1).
    var dummy_w: Window = undefined;
    t.w = &dummy_w;
    t.what = .body;

    // Frame full at org 0: 25 lines = 175 runes shown of 420. Elevator:
    // min.y += 450*0/420 = 0; max.y -= 450*(420-175)/420 = 262 ⇒ (4,20)-(16,208).
    try h.fx.disp.flush();
    var base = h.fx.tree.writes.items.len;
    try t.scrDraw();
    try h.fx.disp.flush();
    try testing.expectEqual(proto.Rect.make(4, 20, 16, 208), t.lastsr);
    // Three fills: bar, elevator, right edge.
    try testing.expectEqual(@as(usize, 3), ScrollHarness.countDraws(h.fx.tree.writes.items[base]));

    // Memo no-op: the origin hasn't moved, so a second scrDraw draws nothing.
    try h.fx.disp.flush();
    base = h.fx.tree.writes.items.len;
    try t.scrDraw();
    try h.fx.disp.flush();
    if (base < h.fx.tree.writes.items.len)
        try testing.expectEqual(@as(usize, 0), ScrollHarness.countDraws(h.fx.tree.writes.items[base]));

    // After scrolling one line the elevator moves and repaints again.
    try t.setOrigin(7, true); // this itself calls scrDraw
    try testing.expect(!eqRect(t.lastsr, proto.Rect.make(4, 20, 16, 208)));
}

test "scroll: scrDraw no-ops for tags and unbound texts" {
    const seed = try genLines(testing.allocator, 60);
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, 0);
    defer h.deinit();
    const t = &h.text;

    // Unbound (w == null): no draw, lastsr untouched.
    try h.fx.disp.flush();
    var base = h.fx.tree.writes.items.len;
    try t.scrDraw();
    try h.fx.disp.flush();
    try testing.expectEqual(proto.Rect{}, t.lastsr);
    if (base < h.fx.tree.writes.items.len)
        try testing.expectEqual(@as(usize, 0), ScrollHarness.countDraws(h.fx.tree.writes.items[base]));

    // Bound but a TAG: still a no-op (scrl.c:61 `t != &t->w->body`).
    var dummy_w: Window = undefined;
    t.w = &dummy_w;
    t.what = .tag;
    base = h.fx.tree.writes.items.len;
    try t.scrDraw();
    try h.fx.disp.flush();
    try testing.expectEqual(proto.Rect{}, t.lastsr);
}

test "scroll: click actions map B1/B2/B3 to setOrigin" {
    const seed = try genLines(testing.allocator, 60); // 420 runes, 60 lines
    defer testing.allocator.free(seed);

    // B2 absolute: click at the vertical middle of the inset bar. s = inset(
    // (4,20,16,470),1) = (5,21,15,469), h = 448. my at the middle (21+224=245):
    // p0 = 420*(245-21)/448 = 420*224/448 = 210. With no selection (q1=0),
    // p0(210) >= q1 ⇒ p0 = backNL(210, 2) = line28 = 196 (scrl.c:133-134); then
    // setOrigin(196, inexact) lands on that line start ⇒ org 196.
    {
        const h = try ScrollHarness.init(seed, 0);
        defer h.deinit();
        try h.text.scrollClick(2, .{ .x = 10, .y = 245 });
        try testing.expectEqual(@as(usize, 196), h.text.org);
    }
    // B1 back-up: start at line20 (org 140). my two rows below s.min.y (21 +
    // 2*18 = 57). rows = (57-21)/18 = 2 ⇒ backNL(140, 2) = line18 = 126.
    {
        const h = try ScrollHarness.init(seed, 140);
        defer h.deinit();
        try h.text.scrollClick(1, .{ .x = 10, .y = 57 });
        try testing.expectEqual(@as(usize, 126), h.text.org);
    }
    // B3: the char under `my` scrolls to the top. At s.min.y (my=21, the first
    // frame row) the char is org itself ⇒ no move.
    {
        const h = try ScrollHarness.init(seed, 70); // line10
        defer h.deinit();
        try h.text.scrollClick(3, .{ .x = 10, .y = 21 });
        try testing.expectEqual(@as(usize, 70), h.text.org);
    }
}
