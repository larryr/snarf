//! #58: the native entry point's boot → session → `shutdown`, headless, under
//! `std.testing.allocator` (which fails the test on any leaked byte). The
//! devdraw peer is scripted — `FakeDevdraw` answers every request the way
//! devdraw's message loop does — so no child process and no window are
//! needed, and CI can run it. The window system's hang-up (the user closing
//! the window) is `Conn.closed` plus a sink that refuses writes.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const draw = @import("draw");
const host = @import("host");
const main_native = @import("main_native.zig");

const App = main_native.App;
const Conn = host.Conn;
const wsys = host.wsys;
const conn_line_len = host.dev_draw.conn_line_len;

/// A devdraw stand-in: decodes each outbound frame and feeds back the reply
/// devdraw would send (srv.c `runmsg`), with the request's own tag. The two
/// long polls (`Trdmouse`/`Trdkbd4`) stay unanswered, as with an idle user.
const FakeDevdraw = struct {
    conn: *Conn,
    /// The `Trddraw` answer: a 1024x768 x8r8g8b8 screen (devdraw.c:945-947).
    line: [conn_line_len]u8,
    hung_up: bool = false,
    frames: usize = 0,

    fn init(conn: *Conn) FakeDevdraw {
        var self: FakeDevdraw = .{ .conn = conn, .line = undefined };
        const fields = [12][]const u8{ "1", "0", "x8r8g8b8", "0", "0", "0", "1024", "768", "0", "0", "1024", "768" };
        for (fields, 0..) |f, i| {
            const cell = self.line[i * 12 ..][0..12];
            @memset(cell, ' ');
            @memcpy(cell[11 - f.len ..][0..f.len], f);
        }
        return self;
    }

    fn sink(self: *FakeDevdraw) Conn.Sink {
        return .{ .ctx = self, .writeAll = writeAll };
    }

    /// The window closed: devdraw is gone, its pipe with it.
    fn hangUp(self: *FakeDevdraw) void {
        self.hung_up = true;
        self.conn.closed = true;
    }

    fn writeAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FakeDevdraw = @ptrCast(@alignCast(ctx));
        if (self.hung_up) return error.BrokenPipe;
        self.frames += 1;
        const tag = wsys.tagOf(bytes);
        const c = self.conn;
        switch (try wsys.decode(bytes)) {
            .twrdraw => |d| try c.feedMsg(.{ .rwrdraw = @intCast(d.len) }, tag),
            .trddraw => |n| {
                if (n == conn_line_len) return c.feedMsg(.{ .rrddraw = &self.line }, tag);
                const zeros = try c.gpa.alloc(u8, n);
                defer c.gpa.free(zeros);
                @memset(zeros, 0);
                try c.feedMsg(.{ .rrddraw = zeros }, tag);
            },
            .tmoveto => try c.feedMsg(.rmoveto, tag),
            .tlabel => try c.feedMsg(.rlabel, tag),
            .tcursor => try c.feedMsg(.rcursor, tag),
            .tcursor2 => try c.feedMsg(.rcursor2, tag),
            .tbouncemouse => try c.feedMsg(.rbouncemouse, tag),
            .trdsnarf => try c.feedMsg(.{ .rrdsnarf = "" }, tag),
            .twrsnarf => try c.feedMsg(.rwrsnarf, tag),
            .ttop => try c.feedMsg(.rtop, tag),
            .tresize => try c.feedMsg(.rresize, tag),
            .tctxt => try c.feedMsg(.rctxt, tag),
            .trdmouse, .trdkbd, .trdkbd4 => {}, // long polls: idle user
            else => return error.UnexpectedFrame,
        }
    }
};

