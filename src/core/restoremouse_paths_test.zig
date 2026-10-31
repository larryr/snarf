//! restoremouse clear paths the RM acceptance suite (`restoremouse_test.zig`,
//! SnarfDev2's) does not reach — PR #43 review items 1 and 4 (#9, R-EDIT-25).
//!
//!   * `rowtype` (rows.c:277) calls `clearmouse()` before anything else, so a
//!     key that `Editor.handleKey` drops on an early return still forgets the
//!     saved pop-up.
//!   * A saved window freed by `Row.close` (`rowclose` → `colcloseall`,
//!     rows.c:208-239 / cols.c:211-227, the Delcol path) never passes through
//!     `Column.close`'s `restoremouse`, so only `Editor.dropTextRefs` clears
//!     `mousew` there. RM-05 goes through `Column.close`, which clears first.
//!
//! Ported from larryr/plan9port@337c6ac. Imports: `std` + `draw` + sibling
//! core files only (S-07 §6).
const std = @import("std");
const testing = std.testing;
const draw = @import("draw");
const boot = @import("boot.zig");
const place = @import("place.zig");
const restoremouse = @import("restoremouse.zig");
const cmd_window = @import("exec/cmd_window.zig");
const Editor = @import("Editor.zig");
const Window = @import("Window.zig");
const Frame = draw.Frame;
const proto = draw.proto;

test "restoremouse paths: a key dropped mid-gesture still clears the save (rows.c:277)" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var popup: Window = undefined; // never dereferenced: handleKey returns early
    restoremouse.save(&ed, &popup);
    ed.gesture.mouse_state = .sweeping_b1; // the FLAG early return
    try ed.handleKey('x');
    try testing.expect(ed.mousew == null);
}

test "restoremouse paths: a key with no Text to type into still clears the save (rows.c:277)" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var popup: Window = undefined;
    restoremouse.save(&ed, &popup);
    // No row, no focus, no text: the `orelse return` early return.
    try ed.handleKey('x');
    try testing.expect(ed.mousew == null);
}

fn bootTwoCols(fx: *Frame.TestFixture) !boot.Tree {
    var tree = try boot.boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "/home/larry/main.zig",
        .body = "main body\n",
    });
    errdefer tree.deinit();
    _ = (try tree.row.add(-1)).?; // a second column for the pop-up
    return tree;
}

test "restoremouse paths: Row.close frees the saved window and dropTextRefs clears it (Delcol path)" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try bootTwoCols(&fx);
    defer tree.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    tree.bind(&ed);

    const col = tree.row.col.items[1];
    const w = try place.mintWindow(&ed, col, -1, "/tmp/+Errors"); // cols.c:150 savemouse
    try testing.expect(ed.mousew == w);
    try tree.row.close(&ed, col, true); // rowclose(row, c, TRUE): no Column.close, no restore
    try testing.expect(ed.mousew == null); // cleared only by Editor.dropTextRefs
}

test "restoremouse paths: Delcol on the pop-up's column clears the save" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try bootTwoCols(&fx);
    defer tree.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    tree.bind(&ed);

    const col = tree.row.col.items[1];
    const w = try place.mintWindow(&ed, col, -1, "/tmp/+Errors");
    try testing.expect(ed.mousew == w);
    try cmd_window.delcol(&ed, &col.tag, null, null, false, false, ""); // exec.c:370-392
    try testing.expectEqual(@as(usize, 1), tree.row.col.items.len); // the column went
    try testing.expect(ed.mousew == null);
}
