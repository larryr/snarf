//! Phase 20 acceptance (R-P20-7): native file save — the host file system
//! mounted at `/` (and `/mnt/host`) in the editor's namespace, NFS-01..10, 14,
//! 16 of `agents/contracts/phase20-native-save.md`. Pulled into the
//! `accept.zig` test root (same module imports).
//!
//! HARNESS: a `std.testing.tmpDir` served by the REAL `hostfs.HostTree` over
//! `hostfs.HostFs` (the same ops table `main_native.zig` mounts at `/`), so
//! these tests pin the editor side AND the hostfs side together — including
//! the atomic Put (PM Q5) at the editor level. The file-level Q5 tests are in
//! `tools/origin/hostfs_native_test.zig`. (TDD stage one used an in-file
//! `TmpFs` because `hostfs` was not yet a module; phase 20's implementation
//! made it one and swapped the real tree in — see the as-built report.)
//! The `main_native.zig` wiring itself (R-P20-2) is not reachable from here:
//! NFS-01w pins it in the source, and the launch gate exercises it.
//!
//! Never writes outside the tmp dir; never touches `$HOME`.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const draw = @import("draw");
const ninep = @import("ninep");
const hostfs = @import("hostfs");
const ns_boot = @import("ns_boot.zig");

const testing = std.testing;
const Io = std.Io;
const msg = ninep.msg;

// ===========================================================================
// Rig — headless boot + namespace {/ and /mnt/host → tmp, /dev → MemTree,
// /mnt/snarf-self → the served window tree}
// ===========================================================================

fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