/// `main`'s shape, minus the spawn: an `App` on the heap, a scripted peer, a
/// scratch host root, and `shutdown` deferred BEFORE `boot` as `main` does.
const Rig = struct {
    a: std.mem.Allocator,
    app: *App,
    peer: FakeDevdraw,
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    /// `App.exit_log`: what `shutdown` would have printed on stderr.
    log: std.Io.Writer.Allocating,
    /// The Put's temp-file bytes just before shutdown (`workSession`).
    partial: ?[]u8 = null,

    fn create() !*Rig {
        const a = testing.allocator;
        const r = try a.create(Rig);
        errdefer a.destroy(r);
        r.a = a;
        r.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer r.tmp.cleanup();
        r.root = try r.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        r.app = try a.create(App);
        r.app.built = .{};
        r.log = .init(a);
        r.partial = null;
        r.app.exit_log = &r.log.writer;
        r.app.conn = Conn.init(a);
        r.peer = FakeDevdraw.init(&r.app.conn);
        r.app.conn.useSink(r.peer.sink());
        return r;
    }

    fn boot(r: *Rig) !void {
        try main_native.boot(r.a, testing.io, r.app, core.Palette.default, r.root);
        r.app.editor.session.home = "/";
        r.app.host_tree.recovery.tmp_dir = r.root; // as main sets $TMPDIR
        try r.app.conn.armMouse();
        try r.app.conn.armKbd();
    }

    /// `shutdown` (idempotent, so a test may call it early), then the rest of
    /// `main`'s exit: reap the peer, free the `App`.
    fn destroy(r: *Rig) void {
        main_native.shutdown(r.app);
        r.app.conn.deinit();
        r.a.destroy(r.app);
        r.log.deinit();
        if (r.partial) |b| r.a.free(b);
        r.a.free(r.root);
        r.tmp.cleanup();
        r.a.destroy(r);
    }

    fn ticks(r: *Rig, n: usize) !void {
        for (0..n) |_| try main_native.tick(r.app);
    }

    fn settle(r: *Rig) !void {
        const ed = &r.app.editor;
        var i: usize = 0;
        while (ed.loads.items.len != 0 or ed.puts.items.len != 0 or
            ed.session.dump != null or ed.session.load != null) : (i += 1)
        {
            if (i >= 20000) return error.JobsNeverFinished;
            try r.ticks(1);
        }
        try r.ticks(4);
    }

    fn run(r: *Rig, t: *core.Text, word: []const u8) !void {
        const n = t.file.buffer.len();
        try t.insertAt(n, " ", true);
        try t.insertAt(n + 1, word, true);
        try core.exec.execute(&r.app.editor, t, n + 1, n + 1 + word.len, null);
        try t.deleteRange(n, n + 1 + word.len, true);
    }

    fn edit(r: *Rig, w: *core.Window, text: []const u8) !void {
        const ed = &r.app.editor;
        ed.seq += 1;
        w.body.file.mark(ed.seq);
        try w.body.insertAt(w.body.file.buffer.len(), text, true);
        try r.ticks(1);
    }

    fn disk(r: *Rig, rel: []const u8) ![]u8 {
        return r.tmp.dir.readFileAlloc(testing.io, rel, r.a, .limited(16 << 20));
    }

    fn entries(r: *Rig) !usize {
        var d = try r.tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
        defer d.close(testing.io);
        var it = d.iterate();
        var n: usize = 0;
        while (try it.next(testing.io)) |_| n += 1;
        return n;
    }

    /// A working session: the boot directory window, a file window with
    /// undo AND redo history, a snarf, a new column with a New window, a
    /// `+Errors` window — then, left IN FLIGHT at the end, a Load and a large
    /// Put that has started writing but not finished.
    fn workSession(r: *Rig) !void {
        const big = try r.a.alloc(u8, 1 << 20);
        defer r.a.free(big);
        @memset(big, 'x');
        try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "first line\nsecond line\n" });
        try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "big.txt", .data = "old\n" });
        try r.boot();
        try r.settle();
        const ed = &r.app.editor;
        const tree = &r.app.tree;

        const fw = try core.openfile.readFile(ed, tree.row.col.items[0], "/notes.txt");
        try r.settle();
        try r.edit(fw, "third\n");
        try r.edit(fw, "fourth\n");
        try r.run(&fw.tag, "Undo");
        try testing.expect(fw.body.file.redoSeq() != 0);
        try fw.body.setSelect(0, 5);
        ed.seltext = &fw.body;
        try r.run(&fw.tag, "Snarf");
        try testing.expectEqualStrings("first", ed.snarf.items);
        try r.run(&tree.row.tag, "Newcol");
        try r.run(&fw.tag, "New");
        ed.warning("main_native_test: {s}\n", .{"a warning"});
        try r.ticks(2);
        try testing.expect(tree.row.col.items.len >= 3);

        const bw = try core.openfile.readFile(ed, tree.row.col.items[1], "/big.txt");
        try r.settle();
        try r.edit(bw, big);
        try r.run(&bw.tag, "Put");
        // Tick until the Put is part-way through writing its temp file.
        var i: usize = 0;
        while (ed.puts.items.len == 0 or ed.puts.items[0].job != .write or try r.entries() != 3) : (i += 1) {
            if (i >= 1000 or ed.puts.items.len == 0) return error.PutNeverStartedWriting;
            try r.ticks(1);
        }
        try r.ticks(2);
        try testing.expect(ed.puts.items.len != 0); // still writing
        try testing.expectEqual(@as(usize, 3), try r.entries()); // + the temp file
        r.partial = try r.tempBytes();
        _ = try core.openfile.readFile(ed, tree.row.col.items[1], "/notes.txt");
        try testing.expect(ed.loads.items.len != 0);
    }

    /// The in-flight Put's temp file (`.big.txt.snarf-put.N`), read raw.
    fn tempBytes(r: *Rig) ![]u8 {
        var d = try r.tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
        defer d.close(testing.io);
        var it = d.iterate();
        while (try it.next(testing.io)) |e| {
            if (std.mem.startsWith(u8, e.name, ".big.txt.snarf-put.")) return r.disk(e.name);
        }
        return error.NoTempFile;
    }

    /// The unfinished Put was DISCARDED, not committed (HostTree.endSession):
    /// the file keeps its old bytes and no temp file is left behind; its
    /// bytes so far are kept in `.big.txt.snarf-partial` (Owner decision
    /// 2026-10-31, Larry), and the user is told both paths (PM ruling
    /// 2026-10-31, SnarfProdd) in a form B3 opens.
    fn expectPutDiscarded(r: *Rig) !void {
        try testing.expectEqualStrings(
            "snarf: Put of /big.txt not finished at exit; file left unchanged\n" ++
                "snarf: partial contents saved in /.big.txt.snarf-partial\n",
            r.log.written(),
        );
        const got = try r.disk("big.txt");
        defer r.a.free(got);
        try testing.expectEqualStrings("old\n", got);
        const kept = try r.disk(".big.txt.snarf-partial");
        defer r.a.free(kept);
        const partial = r.partial.?;
        try testing.expect(partial.len != 0 and partial.len < 4 + (1 << 20)); // really unfinished
        try testing.expectEqualSlices(u8, partial, kept); // exactly what had arrived
        try testing.expectEqual(@as(usize, 3), try r.entries()); // + the recovery file, no temp
        try expectB3Paths(r.log.written(), &.{ "/big.txt", "/.big.txt.snarf-partial" });
    }
};

