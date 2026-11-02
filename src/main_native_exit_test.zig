//! #13 `Exit` on the native host: acme's `xexit` (exec.c:1148-1163) sends
//! `cexit` once `rowclean` passes; here that is `Editor.exit_requested`, which
//! ends `main`'s loop (`main_native.running`) so the deferred #58/#68
//! `shutdown` frees the session and `conn.deinit` ends devdraw. Plan:
//! `notes/snarfdev2/test-plans/M1-13-builtins.md` BI-01/02 (BI-13 is the
//! manual Mac run).
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const main_native = @import("main_native.zig");
const mnt = @import("main_native_test.zig");
const Rig = mnt.Rig;

fn openFile(r: *Rig, body: []const u8) !*core.Window {
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = body });
    try r.boot();
    try r.settle();
    const w = try core.openfile.readFile(&r.app.editor, r.app.tree.row.col.items[0], "/f.txt");
    try r.settle();
    return w;
}

test "native Exit: a clean session stops the loop; shutdown frees it with devdraw up (#13 BI-01)" {
    const r = try Rig.create();
    defer r.destroy();
    _ = try openFile(r, "x\n");
    try testing.expect(main_native.running(r.app));
    try r.run(&r.app.tree.row.tag, "Exit");
    try testing.expect(!main_native.running(r.app)); // the loop's own test
    try testing.expect(!r.app.conn.isClosed()); // devdraw not yet hung up: shutdown reaches it
    main_native.shutdown(r.app);
    try testing.expectEqual(main_native.Built{}, r.app.built);
    try testing.expectEqualStrings("", r.log.written());
}

test "native Exit: a dirty window takes a strike first; the second Exit stops the loop (#13 BI-02)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openFile(r, "x\n");
    try r.edit(w, "more\n");
    try testing.expect(w.dirty);
    try r.run(&w.tag, "Exit");
    try testing.expect(main_native.running(r.app));
    try testing.expect(std.mem.indexOf(u8, r.app.editor.warningText(), "/f.txt modified\n") != null);
    try r.run(&w.tag, "Exit");
    try testing.expect(!main_native.running(r.app));
    main_native.shutdown(r.app);
    // The edit was never Put: the file on disk is unchanged.
    const got = try r.disk("f.txt");
    defer r.a.free(got);
    try testing.expectEqualStrings("x\n", got);
}

test "native Exit: a Put still writing when Exit is accepted commits before the loop stops (#13)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openFile(r, "old\n");
    try r.edit(w, "new\n");
    try r.run(&w.tag, "Put");
    try testing.expect(r.app.editor.puts.items.len != 0); // still writing
    // The port's Put is asynchronous and the window stays dirty until it
    // commits, so this Exit takes the dirty strike (acme's synchronous Put
    // would already be clean); the second one is accepted.
    try r.run(&w.tag, "Exit");
    try r.run(&w.tag, "Exit");
    try testing.expect(r.app.editor.exit_requested);
    try testing.expect(main_native.running(r.app)); // held open for the Put
    var i: usize = 0;
    while (main_native.running(r.app)) : (i += 1) {
        if (i >= 20000) return error.PutNeverFinished;
        try r.ticks(1);
    }
    main_native.shutdown(r.app);
    try testing.expectEqualStrings("", r.log.written()); // nothing cut off
    const got = try r.disk("f.txt");
    defer r.a.free(got);
    try testing.expectEqualStrings("old\nnew\n", got);
}

test "native Exit: main's loop runs on `running`, ahead of the deferred shutdown (#13, source pin)" {
    const src = @embedFile("main_native.zig");
    const defer_shutdown = std.mem.indexOf(u8, src, "defer shutdown(a);").?;
    const loop = std.mem.indexOf(u8, src, "while (running(a)) {").?;
    try testing.expect(defer_shutdown < loop);
}
