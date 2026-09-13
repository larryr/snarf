//! Window placement — `makenewwindow` (util.c:449-495, "Heuristic city") and the
//! shared empty-window mint helper every creation path funnels through.
//! Namespace module (S-07 P-1, lowercase). Ported from larryr/plan9port@337c6ac;
//! cite as `util.c:NN` / `cols.c:NN`.
//!
//! R-EDIT-23 (placement / active column). Split out of `exec/cmd_window.zig` so
//! that file keeps its ~400-line soft cap once the placement tests land: the
//! builtins stay there, the geometry lives here. `colOf`/`rowOf` (the C's
//! `t->col`/`t->row` fields) moved here with it — `cmd_window` and `Editor` both
//! need them.
//!
//! Deliberately NOT used by `New`/`Newcol`: look.c:922 makes New's window with
//! `coladd(et->col, nil, nil, -1)`, i.e. the executing tag's own column, and
//! exec.c:352-364 does the same for Newcol (R-P12b-2). The heuristic is for
//! windows nobody pointed at: the served `new` walk (acme.c:877 `makenewwindow(nil)`)
//! today; `openfile` (look.c:283) and `plumblook` (look.c:856) when they land.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const draw = @import("draw");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");
const Window = @import("Window.zig");
const Column = @import("Column.zig");
const Row = @import("Row.zig");

/// `t->col` (dat.h): the Column a Text belongs to. A window text ⇒ the window's
/// column; a columntag ⇒ its own Column (via `@fieldParentPtr`); anything else
/// (a rowtag) ⇒ null.
pub fn colOf(et: *Text) ?*Column {
    if (et.w) |w| return w.col;
    if (et.what == .columntag) {
        const c: *Column = @fieldParentPtr("tag", et);
        return c;
    }
    return null;
}

/// `t->row` (dat.h): the Row a Text belongs to. A rowtag ⇒ its own Row (via
/// `@fieldParentPtr`); otherwise the row of `colOf(et)`.
pub fn rowOf(et: *Text) ?*Row {
    if (et.what == .rowtag) {
        const r: *Row = @fieldParentPtr("tag", et);
        return r;
    }
    const c = colOf(et) orelse return null;
    return c.row;
}

/// Mint one empty window named `name` into column `c` at `y` (`coladd(c, nil,
/// nil, y)` + `winsetname` + `winsettag`, cols.c:52-158 / look.c:921-926).
/// `y < c.r.min.y` (conventionally `-1`) means the C's "steal the bottom half of
/// the last window" default.
///
/// Mirrors `boot.addWinTo`: heap a body `File` over "", hand it to the Column
/// (which takes ownership, `owns_body`, R-P9-5), set the name, compose the tag
/// (`setTag1`), park the caret at the tag end, and fill both frames. THE single
/// creation seam: `cmd_window.makeWindow` (New/Newcol), `makeNewWindow` below and
/// `errors.errorWin` (+Errors) all go through it, so a future `openfile` replaces
/// exactly one function.
pub fn mintWindow(c: *Column, y: i32, name: []const u8) Text.Error!*Window {
    const a = c.chrome.allocator;
    const f = try a.create(File);
    var transferred = false;
    errdefer if (!transferred) a.destroy(f);
    f.* = File.init(a, try Buffer.initFromBytes(a, ""));
    errdefer if (!transferred) f.deinit();

    const w = try c.add(&c.row.?.winid, f, y); // coladd (steal / split)
    w.owns_body = true; // the Window now owns and frees this body File
    transferred = true; // f is reachable from the tree; its deinit chain frees it

    try w.body.file.setName(name);
    try w.setTag1();
    const nc = w.tag.file.buffer.len();
    try w.tag.setSelect(nc, nc);
    try w.body.fill();
    try w.tag.fill();
    return w;
}

fn dy(r: draw.proto.Rect) i32 {
    return r.max.y - r.min.y;
}

