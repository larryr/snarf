//! `colgrow` (cols.c:333-472) — give one window in a column more room, taking it
//! from its neighbours. Namespace module (S-07 P-1) over `*Column`, carved out
//! of `Column.zig` so that file stays inside the ~400-line cap; `Column` keeps a
//! decl alias, so `c.grow(w)` resolves exactly as a method would.
//!
//! SCOPE (R-P12b-3, phase-16b contract item 11): the `but == 1` arm ONLY —
//! "grow this window a bit at its neighbours' expense", which is the call
//! `makenewwindow` makes when the window it just placed came out under two lines
//! (util.c:494-495) and the one `coladd` makes to fatten a landing window before
//! splitting it (cols.c:81-87). `colgrow` is 141 lines in the C, past the
//! contract's verbatim-port threshold, so its other arms stay out:
//!
//!   * `but < 0` — "make sure the window fills its own space", the Zerox/
//!     `winctl`-resize path (exec.c:1344). No caller in the port yet.
//!   * `but == 2` / `but == 3` — the layout-box clicks (cols.c:507, phase 8
//!     deferred them with the rest of the layout box). `but == 3` also reorders
//!     the column and sets `safe = FALSE`, which nothing here is ready for.
//!
//! The PACKING half below (cols.c:407-470) is shared by every arm in the C and
//! is ported whole, so adding an arm later is the `if` above it, not a rewrite.
//!
//! DROPPED, as everywhere else in the port: `winmousebut(w)` (cols.c:471) warps
//! the pointer onto the grown window's tag button. R-EDIT-25 (as amended in
//! phase 15) makes a warp a `/dev/mouse` write from `core/warp.zig`, and
//! `coladd`'s own `savemouse`/`moveto` arms are dropped for the same reason
//! (R-P8-7).
//!
//! Ported from larryr/plan9port@337c6ac; cite as `cols.c:NN`.
//!
//! Imports: `std` + `draw` + sibling core files only (S-07 §6).
const draw = @import("draw");
const Chrome = @import("Chrome.zig");
const Column = @import("Column.zig");
const Window = @import("Window.zig");
const Text = @import("text/Text.zig");

const Rect = draw.Rect;

/// Grow `w` inside its column, `but == 1`: aim for roughly half again as many
/// lines (or five more, whichever is larger), never more than the column holds,
/// and take the difference from the nearest neighbours outwards — half of each
/// one's lines at a time, alternating below then above (cols.c:391-405).
///
/// `error.IoError` if `w` is not in `c` (the C `error()`s, cols.c:341).
pub fn grow(c: *Column, w: *Window) Text.Error!void {
    const i = indexOf(c, w) orelse return error.IoError; // cols.c:338-341
    const a = c.chrome.allocator;
    const nw = c.w.items.len;

    var cr = c.r; // cols.c:344
    cr.min.y = c.w.items[0].r.min.y; // cols.c:355

    // Old line count per window, and the column's total (cols.c:368-375).
    // `taglines-1` is the tag's contribution above the single line every
    // window always has; it is 0 while `taglines == 1` (R-P8-1), and the term
    // is kept so a later `wintaglines` needs no change here.
    const nl = try a.alloc(i32, nw);
    defer a.free(nl);
    const ny = try a.alloc(i32, nw);
    defer a.free(ny);
    @memset(ny, 0);

    const onl: i32 = @intCast(w.body.fr.maxlines); // cols.c:369
    var tot: i32 = 0;
    for (c.w.items, 0..) |v, j| {
        const l = v.taglines - 1 + @as(i32, @intCast(v.body.fr.maxlines)); // cols.c:377
        nl[j] = l;
        tot += l;
    }

    // Approximate the new line count for this window (cols.c:387-392).
    const want = w.taglines - 1 + @as(i32, @intCast(w.maxlines));
    var nnl = @min(onl + @max(@min(@as(i32, 5), want), @divTrunc(onl, 2)), tot);
    if (nnl < want) nnl = @divTrunc(want + nnl, 2);
    if (nnl == 0) nnl = 2;
    var dnl = nnl - onl;

    // Take the difference from the neighbours, nearest first: below, then
    // above, stepping outwards (cols.c:394-405). `max(1, …)` is what stops a
    // one-line neighbour from being skipped forever.
    var k: usize = 1;
    while (k < nw) : (k += 1) {
        if (i + k < nw and nl[i + k] != 0) { // prune from a later window
            const l = @min(dnl, @max(@as(i32, 1), @divTrunc(nl[i + k], 2)));
            nl[i + k] -= l;
            nl[i] += l;
            dnl -= l;
        }
        if (i >= k and nl[i - k] != 0) { // prune from an earlier window
            const l = @min(dnl, @max(@as(i32, 1), @divTrunc(nl[i - k], 2)));
            nl[i - k] -= l;
            nl[i] += l;
            dnl -= l;
        }
    }

    try pack(c, w, i, cr, nl, ny);
}

