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

fn tickUntilStopped(r: *Rig) !void {
    var i: usize = 0;
    while (main_native.running(r.app)) : (i += 1) {
        if (i >= 20000) return error.LoopNeverStopped;
        try r.ticks(1);
    }
}

test "native Exit: an Exit while a Put is writing waits for it, then finds the window clean (PR #74 Q4)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openFile(r, "old\n");
    try r.edit(w, "new\n");
    try r.run(&w.tag, "Put");
    try testing.expect(r.app.editor.puts.items.len != 0); // still writing
    // acme's Put is synchronous, so its Exit sees a clean window: ONE Exit
    // suffices here too, with no "modified" strike.
    try r.run(&w.tag, "Exit");
    try testing.expect(r.app.editor.exit_waiting != null);
    try testing.expect(!r.app.editor.exit_requested); // rowclean not run yet
    try tickUntilStopped(r);
    try testing.expect(r.app.editor.exit_requested);
    try testing.expect(std.mem.indexOf(u8, r.app.editor.warningText(), "modified") == null);
    main_native.shutdown(r.app);
    try testing.expectEqualStrings("", r.log.written()); // nothing cut off
    const got = try r.disk("f.txt");
    defer r.a.free(got);
    try testing.expectEqualStrings("old\nnew\n", got);
}

test "native Exit: after the wait, a window still dirty takes the strike as usual (PR #74 Q4)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openFile(r, "old\n");
    try r.edit(w, "new\n");
    try r.run(&w.tag, "Put");
    try r.run(&w.tag, "Exit"); // waits for the Put
    try r.edit(w, "more\n"); // dirty again before the Put's commit is checked
    var i: usize = 0;
    while (r.app.editor.exit_waiting != null) : (i += 1) {
        if (i >= 20000) return error.PutNeverFinished;
        try r.ticks(1);
    }
    // Refused: rowclean warned "/f.txt modified" (flushed to +Errors in the
    // same frame) and took the strike, clearing `dirty` (wind.c:666-672).
    try testing.expect(main_native.running(r.app));
    try testing.expect(!r.app.editor.exit_requested);
    try testing.expect(!w.dirty);
    try r.run(&w.tag, "Exit"); // the second strike goes through
    try testing.expect(!main_native.running(r.app));
    main_native.shutdown(r.app);
}

test "native Exit: a second Exit while the first waits stops at once through the #68 shutdown (PR #74 Q4)" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try openFile(r, "old\n");
    const big = try r.a.alloc(u8, 1 << 20);
    defer r.a.free(big);
    @memset(big, 'x');
    try r.edit(w, big);
    try r.run(&w.tag, "Put");
    // Tick until the Put is part-way through writing its temp file.
    const ed = &r.app.editor;
    var i: usize = 0;
    while (ed.puts.items.len == 0 or ed.puts.items[0].job != .write) : (i += 1) {
        if (i >= 1000 or ed.puts.items.len == 0) return error.PutNeverStartedWriting;
        try r.ticks(1);
    }
    try r.ticks(2);
    try r.run(&w.tag, "Exit");
    try testing.expect(main_native.running(r.app));
    try r.run(&w.tag, "Exit");
    try testing.expect(r.app.editor.puts.items.len != 0); // the Put never finished
    try testing.expect(!main_native.running(r.app));
    main_native.shutdown(r.app);
    // #58/#68: the cut-off Put is reported and the original is untouched.
    try testing.expect(std.mem.indexOf(u8, r.log.written(), "snarf: Put of ") != null);
    try testing.expect(std.mem.indexOf(u8, r.log.written(), "/f.txt not finished at exit; file left unchanged\n") != null);
    const got = try r.disk("f.txt");
    defer r.a.free(got);
    try testing.expectEqualStrings("old\n", got);
}

test "native Exit: main's loop runs on `running`, ahead of the deferred shutdown (#13, source pin)" {
    const src = @embedFile("main_native.zig");
    const defer_shutdown = std.mem.indexOf(u8, src, "defer shutdown(a);").?;
    const loop = std.mem.indexOf(u8, src, "while (running(a)) {").?;
    try testing.expect(defer_shutdown < loop);
}