const Rig = struct {
    a: std.mem.Allocator,
    tmp: testing.TmpDir,
    host: hostfs.HostFs,
    fs: hostfs.HostTree,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,
    fs_root: u32,
    fx: draw.Frame.TestFixture,
    ns: ninep.mount.Namespace,
    dev: *core.MemTree.Harness,
    tree: core.boot.Tree,
    ed: core.Editor,
    self: ns_boot.SelfTree,
    col: *core.Column,

    fn create() !*Rig {
        const a = testing.allocator;
        const r = try a.create(Rig);
        r.a = a;
        r.tmp = testing.tmpDir(.{ .iterate = true });
        const path = try r.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        defer a.free(path);
        r.host = try hostfs.HostFs.open(testing.io, path);
        r.fs = hostfs.HostTree.init(a, &r.host);
        r.pipe = try ninep.chan.Pipe.init(a, 65536);
        r.srv = try ninep.server.Server.init(a, r.pipe.serverEnd(), &hostfs.HostTree.ops, &r.fs, 8192);
        r.cl = try ninep.Client.init(a, r.pipe.clientEnd(), 8192);
        r.cl.pump = .{ .ctx = &r.srv, .run = pumpServer };
        _ = try r.cl.version(8192);
        r.fs_root = (try r.cl.attach("larry", "")).fid;
        r.fx = try draw.Frame.TestFixture.init();
        r.ns = ninep.mount.Namespace.init(a);
        // The host file system at the root AND as the /mnt/host alias (R-P20-2);
        // /dev and /mnt/snarf-self must keep winning by longest prefix.
        try r.ns.mount("/", &r.cl, r.fs_root);
        try r.ns.mount("/mnt/host", &r.cl, r.fs_root);
        r.dev = try core.MemTree.Harness.create(a, &r.ns, "/dev");
        r.tree = try core.boot.boot(a, r.fx.disp, r.fx.font, draw.proto.Rect.make(0, 0, 640, 480), .{ .ns = &r.ns });
        r.ed = core.Editor.init(a);
        r.tree.bind(&r.ed);
        try r.self.start(a, &r.ed, &r.ns);
        r.col = r.tree.row.col.items[0];
        return r;
    }

    fn destroy(r: *Rig) void {
        r.ed.deinit();
        r.tree.deinit();
        r.self.cl.deinit();
        r.self.srv.deinit();
        r.self.pipe.deinit();
        r.dev.destroy(r.a);
        r.ns.deinit();
        r.fx.deinit();
        r.cl.clunk(r.fs_root) catch {};
        r.cl.deinit();
        r.srv.deinit();
        r.pipe.deinit();
        r.host.close();
        r.tmp.cleanup();
        r.a.destroy(r);
    }

    fn pollAll(r: *Rig) !void {
        _ = try r.srv.poll();
        try r.self.poll();
        try r.dev.poll();
    }

    /// One editor frame plus every server's poll.
    fn tick(r: *Rig) !void {
        try r.ed.frameEnd(r.fx.disp);
        try r.pollAll();
    }

    fn busy(r: *Rig) bool {
        return r.ed.loads.items.len != 0 or r.ed.puts.items.len != 0 or
            r.ed.session.dump != null or r.ed.session.load != null;
    }

    /// Phase-17 jobs are asynchronous: tick until every Load/Put has finished
    /// (bounded), then a few more frames so warnings flush and tags settle.
    fn settle(r: *Rig) !void {
        var i: usize = 0;
        while (r.busy()) : (i += 1) {
            if (i >= 20000) return error.JobsNeverFinished;
            try r.tick();
        }
        for (0..4) |_| try r.tick();
    }

    // -- disk (direct, bypassing 9P) ------------------------------------------

    fn seed(r: *Rig, rel: []const u8, data: []const u8) !void {
        try r.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn disk(r: *Rig, rel: []const u8) ![]u8 {
        return r.tmp.dir.readFileAlloc(testing.io, rel, r.a, .limited(16 << 20));
    }

    fn diskIs(r: *Rig, rel: []const u8, want: []const u8) !void {
        const d = try r.disk(rel);
        defer r.a.free(d);
        try testing.expectEqualStrings(want, d);
    }

    fn entryNames(r: *Rig) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(r.a);
        var d = try r.tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
        defer d.close(testing.io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| r.a.free(n);
            names.deinit(r.a);
        }
        var it = d.iterate();
        while (try it.next(testing.io)) |e| try names.append(r.a, try r.a.dupe(u8, e.name));
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items, 0..) |n, i| {
            if (i > 0) try out.append(r.a, ' ');
            try out.appendSlice(r.a, n);
        }
        return out.toOwnedSlice(r.a);
    }

    // -- editor ---------------------------------------------------------------

    /// acme.c:285-300 `readfile` — the boot-window / B3-open load.
    fn openWin(r: *Rig, path: []const u8) !*core.Window {
        const w = try core.openfile.readFile(&r.ed, r.col, path);
        try r.settle();
        return w;
    }

    fn bodyBytes(r: *Rig, w: *core.Window) ![]u8 {
        var aw: Io.Writer.Allocating = .init(r.a);
        defer aw.deinit();
        try w.body.file.buffer.writeRaw(&aw.writer);
        return aw.toOwnedSlice();
    }

    fn expectBody(r: *Rig, w: *core.Window, want: []const u8) !void {
        const got = try r.bodyBytes(w);
        defer r.a.free(got);
        try testing.expectEqualStrings(want, got);
    }

    /// An edit as a typed user makes one: a new undo transaction.
    fn edit(r: *Rig, w: *core.Window, pos: usize, text: []const u8) !void {
        r.ed.seq += 1;
        w.body.file.mark(r.ed.seq);
        try w.body.insertAt(pos, text, true);
        try r.tick(); // the frameEnd tag sweep composes " Put"/" Undo"
    }

    /// Run the builtin `word` the way a B2 click does: execute it from `t`'s
    /// text (appended to the tag first, since the file-window tag lacks `Get`).
    fn run(r: *Rig, t: *core.Text, word: []const u8) !void {
        const n = t.file.buffer.len();
        var sp = [_]u8{' '};
        try t.insertAt(n, &sp, true);
        try t.insertAt(n + 1, word, true);
        try core.exec.execute(&r.ed, t, n + 1, n + 1 + word.len, null);
        // Un-type the word so the tag is as it was (the jobs captured what they need).
        try t.deleteRange(n, n + 1 + word.len, true);
    }

    fn bodiesContain(r: *Rig, needle: []const u8) !bool {
        for (r.tree.row.col.items) |c| for (c.w.items) |w| {
            const b = try r.bodyBytes(w);
            defer r.a.free(b);
            if (std.mem.indexOf(u8, b, needle) != null) return true;
        };
        return false;
    }

    fn tagHas(r: *Rig, w: *core.Window, word: []const u8) !bool {
        var aw: Io.Writer.Allocating = .init(r.a);
        defer aw.deinit();
        try w.tag.file.buffer.writeRaw(&aw.writer);
        return std.mem.indexOf(u8, aw.written(), word) != null;
    }
};

