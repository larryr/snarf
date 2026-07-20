//! A row: a `rowtag` `Text` over a horizontal sequence of `Column`s that share
//! the row's rectangle, separated by `Border`-px black vertical bands. This is
//! acme's top-level layout container. file-as-struct (S-07 P-1): this file *is*
//! the Row.
//!
//! Ported from larryr/plan9port@337c6ac acme/rows.c; cite as `rows.c:NN`. This is
//! `rowinit` (rows.c:25-48), `rowadd` (rows.c:50-101), `rowresize`
//! (rows.c:103-138), `rowwhich` (rows.c:255-266) and `rowwhichcol`
//! (rows.c:242-253). `rowtype`/`rowdragcol`/`rowclose`/`Dump`/`Load` are phases
//! 9/10; the `clearmouse`/warp calls are dropped (R-P8-7).
//!
//! Columns are individually HEAP-allocated (`allocator.create`) and stored as
//! pointers for address stability (contract §7-8), owned by the Row.
//!
//! Imports: `std` + `draw` + sibling core files only (S-07 §6).
const std = @import("std");
const draw = @import("draw");
const Chrome = @import("Chrome.zig");
const Text = @import("text/Text.zig");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");
const Column = @import("Column.zig");
const Editor = @import("Editor.zig");

const Row = @This();
const Rect = draw.Rect;
const Point = draw.Point;

pub const Error = Text.Error;

/// `Lcolhdr` (rows.c:16-23): the row-tag command band, 29 runes incl. the
/// trailing space the caret sits after.
const header = "Newcol Kill Putall Dump Exit ";

r: Rect,
tag: Text,
/// The row tag's backing `File`, owned by the Row.
tag_file: File,
/// The columns, left to right. Heap-created pointers (stability §7-8), owned by
/// the Row (freed by `deinit`).
col: std.ArrayList(*Column) = .empty,
/// Running window id — the C's global `winid`, moved here (R-P9-5) so it is
/// reachable from the Editor via `ed.row`, letting New/Newcol mint ids
/// mid-session. `Column.add` pre-increments it (the C's `++winid`).
winid: u32 = 0,
chrome: *const Chrome,

/// `rowinit` (rows.c:25-48): white fill, a `rowtag` `Text` over the top
/// `font.height` strip, a `Border`-px black band beneath it, and the command
/// header with the caret at its end. (Unlike a column, no button.)
pub fn init(row: *Row, chrome: *const Chrome, r: Rect) Error!void {
    const a = chrome.allocator;
    const font = chrome.font;
    const fh: i32 = font.height;
    const screen = &chrome.display.image;

    row.chrome = chrome;
    row.r = r; // rows.c:32
    row.col = .empty; // rows.c:33-34 row->col = nil / row->ncol = 0
    row.winid = 0; // the C's global winid seed (field default doesn't apply to create()+init)

    try screen.draw(r, chrome.white, null, .{}); // rows.c:31 white fill

    // rowtag over the top one-line strip (rows.c:35-39).
    var r1 = r;
    r1.max.y = r1.min.y + fh;
    row.tag_file = File.init(a, try Buffer.initFromBytes(a, ""));
    errdefer row.tag_file.deinit();
    row.tag = try Text.init(&row.tag_file, a, r1, font, screen, chrome.tag_cols);
    row.tag.what = .rowtag; // rows.c:39

    // Border-px black band beneath the tag (rows.c:43-45).
    r1.min.y = r1.max.y;
    r1.max.y += Chrome.border;
    try screen.draw(r1, chrome.black, null, .{}); // rows.c:45

    // Header text + caret at the end (rows.c:46-47).
    try row.tag.insertAt(0, header, true); // textinsert
    const nc = row.tag.file.buffer.len();
    try row.tag.setSelect(nc, nc); // textsetselect
}

/// Free the tag, its `File`, and every owned column (each column frees its own
/// windows; body `File`s are caller-owned and are not freed here).
pub fn deinit(row: *Row) void {
    const a = row.chrome.allocator;
    for (row.col.items) |c| {
        c.deinit();
        a.destroy(c);
    }
    row.col.deinit(a);
    row.tag.deinit();
    row.tag_file.deinit();
}

