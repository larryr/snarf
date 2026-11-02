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
        "snarf: partial contents saved in {s}/snarf-partial-4242-g.1\n" ++
        // The read-only directory also keeps the empty temp (PR #74 Q2).
        "snarf: could not remove temp file /ro/.g.snarf-put.0\n", .{r.alt_path});
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
            "snarf: could not save partial contents (FileNotFound)\n" ++
            "snarf: could not remove temp file /ro/.g.snarf-put.0\n",
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

// #68 review finding 1: the teardown's own Tclunks sit in the pipe, and any
// later write that blocks pumps the server. `hangUp` (called by `shutdown`
// before teardown) must turn every such Tclunk into a discard.

/// An OTRUNC Put of `rel` that has received `data`; returns its fid.
fn putFid(r: *Rig, rel: []const u8, data: []const u8) !u32 {
    const f = try r.cl.walk(r.root, &.{rel});
    _ = try r.cl.open(f.fid, msg.OWRITE | msg.OTRUNC);
    _ = try r.cl.write(f.fid, 0, data);
    return f.fid;
}

test "hangUp: a Tclunk pumped after hangUp discards the Put, keeps the partial bytes, and says so (#68 finding 1)" {
    const r = try Rig.create(&.{.{ "f", "old\n" }});
    defer r.destroy();
    const fid = try putFid(r, "f", "half-written");
    ninep.tickets.discardClunk(&r.cl, fid); // what teardown queues; the server has not seen it
    r.tree.hangUp(&r.log.writer);
    _ = try r.srv.poll(); // what a blocked write's pump does
    try r.expectFile(r.tmp.dir, "f", "old\n"); // NOT committed
    try r.expectFile(r.tmp.dir, ".f.snarf-partial", "half-written");
    try testing.expectEqualStrings(
        "snarf: Put of /f not finished at exit; file left unchanged\n" ++
            "snarf: partial contents saved in /.f.snarf-partial\n",
        r.log.written(),
    );
}

test "hangUp: control — the same pumped Tclunk WITHOUT hangUp commits (why shutdown must hang up first)" {
    const r = try Rig.create(&.{.{ "f", "old\n" }});
    defer r.destroy();
    const fid = try putFid(r, "f", "all of it\n");
    ninep.tickets.discardClunk(&r.cl, fid);
    _ = try r.srv.poll();
    try r.expectFile(r.tmp.dir, "f", "all of it\n");
}

test "hangUp: a Put whose Tclunk was already queued commits when the host drains first (shutdown's order)" {
    const r = try Rig.create(&.{.{ "f", "old\n" }});
    defer r.destroy();
    const fid = try putFid(r, "f", "finished\n");
    ninep.tickets.discardClunk(&r.cl, fid); // the client really did close the file
    _ = try r.srv.poll(); // shutdown drains BEFORE hanging up
    r.tree.hangUp(&r.log.writer);
    try r.expectFile(r.tmp.dir, "f", "finished\n");
    try testing.expectEqual(@as(usize, 0), r.log.written().len); // nothing was unfinished
}

// #70 (SnarfProdd ruling 2026-11-02): a Put of a NEW file (Tcreate) is handled
// like one of an existing file. Cut off at exit, the real name must not exist,
// the partial bytes go to the recovery file, and both notice lines print.

/// A Tcreate Put of the new file `name` (in the root) that has received `data`.
fn createPut(r: *Rig, name: []const u8, data: []const u8) !u32 {
    const d = try r.cl.walk(r.root, &.{});
    _ = try r.cl.create(d.fid, name, 0o666, msg.OWRITE);
    if (data.len != 0) _ = try r.cl.write(d.fid, 0, data);
    return d.fid;
}

/// The names in `dir` (sorted, joined by spaces) — to catch temp litter.
fn listing(r: *Rig, dir: std.Io.Dir, sub: []const u8) ![]u8 {
    var d = try dir.openDir(io, sub, .{ .iterate = true });
    defer d.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| r.a.free(n);
        names.deinit(r.a);
    }
    var it = d.iterate();
    while (try it.next(io)) |e| try names.append(r.a, try r.a.dupe(u8, e.name));
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return std.mem.join(r.a, " ", names.items);
}

fn expectListing(r: *Rig, dir: std.Io.Dir, sub: []const u8, want: []const u8) !void {
    const got = try listing(r, dir, sub);
    defer r.a.free(got);
    try testing.expectEqualStrings(want, got);
}

test "#70: a Put of a NEW file cut off at exit leaves no file under its name, keeps the bytes, prints both lines" {
    const r = try Rig.create(&.{});
    defer r.destroy();
    _ = try createPut(r, "new.txt", "half of a new file");
    // While the Put is in flight the name holds an empty placeholder only.
    try r.expectFile(r.tmp.dir, "new.txt", "");
    try testing.expectEqualStrings(
        "snarf: Put of /new.txt not finished at exit; file not created\n" ++
            "snarf: partial contents saved in /.new.txt.snarf-partial\n",
        r.end(),
    );
    try testing.expectError(error.FileNotFound, r.tmp.dir.statFile(io, "new.txt", .{}));
    try r.expectFile(r.tmp.dir, ".new.txt.snarf-partial", "half of a new file");
    try Rig.expectMode0600(r.tmp.dir, ".new.txt.snarf-partial");
    try expectListing(r, r.tmp.dir, ".", ".new.txt.snarf-partial"); // no temp litter
}

test "#70: a zero-byte Put of a NEW file cut off at exit: the notice, and no file at all" {
    const r = try Rig.create(&.{});
    defer r.destroy();
    _ = try createPut(r, "empty.txt", "");
    try testing.expectEqualStrings("snarf: Put of /empty.txt not finished at exit; file not created\n", r.end());
    try expectListing(r, r.tmp.dir, ".", "");
}