const tricky = "caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x98\x80\r\nno trailing newline";

fn umaskNow() u32 {
    if (builtin.os.tag == .linux) {
        const old: u32 = @intCast(std.os.linux.syscall1(.umask, 0o022));
        _ = std.os.linux.syscall1(.umask, old);
        return old;
    }
    const old: u32 = @intCast(std.c.umask(0o022));
    _ = std.c.umask(@intCast(old));
    return old;
}

// ===========================================================================
// NFS-01..16
// ===========================================================================

test "phase-20 NFS-01: root mount falls through; /dev and /mnt/snarf-self still win by longest prefix" {
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("f.txt", "x");
    try testing.expectEqualStrings("/", (try r.ns.resolve("/f.txt")).entry.prefix);
    try testing.expectEqualStrings("f.txt", (try r.ns.resolve("/f.txt")).remainder);
    try testing.expectEqualStrings("/dev", (try r.ns.resolve("/dev/mouse")).entry.prefix);
    try testing.expectEqualStrings("/mnt/snarf-self", (try r.ns.resolve("/mnt/snarf-self/1/ctl")).entry.prefix);
    try testing.expectEqualStrings("/mnt/host", (try r.ns.resolve("/mnt/host/f.txt")).entry.prefix);
    // The alias is the same server: /mnt/host/f.txt and /f.txt are one file.
    const a = try r.openWin("/f.txt");
    const b = try r.openWin("/mnt/host/f.txt");
    try r.expectBody(a, "x");
    try r.expectBody(b, "x");
}

test "phase-20 NFS-02: open an absolute path — body byte-exact (UTF-8, CRLF, no trailing NL)" {
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("t.txt", tricky);
    const w = try r.openWin("/t.txt");
    try r.expectBody(w, tricky);
    try testing.expectEqualStrings("/t.txt", w.body.file.name.items);
    try testing.expect(!w.dirty);
}

test "phase-20 NFS-03: a directory path opens a dirwin with '/' on subdirs" {
    const r = try Rig.create();
    defer r.destroy();
    try r.tmp.dir.createDirPath(testing.io, "d/sub");
    try r.seed("d/a.txt", "a");
    const w = try r.openWin("/d");
    try testing.expect(w.isdir);
    const b = try r.bodyBytes(w);
    defer r.a.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "sub/") != null);
    try testing.expect(std.mem.indexOf(u8, b, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, b, "a.txt/") == null);
}

test "phase-20 NFS-04: a nonexistent path warns 'can't open', loads nothing, no crash" {
    const r = try Rig.create();
    defer r.destroy();
    const w = try r.openWin("/nope.txt");
    try r.expectBody(w, "");
    try testing.expect(try r.bodiesContain("can't open /nope.txt"));
    try testing.expect(!w.dirty);
}