/// `rowadd` (rows.c:50-101), no-clone: place a new empty column at (or near)
/// `x_in`. With `x_in` left of the column region and at least one column present,
/// steal the right 2/5 of the last column (splitting it at 3/5). Refuse (return
/// `null`) when the landing column is narrower than 100px. Otherwise shrink the
/// landing column to the left of the split and carve the new one out of the
/// remainder.
pub fn add(row: *Row, x_in: i32) Error!?*Column {
    const a = row.chrome.allocator;
    const screen = &row.chrome.display.image;
    const bd = Chrome.border;

    var x = x_in;
    var r = row.r;
    r.min.y = row.tag.fr.r.max.y + bd; // rows.c:59
    const ncol = row.col.items.len;

    // steal 3/5 of the last column by default (rows.c:60-63).
    if (x < r.min.x and ncol > 0) {
        const d = row.col.items[ncol - 1];
        x = d.r.min.x + @divTrunc(3 * dx(d.r), 5);
    }

    // find the column we'll land on (rows.c:65-69).
    var i: usize = 0;
    while (i < ncol) : (i += 1) {
        if (x < row.col.items[i].r.max.x) break;
    }

    if (ncol > 0) {
        if (i < ncol) i += 1; // new column goes after d (rows.c:71-72)
        const d = row.col.items[i - 1];
        r = d.r;
        if (dx(r) < 100) return null; // rows.c:74-75 refuse
        try screen.draw(r, row.chrome.white, null, .{}); // rows.c:76
        var r1 = r;
        r1.max.x = @min(x - bd, r.max.x - 50); // rows.c:78
        if (dx(r1) < 50) r1.max.x = r1.min.x + 50; // rows.c:79-80
        try d.resize(r1); // rows.c:81 colresize
        // Border-px black vertical band beside d (rows.c:82-84).
        r1.min.x = r1.max.x;
        r1.max.x = r1.min.x + bd;
        try screen.draw(r1, row.chrome.black, null, .{});
        r.min.x = r1.max.x; // rows.c:85
    }

    // heap-create the new column over the freed rect (c==nil branch, rows.c:87-90).
    const c = try a.create(Column);
    errdefer a.destroy(c);
    try c.init(row.chrome, r); // colinit
    errdefer c.deinit();
    c.row = row; // rows.c:93

    // splice at index i (rows.c:95-98).
    try row.col.insert(a, i, c);
    return c;
}

/// `rowclose` (rows.c:208-239), the x-axis mirror of `Column.close`: find `c`'s
/// index (assert found); capture `r = c.r`; `dofree` drops the Editor's text
/// refs into EVERY window of the column (R-P9-13 — the C's textclose nils fire
/// per window inside colcloseall's winclose cascade, text.c:109/113) and then
/// destroys the whole column (`colcloseall`, cols.c:211-227 — `Column.deinit`
/// already cascades to every owned window/File); splice `c` out. An emptied row
/// white-fills and returns; otherwise the LAST column extends RIGHT or the NEXT
/// column extends LEFT, the freed rect is white-filled (rows.c uses
/// `display->white` here, not the body BACK color), and the neighbor is resized
/// into it.
pub fn close(row: *Row, ed: *Editor, c: *Column, dofree: bool) Error!void {
    const a = row.chrome.allocator;
    const screen = &row.chrome.display.image;

    const i = blk: {
        for (row.col.items, 0..) |it, idx| {
            if (it == c) break :blk idx;
        }
        unreachable; // rows.c:215 error("can't find column")
    };

    var r = c.r; // rows.c:216

    if (dofree) {
        for (c.w.items) |w| ed.dropTextRefs(w); // R-P9-13; text.c:109/113
        c.deinit(); // colcloseall (cols.c:211-227): cascades tag + every window
        a.destroy(c);
    }

    _ = row.col.orderedRemove(i); // rows.c:220-221

    const ncol = row.col.items.len;
    if (ncol == 0) {
        try screen.draw(r, row.chrome.white, null, .{}); // rows.c:223-225
        return;
    }

    var neighbor: *Column = undefined;
    if (i == ncol) {
        // extend the last (previous) column right (rows.c:227-230).
        neighbor = row.col.items[i - 1];
        r.min.x = neighbor.r.min.x;
        r.max.x = row.r.max.x;
    } else {
        // extend the next column left (rows.c:231-233).
        neighbor = row.col.items[i];
        r.max.x = neighbor.r.max.x;
    }

    try screen.draw(r, row.chrome.white, null, .{}); // rows.c:235
    try neighbor.resize(r); // rows.c:236
}

