//! `colsort` (cols.c:293-331) — the `Sort` builtin's body: restack a column's
//! windows in name order. Namespace module (S-07 P-1) over `*Column`, carved
//! out of `Column.zig` like `colgrow.zig` (size cap); `Column` keeps a decl
//! alias, so `c.sort(ed)` resolves as a method.
//!
//! Order is `colcmp` (cols.c:275-291): rune by rune over the body file names,
//! a proper prefix first. UTF-8 byte order IS code-point order, and a rune
//! prefix is a byte prefix, so `std.mem.order` on the names is the same
//! comparison. acme's `qsort` leaves equal names in an unspecified order; the
//! port's sort is stable (equal names keep their column order), which is one
//! of the orders acme can produce. Directory windows are not special: their
//! names end in `/`, which sorts where '/' sorts (PM Q4: ACME order).
//!
//! Heights: each window keeps its own height (`Dy(w->r)`, cols.c:318), laid
//! out top-down from the column tag with a `Border` band above each; the last
//! window takes whatever is left (cols.c:316-317).
//!
//! Ported from larryr/plan9port@337c6ac; cite as `cols.c:NN`.
//!
//! Imports: `std` + `draw` + sibling core files only (S-07 §6).
const std = @import("std");
const draw = @import("draw");
const Chrome = @import("Chrome.zig");
const Column = @import("Column.zig");
const Window = @import("Window.zig");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const restoremouse = @import("restoremouse.zig");

/// `colcmp` (cols.c:275-291) as a less-than.
fn nameLess(_: void, a: *Window, b: *Window) bool {
    return std.mem.order(u8, a.body.file.name.items, b.body.file.name.items) == .lt;
}

/// `colsort` (cols.c:293-331).
pub fn sort(c: *Column, ed: *Editor) Text.Error!void {
    if (c.w.items.len == 0) return; // cols.c:299-300
    restoremouse.clear(ed); // cols.c:301 clearmouse()
    std.mem.sort(*Window, c.w.items, {}, nameLess); // cols.c:304 qsort(colcmp)
    const screen = &c.chrome.display.image;
    var r = c.r; // cols.c:307
    r.min.y = c.tag.fr.r.max.y; // cols.c:308
    try screen.draw(r, c.chrome.body_cols[@intFromEnum(draw.Frame.ColorSlot.back)], null, .{}); // cols.c:309
    var y = r.min.y; // cols.c:310
    const n = c.w.items.len;
    for (c.w.items, 0..) |w, i| {
        const last = i == n - 1;
        r.min.y = y; // cols.c:313
        if (last) {
            r.max.y = c.r.max.y; // cols.c:315
        } else {
            r.max.y = r.min.y + (w.r.max.y - w.r.min.y) + Chrome.border; // cols.c:317
        }
        var r1 = r; // cols.c:318
        r1.max.y = r1.min.y + Chrome.border; // cols.c:319
        try screen.draw(r1, c.chrome.rule, null, .{}); // cols.c:320 display->black
        r.min.y = r1.max.y; // cols.c:321
        y = try w.resize(r, false, last); // cols.c:322
    }
}