test "phase-20 NFS-05: Put writes the buffer to disk, window goes clean, putseq advances" {
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("f.txt", "hello\n");
    const w = try r.openWin("/f.txt");
    try r.edit(w, 0, "X");
    try testing.expect(try r.tagHas(w, " Put"));
    try r.run(&w.tag, "Put");
    try r.settle();
    try r.diskIs("f.txt", "Xhello\n");
    try testing.expect(!w.dirty and !w.body.file.mod);
    try testing.expectEqual(w.body.file.seq, w.putseq);
    try testing.expect(!(try r.tagHas(w, " Put")));
}

test "phase-20 NFS-06: Undo after Put reverts the buffer, dirties the window, disk keeps the Put bytes" {
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("f.txt", "hello\n");
    const w = try r.openWin("/f.txt");
    try r.edit(w, 0, "X");
    try r.run(&w.tag, "Put");
    try r.settle();
    try r.diskIs("f.txt", "Xhello\n");
    try r.run(&w.tag, "Undo");
    try r.tick();
    try r.expectBody(w, "hello\n");
    try testing.expect(w.dirty);
    try testing.expect(try r.tagHas(w, " Put"));
    try r.diskIs("f.txt", "Xhello\n");
}

test "phase-20 NFS-07: Get reloads changed disk content; Get on a dirty window warns first, loads second" {
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("f.txt", "one\n");
    const w = try r.openWin("/f.txt");
    try r.seed("f.txt", "changed on disk\n");
    try r.run(&w.tag, "Get");
    try r.settle();
    try r.expectBody(w, "changed on disk\n");

    // Dirty: first Get warns and leaves the buffer; the second loads (R-P17-8).
    try r.edit(w, 0, "local ");
    try r.seed("f.txt", "again\n");
    try r.run(&w.tag, "Get");
    try testing.expect(r.ed.warningsPending());
    try r.settle();
    try r.expectBody(w, "local changed on disk\n");
    try testing.expect(w.body.file.mod and !w.dirty); // winclean spends the strike (wind.c:667-690)
    try r.run(&w.tag, "Get");
    try r.settle();
    try r.expectBody(w, "again\n");
    try testing.expect(!w.dirty);
}

test "phase-20 NFS-08: Putall writes exactly the dirty files; the clean file is untouched" {
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("a.txt", "a\n");
    try r.seed("b.txt", "b\n");
    try r.seed("c.txt", "c\n");
    const wa = try r.openWin("/a.txt");
    const wb = try r.openWin("/b.txt");
    _ = try r.openWin("/c.txt");
    const before = try r.tmp.dir.statFile(testing.io, "c.txt", .{});
    try r.edit(wa, 0, "A");
    try r.edit(wb, 0, "B");
    try r.run(&r.tree.row.tag, "Putall");
    try r.settle();
    try r.diskIs("a.txt", "Aa\n");
    try r.diskIs("b.txt", "Bb\n");
    try r.diskIs("c.txt", "c\n");
    const after = try r.tmp.dir.statFile(testing.io, "c.txt", .{});
    try testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    try testing.expect(!wa.dirty and !wb.dirty);
}

test "phase-20 NFS-09: Put to a new path creates the file, content exact, mode 0666 & ~umask" {
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("f.txt", "seed\n");
    const w = try r.openWin("/f.txt");
    try core.wintag.setName(w, "/new.txt");
    try r.edit(w, 0, "fresh ");
    try r.run(&w.tag, "Put");
    try r.settle();
    try r.diskIs("new.txt", "fresh seed\n");
    try r.diskIs("f.txt", "seed\n");
    const st = try r.tmp.dir.statFile(testing.io, "new.txt", .{});
    const mode: u32 = @intCast(st.permissions.toMode());
    try testing.expectEqual(@as(u32, 0o666 & ~umaskNow()), mode & 0o777);
    try testing.expect(!w.dirty);
}