/// The `Pack:` half (cols.c:407-470): lay every window out at the line counts
/// `nl` names — everyone above `i` from the column top down, everyone below it
/// from the column bottom up, then `w` itself into whatever is left.
fn pack(c: *Column, w: *Window, i: usize, cr: Rect, nl: []const i32, ny: []i32) Text.Error!void {
    const fh: i32 = c.chrome.font.height;
    const screen = &c.chrome.display.image;
    const bd = Chrome.border;
    const nw = c.w.items.len;

    // Pack everyone above (cols.c:408-421).
    var y1 = cr.min.y;
    for (c.w.items[0..i], 0..) |v, j0| {
        var r = v.r;
        r.min.y = y1;
        r.max.y = y1 + dy(v.tagtop);
        if (nl[j0] != 0) r.max.y += 1 + nl[j0] * v.body.fr.font.height;
        r.min.y = try v.resize(r, c.safe, false); // cols.c:417 winresize
        r.max.y = r.min.y + bd;
        try screen.draw(r, c.chrome.black, null, .{}); // cols.c:419
        y1 = r.max.y;
    }

    // Scan upwards to see where everyone below lands (cols.c:423-434).
    var y2 = c.r.max.y;
    var j: usize = nw;
    while (j > i + 1) {
        j -= 1;
        const v = c.w.items[j];
        var r = v.r;
        r.min.y = y2 - dy(v.tagtop);
        if (nl[j] != 0) r.min.y -= 1 + nl[j] * v.body.fr.font.height;
        r.min.y -= bd;
        ny[j] = r.min.y;
        y2 = r.min.y;
    }

    // The grown window takes what is left, floored at one tag line plus one
    // body line plus the border (cols.c:436-441).
    var r = w.r;
    r.min.y = y1;
    r.max.y = y2;
    if (dy(r) < dy(w.tagtop) + 1 + fh + bd) {
        r.max.y = r.min.y + dy(w.tagtop) + 1 + fh + bd;
    }
    r.max.y = try w.resize(r, c.safe, true); // cols.c:443 winresize
    if (i + 1 < nw) { // cols.c:444-450
        r.min.y = r.max.y;
        r.max.y += bd;
        try screen.draw(r, c.chrome.black, null, .{});
        const shift = y2 - r.max.y;
        for (ny[i + 1 ..]) |*v| v.* -= shift;
    }

    // Pack everyone below (cols.c:452-467).
    y1 = r.max.y;
    j = i + 1;
    while (j < nw) : (j += 1) {
        const v = c.w.items[j];
        var vr = v.r;
        vr.min.y = y1;
        vr.max.y = y1 + dy(v.tagtop);
        if (nl[j] != 0) vr.max.y += 1 + nl[j] * v.body.fr.font.height;
        y1 = try v.resize(vr, c.safe, j == nw - 1); // no keepextra but the last
        if (j + 1 < nw) { // no border under the last window (cols.c:461)
            vr.min.y = y1;
            vr.max.y += bd;
            try screen.draw(vr, c.chrome.black, null, .{});
            y1 = vr.max.y;
        }
    }
    c.safe = true; // cols.c:470
}

fn indexOf(c: *Column, w: *Window) ?usize {
    for (c.w.items, 0..) |v, j| if (v == w) return j;
    return null;
}

fn dy(r: Rect) i32 {
    return r.max.y - r.min.y;
}
