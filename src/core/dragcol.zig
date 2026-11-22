//! `rowdragcol` (rows.c:140-206) — drag a column tag's button to resize against
//! the column on its left, or to move the column. Namespace module (S-07 P-1).
//! Ported from larryr/plan9port@337c6ac.
//!
//! Acme blocks in `readmouse`. Snarf is edge-triggered: one sample is one
//! `Editor.handleMouse`, and `Gesture` routes every sample here until the
//! gesture ends (`Drag` lives on `Gesture`, no globals). While the tracked
//! button is down the pointer is acme's box (`cursor.box`, rows.c:151); it
//! returns to the arrow when that button changes (rows.c:156), before any
//! layout. Layout moves only on a clean button-up; there is no rubber-band.
//!
//! Imports: `draw` and sibling core files. Does not import `Gesture` (same
//! cycle shape as `textselect` / `Editor` / `Gesture`). Never dev/shim.
const draw = @import("draw");
const Editor = @import("Editor.zig");
const Column = @import("Column.zig");
const Row = @import("Row.zig");
const Chrome = @import("Chrome.zig");
const restoremouse = @import("restoremouse.zig");
const cursor = @import("cursor.zig");
const warp = @import("warp.zig");

const Point = draw.Point;
const MouseEvent = Editor.MouseEvent;

/// Pinned column drag. `col == null` means idle.
pub const Drag = struct {
    /// Column captured at the press. Not read after a destroy (rows.c:179).
    col: ?*Column = null,
    /// `b` (rows.c:152): the button set that started the drag.
    buttons: u8 = 0,
    /// `op` (rows.c:153): the press point.
    op: Point = .{},
    /// A sample arrived with a different non-zero button set (rows.c:157-160).
    /// Further samples are discarded until every button is up.
    draining: bool = false,
};

const Release = enum { inert, painted, destroyed };

/// Press on a column tag's button (rows.c:150-153). No layout, no `activecol`.
pub fn begin(ed: *Editor, d: *Drag, c: *Column, buttons: u8, pt: Point) void {
    restoremouse.clear(ed); // rows.c:150 clearmouse()
    cursor.set(ed, cursor.box); // rows.c:151 setcursor2(boxcursor)
    d.* = .{
        .col = c,
        .buttons = buttons,
        .op = pt,
    };
}

/// One sample of a drag that `begin` already pinned. `true` means the gesture
/// is over and the caller drops `d` (the column may already be freed).
pub fn step(ed: *Editor, d: *Drag, ev: MouseEvent) Row.Error!bool {
    const c = d.col orelse return true;
    const b = ev.buttons;
    if (d.draining) {
        if (b != 0) return false; // rows.c:158 while(mouse->buttons)
        if (columnInRow(c)) ed.activecol = c; // acme.c:639-640, at gesture end
        return true;
    }
    if (b == d.buttons) return false; // rows.c:154 while(buttons == b)
    cursor.arrow(ed); // rows.c:156 setcursor(nil), before layout or the drain
    if (b != 0) {
        d.draining = true; // rows.c:157-160 cancel; do not apply
        return false;
    }
    switch (try release(ed, d, c, d.op, .{ .x = ev.x, .y = ev.y })) {
        .inert => {
            if (columnInRow(c)) ed.activecol = c;
        },
        .painted => {
            if (columnInRow(c)) ed.activecol = c;
            ed.needs_flush = true;
        },
        // `c` was freed. Do not read it and do not assign `activecol`.
        .destroyed => ed.needs_flush = true,
    }
    return true;
}

fn release(ed: *Editor, d: *Drag, c: *Column, op: Point, p: Point) Row.Error!Release {
    const row = c.row orelse return .inert;
    const i = columnIndex(row, c) orelse return .inert; // gone: no paint, no unreachable
    // Five pixels on one axis is enough. Four on both is not (rows.c:170-171).
    if (deadzone(p.x, op.x) and deadzone(p.y, op.y)) return .inert;

    const ncol = row.col.items.len;
    const shuffle_left = i > 0 and p.x < row.col.items[i - 1].r.min.x;
    const shuffle_right = i + 1 < ncol and p.x > c.r.max.x;
    if (shuffle_left or shuffle_right) return try shuffle(ed, d, row, c, p); // rows.c:172-184
    if (i == 0) return .inert; // rows.c:185-186 leftmost is resized by its right neighbor
    if (try resizePair(ed, row, row.col.items[i - 1], c, p)) return .painted;
    return .inert; // the pair cannot hold two columns without a panic; no paint
}

