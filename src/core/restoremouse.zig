//! `restoremouse` — acme's return-after-Del warp: `savemouse`, `restoremouse`
//! and `clearmouse` (util.c:383-408), the paper's third warp ("reducing the
//! irritation of windows that pop up to report annoying errors"). Namespace
//! module (S-07 P-1, lowercase). Ported from larryr/plan9port@337c6ac.
//!
//! The C keeps two file-statics, `prevmouse` and `mousew` (util.c:15-16). Here
//! they are `Editor.prevmouse`/`Editor.mousew` (no globals, S-07), and the
//! dangling-pointer hygiene the C gets for free from `colclose` always calling
//! `restoremouse` is made explicit: `Editor.dropTextRefs` nils `mousew` when its
//! window dies by any path (R-P9-3 lineage).
//!
//! Call sites, as in the C:
//!   * `save`    — every new window (`coladd`, cols.c:150), via
//!                 `place.mintWindow`, the single runtime creation seam.
//!   * `restore` — `Column.close` (`colclose`, cols.c:178).
//!   * `clear`   — typing (`rowtype`, rows.c:277, first thing in
//!                 `Editor.handleKey`) and the B1 chord (text.c:1092).
//!                 `colcloseall` (cols.c:226) is covered by `dropTextRefs` per
//!                 window (`Row.close`).
//!
//! KNOWN GAP (R-EDIT-25, PR #43 review item 5): the C's other `clearmouse`
//! sites are NOT ported. `colsort` (cols.c:303), `coldragwin` (:484) and
//! `rowdragcol` (rows.c:150) have no port yet, so they will clear when they
//! land. `colresize` (cols.c:242 → `Column.resize`) and `rowadd` (rows.c:99 →
//! `Row.add`) are ported but take no Editor, and threading one through is not
//! small: `Row.add` has ~27 call sites (most of them tests), `Column.resize` is
//! reached from `Column.add`, `Row.add`, `Row.resize` and `Row.close`, and
//! `boot.boot` builds the tree (calling both) before any Editor exists. The
//! effect: a pop-up saved before a column resize, Newcol or screen resize
//! still warps back on a later Del. The PM Q3 check below bounds it: the warp
//! fires only if the pointer is still inside the pop-up, i.e. the user went to
//! it and deleted it, which is the case the warp exists for.
//!
//! DIVERGENCE (SnarfProdd, 2026-10-14, PM Q3; R-EDIT-25): restore ONLY if the
//! pointer is still inside the dying window. The C restores whenever
//! `mousew == w` — safe there because `coladd` also warps the pointer INTO the
//! new window (cols.c:153-154), a warp this port does not issue (R-P8-7). With
//! the pointer left where it was, warping back from Del somewhere else would be
//! a surprise, so the check keeps the warp to the case the paper describes:
//! the user went to the pop-up and deleted it.
//!
//! Like every warp, the write is best effort (`warp.to`): no `/dev/mouse`, or a
//! host that refuses it (browser), and nothing happens.
//!
//! Imports: sibling core files only (S-07 §6).
const Editor = @import("Editor.zig");
const Window = @import("Window.zig");
const warp = @import("warp.zig");
const Gesture = @import("Gesture.zig");

/// `savemouse` (util.c:383-388): remember where the pointer is now and which
/// window just popped up.
pub fn save(ed: *Editor, w: *Window) void {
    ed.prevmouse = ed.gesture.mouse_pt; // util.c:386 `mouse->xy`
    ed.mousew = w; // util.c:387
}

/// `restoremouse` (util.c:390-402): if `w` is the saved window (and, PM Q3, the
/// pointer is still inside it), warp back to the saved point. Always forgets
/// the save (util.c:400). Returns the C's `did`.
pub fn restore(ed: *Editor, w: *Window) bool {
    var did = false;
    if (ed.mousew) |mw| {
        if (mw == w and Gesture.ptInRect(w.r, ed.gesture.mouse_pt.x, ed.gesture.mouse_pt.y)) { // util.c:396 + PM Q3
            warp.to(ed, ed.prevmouse); // util.c:397 moveto(mousectl, prevmouse)
            did = true;
        }
    }
    ed.mousew = null; // util.c:400
    return did;
}

/// `clearmouse` (util.c:404-408): forget any saved pop-up.
pub fn clear(ed: *Editor) void {
    ed.mousew = null;
}

const testing = @import("std").testing;

test "restoremouse: save records the point; restore of another window forgets it and does not warp" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var popup: Window = undefined; // never dereferenced on these paths
    var other: Window = undefined;
    ed.gesture.mouse_pt = .{ .x = 5, .y = 7 };
    save(&ed, &popup);
    try testing.expectEqual(@as(i32, 5), ed.prevmouse.x);
    try testing.expectEqual(@as(i32, 7), ed.prevmouse.y);
    try testing.expect(ed.mousew == &popup);
    try testing.expect(!restore(&ed, &other)); // util.c:396 mousew != w
    try testing.expect(ed.mousew == null); // util.c:400 forgets regardless
}

test "restoremouse: clear forgets the saved pop-up" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var popup: Window = undefined;
    save(&ed, &popup);
    clear(&ed);
    try testing.expect(ed.mousew == null);
    try testing.expect(!restore(&ed, &popup));
}
