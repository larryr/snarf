//! #58 / PR #68 — extra coverage for the recovery file (SnarfDev2 validation).
//! Same rig as `recovery_test.zig` (a scratch dir served through the real
//! `HostTree`, an OTRUNC Put that never gets its Tclunk, then `endSession`),
//! for the spec bullets the PR's own tests leave open: relative/empty/trailing-
//! slash `$TMPDIR`, symlinks at the recovery name, numbering exhaustion, the
//! in-place variant, a Put that already failed, several discarded Puts, and a
//! Put of a NEW file (Tcreate) cut off at exit.
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
    last_put: u32 = 0,

    fn create(files: []const [2][]const u8) !*Rig {
        const a = testing.allocator;
        const r = try a.create(Rig);
        r.a = a;
        r.ended = false;
        r.last_put = 0;
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
        r.last_put = f.fid;
        if (data.len != 0) _ = try r.cl.write(f.fid, 0, data);
    }

    /// Twrite more bytes on the most recent Put's fid; true if the server refused.
    fn writeLastFails(r: *Rig) bool {
        _ = r.cl.write(r.last_put, 3, "def") catch return true;
        return false;
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

/// Flip to true in the PR that reports a cut-off Put of a NEW file (Tcreate path).
const create_put_notice_fixed = false; // #70

fn altEmpty(r: *Rig) !bool {
    var d = try r.alt.dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    return (try it.next(io)) == null;
}

fn absDelete(p: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, p) catch {};
}

/// A Put whose own directory goes read-only mid-write, with `$TMPDIR` = `tmpdir`:
/// the fallback must land in /tmp under `pid`.
fn expectTmpFallbackToSlashTmp(tmpdir: []const u8, pid: u32) !void {
    if (isRoot()) return error.SkipZigTest;
    const r = try Rig.create(&.{.{ "ro/snarfdev2-58-g", "old" }});
    defer r.destroy();
    r.tree.recovery = .{ .tmp_dir = tmpdir, .pid = pid };
    var buf: [128]u8 = undefined;
    const want_path = try std.fmt.bufPrint(&buf, "/tmp/snarf-partial-{d}-snarfdev2-58-g", .{pid});
    absDelete(want_path);
    defer absDelete(want_path);
    try r.startPut("ro/snarfdev2-58-g", "part");
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o555), .{});
    defer r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o755), .{}) catch {};
    var wb: [256]u8 = undefined;
    const want = try std.fmt.bufPrint(&wb, "snarf: Put of /ro/snarfdev2-58-g not finished at exit; file left unchanged\n" ++
        "snarf: partial contents saved in {s}\n", .{want_path});
    try testing.expectEqualStrings(want, r.end());
    try r.expectFile(std.Io.Dir.cwd(), want_path, "part");
    try Rig.expectMode0600(std.Io.Dir.cwd(), want_path);
    try testing.expect(try altEmpty(r));
}

test "recovery+: a relative $TMPDIR means /tmp" {
    try expectTmpFallbackToSlashTmp("relative/tmp", 3900005801);
}

test "recovery+: an empty $TMPDIR means /tmp" {
    try expectTmpFallbackToSlashTmp("", 3900005802);
}

test "recovery+: a trailing slash on $TMPDIR is not doubled in the printed path" {
    if (isRoot()) return error.SkipZigTest;
    const r = try Rig.create(&.{.{ "ro/g", "old" }});
    defer r.destroy();
    const slashed = try std.fmt.allocPrint(r.a, "{s}/", .{r.alt_path});
    defer r.a.free(slashed);
    r.tree.recovery.tmp_dir = slashed;
    try r.startPut("ro/g", "part");
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o555), .{});
    defer r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o755), .{}) catch {};
    const out = r.end();
    try testing.expect(std.mem.indexOf(u8, out, "//") == null);
    try r.expectFile(r.alt.dir, "snarf-partial-4242-g", "part");
}

test "recovery+: a dangling symlink at the recovery name is not followed (exclusive create)" {
    const r = try Rig.create(&.{.{ "f", "old" }});
    defer r.destroy();
    try r.tmp.dir.symLink(io, "victim-not-created", ".f.snarf-partial", .{});
    try r.startPut("f", "newer");
    try testing.expectEqualStrings(
        "snarf: Put of /f not finished at exit; file left unchanged\n" ++
            "snarf: partial contents saved in /.f.snarf-partial.1\n",
        r.end(),
    );
    try testing.expectError(error.FileNotFound, r.tmp.dir.statFile(io, "victim-not-created", .{}));
    try r.expectFile(r.tmp.dir, ".f.snarf-partial.1", "newer");
}

test "recovery+: a symlink to another file at the recovery name never overwrites that file" {
    const r = try Rig.create(&.{ .{ "f", "old" }, .{ "precious", "keep me" } });
    defer r.destroy();
    try r.tmp.dir.symLink(io, "precious", ".f.snarf-partial", .{});
    try r.startPut("f", "newer");
    _ = r.end();
    try r.expectFile(r.tmp.dir, "precious", "keep me");
    try r.expectFile(r.tmp.dir, ".f.snarf-partial.1", "newer");
}