test "#70: a finished Put of a NEW file commits its bytes under the name, no litter" {
    const r = try Rig.create(&.{});
    defer r.destroy();
    const fid = try createPut(r, "n", "whole\n");
    _ = try r.cl.write(fid, 6, "more\n");
    try r.expectFile(r.tmp.dir, "n", ""); // not visible before the Tclunk
    try r.cl.clunk(fid);
    try r.expectFile(r.tmp.dir, "n", "whole\nmore\n");
    try expectListing(r, r.tmp.dir, ".", "n");
    try testing.expectEqualStrings("", r.end());
}

test "#70: a finished zero-byte Put of a NEW file makes an empty file" {
    const r = try Rig.create(&.{});
    defer r.destroy();
    const fid = try createPut(r, "e", "");
    try r.cl.clunk(fid);
    try r.expectFile(r.tmp.dir, "e", "");
    try expectListing(r, r.tmp.dir, ".", "e");
}

test "#70: Tcreate of an existing name still fails and leaves the file alone" {
    const r = try Rig.create(&.{.{ "f", "keep" }});
    defer r.destroy();
    const d = try r.cl.walk(r.root, &.{});
    try testing.expectError(error.FileExists, r.cl.create(d.fid, "f", 0o666, msg.OWRITE));
    try r.expectFile(r.tmp.dir, "f", "keep");
    try expectListing(r, r.tmp.dir, ".", "f");
}

test "#70: a NEW-file Put whose write fails leaves no file under the name" {
    const r = try Rig.create(&.{});
    defer r.destroy();
    const fid = try createPut(r, "w", "abc");
    // Pull the temp out from under the Put: the next Twrite fails.
    var d = try r.tmp.dir.openDir(io, ".", .{ .iterate = true });
    var it = d.iterate();
    var nb: [128]u8 = undefined;
    var temp: []const u8 = "";
    while (try it.next(io)) |e| if (std.mem.startsWith(u8, e.name, ".w.snarf-put.")) {
        @memcpy(nb[0..e.name.len], e.name);
        temp = nb[0..e.name.len];
    };
    d.close(io);
    try testing.expect(temp.len != 0);
    try r.tmp.dir.deleteFile(io, temp);
    try testing.expect(std.meta.isError(r.cl.write(fid, 3, "def")));
    try r.cl.clunk(fid);
    try expectListing(r, r.tmp.dir, ".", "");
    try testing.expectEqualStrings("", r.end());
}

test "#70 item 3: a temp the read-only directory keeps is emptied, then removed once it can be" {
    if (isRoot()) return error.SkipZigTest;
    const r = try Rig.create(&.{ .{ "ro/g", "old" }, .{ "ro/h", "h" } });
    defer r.destroy();
    const f = try r.cl.walk(r.root, &.{ "ro", "g" });
    _ = try r.cl.open(f.fid, msg.OWRITE | msg.OTRUNC);
    _ = try r.cl.write(f.fid, 0, "new bytes");
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o555), .{});
    try r.cl.clunk(f.fid); // rename refused: saved in place, temp undeletable
    try r.expectFile(r.tmp.dir, "ro/g", "new bytes");
    try expectListing(r, r.tmp.dir, "ro", ".g.snarf-put.0 g h");
    try r.expectFile(r.tmp.dir, "ro/.g.snarf-put.0", ""); // no stray copy of the bytes
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o755), .{});
    // The next Put to finish sweeps it.
    const h = try r.cl.walk(r.root, &.{ "ro", "h" });
    _ = try r.cl.open(h.fid, msg.OWRITE | msg.OTRUNC);
    _ = try r.cl.write(h.fid, 0, "H");
    try r.cl.clunk(h.fid);
    try expectListing(r, r.tmp.dir, "ro", "g h");
    try testing.expectEqualStrings("", r.end());
}

test "#70 item 3: endSession retries the stray temp's delete" {
    if (isRoot()) return error.SkipZigTest;
    const r = try Rig.create(&.{.{ "ro/g", "old" }});
    defer r.destroy();
    const f = try r.cl.walk(r.root, &.{ "ro", "g" });
    _ = try r.cl.open(f.fid, msg.OWRITE | msg.OTRUNC);
    _ = try r.cl.write(f.fid, 0, "new");
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o555), .{});
    try r.cl.clunk(f.fid);
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o755), .{});
    try testing.expectEqual(@as(usize, 1), r.tree.strays.items.len);
    try testing.expectEqualStrings("", r.end());
    try expectListing(r, r.tmp.dir, "ro", "g");
    try testing.expectEqual(@as(usize, 0), r.tree.strays.items.len);
}

test "PR #74 Q2: a stray temp that still can't be removed at exit is named on its own line" {
    if (isRoot()) return error.SkipZigTest;
    const r = try Rig.create(&.{.{ "ro/g", "old" }});
    defer r.destroy();
    defer r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o755), .{}) catch {};
    const f = try r.cl.walk(r.root, &.{ "ro", "g" });
    _ = try r.cl.open(f.fid, msg.OWRITE | msg.OTRUNC);
    _ = try r.cl.write(f.fid, 0, "new");
    try r.tmp.dir.setFilePermissions(io, "ro", .fromMode(0o555), .{});
    try r.cl.clunk(f.fid); // committed in place; the temp can't be deleted
    try testing.expectEqual(@as(usize, 1), r.tree.strays.items.len);
    try testing.expectEqualStrings("snarf: could not remove temp file /ro/.g.snarf-put.0\n", r.end());
    try r.expectFile(r.tmp.dir, "ro/g", "new");
}
