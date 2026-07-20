//! A column: a `columntag` `Text` over a vertical stack of `Window`s that share
//! the column's rectangle, separated by `Border`-px black bands. file-as-struct
//! (S-07 P-1): this file *is* the Column.
//!
//! Ported from larryr/plan9port@337c6ac acme/cols.c; cite as `cols.c:NN`. This is
//! the no-clone/no-warp `colinit` (cols.c:26-50), `coladd` (cols.c:52-158) and
//! `colresize` (cols.c:235-272) plus `colwhich` (cols.c:558-580). The mouse-warp
//! arms (`savemouse`/`moveto`, cols.c:150-154) are dropped (R-P8-7 — a browser
//! can't move the pointer), and the `colgrow` "grow the landing window first"
//! loop (cols.c:81-87) is deferred with the rest of colgrow/colsort/colclose/
//! coldragwin (later phases): the buggered fallback still fires when the clamped
//! landing position can't fit.
//!
//! Windows are individually HEAP-allocated (`allocator.create`) and stored as
//! pointers so their addresses stay stable — a `Text`'s `SelectState` aliases
//! `Text.fr`, and `Text.w` aliases the owning Window (contract §7-8).
//!
//! Imports: `std` + `draw` + sibling core files only (S-07 §6).
const std = @import("std");
const draw = @import("draw");
const Chrome = @import("Chrome.zig");
const Text = @import("text/Text.zig");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");
const Window = @import("Window.zig");
const Row = @import("Row.zig");

const Column = @This();
const Rect = draw.Rect;
const Point = draw.Point;

pub const Error = Text.Error;

/// `Lheader` (cols.c:15-24): the column-tag command band, 38 runes incl. the
/// trailing space the caret sits after.
const header = "New Cut Paste Snarf Sort Zerox Delcol ";

r: Rect,
tag: Text,
/// The column tag's backing `File`, owned by the Column.
tag_file: File,
/// The owning `Row`, or null before the column is spliced into one.
row: ?*Row = null,
/// The stacked windows, top to bottom. Heap-created pointers (stability §7-8),
/// owned by the Column (freed by `deinit`).
w: std.ArrayList(*Window) = .empty,
safe: bool = true,
chrome: *const Chrome,

/// `colinit` (cols.c:26-50): white ground, a `columntag` `Text` over the top
/// `font.height` strip, a `Border`-px black band beneath it, the command header
/// with the caret at its end, and the purple colbutton over the tag scrollbar.
pub fn init(c: *Column, chrome: *const Chrome, r: Rect) Error!void {
    const a = chrome.allocator;
    const font = chrome.font;
    const fh: i32 = font.height;
    const screen = &chrome.display.image;

    c.chrome = chrome;
    c.r = r; // cols.c:33
    c.w = .empty; // cols.c:34 c->w = nil / c->nw = 0
    c.row = null;
    c.safe = true; // cols.c:49

    try screen.draw(r, chrome.white, null, .{}); // cols.c:32 white ground

    // columntag over the top one-line strip (cols.c:39-42).
    var r1 = r;
    r1.max.y = r1.min.y + fh;
    c.tag_file = File.init(a, try Buffer.initFromBytes(a, ""));
    errdefer c.tag_file.deinit();
    c.tag = try Text.init(&c.tag_file, a, r1, font, screen, chrome.tag_cols);
    c.tag.what = .columntag; // cols.c:42

    // Border-px black band beneath the tag (cols.c:43-45).
    r1.min.y = r1.max.y;
    r1.max.y += Chrome.border;
    try screen.draw(r1, chrome.black, null, .{}); // cols.c:45

    // Header text + caret at the end (cols.c:46-47).
    try c.tag.insertAt(0, header, true); // textinsert
    const nc = c.tag.file.buffer.len();
    try c.tag.setSelect(nc, nc); // textsetselect

    // Purple colbutton over the tag scrollbar strip (cols.c:48).
    try screen.draw(c.tag.scrollr, chrome.colbutton, null, .{});
}

/// Free the tag, its `File`, and every owned window. Body `File`s are borrowed
/// (caller-owned) and are NOT freed here.
pub fn deinit(c: *Column) void {
    const a = c.chrome.allocator;
    for (c.w.items) |w| {
        w.deinit();
        a.destroy(w);
    }
    c.w.deinit(a);
    c.tag.deinit();
    c.tag_file.deinit();
}