/// Larry (2026-10-31): a B3 on each path in the shutdown notice must open
/// it. Lay `out` into a Text, as the +Errors window would show it, and B3
/// at the first, a middle and the last rune of each `want` path: acme's own
/// expansion (`expandfile`, look.c:592-729, then `dirname`'s rooting) must
/// yield the WHOLE path — no `:addr` split off, nothing glued on.
fn expectB3Paths(out: []const u8, want: []const []const u8) !void {
    const a = testing.allocator;
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var file = core.File.init(a, core.Buffer.initEmpty(a));
    defer file.deinit();
    const w = &fx.disp.white;
    var text = try core.Text.init(&file, a, draw.proto.Rect.make(0, 0, 656, 470), fx.font, &fx.disp.image, .{ w, w, w, w, w });
    defer text.deinit();
    try text.insertAt(0, out, true);
    var ed = core.Editor.init(a);
    defer ed.deinit();
    for (want) |path| {
        const at = std.mem.indexOf(u8, out, path) orelse return error.PathNotInOutput; // ASCII: bytes == runes
        for ([_]usize{ at, at + path.len / 2, at + path.len - 1 }) |click| {
            const c = core.expand.expandFile(&text, click, click, false) orelse return error.NotAFileName;
            try testing.expectEqual(core.expand.Kind.file, c.kind);
            try testing.expect(!c.has_addr);
            try testing.expectEqual(at, c.q0);
            try testing.expectEqual(at + path.len, c.q1);
            const name = try core.expand.runeText(a, &text, c.name_q0, c.name_q1);
            defer a.free(name);
            const abs = try core.expand.absolute(&ed, a, &text, name);
            defer a.free(abs);
            try testing.expectEqualStrings(path, abs);
        }
    }
}

