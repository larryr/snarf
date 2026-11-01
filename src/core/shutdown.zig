//! shutdown — the core half of ending a session (#58): free everything the
//! `Editor` and the window tree own, in the one order that is safe. The
//! native host calls it when devdraw hangs up (`main_native.shutdown`), and
//! #13's `Exit` will reach it through the same host path.
//!
//! acme never frees its tree: `threadexitsall` (acme.c:281) lets the kernel
//! reclaim the process. The port frees it for real, so that a leak-checking
//! allocator (`init.gpa` in safe builds, `std.testing.allocator` in tests) can
//! go on meaning something at exit instead of reporting the whole session.
//!
//! Imports: sibling core files only (S-07 §6).
const Editor = @import("Editor.zig");
const boot = @import("boot.zig");

/// Tear down `ed`, then `tree`. Neither is usable afterwards.
///
/// ORDER (both halves are load-bearing):
///   1. `Editor.deinit` first: it abandons every in-flight Load, Put, Dump and
///      Load-dump job, each of which still holds a `*Window` and namespace
///      handles, and frees the snarf buffer, pending warnings, the Edit
///      pattern and the regexp cache. Freeing the windows first would leave
///      those jobs pointing into freed memory.
///   2. `Tree.deinit` second: `Row.deinit` → every `Column` → every `Window`
///      → its tag and body `Text`s (frames included), owned body `File`s
///      (undo/redo logs, names) and directory listings; then the `Chrome`
///      solids, which are freed THROUGH the display — so the caller's
///      `Display`/`Font` (and the 9P stack under them) must still be alive.
///
/// The namespace (`tree.ns`/`ed.ns`) is borrowed by both and is the host's to
/// free, after this returns.
pub fn teardown(ed: *Editor, tree: *boot.Tree) void {
    ed.deinit();
    tree.deinit();
}

// ===========================================================================
// Tests — a realistic session torn down under `std.testing.allocator`, which
// fails the test on any leaked byte (#58).
// ===========================================================================
const std = @import("std");
const testing = std.testing;
const draw = @import("draw");
const ninep = @import("ninep");
const MemTree = @import("MemTree.zig");
const openfile = @import("openfile.zig");
const exec = @import("exec/exec.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");

/// Run the builtin `word` as if B2-clicked in `t`: append it to `t` and
/// execute that range (exec.c:157 `execute`).
fn run(ed: *Editor, t: *Text, word: []const u8) !void {
    const n = t.file.buffer.len();
    try t.insertAt(n, word, true);
    try exec.execute(ed, t, n, n + word.len, null);
}

/// A typed edit: its own undo transaction (`seq++` + `File.mark`).
fn edit(ed: *Editor, w: *Window, text: []const u8) !void {
    ed.seq += 1;
    w.body.file.mark(ed.seq);
    try w.body.insertAt(w.body.file.buffer.len(), text, true);
}

fn windowCount(tree: *boot.Tree) usize {
    var n: usize = 0;
    for (tree.row.col.items) |c| n += c.w.items.len;
    return n;
}

test "shutdown: teardown frees a realistic session (columns, dir windows, +Errors, undo, snarf, jobs in flight) (#58)" {
    const a = testing.allocator;
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();
    const m = try MemTree.Harness.create(a, &ns, "/m");
    defer m.destroy(a);
    try m.tree.put("notes.txt", "first line\nsecond line\n");
    try m.tree.put("todo", "milk\n");

    var tree = try boot.boot(a, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 900, 600), .{
        .dir_boot = true,
        .ns = &ns,
    });
    var ed = Editor.init(a);
    tree.bind(&ed);
    ed.session.home = "/m";
    var torn = false;
    defer if (!torn) teardown(&ed, &tree);

    // A directory window, as the native boot opens one, plus a file window.
    const cols = tree.row.col.items;
    _ = try openfile.readFile(&ed, cols[cols.len - 1], "/m");
    const fw = try openfile.readFile(&ed, cols[0], "/m/notes.txt");
    for (0..60) |_| {
        try ed.frameEnd(fx.disp);
        try m.poll();
    }
    try testing.expectEqual(@as(usize, 0), ed.loads.items.len);

    // A third column with a fresh window (Newcol), and New in the first.
    try run(&ed, &tree.row.tag, " Newcol");
    try run(&ed, &fw.tag, " New");
    try testing.expectEqual(@as(usize, 3), tree.row.col.items.len);

    // Edits with undo history: two transactions, one undone (so both the undo
    // and the redo logs hold entries), then a Snarf of a selection.
    try edit(&ed, fw, "third\n");
    try edit(&ed, fw, "fourth\n");
    try run(&ed, &fw.tag, " Undo");
    try testing.expect(fw.body.file.redoSeq() != 0);
    try fw.body.setSelect(0, 5);
    ed.seltext = &fw.body;
    try run(&ed, &fw.tag, " Snarf");
    try testing.expectEqualStrings("first", ed.snarf.items);

    // +Errors: a warning flushed into its own window.
    ed.warning("shutdown test: {s}\n", .{"a warning"});
    try ed.frameEnd(fx.disp);
    try testing.expect(windowCount(&tree) >= 5);

    // Jobs still in flight when the session ends: a window load and a Dump.
    _ = try openfile.readFile(&ed, tree.row.col.items[1], "/m/todo");
    try ed.session.startDump(&ed, "");
    try testing.expect(ed.loads.items.len != 0);
    try testing.expect(ed.session.dump != null);

    torn = true;
    teardown(&ed, &tree); // testing.allocator reports any leak at test end
}