/// `coladd` (cols.c:52-158), no-clone/no-warp: place a new window carrying
/// `body_file` at (or near) `y_in`. With `y_in` above the window region and at
/// least one window present, steal the bottom half of the last window; otherwise
/// find the window `y_in` lands on, clamp the split point, shrink that window and
/// carve the new one out of the freed space. When the split can't fit (buggered),
/// splice the window anyway and redistribute the whole column with `resize`.
/// `winid` is pre-incremented for the new window's id (the C's `++winid`).
pub fn add(c: *Column, winid: *u32, body_file: *File, y_in: i32) Error!*Window {
    const a = c.chrome.allocator;
    const font = c.chrome.font;
    const fh: i32 = font.height;
    const screen = &c.chrome.display.image;

    var y = y_in;
    var r = c.r;
    r.min.y = c.tag.fr.r.max.y + Chrome.border; // cols.c:61
    const nw = c.w.items.len;

    // steal half of the last window by default (cols.c:62-64).
    if (y < r.min.y and nw > 0) {
        const v = c.w.items[nw - 1];
        y = v.body.fr.r.min.y + @divTrunc(dy(v.body.fr.r), 2);
    }

    // find the window we'll land on (cols.c:66-71).
    var i: usize = 0;
    while (i < nw) : (i += 1) {
        if (y < c.w.items[i].r.max.y) break;
    }

    var buggered = false;
    if (nw > 0) {
        if (i < nw) i += 1; // new window goes after v (cols.c:74-75)
        const v = c.w.items[i - 1];
        const minht = fh + Chrome.border + 1; // cols.c:79
        // (colgrow "grow v first" loop cols.c:81-87 deferred — buggered still
        //  fires below when the clamp leaves no room.)

        // where the new window stops (cols.c:93-97).
        const ymax = if (i < nw) c.w.items[i].r.min.y - Chrome.border else c.r.max.y;

        // clamp the split point (cols.c:100-107).
        y = @max(y, v.tagtop.max.y + Chrome.border); // must start after v's tag
        y = @min(y, ymax - minht); // must end before ymax
        if (y < v.tagtop.max.y + Chrome.border) buggered = true;

        // resize & redraw v shrunk into its top portion (cols.c:112-118).
        r = v.r;
        r.max.y = ymax;
        try screen.draw(r, v.body.fr.col(.back), null, .{}); // cols.c:114 textcols[BACK]
        var r1 = r;
        y = @min(y, ymax - (fh * v.taglines + fh + Chrome.border + 1)); // cols.c:116
        const nlines: i32 = @intCast(v.body.fr.nlines);
        r1.max.y = @min(y, v.body.fr.r.min.y + nlines * fh); // cols.c:117
        r1.min.y = try v.resize(r1, false, false); // cols.c:118 winresize
        // Border-px black band beneath v (cols.c:119-120).
        r1.max.y = r1.min.y + Chrome.border;
        try screen.draw(r1, c.chrome.black, null, .{});
        r.min.y = r1.max.y; // leave r with the new window's coordinates (cols.c:125)
    }

    // heap-create the new window over the freed rect (w==nil branch, cols.c:127-131).
    const w = try a.create(Window);
    errdefer a.destroy(w);
    try screen.draw(r, c.chrome.body_cols[@intFromEnum(draw.Frame.ColorSlot.back)], null, .{}); // cols.c:130
    winid.* += 1; // ++winid
    try w.init(c.chrome, body_file, winid.*, r); // cols.c:131 wininit
    errdefer w.deinit();
    w.col = c; // cols.c:129

    // splice at index i (cols.c:140-143).
    try c.w.insert(a, i, w);
    c.safe = true; // cols.c:144

    // too many windows ⇒ redraw the whole column (cols.c:147-148).
    if (buggered) try c.resize(c.r);

    return w;
}

/// `colresize` (cols.c:235-272): relayout the tag strip + colbutton + black band,
/// then stack the windows proportionally — each non-last window keeps its share of
/// the growable height `new/old`, clamped to at least one tag line + border, with
/// a `Border`-px black band above each. The last window takes the remainder and
/// keeps its extra fringe (`keepextra`).
pub fn resize(c: *Column, r: Rect) Error!void {
    const font = c.chrome.font;
    const fh: i32 = font.height;
    const screen = &c.chrome.display.image;
    const bd = Chrome.border;

    var r1 = r;
    r1.max.y = r1.min.y + fh;
    _ = try c.tag.resize(r1, true); // cols.c:245 textresize TRUE
    try screen.draw(c.tag.scrollr, c.chrome.colbutton, null, .{}); // cols.c:246
    r1.min.y = r1.max.y;
    r1.max.y += bd;
    try screen.draw(r1, c.chrome.black, null, .{}); // cols.c:249 black band
    r1.max.y = r.max.y; // cols.c:250

    const nw: i32 = @intCast(c.w.items.len);
    const new = dy(r) - nw * (bd + fh); // cols.c:251
    const old = dy(c.r) - nw * (bd + fh); // cols.c:252
    for (c.w.items, 0..) |w, idx| {
        const is_last = idx == c.w.items.len - 1; // safe: loop body ⇒ len ≥ 1
        w.maxlines = 0; // cols.c:255
        if (is_last) {
            r1.max.y = r.max.y; // cols.c:257
        } else {
            r1.max.y = r1.min.y; // cols.c:259
            if (new > 0 and old > 0 and dy(w.r) > bd + fh) { // cols.c:260
                r1.max.y += @divTrunc((dy(w.r) - bd - fh) * new, old) + bd + fh; // cols.c:261
            }
        }
        r1.max.y = @max(r1.max.y, r1.min.y + bd + fh); // cols.c:264
        var r2 = r1;
        r2.max.y = r2.min.y + bd; // cols.c:266
        try screen.draw(r2, c.chrome.black, null, .{}); // cols.c:267 black top band
        r1.min.y = r2.max.y; // cols.c:268
        r1.min.y = try w.resize(r1, false, is_last); // cols.c:269 winresize
    }
    c.r = r; // cols.c:271
}

