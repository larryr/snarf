//! #58: what `HostTree.endSession` does with a Put the session ended under
//! (Owner decision 2026-10-31 (Larry): keep partial Put in a recovery file,
//! vim-style). Each test serves a scratch directory through the real
//! `HostTree`, starts an OTRUNC Put, never clunks it, and ends the session.
const std = @import("std");
const testing = std.testing;
const ninep = @import("ninep");
const msg = ninep.msg;
const server = ninep.server;
const HostFs = @import("HostFs.zig");
const HostTree = @import("HostTree.zig");

const io = testing.io;

const Rig = struct {
    a: std.mem.Allocator,
    tmp: testing.TmpDir,
    /// A second scratch directory standing in for `$TMPDIR`.
    alt: testing.TmpDir,
    alt_path: [:0]u8,
    fs: HostFs,
    tree: HostTree,
    pipe: *ninep.chan.Pipe,
    srv: server.Server,
    cl: ninep.Client,
    root: u32,
    log: std.Io.Writer.Allocating,
    ended: bool = false,

    fn create(files: []const [2][]const u8) !*Rig {
        const a = testing.allocator;
        const r = try a.create(Rig);
        r.a = a;
        r.ended = false;
        r.tmp = testing.tmpDir(.{ .iterate = true });
        r.alt = testing.tmpDir(.{ .iterate = true });
        for (files) |f| {
            if (std.fs.path.dirname(f[0])) |d| try r.tmp.dir.createDirPath(io, d);
            try r.tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
        }
        const path = try r.tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(path);
        r.alt_path = try r.alt.dir.realPathFileAlloc(io, ".", a);
        r.fs = try HostFs.open(io, path);
        r.tree = HostTree.init(a, &r.fs);
        r.tree.recovery = .{ .tmp_dir = r.alt_path, .pid = 4242 };
        r.pipe = try ninep.chan.Pipe.init(a, 16384);
        r.srv = try server.Server.init(a, r.pipe.serverEnd(), &HostTree.ops, &r.tree, 8192);
        r.cl = try ninep.Client.init(a, r.pipe.clientEnd(), 8192);
        r.cl.pump = .{ .ctx = &r.srv, .run = pump };
        _ = try r.cl.version(8192);
        r.root = (try r.cl.attach("larry", "")).fid;
        r.log = .init(a);
        return r;
    }

    fn pump(p: *anyopaque) anyerror!void {
        _ = try @as(*server.Server, @ptrCast(@alignCast(p))).poll();
    }

    /// An OTRUNC Put of `rel` that has received `data` and then nothing more.
    fn startPut(r: *Rig, rel: []const u8, data: []const u8) !void {
        var names: [4][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |s| : (n += 1) names[n] = s;
        const f = try r.cl.walk(r.root, names[0..n]);
        _ = try r.cl.open(f.fid, msg.OWRITE | msg.OTRUNC);
        if (data.len != 0) _ = try r.cl.write(f.fid, 0, data);
    }

    fn end(r: *Rig) []const u8 {
        r.tree.endSession(&r.srv, &r.log.writer);
        r.ended = true;
        return r.log.written();
    }

    fn destroy(r: *Rig) void {
        if (!r.ended) r.tree.endSession(&r.srv, null);
        r.cl.deinit();
        r.srv.deinit();
        r.pipe.deinit();
        r.fs.close();
        r.log.deinit();
        r.a.free(r.alt_path);
        r.alt.cleanup();
        r.tmp.cleanup();
        r.a.destroy(r);
    }

    fn expectFile(r: *Rig, dir: std.Io.Dir, rel: []const u8, want: []const u8) !void {
        const got = try dir.readFileAlloc(io, rel, r.a, .limited(1 << 20));
        defer r.a.free(got);
        try testing.expectEqualStrings(want, got);
    }

    fn expectMode0600(dir: std.Io.Dir, rel: []const u8) !void {
        const st = try dir.statFile(io, rel, .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    }
};

fn isRoot() bool {
    if (@import("builtin").os.tag == .linux) return std.os.linux.geteuid() == 0;
    return std.c.geteuid() == 0;
}

test "recovery: the exact partial bytes land beside the original (mode 0600); the original is untouched" {
    const r = try Rig.create(&.{.{ "d/notes.txt", "original\n" }});
    defer r.destroy();
    const partial = "first half of a new\x00buffer, no newline";
    try r.startPut("d/notes.txt", partial);
    try testing.expectEqualStrings(
        "snarf: Put of /d/notes.txt not finished at exit; file left unchanged\n" ++
            "snarf: partial contents saved in /d/.notes.txt.snarf-partial\n",
        r.end(),
    );
    try r.expectFile(r.tmp.dir, "d/notes.txt", "original\n");
    try r.expectFile(r.tmp.dir, "d/.notes.txt.snarf-partial", partial);
    try Rig.expectMode0600(r.tmp.dir, "d/.notes.txt.snarf-partial");
}

test "recovery: a taken name gets the next numbered suffix; nothing is overwritten" {
    const r = try Rig.create(&.{
        .{ "f", "old" },
        .{ ".f.snarf-partial", "earlier crash" },
        .{ ".f.snarf-partial.1", "earlier crash 2" },
    });
    defer r.destroy();
    try r.startPut("f", "newer");
    try testing.expectEqualStrings(
        "snarf: Put of /f not finished at exit; file left unchanged\n" ++
            "snarf: partial contents saved in /.f.snarf-partial.2\n",
        r.end(),
    );
    try r.expectFile(r.tmp.dir, ".f.snarf-partial", "earlier crash");
    try r.expectFile(r.tmp.dir, ".f.snarf-partial.1", "earlier crash 2");
    try r.expectFile(r.tmp.dir, ".f.snarf-partial.2", "newer");
    try r.expectFile(r.tmp.dir, "f", "old");
}

test "recovery: a read-only directory falls back to $TMPDIR as snarf-partial-<pid>-<base>" {
    if (isRoot()) return error.SkipZigTest; // root writes through 0555
    const r = try Rig.create(&.{.{ "ro/g", "old" }});
    defer r.destroy();
    // A fallback name already taken in $TMPDIR, too.
    try r.alt.dir.writeFile(io, .{ .sub_path = "snarf-partial-4242-g", .data = "someone else's" });
    try r.startPut("ro/g", "part");
    // The directory goes read-only mid-Put (the phase-20 dirlock probe).
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o555), .{});
    defer r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o755), .{}) catch {};
    const want = try std.fmt.allocPrint(r.a, "snarf: Put of /ro/g not finished at exit; file left unchanged\n" ++
        "snarf: partial contents saved in {s}/snarf-partial-4242-g.1\n", .{r.alt_path});
    defer r.a.free(want);
    try testing.expectEqualStrings(want, r.end());
    try r.expectFile(r.alt.dir, "snarf-partial-4242-g", "someone else's");
    try r.expectFile(r.alt.dir, "snarf-partial-4242-g.1", "part");
    try Rig.expectMode0600(r.alt.dir, "snarf-partial-4242-g.1");
    try r.expectFile(r.tmp.dir, "ro/g", "old");
}