/// `makenewwindow` (util.c:449-495) — "Heuristic city": pick the column, then the
/// spot inside it, for a window nobody placed by hand (R-EDIT-23). `t` is the C's
/// `Text *t` argument: the Text the new window is "near" (null from the served
/// `new` walk, acme.c:877).
///
/// Column (util.c:454-466): `activecol`, else `seltext`'s column, else `t`'s
/// column, else the LAST column — creating one when the row has none. The chosen
/// column becomes `activecol` (util.c:466), so a burst of served `new`s stacks in
/// one column.
///
/// Spot (util.c:467-494): with no reference window (`t==nil`, `t->w==nil`) or an
/// empty column, `coladd(c,nil,nil,-1)` steals the bottom half of the last
/// window. Otherwise find the window with the most SCREEN lines (`bigw`) and the
/// one with the most BLANK lines (`emptyw`) — the C's `>=` deliberately picks the
/// LOWER of equals, i.e. the one nearer the bottom of the screen. A big blank
/// spot (`el>15`, or `el>3` and more than half of `bigw`) is used as-is; else the
/// biggest window is split at its vertical midpoint — unless `t`'s own window is
/// in this column and is at least 2/3 as tall, in which case THAT is split.
///
/// DROPPED: no `moveto` warp exists on this path in the C, and R-EDIT-25 forbids
/// adding one.
pub fn makeNewWindow(ed: *Editor, t: ?*Text) Text.Error!*Window {
    // --- column choice (util.c:454-466) ------------------------------------
    const c: *Column = blk: {
        if (ed.activecol) |ac| break :blk ac; // util.c:454-455
        if (ed.seltext) |st| {
            if (colOf(st)) |sc| break :blk sc; // util.c:456-457
        }
        if (t) |tt| {
            if (colOf(tt)) |tc| break :blk tc; // util.c:458-459
        }
        // util.c:460-465: last column, creating one if the row has none. The C
        // `error()`s (fatal) when it cannot; the port raises IoError.
        const row = ed.row orelse return error.IoError;
        if (row.col.items.len == 0) {
            break :blk (try row.add(-1)) orelse return error.IoError; // util.c:461-462
        }
        break :blk row.col.items[row.col.items.len - 1]; // util.c:464
    };
    ed.activecol = c; // util.c:466

    // --- no reference window, or an empty column (util.c:467-468) ----------
    const tw: ?*Window = if (t) |tt| tt.w else null;
    if (tw == null or c.w.items.len == 0) return mintWindow(c, -1, "");

    // --- biggest window and biggest blank spot (util.c:471-481) ------------
    var emptyw: *Window = c.w.items[0];
    var bigw: *Window = emptyw;
    for (c.w.items[1..]) |w| {
        // "use >= to choose one near bottom of screen" (util.c:475)
        if (w.body.fr.maxlines >= bigw.body.fr.maxlines) bigw = w;
        if (blank(w) >= blank(emptyw)) emptyw = w;
    }
    const emptyb = &emptyw.body;
    const el = blank(emptyw); // util.c:483

    var y: i32 = undefined;
    if (el > 15 or (el > 3 and el > @divTrunc(lines(bigw) - 1, 2))) {
        // if empty space is big, use it (util.c:485-486)
        y = emptyb.fr.r.min.y + @as(i32, @intCast(emptyb.fr.nlines)) * emptyb.fr.font.height;
    } else {
        // if this window is in column and isn't much smaller, split it
        // (util.c:489-490)
        var victim = bigw;
        if (tw) |w| {
            if (colOf(t.?) == c and dy(w.r) > @divTrunc(2 * dy(bigw.r), 3)) victim = w;
        }
        y = @divTrunc(victim.r.min.y + victim.r.max.y, 2); // util.c:491
    }
    const w = try mintWindow(c, y, ""); // util.c:493 coladd(c, nil, nil, y)
    // DEFERRED colgrow (cols.c:333+) R-P12b-3: the C follows with
    // `if(w->body.fr.maxlines < 2) colgrow(w->col, w, 1)` (util.c:494).
    return w;
}

/// `w->body.fr.maxlines` as a signed count (the C's int field).
fn lines(w: *Window) i32 {
    return @intCast(w.body.fr.maxlines);
}

/// `fr.maxlines - fr.nlines`, the blank-line count (util.c:477/483). Signed
/// because the C compares it against -1/2 and the frame can momentarily report
/// `nlines > maxlines` mid-resize.
fn blank(w: *Window) i32 {
    return @as(i32, @intCast(w.body.fr.maxlines)) - @as(i32, @intCast(w.body.fr.nlines));
}

// ===========================================================================
// Tests. The named placement tests (T10-T14 of the phase-12b contract) live in
// `exec/cmd_window.zig` alongside the builtins they serve; this smoke test only
// keeps the module's own decls reachable.
// ===========================================================================
const testing = std.testing;

test "place: mintWindow and makeNewWindow are reachable" {
    try testing.expect(@TypeOf(mintWindow) != void);
    try testing.expect(@TypeOf(makeNewWindow) != void);
}