test "recovery+: all numbered names beside the file taken -> $TMPDIR fallback" {
    const r = try Rig.create(&.{.{ "f", "old" }});
    defer r.destroy();
    try r.tmp.dir.writeFile(io, .{ .sub_path = ".f.snarf-partial", .data = "x" });
    var i: usize = 1;
    var nb: [64]u8 = undefined;
    while (i < 1000) : (i += 1) {
        try r.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&nb, ".f.snarf-partial.{d}", .{i}), .data = "x" });
    }
    try r.startPut("f", "late");
    const want = try std.fmt.allocPrint(r.a, "snarf: Put of /f not finished at exit; file left unchanged\n" ++
        "snarf: partial contents saved in {s}/snarf-partial-4242-f\n", .{r.alt_path});
    defer r.a.free(want);
    try testing.expectEqualStrings(want, r.end());
    try r.expectFile(r.alt.dir, "snarf-partial-4242-f", "late");
    try r.expectFile(r.tmp.dir, ".f.snarf-partial.999", "x");
}

test "recovery+: the in-place variant (directory read-only from the start) prints the in-place line and saves nothing" {
    if (isRoot()) return error.SkipZigTest;
    const r = try Rig.create(&.{.{ "ro/g", "old contents" }});
    defer r.destroy();
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o555), .{});
    defer r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o755), .{}) catch {};
    try r.startPut("ro/g", "pa");
    try testing.expectEqualStrings(
        "snarf: Put of /ro/g not finished at exit; written in place and may be incomplete\n",
        r.end(),
    );
    try r.expectFile(r.tmp.dir, "ro/g", "pa"); // the partial bytes ARE the file
    try testing.expectError(error.FileNotFound, r.tmp.dir.statFile(io, "ro/.g.snarf-partial", .{}));
    try testing.expect(try altEmpty(r));
}

test "recovery+: a Put that already failed is not reported again and saves nothing" {
    const r = try Rig.create(&.{.{ "f", "old" }});
    defer r.destroy();
    try r.startPut("f", "abc");
    // Pull the temp out from under the Put: the next Twrite fails (p.failed).
    var d = try r.tmp.dir.openDir(io, ".", .{ .iterate = true });
    var it = d.iterate();
    var nb: [128]u8 = undefined;
    var temp: []const u8 = "";
    while (try it.next(io)) |e| if (std.mem.startsWith(u8, e.name, ".f.snarf-put.")) {
        @memcpy(nb[0..e.name.len], e.name);
        temp = nb[0..e.name.len];
    };
    d.close(io);
    try testing.expect(temp.len != 0);
    try r.tmp.dir.deleteFile(io, temp);
    try testing.expect(r.writeLastFails());
    try testing.expectEqualStrings("", r.end());
    try testing.expectError(error.FileNotFound, r.tmp.dir.statFile(io, ".f.snarf-partial", .{}));
    try testing.expect(try altEmpty(r));
    try r.expectFile(r.tmp.dir, "f", "old");
}

test "recovery+: two Puts cut off in one session give two notices, each with its own file" {
    const r = try Rig.create(&.{ .{ "a", "A" }, .{ "d/b", "B" } });
    defer r.destroy();
    try r.startPut("a", "a-part");
    try r.startPut("d/b", "b-part");
    const out = r.end();
    try testing.expect(std.mem.indexOf(u8, out, "snarf: Put of /a not finished at exit; file left unchanged\nsnarf: partial contents saved in /.a.snarf-partial\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "snarf: Put of /d/b not finished at exit; file left unchanged\nsnarf: partial contents saved in /d/.b.snarf-partial\n") != null);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\n"));
    try r.expectFile(r.tmp.dir, ".a.snarf-partial", "a-part");
    try r.expectFile(r.tmp.dir, "d/.b.snarf-partial", "b-part");
}

test "recovery+: FLAG create_put_notice_fixed: a Put of a NEW file cut off at exit is reported" {
    const r = try Rig.create(&.{});
    defer r.destroy();
    // Put of a file that does not exist yet: Tcreate on the directory fid,
    // then Twrites straight into the new file (no Replace, no temp).
    const dfid = try r.cl.walk(r.root, &.{});
    _ = try r.cl.create(dfid.fid, "new.txt", 0o644, msg.OWRITE);
    _ = try r.cl.write(dfid.fid, 0, "half of a new file");
    const out = r.end();
    const reported = std.mem.indexOf(u8, out, "/new.txt not finished at exit") != null;
    if (create_put_notice_fixed) {
        try testing.expect(reported);
    } else {
        // Today: silent, and a truncated new.txt is left with no word.
        try r.expectFile(r.tmp.dir, "new.txt", "half of a new file");
        if (reported) return error.UnexpectedPassFlipFlag;
        return error.SkipZigTest;
    }
}