test "main_native: the other notice forms are B3-able too (tmp fallback, failure, in place) (#58)" {
    // The exact formats HostTree.keepPartial prints (src/hostfs/HostTree.zig),
    // with a $TMPDIR fallback path that has a pid and a numbered suffix.
    try expectB3Paths(
        "snarf: Put of /home/larry/src/a-b_c.zig not finished at exit; file left unchanged\n" ++
            "snarf: partial contents saved in /tmp/snarf-partial-4242-a-b_c.zig.1\n" ++
            "snarf: Put of /etc/ro/g not finished at exit; file left unchanged\n" ++
            "snarf: could not save partial contents (AccessDenied)\n" ++
            "snarf: Put of /mnt/x/y not finished at exit; written in place and may be incomplete\n",
        &.{ "/home/larry/src/a-b_c.zig", "/tmp/snarf-partial-4242-a-b_c.zig.1", "/etc/ro/g", "/mnt/x/y" },
    );
}

test "main_native: shutdown frees a working session with devdraw still up (#13 Exit path) (#58)" {
    const r = try Rig.create();
    defer r.destroy();
    try r.workSession();
    main_native.shutdown(r.app);
    try testing.expectEqual(main_native.Built{}, r.app.built);
    try r.expectPutDiscarded();
}

test "main_native: shutdown frees a working session after devdraw hangs up (window closed) (#58)" {
    const r = try Rig.create();
    defer r.destroy();
    try r.workSession();
    r.peer.hangUp();
    // The loop's exit test, then main's deferred shutdown.
    try testing.expect(r.app.conn.isClosed());
    const before = r.peer.frames;
    main_native.shutdown(r.app);
    try testing.expectEqual(before, r.peer.frames); // nothing reached the dead peer
    try r.expectPutDiscarded();
}

test "main_native: a Put that finished before exit is not reported (#58)" {
    const r = try Rig.create();
    defer r.destroy();
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "old\n" });
    try r.boot();
    try r.settle();
    const w = try core.openfile.readFile(&r.app.editor, r.app.tree.row.col.items[0], "/f.txt");
    try r.settle();
    try r.edit(w, "new\n");
    try r.run(&w.tag, "Put");
    try r.settle();
    main_native.shutdown(r.app);
    try testing.expectEqualStrings("", r.log.written());
    const got = try r.disk("f.txt");
    defer r.a.free(got);
    try testing.expectEqualStrings("old\nnew\n", got);
}

test "main_native: a boot that fails part-way is torn down by the same shutdown (#58)" {
    const r = try Rig.create();
    defer r.destroy();
    r.a.free(r.root);
    r.root = try r.a.dupeZ(u8, "/nonexistent/snarf-58-host-root");
    try testing.expectError(error.FileNotFound, main_native.boot(r.a, testing.io, r.app, core.Palette.default, r.root));
    try testing.expect(r.app.built.self_tree and !r.app.built.host_fs);
    main_native.shutdown(r.app);
    try testing.expectEqualStrings("", r.log.written()); // nothing to discard
    // destroy → shutdown frees exactly the half that was built.
}

test "main_native: main defers shutdown before boot, and conn.deinit after it (#58, source pin)" {
    // `main` spawns a real devdraw, so it cannot run headless; pin its exit
    // wiring instead. Defers run in reverse: `shutdown` (registered later)
    // runs BEFORE `conn.deinit`, and covers a `boot` that fails.
    const src = @embedFile("main_native.zig");
    const conn_deinit = std.mem.indexOf(u8, src, "defer a.conn.deinit();").?;
    const defer_shutdown = std.mem.indexOf(u8, src, "defer shutdown(a);").?;
    const call_boot = std.mem.indexOf(u8, src, "try boot(gpa, init.io, a, pal, \"/\");").?;
    try testing.expect(conn_deinit < defer_shutdown);
    try testing.expect(defer_shutdown < call_boot);
    try testing.expect(std.mem.indexOf(u8, src, "defer a.tree.deinit();") == null);
}