fn shuffle(ed: *Editor, d: *Drag, row: *Row, c: *Column, p: Point) Row.Error!Release {
    const x = c.r.min.x; // rows.c:174, before the detach
    try row.close(ed, c, false); // rows.c:175
    if (try row.attach(ed, c, p.x) == null) { // rows.c:176
        if (try row.attach(ed, c, x) == null) { // rows.c:177
            if (try row.attach(ed, c, -1) == null) { // rows.c:178
                d.col = null; // about to free `c`; do not read it after close
                try row.close(ed, c, true); // rows.c:179
                return .destroyed;
            }
        }
    }
    colmousebut(ed, c); // rows.c:182
    return .painted;
}

/// Resize `c` against `d`, the column on its left (rows.c:187-205).
/// Lower clamp, then upper, so the upper bound wins when both cannot hold.
/// False, and nothing is drawn, when that x would make either column narrower
/// than `Row.resize`'s floor: acme dies in `frinsert` there, and a browser
/// window is allowed to be that narrow (R-GFX-05). The 80px margins are not
/// changed when both sides still fit.
fn resizePair(ed: *Editor, row: *Row, d: *Column, c: *Column, p: Point) Row.Error!bool {
    var x = p.x;
    const margin: i32 = 80; // rows.c:188-191
    const lo = d.r.min.x + margin + Chrome.scrollwid;
    const hi = c.r.max.x - margin - Chrome.scrollwid;
    if (x < lo) x = lo;
    if (x > hi) x = hi;

    // Same floor as `Row.minColWidth`: scrollbar strip + gap + one glyph.
    const min_col = Chrome.scrollwid + Chrome.scrollgap + row.chrome.font.height;
    if (x - d.r.min.x < min_col or c.r.max.x - (x + Chrome.border) < min_col) return false;

    const screen = &row.chrome.display.image;
    var span = d.r;
    span.max.x = c.r.max.x; // rects from before the clamp is applied to them
    try screen.draw(span, row.chrome.ground, null, .{}); // rows.c:194 white → ground

    var left = d.r;
    left.max.x = x;
    try d.resize(ed, left); // rows.c:196

    var band = c.r;
    band.min.x = x;
    band.max.x = x + Chrome.border;
    try screen.draw(band, row.chrome.rule, null, .{}); // rows.c:201 black → rule

    var right = c.r;
    right.min.x = x + Chrome.border;
    try c.resize(ed, right); // rows.c:204
    colmousebut(ed, c); // rows.c:205
    return true;
}

/// `colmousebut` (cols.c:230-233): warp to the center of the tag button.
/// `divpt(addpt(min, max), 2)` — integer division toward zero.
fn colmousebut(ed: *Editor, c: *Column) void {
    const s = c.tag.scrollr;
    warp.to(ed, .{
        .x = @divTrunc(s.min.x + s.max.x, 2),
        .y = @divTrunc(s.min.y + s.max.y, 2),
    });
}

fn columnIndex(row: *Row, c: *Column) ?usize {
    for (row.col.items, 0..) |it, i| {
        if (it == c) return i;
    }
    return null;
}

fn columnInRow(c: *Column) bool {
    const row = c.row orelse return false;
    return columnIndex(row, c) != null;
}

/// True when the non-negative distance on one axis is `< 5` (rows.c:170).
fn deadzone(a: i32, b: i32) bool {
    const delta: i64 = @as(i64, a) - @as(i64, b);
    const mag: i64 = if (delta < 0) -delta else delta;
    return mag < 5;
}

test {
    _ = @import("dragcol_test.zig");
}