/// `colwhich` (cols.c:558-580): the `Text` at `p` — the column tag, a window's
/// tag (its collapsed `tagtop` or full tag rect), or its body — or `null` when
/// `p` is outside the column or in the dead corner past the body's last full line.
pub fn which(c: *Column, p: Point) ?*Text {
    if (!ptinrect(p, c.r)) return null; // cols.c:564-565
    if (ptinrect(p, c.tag.all)) return &c.tag; // cols.c:566-567
    for (c.w.items) |w| {
        if (ptinrect(p, w.r)) { // cols.c:570
            if (ptinrect(p, w.tagtop) or ptinrect(p, w.tag.all)) return &w.tag; // cols.c:571-572
            // exclude the partial line at the bottom (cols.c:573-575).
            if (p.x >= w.body.scrollr.max.x and p.y >= w.body.fr.r.max.y) return null;
            return &w.body; // cols.c:576
        }
    }
    return null; // cols.c:579
}

// --- small geometry helpers (libc rectangle macros) ---
fn dy(r: Rect) i32 {
    return r.max.y - r.min.y;
}

fn ptinrect(p: Point, r: Rect) bool {
    return p.x >= r.min.x and p.x < r.max.x and p.y >= r.min.y and p.y < r.max.y;
}

// ===========================================================================
// Tests. 9x18 font (height 18, width 9); Border 2, Scrollwid 12, Scrollgap 4.
// Layout pins are hand-computed from cols.c against these constants.
// ===========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;

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