test "phase-20 NFS-10: Put onto a read-only file warns, window stays dirty, bytes intact, no temp litter" {
    if (builtin.os.tag == .linux and std.os.linux.geteuid() == 0) return error.SkipZigTest; // root ignores mode bits
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("ro.txt", "original\n");
    var f = try r.tmp.dir.openFile(testing.io, "ro.txt", .{});
    try f.setPermissions(testing.io, .fromMode(0o444));
    f.close(testing.io);
    const w = try r.openWin("/ro.txt");
    try r.edit(w, 0, "clobber ");
    try r.run(&w.tag, "Put");
    try r.settle();
    try testing.expect(try r.bodiesContain("/ro.txt"));
    try testing.expect(r.ed.puts.items.len == 0);
    try testing.expect(w.dirty and w.body.file.mod);
    try testing.expect(try r.tagHas(w, " Put"));
    try r.diskIs("ro.txt", "original\n");
    const names = try r.entryNames();
    defer r.a.free(names);
    try testing.expectEqualStrings("ro.txt", names);
}

test "phase-20 NFS-14: /mnt/snarf-self ctl 'put' has the same disk effect as the tag Put" {
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("f.txt", "hello\n");
    const w = try r.openWin("/f.txt");
    try r.edit(w, 0, "Y");
    var idb: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&idb, "{d}", .{w.id});
    const fid = (try r.self.cl.walk(r.self.root_fid, &.{ id, "ctl" })).fid;
    _ = try r.self.cl.open(fid, msg.ORDWR);
    _ = try r.self.cl.write(fid, 0, "put\n");
    try r.settle();
    try r.diskIs("f.txt", "Yhello\n");
    try testing.expect(!w.dirty and !w.body.file.mod);
    try testing.expectEqual(w.body.file.seq, w.putseq);
}

test "phase-20 NFS-16: a 5 MB file opens in well under 5 s" {
    const r = try Rig.create();
    defer r.destroy();
    const big = try r.a.alloc(u8, 5 << 20);
    defer r.a.free(big);
    for (big, 0..) |*b, i| b.* = if (i % 80 == 79) '\n' else @intCast('a' + i % 26);
    try r.seed("big.txt", big);
    const t0 = Io.Timestamp.now(testing.io, .awake);
    const w = try r.openWin("/big.txt");
    const ms = t0.untilNow(testing.io, .awake).toMilliseconds();
    try testing.expectEqual(@as(usize, 5 << 20), w.body.file.buffer.len());
    try testing.expect(ms < 5000);
}