/// `rowresize` (rows.c:103-138): relayout the tag strip + black band, then scale
/// every column in x proportionally to the row's width change (`deltax` shifts
/// the origin), with a `Border`-px black band between adjacent columns.
pub fn resize(row: *Row, r: Rect) Error!void {
    const font = row.chrome.font;
    const fh: i32 = font.height;
    const screen = &row.chrome.display.image;
    const bd = Chrome.border;

    const or_ = row.r; // rows.c:110
    const deltax = r.min.x - or_.min.x; // rows.c:111
    row.r = r; // rows.c:112

    var r1 = r;
    r1.max.y = r1.min.y + fh;
    _ = try row.tag.resize(r1, true); // rows.c:115 textresize TRUE
    r1.min.y = r1.max.y;
    r1.max.y += bd;
    try screen.draw(r1, row.chrome.black, null, .{}); // rows.c:118 band

    var rr = r;
    rr.min.y = r1.max.y; // rows.c:119
    r1 = rr; // rows.c:120
    r1.max.x = r1.min.x; // rows.c:121
    for (row.col.items, 0..) |c, i| {
        r1.min.x = r1.max.x; // rows.c:124
        if (i == row.col.items.len - 1) { // safe: loop body ⇒ len ≥ 1
            r1.max.x = rr.max.x; // rows.c:127
        } else {
            // proportional x-scale of the column's right edge (rows.c:129).
            r1.max.x = @divTrunc((c.r.max.x - or_.min.x) * dx(rr), dx(or_)) + deltax;
        }
        if (i > 0) { // border band between columns (rows.c:130-135)
            var r2 = r1;
            r2.max.x = r2.min.x + bd;
            try screen.draw(r2, row.chrome.black, null, .{});
            r1.min.x = r2.max.x;
        }
        try c.resize(r1); // rows.c:136 colresize
    }
}

/// `rowwhichcol` (rows.c:242-253): the column containing `p`, or null.
pub fn whichCol(row: *Row, p: Point) ?*Column {
    for (row.col.items) |c| {
        if (ptinrect(p, c.r)) return c;
    }
    return null;
}

/// `rowwhich` (rows.c:255-266): the row tag if `p` is in it, else the `Text`
/// resolved by the column at `p` (`colwhich`), else null.
pub fn which(row: *Row, p: Point) ?*Text {
    if (ptinrect(p, row.tag.all)) return &row.tag; // rows.c:260-261
    if (row.whichCol(p)) |c| return c.which(p); // rows.c:262-264
    return null; // rows.c:265
}

// --- small geometry helpers (libc rectangle macros) ---
fn dx(r: Rect) i32 {
    return r.max.x - r.min.x;
}

fn ptinrect(p: Point, r: Rect) bool {
    return p.x >= r.min.x and p.x < r.max.x and p.y >= r.min.y and p.y < r.max.y;
}

// ===========================================================================
// Tests. 9x18 font (height 18, width 9); Border 2, Scrollwid 12, Scrollgap 4.
// Layout pins are hand-computed from rows.c against these constants.
// ===========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;
const Window = @import("Window.zig");

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