const ColHarness = struct {
    fx: Frame.TestFixture,
    chrome: *Chrome,
    col: *Column,
    bodies: std.ArrayList(*File),
    winid: u32 = 0,

    fn init(r: Rect) !*ColHarness {
        const a = testing.allocator;
        const h = try a.create(ColHarness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.chrome = try Chrome.init(a, h.fx.disp, h.fx.font);
        h.col = try a.create(Column);
        try h.col.init(h.chrome, r);
        h.bodies = .empty;
        h.winid = 0;
        return h;
    }

    /// Add a window with a `lines`-line body at `y`.
    fn addWin(h: *ColHarness, lines: usize, y: i32) !*Window {
        const a = testing.allocator;
        const seed = try genLines(a, lines);
        defer a.free(seed);
        const f = try a.create(File);
        f.* = File.init(a, try Buffer.initFromBytes(a, seed));
        try h.bodies.append(a, f);
        const w = try h.col.add(&h.winid, f, y);
        // W1's Window.init leaves the body frame empty (fill is deferred to
        // resize); a real, displayed window is filled, which is coladd's
        // precondition, so populate it here for the layout pins.
        try w.body.fill();
        return w;
    }

    fn deinit(h: *ColHarness) void {
        const a = testing.allocator;
        h.col.deinit();
        a.destroy(h.col);
        for (h.bodies.items) |f| {
            f.deinit();
            a.destroy(f);
        }
        h.bodies.deinit(a);
        h.chrome.deinit();
        h.fx.deinit();
        a.destroy(h);
    }
};

test "column: init lays out the columntag header and caret" {
    const h = try ColHarness.init(proto.Rect.make(0, 0, 200, 400));
    defer h.deinit();
    const c = h.col;

    try testing.expect(c.tag.what == .columntag);
    try testing.expect(c.safe);
    try testing.expectEqual(@as(usize, 0), c.w.items.len);
    try testing.expectEqual(proto.Rect.make(0, 0, 200, 400), c.r);
    // The 38-rune header is in the tag file with the caret parked at its end.
    try testing.expectEqual(@as(usize, 38), c.tag.file.buffer.len());
    try testing.expectEqual(@as(usize, 38), c.tag.q0);
    try testing.expectEqual(@as(usize, 38), c.tag.q1);
    // The tag occupies the top 18px line; the window region begins at 20 (18+Border).
    try testing.expectEqual(@as(i32, 18), c.tag.fr.r.max.y);
}

test "column: add steals half of the landing window" {
    const h = try ColHarness.init(proto.Rect.make(0, 0, 200, 400));
    defer h.deinit();
    const c = h.col;

    // First window fills the whole region below the tag (20..400).
    const a = try h.addWin(40, 20);
    try testing.expectEqual(proto.Rect.make(0, 20, 200, 400), a.r);

    // Second window with y above the region steals the bottom half of A: A's
    // body frame is 39..399 (360px), the split lands at 39+180=219, so A trims
    // to 219 and B takes 221..400 (past the 2px band).
    const b = try h.addWin(40, 0);
    try testing.expectEqual(@as(usize, 2), c.w.items.len);
    try testing.expect(c.w.items[0] == a and c.w.items[1] == b);
    try testing.expectEqual(@as(i32, 219), a.r.max.y);
    try testing.expectEqual(@as(i32, 221), b.r.min.y);
    try testing.expectEqual(@as(i32, 400), b.r.max.y);
}

test "column: add buggered redistributes the whole column" {
    // A 60px column has room for the tag (0..18), band (18..20) and a single
    // window; a second window can't fit, so coladd sets `buggered` and falls back
    // to colresize, which re-lays both windows from the region top. Both bodies
    // collapse: A gets tag-only (20..38), B gets tag-only (40..58).
    const h = try ColHarness.init(proto.Rect.make(0, 0, 200, 60));
    defer h.deinit();
    const c = h.col;

    _ = try h.addWin(40, 20);
    const b = try h.addWin(40, 0); // steal path → clamp → buggered
    try testing.expect(c.w.items[1] == b);
    try testing.expectEqual(@as(usize, 2), c.w.items.len);

    // colresize re-laid from the region top with 2px bands between.
    try testing.expectEqual(proto.Rect.make(0, 20, 200, 38), c.w.items[0].r);
    try testing.expectEqual(proto.Rect.make(0, 40, 200, 58), c.w.items[1].r);
    try testing.expectEqual(c.w.items[0].r.max.y + Chrome.border, c.w.items[1].r.min.y);
}

test "column: resize stacks windows proportionally" {
    const h = try ColHarness.init(proto.Rect.make(0, 0, 200, 400));
    defer h.deinit();
    const c = h.col;

    _ = try h.addWin(40, 20); // A: 20..219
    _ = try h.addWin(40, 0); // B: 221..400

    // Grow to 600: new = 600-2*20 = 560, old = 400-2*20 = 360. A (Dy 199) keeps
    // (199-20)*560/360 + 20 = 298 of growable slot → its winresize trims the body
    // to a line multiple, ending at 309; B takes 311..600.
    try c.resize(proto.Rect.make(0, 0, 200, 600));
    try testing.expectEqual(@as(i32, 20), c.w.items[0].r.min.y);
    try testing.expectEqual(@as(i32, 309), c.w.items[0].r.max.y);
    try testing.expectEqual(@as(i32, 311), c.w.items[1].r.min.y);
    try testing.expectEqual(@as(i32, 600), c.w.items[1].r.max.y);
    try testing.expectEqual(proto.Rect.make(0, 0, 200, 600), c.r);
}

test "column: which routes tag vs body vs partial-line" {
    const h = try ColHarness.init(proto.Rect.make(0, 0, 200, 400));
    defer h.deinit();
    const c = h.col;

    const a = try h.addWin(40, 20); // A: 20..219 (body trimmed, no fringe)
    const b = try h.addWin(40, 0); // B: 221..400 (body frame 240..384, fringe below)

    // The column tag (top strip).
    try testing.expectEqual(&c.tag, c.which(.{ .x = 100, .y = 5 }).?);
    // Window A's tag line.
    try testing.expectEqual(&a.tag, c.which(.{ .x = 100, .y = 25 }).?);
    // Window A's body.
    try testing.expectEqual(&a.body, c.which(.{ .x = 100, .y = 150 }).?);
    // Window B's body (above the last full line).
    try testing.expectEqual(&b.body, c.which(.{ .x = 100, .y = 300 }).?);
    // The dead corner past B's last full line (x in the body, y in the fringe).
    try testing.expect(c.which(.{ .x = 100, .y = 390 }) == null);
    // Outside the column entirely.
    try testing.expect(c.which(.{ .x = 100, .y = 500 }) == null);
}