test "phase-20 NFS-01w: main_native wires hostfs at / and /mnt/host (R-P20-2, source pin)" {
    // The harness above builds its own namespace, so it cannot see the real
    // entry point. Pin the contract's wiring sentence in the source itself
    // (same directory, so @embedFile is in-module). Turns green when
    // `main_native.zig` does `HostFs.open(io, "/")` + mounts "/" and "/mnt/host".
    const src = @embedFile("main_native.zig");
    try testing.expect(std.mem.indexOf(u8, src, "HostFs.open(") != null);
    try testing.expect(std.mem.indexOf(u8, src, "\"/mnt/host\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".mount(\"/\"") != null);
}

// ===========================================================================
// NFS-11..13 — Dump/Load through the root mount (R-P20-5). Added by the
// implementation stage: they pass with ZERO extra plumbing once `$home`
// resolves through `/` (here `$home` = `/home`, i.e. tmp/home).
// ===========================================================================

/// Windows that are not `+Errors` (warnings make one; "unchanged" ignores it).
fn fileWindows(r: *Rig) usize {
    var n: usize = 0;
    for (r.tree.row.col.items) |c| for (c.w.items) |w| {
        if (!std.mem.endsWith(u8, w.body.file.name.items, "+Errors")) n += 1;
    };
    return n;
}

test "phase-20 NFS-11: Dump writes $home/acme.dump in acme's text format" {
    const r = try Rig.create();
    defer r.destroy();
    try r.tmp.dir.createDirPath(testing.io, "home");
    r.ed.session.home = "/home";
    try r.seed("f.txt", "hello\n");
    _ = try r.openWin("/f.txt");
    try r.run(&r.tree.row.tag, "Dump");
    try r.settle();
    const d = try r.disk("home/acme.dump");
    defer r.a.free(d);
    try testing.expect(std.mem.startsWith(u8, d, "/\n")); // rows.c:481 wdir line
    try testing.expect(std.mem.indexOf(u8, d, "/f.txt") != null);
    try testing.expect(!r.ed.warningsPending());
}

test "phase-20 NFS-12: a fresh editor's Load restores the dumped windows, names and contents" {
    var dumped: []u8 = undefined;
    {
        const r = try Rig.create();
        defer r.destroy();
        try r.tmp.dir.createDirPath(testing.io, "home");
        r.ed.session.home = "/home";
        try r.seed("f.txt", "hello\n");
        try r.seed("g.txt", "world\n");
        _ = try r.openWin("/f.txt");
        _ = try r.openWin("/g.txt");
        try r.run(&r.tree.row.tag, "Dump");
        try r.settle();
        dumped = try r.disk("home/acme.dump");
    }
    defer testing.allocator.free(dumped);

    const r = try Rig.create();
    defer r.destroy();
    try r.tmp.dir.createDirPath(testing.io, "home");
    r.ed.session.home = "/home";
    try r.seed("f.txt", "hello\n");
    try r.seed("g.txt", "world\n");
    try r.seed("home/acme.dump", dumped);
    const before = fileWindows(r); // the boot scratch window
    try r.run(&r.tree.row.tag, "Load");
    try r.settle();
    try testing.expect(!r.ed.warningsPending());
    // Load adds on top (rowload initing=FALSE, rows.c:559): the dump held the
    // first editor's scratch window plus /f.txt and /g.txt.
    try testing.expectEqual(before + 3, fileWindows(r));
    var names: usize = 0;
    for (r.tree.row.col.items) |c| for (c.w.items) |w| {
        const n = w.body.file.name.items;
        if (std.mem.eql(u8, n, "/f.txt") or std.mem.eql(u8, n, "/g.txt")) names += 1;
    };
    try testing.expectEqual(@as(usize, 2), names);
    try testing.expect(try r.bodiesContain("hello\n"));
    try testing.expect(try r.bodiesContain("world\n"));
}

test "phase-20 NFS-13: Load of a missing or corrupt dump warns and leaves the editor unchanged" {
    const r = try Rig.create();
    defer r.destroy();
    try r.tmp.dir.createDirPath(testing.io, "home");
    r.ed.session.home = "/home";
    const before = fileWindows(r);
    try r.run(&r.tree.row.tag, "Load");
    try r.settle();
    try testing.expect(try r.bodiesContain("can't open load file /home/acme.dump"));
    try testing.expectEqual(before, fileWindows(r));

    try r.seed("home/acme.dump", "/\n"); // header cut short: fails before any window
    try r.run(&r.tree.row.tag, "Load");
    try r.settle();
    try testing.expect(try r.bodiesContain("bad load file /home/acme.dump:"));
    try testing.expectEqual(before, fileWindows(r));
}

test "phase-20 NFS-01b: a dirwin on / lists synthetic mount points with the host root (R-9P-16)" {
    // Corrects the contract's R-P20-2 claim: synthetic prefixes ARE listed —
    // ListDirJob concatenates syntheticChildren with the union members'
    // streams (S-02 §1.2, nsio.zig), so the boot window shows dev/ and mnt/
    // alongside the real files.
    const r = try Rig.create();
    defer r.destroy();
    try r.seed("realfile.txt", "x");
    const w = try r.openWin("/");
    try testing.expect(w.isdir);
    const b = try r.bodyBytes(w);
    defer r.a.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "dev/") != null);
    try testing.expect(std.mem.indexOf(u8, b, "mnt/") != null);
    try testing.expect(std.mem.indexOf(u8, b, "realfile.txt") != null);
}