test "recovery: when nowhere takes it, the notice keeps its wording and adds the reason" {
    if (isRoot()) return error.SkipZigTest;
    const r = try Rig.create(&.{.{ "ro/g", "old" }});
    defer r.destroy();
    r.tree.recovery.tmp_dir = "/nonexistent/snarf-58-tmp";
    try r.startPut("ro/g", "part");
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o555), .{});
    defer r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o755), .{}) catch {};
    try testing.expectEqualStrings(
        "snarf: Put of /ro/g not finished at exit; file left unchanged\n" ++
            "snarf: could not save partial contents (FileNotFound)\n",
        r.end(),
    );
    try r.expectFile(r.tmp.dir, "ro/g", "old");
}

test "recovery: a Put of zero bytes still gets the notice but leaves no file" {
    const r = try Rig.create(&.{.{ "f", "old" }});
    defer r.destroy();
    try r.startPut("f", "");
    try testing.expectEqualStrings("snarf: Put of /f not finished at exit; file left unchanged\n", r.end());
    try r.expectFile(r.tmp.dir, "f", "old");
    try testing.expectError(error.FileNotFound, r.tmp.dir.statFile(io, ".f.snarf-partial", .{}));
    var d = try r.alt.dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    try testing.expect((try it.next(io)) == null);
}