const RowHarness = struct {
    fx: Frame.TestFixture,
    chrome: *Chrome,
    row: *Row,
    bodies: std.ArrayList(*File),
    winid: u32 = 0,

    fn init(r: Rect) !*RowHarness {
        const a = testing.allocator;
        const h = try a.create(RowHarness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.chrome = try Chrome.init(a, h.fx.disp, h.fx.font);
        h.row = try a.create(Row);
        try h.row.init(h.chrome, r);
        h.bodies = .empty;
        h.winid = 0;
        return h;
    }

    /// Add a window with a `lines`-line body to column `c` at `y`.
    fn addWin(h: *RowHarness, c: *Column, lines: usize, y: i32) !*Window {
        const a = testing.allocator;
        const seed = try genLines(a, lines);
        defer a.free(seed);
        const f = try a.create(File);
        f.* = File.init(a, try Buffer.initFromBytes(a, seed));
        try h.bodies.append(a, f);
        const w = try c.add(&h.winid, f, y);
        try w.body.fill(); // displayed-window precondition (see Column ColHarness)
        return w;
    }

    fn deinit(h: *RowHarness) void {
        const a = testing.allocator;
        h.row.deinit();
        a.destroy(h.row);
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

test "row: init lays out the rowtag header and caret" {
    const h = try RowHarness.init(proto.Rect.make(0, 0, 600, 400));
    defer h.deinit();
    const row = h.row;

    try testing.expect(row.tag.what == .rowtag);
    try testing.expectEqual(@as(usize, 0), row.col.items.len);
    try testing.expectEqual(@as(usize, 29), row.tag.file.buffer.len()); // 29-rune header
    try testing.expectEqual(@as(usize, 29), row.tag.q1);
    try testing.expectEqual(@as(i32, 18), row.tag.fr.r.max.y);
}

test "row: add steals 3/5 split and refuses <100px" {
    // --- 3/5 steal ---
    {
        const h = try RowHarness.init(proto.Rect.make(0, 0, 600, 400));
        defer h.deinit();
        const row = h.row;

        const c0 = (try row.add(0)).?; // first column fills the region (0..600)
        try testing.expectEqual(@as(i32, 600), c0.r.max.x);

        // x<min ⇒ split c0 at min.x + 3*Dx/5 = 360; c0 keeps 0..358 (360-Border),
        // the new column takes 360..600.
        const c1 = (try row.add(-1)).?;
        try testing.expectEqual(@as(usize, 2), row.col.items.len);
        try testing.expectEqual(@as(i32, 358), c0.r.max.x);
        try testing.expectEqual(@as(i32, 360), c1.r.min.x);
        try testing.expectEqual(@as(i32, 600), c1.r.max.x);
    }

    // --- refuses a landing column narrower than 100px ---
    {
        const h = try RowHarness.init(proto.Rect.make(0, 0, 150, 400));
        defer h.deinit();
        const row = h.row;

        _ = (try row.add(0)).?; // c0: 0..150
        const c1 = (try row.add(75)).?; // split at 75 → c0 0..73, c1 75..150 (Dx 75)
        try testing.expectEqual(@as(i32, 75), c1.r.min.x);
        // Landing on the 75px-wide c1 (<100) refuses.
        try testing.expect((try row.add(100)) == null);
        try testing.expectEqual(@as(usize, 2), row.col.items.len);
    }
}

test "row: resize scales columns in x with row tag strip" {
    const h = try RowHarness.init(proto.Rect.make(0, 0, 600, 400));
    defer h.deinit();
    const row = h.row;

    _ = (try row.add(0)).?; // c0: 0..600
    _ = (try row.add(300)).?; // split at 300 → c0 0..298, c1 300..600

    // Double the width: Dx(r)/Dx(or) = 1200/600 = 2, deltax = 0. c0's right edge
    // 298 → 596; c1 takes 598..1200 (past the 2px band). The tag strip spans the
    // new width.
    try row.resize(proto.Rect.make(0, 0, 1200, 400));
    try testing.expectEqual(proto.Rect.make(0, 20, 596, 400), row.col.items[0].r);
    try testing.expectEqual(proto.Rect.make(598, 20, 1200, 400), row.col.items[1].r);
    try testing.expectEqual(proto.Rect.make(0, 0, 1200, 400), row.r);
    try testing.expectEqual(@as(i32, 1200), row.tag.all.max.x);
}

test "row: which finds rowtag/columntag/tag/body" {
    const h = try RowHarness.init(proto.Rect.make(0, 0, 600, 400));
    defer h.deinit();
    const row = h.row;

    const c0 = (try row.add(0)).?; // c0: (0,20)..(600,400); its columntag at y 20..38
    const win = try h.addWin(c0, 40, 20); // window: tag 40..58, body from 59

    // rowtag (the row's own top strip).
    try testing.expectEqual(&row.tag, row.which(.{ .x = 100, .y = 5 }).?);
    // columntag (routed through colwhich).
    try testing.expectEqual(&c0.tag, row.which(.{ .x = 100, .y = 25 }).?);
    // window tag.
    try testing.expectEqual(&win.tag, row.which(.{ .x = 100, .y = 45 }).?);
    // window body.
    try testing.expectEqual(&win.body, row.which(.{ .x = 100, .y = 200 }).?);
    // outside every column and the row tag.
    try testing.expect(row.which(.{ .x = 100, .y = 500 }) == null);
}

// --- close (rows.c:208-239) ----------------------------------------------------

test "row: close removes a column and the neighbor grows back" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();

    // Close the LEFT column: the right column extends LEFT to cover the whole
    // row body (rows.c:231-235, the "extend next window left" arm mirrored in x).
    {
        const h = try RowHarness.init(proto.Rect.make(0, 0, 600, 400));
        defer h.deinit();
        const row = h.row;
        const c0 = (try row.add(0)).?; // 0..600
        const c1 = (try row.add(-1)).?; // split at 360: c0 0..358, c1 360..600

        try row.close(&ed, c0, true);
        try testing.expectEqual(@as(usize, 1), row.col.items.len);
        try testing.expectEqual(c1, row.col.items[0]);
        try testing.expectEqual(proto.Rect.make(0, 20, 600, 400), row.col.items[0].r);
    }

    // Mirror: close the RIGHT (last) column — the left column extends RIGHT to
    // `row.r.max.x` (rows.c:227-230). Editor refs into the dying column's
    // windows are dropped (R-P9-13, the C's per-window textclose nils).
    {
        const h = try RowHarness.init(proto.Rect.make(0, 0, 600, 400));
        defer h.deinit();
        const row = h.row;
        const c0 = (try row.add(0)).?;
        const c1 = (try row.add(-1)).?;

        const f = try testing.allocator.create(File);
        f.* = File.init(testing.allocator, try Buffer.initFromBytes(testing.allocator, "x"));
        const w = try c1.add(&row.winid, f, -1);
        w.owns_body = true;
        ed.seltext = &w.body;
        ed.argtext = &w.tag;

        try row.close(&ed, c1, true);
        try testing.expect(ed.seltext == null); // dropped, not dangling
        try testing.expect(ed.argtext == null);
        try testing.expectEqual(@as(usize, 1), row.col.items.len);
        try testing.expectEqual(c0, row.col.items[0]);
        try testing.expectEqual(proto.Rect.make(0, 20, 600, 400), row.col.items[0].r);
    }
}
