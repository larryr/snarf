//! #12 + #31 end to end on the native host: the editor's Snarf/Cut/Paste
//! through `/dev/snarf` (`core/clipboard.zig`), the input device's
//! buffer-until-clunk (`host/devdraw/dev_input.zig`), and `Trdsnarf`/`Twrsnarf`
//! to a scripted devdraw whose pasteboard stands in for the macOS one. Plan:
//! `notes/snarfdev2/test-plans/M1-12-clipboard.md` (CB-04..07 at the app level).
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const mnt = @import("main_native_test.zig");
const Rig = mnt.Rig;

fn openWith(r: *Rig, body: []const u8) !*core.Window {
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = body });
    try r.boot();
    try r.settle();
    const w = try core.openfile.readFile(&r.app.editor, r.app.tree.row.col.items[0], "/c.txt");
    try r.settle();
    return w;
}

fn bodyText(w: *core.Window, out: []u8) []const u8 {
    return w.body.file.buffer.read(0, w.body.file.buffer.len(), out);
}

fn select(r: *Rig, w: *core.Window, q0: usize, q1: usize) !void {
    try w.body.setSelect(q0, q1);
    r.app.editor.seltext = &w.body;
}

test "native clipboard: Snarf puts the selection on the pasteboard in one Twrsnarf (#12 CB-04)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openWith(r, "caf\u{e9} \u{65e5}\u{672c} \u{1F600}\n");
    try select(r, w, 0, 9); // all but the newline: 4 + 1 + 2 + 1 + 1 runes
    try r.run(&w.tag, "Snarf");
    try testing.expectEqualStrings("caf\u{e9} \u{65e5}\u{672c} \u{1F600}", r.peer.pasteboard.items);
    try testing.expectEqual(@as(usize, 1), r.peer.wrsnarfs);
}

test "native clipboard: Cut puts the selection on the pasteboard too (exec.c:1003)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openWith(r, "keep CUTME keep\n");
    try select(r, w, 5, 10);
    try r.run(&w.tag, "Cut");
    try testing.expectEqualStrings("CUTME", r.peer.pasteboard.items);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("keep  keep\n", bodyText(w, &buf));
}

test "native clipboard: Paste inserts what another app copied, not a stale snarf (#12 CB-05/06)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openWith(r, "ab\n");
    try r.app.editor.snarf.appendSlice(testing.allocator, "STALE");
    try r.peer.pasteboard.appendSlice(testing.allocator, "from TextEdit: \u{e9}\u{301}");
    try select(r, w, 2, 2);
    try r.run(&w.tag, "Paste");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("abfrom TextEdit: \u{e9}\u{301}\n", bodyText(w, &buf));
    try testing.expectEqualStrings("from TextEdit: \u{e9}\u{301}", r.app.editor.snarf.items);
}

test "native clipboard: an empty pasteboard pastes snarf's own buffer (acmegetsnarf's empty guard)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openWith(r, "ab\n");
    try r.app.editor.snarf.appendSlice(testing.allocator, "MINE");
    try select(r, w, 0, 0);
    try r.run(&w.tag, "Paste");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("MINEab\n", bodyText(w, &buf));
}

test "native clipboard: a snarf bigger than one 9P message reaches the pasteboard whole (#31 CB-07)" {
    const r = try Rig.create();
    defer r.destroy();
    const n: usize = 50_000; // several Twrites at msize 8192
    const big = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    const w = try openWith(r, big);
    try select(r, w, 0, n);
    try r.run(&w.tag, "Snarf");
    try testing.expectEqual(@as(usize, 1), r.peer.wrsnarfs);
    try testing.expect(std.mem.eql(u8, big, r.peer.pasteboard.items));
    // … and back: a big pasteboard pastes whole.
    try select(r, w, n, n);
    try r.run(&w.tag, "Paste");
    try testing.expectEqual(2 * n, w.body.file.buffer.len());
}

test "native clipboard: pasteboard bytes are taken as cvttorunes does (bad UTF-8 -> U+FFFD, stop at NUL)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openWith(r, "\n");
    try r.peer.pasteboard.appendSlice(testing.allocator, "a\xffb\x00ignored");
    try select(r, w, 0, 0);
    try r.run(&w.tag, "Paste");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("a\u{FFFD}b\n", bodyText(w, &buf));
}
