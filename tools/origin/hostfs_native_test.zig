//! Host-filesystem 9P harness for issue #11 (native file server).
//! Requirements: R-EDIT-15, R-EDIT-16, R-P17-5 (S-02 authoritative, PM Q6),
//! ADR-0005 §2. Plan: `notes/snarfdev2/test-plans/M1-11-native-fs.md`.
//!
//! #11 reuses `hostfs.zig` in-process on native (NEXT-PHASES Tier 2 #4). This
//! harness serves a temp directory through `HostFs` + `tree.Tree` over an
//! in-memory 9P pipe (no socket, no thread), so the file-level semantics a
//! native mount will rely on are pinned now, independent of WebSocket and of
//! where #11 finally mounts it (PM Q1: per #11 spec text; checklist step 4
//! conflict is TBD pending Larry). Paths are under the tree's `fs/`.
//!
//! The one EXPECTED-FAIL test (`NFS-10b`, gated on a `native_fs_landed`
//! flag) was replaced in phase 20 by a plain test of the orchestrator's
//! ruling on the empty Put (see that test).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ninep = @import("ninep");
const msg = ninep.msg;
const HostFs = @import("hostfs").HostFs;
const tree = @import("tree.zig");

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// A temp export served over an in-process 9P pipe. Heap-allocated so the
/// server's context pointers stay put.
pub const TempExport = struct {
    tmp: testing.TmpDir,
    host: HostFs,
    tr: tree.Tree,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,
    root: u32,

    pub fn create() !*TempExport {
        const a = testing.allocator;
        const io = testing.io;
        const h = try a.create(TempExport);
        errdefer a.destroy(h);
        h.tmp = testing.tmpDir(.{ .iterate = true });
        const path = try h.tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(path);
        h.host = try HostFs.open(io, path);
        h.tr = tree.Tree.init(a, &h.host);
        h.pipe = try ninep.chan.Pipe.init(a, 65536);
        h.srv = try ninep.server.Server.init(a, h.pipe.serverEnd(), &tree.Tree.ops, &h.tr, 16384);
        h.cl = try ninep.Client.init(a, h.pipe.clientEnd(), 16384);
        h.cl.pump = .{ .ctx = &h.srv, .run = pump };
        _ = try h.cl.version(16384);
        h.root = (try h.cl.attach("larry", "")).fid;
        return h;
    }

    pub fn destroy(h: *TempExport) void {
        h.cl.clunk(h.root) catch {};
        h.cl.deinit();
        h.srv.deinit();
        h.pipe.deinit();
        h.tr.deinit();
        h.host.close();
        h.tmp.cleanup();
        testing.allocator.destroy(h);
    }

    /// Put a file on disk directly (bypassing 9P).
    pub fn seed(h: *TempExport, rel: []const u8, data: []const u8) !void {
        try h.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    /// Read a file from disk directly. Caller frees.
    pub fn disk(h: *TempExport, rel: []const u8) ![]u8 {
        return h.tmp.dir.readFileAlloc(testing.io, rel, testing.allocator, .limited(1 << 20));
    }

    fn walkFs(h: *TempExport, rel: []const u8) !u32 {
        var names: [16][]const u8 = undefined;
        names[0] = "fs";
        var n: usize = 1;
        var it = std.mem.tokenizeScalar(u8, rel, '/');
        while (it.next()) |c| : (n += 1) names[n] = c;
        return (try h.cl.walk(h.root, names[0..n])).fid;
    }

    /// Read a whole file through 9P. Caller frees.
    pub fn read9p(h: *TempExport, rel: []const u8) ![]u8 {
        const fid = try h.walkFs(rel);
        defer h.cl.clunk(fid) catch {};
        _ = try h.cl.open(fid, msg.OREAD);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(testing.allocator);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try h.cl.read(fid, out.items.len, &buf);
            if (n == 0) break;
            try out.appendSlice(testing.allocator, buf[0..n]);
        }
        return out.toOwnedSlice(testing.allocator);
    }

    /// The Put shape (`nswrite.WriteFileJob`): open OTRUNC|OWRITE if it
    /// exists, else walk the parent and Tcreate 0666; write in chunks; clunk.
    pub fn put9p(h: *TempExport, rel: []const u8, data: []const u8) !void {
        const fid = blk: {
            if (h.walkFs(rel)) |f| {
                _ = h.cl.open(f, msg.OWRITE | msg.OTRUNC) catch |e| {
                    h.cl.clunk(f) catch {};
                    return e;
                };
                break :blk f;
            } else |e| {
                if (e != error.FileDoesNotExist) return e;
                const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
                const parent = if (slash) |s| rel[0..s] else "";
                const base = if (slash) |s| rel[s + 1 ..] else rel;
                const p = try h.walkFs(parent);
                _ = h.cl.create(p, base, 0o666, msg.OWRITE) catch |ce| {
                    h.cl.clunk(p) catch {};
                    return ce;
                };
                break :blk p;
            }
        };
        defer h.cl.clunk(fid) catch {};
        var off: usize = 0;
        while (off < data.len) {
            const n = @min(data.len - off, 4096);
            off += try h.cl.write(fid, off, data[off..][0..n]);
        }
    }
};

const tricky = "caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x98\x80\r\nno trailing newline";

test "hostfs-native NFS-02: 9P read is byte-exact (UTF-8, CRLF, no trailing NL)" {
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("t.txt", tricky);
    const got = try h.read9p("t.txt");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(tricky, got);
}

test "hostfs-native NFS-05: Put-shaped overwrite lands exact bytes on disk (shorter than before)" {
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("a.zig", "a much longer original body\n");
    try h.put9p("a.zig", "short\n");
    const d = try h.disk("a.zig");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("short\n", d);
}

test "hostfs-native NFS-09: Put to a new path in a subdirectory creates it" {
    const h = try TempExport.create();
    defer h.destroy();
    try h.tmp.dir.createDirPath(testing.io, "sub");
    try h.put9p("sub/new.txt", tricky);
    const d = try h.disk("sub/new.txt");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings(tricky, d);
}

test "hostfs-native NFS-09b: a new file's host mode is 0666 &~ umask (PM Q5)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    const h = try TempExport.create();
    defer h.destroy();
    try h.put9p("m.txt", "x");
    const old: u32 = @intCast(linux.syscall1(.umask, 0o022));
    _ = linux.syscall1(.umask, old);
    const st = try h.tmp.dir.statFile(testing.io, "m.txt", .{});
    const mode: u32 = @intCast(st.permissions.toMode());
    try testing.expectEqual(@as(u32, 0o666 & ~old), mode & 0o777);
}

test "hostfs-native NFS-04: open of a missing path is an honest 9P error" {
    const h = try TempExport.create();
    defer h.destroy();
    try testing.expectError(error.FileDoesNotExist, h.read9p("nope.txt"));
}

test "hostfs-native NFS-10: Put to a read-only file errors and leaves the old bytes intact (PM Q5)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest; // root ignores mode bits
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("ro.txt", "original\n");
    var f = try h.tmp.dir.openFile(testing.io, "ro.txt", .{});
    try f.setPermissions(testing.io, .fromMode(0o444));
    f.close(testing.io);
    try testing.expectError(error.PermissionDenied, h.put9p("ro.txt", "clobbered\n"));
    const d = try h.disk("ro.txt");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("original\n", d);
}

/// Flip when issue #28 is fixed (confined mode refuses escaping symlinks).
const symlink_escape_fixed = false;

fn readable(h: *TempExport, rel: []const u8) bool {
    const bytes = h.read9p(rel) catch return false;
    testing.allocator.free(bytes);
    return true;
}

// Symlink policy (PM, 2026-10-14; issue #28). `HostFs` has no mode switch
// yet, so both policies are exercised against today's single HostFs; when #28
// adds trusted-local vs confined-export modes, point each test at its mode.

test "hostfs-native NFS-15a: native (trusted local) mount follows symlinks, even out of the root" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const h = try TempExport.create();
    defer h.destroy();
    try h.tmp.dir.symLink(testing.io, "/etc/hostname", "escape", .{});
    try testing.expect(readable(h, "escape"));
}

test "hostfs-native NFS-15b: remote export allows symlinks that stay inside the root" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("real.txt", "inside\n");
    try h.tmp.dir.symLink(testing.io, "real.txt", "link.txt", .{});
    const got = try h.read9p("link.txt");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("inside\n", got);
}

test "hostfs-native NFS-15c: remote export refuses symlinks escaping the root (known bug #28)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const h = try TempExport.create();
    defer h.destroy();
    try h.tmp.dir.symLink(testing.io, "/etc/hostname", "escape", .{});
    const refused = !readable(h, "escape");
    if (!symlink_escape_fixed) {
        if (refused) return error.UnexpectedPassFlipFlag;
        return error.SkipZigTest;
    }
    try testing.expect(refused);
}

test "hostfs-native NFS-15d: '..' never escapes the export root" {
    const h = try TempExport.create();
    defer h.destroy();
    // fs/.. is the synthetic origin root, never the host parent directory.
    const up = try h.cl.walk(h.root, &.{ "fs", "..", ".." });
    h.cl.clunk(up.fid) catch {};
    try testing.expectError(error.FileDoesNotExist, h.cl.walk(h.root, &.{ "fs", "..", "..", "etc" }));
    try testing.expectError(error.FileDoesNotExist, h.cl.walk(h.root, &.{ "fs", "..", "..", "..", "etc", "hostname" }));
}

test "hostfs-native NFS-16: a 5 MB file round-trips through 9P" {
    const a = testing.allocator;
    const h = try TempExport.create();
    defer h.destroy();
    const big = try a.alloc(u8, 5 << 20);
    defer a.free(big);
    for (big, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    try h.put9p("big.txt", big);
    const got = try h.read9p("big.txt");
    defer a.free(got);
    try testing.expect(std.mem.eql(u8, big, got));
}

test "hostfs-native NFS-10b: OTRUNC open + clunk with no write is an EMPTY Put, committed atomically" {
    // Phase 20 ruling (orchestrator, contract clarification of PM Q5): an
    // OTRUNC open followed by a clean clunk with ZERO writes is acme putting an
    // empty buffer (exec.c:727 create + no writes + close), so the file ends
    // EMPTY — exactly as acme leaves it. Atomicity protects against FAILED
    // Puts (a failed Twrite poisons the fid: Q5-b), not against empty ones.
    // This test previously asserted the old bytes survive (an xfail written
    // before the ruling); that contradicted the contract and was corrected.
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("keep.txt", "precious\n");
    const fid = try h.walkFs("keep.txt");
    _ = try h.cl.open(fid, msg.OWRITE | msg.OTRUNC);
    const d0 = try h.disk("keep.txt");
    defer testing.allocator.free(d0);
    try testing.expectEqualStrings("precious\n", d0); // untouched until clunk
    try h.cl.clunk(fid);
    const d = try h.disk("keep.txt");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("", d);
}

// ---------------------------------------------------------------------------
// Phase 20 (R-P20-3, PM Q5): hostfs makes Put atomic. An OTRUNC open of an
// existing file must NOT touch it: bytes go to a same-directory temp file that
// is renamed over the original on clunk; a failure before clunk discards the
// temp. New files are created `0666 & ~umask`. These are real tests (not
// `xfail`): they FAIL until the implementation lands.
// ---------------------------------------------------------------------------

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

/// Sorted, space-joined names in the export root. Caller frees.
fn listRoot(h: *TempExport) ![]u8 {
    const a = testing.allocator;
    var d = try h.tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer d.close(testing.io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var it = d.iterate();
    while (try it.next(testing.io)) |e| try names.append(a, try a.dupe(u8, e.name));
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (names.items, 0..) |n, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, n);
    }
    return out.toOwnedSlice(a);
}

fn expectDisk(h: *TempExport, rel: []const u8, want: []const u8) !void {
    const d = try h.disk(rel);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings(want, d);
}

/// A write that must fail: far past any file-size limit.
const unwritable_offset: u64 = 1 << 62;

test "hostfs-native Q5-a: atomic replace — old bytes stay readable until clunk, new ones appear at clunk" {
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("keep.txt", "old\n");
    const fid = try h.walkFs("keep.txt");
    _ = try h.cl.open(fid, msg.OWRITE | msg.OTRUNC);
    try expectDisk(h, "keep.txt", "old\n"); // open(OTRUNC) alone must not truncate
    _ = try h.cl.write(fid, 0, "brand new content\n");
    try expectDisk(h, "keep.txt", "old\n"); // still the old file mid-write
    // And a concurrent reader through 9P sees the old file too.
    const rd = try h.read9p("keep.txt");
    defer testing.allocator.free(rd);
    try testing.expectEqualStrings("old\n", rd);
    try h.cl.clunk(fid);
    try expectDisk(h, "keep.txt", "brand new content\n");
}

test "hostfs-native Q5-b: a failure before clunk keeps the old file (shorter and longer)" {
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("keep.txt", "precious\n");
    const fid = try h.walkFs("keep.txt");
    _ = try h.cl.open(fid, msg.OWRITE | msg.OTRUNC);
    _ = try h.cl.write(fid, 0, "partial");
    if (h.cl.write(fid, unwritable_offset, "x")) |_| {
        return error.FailureInjectionDidNotFail;
    } else |_| {}
    try h.cl.clunk(fid); // clunk after a failed write must DISCARD, not commit
    try expectDisk(h, "keep.txt", "precious\n");
}

test "hostfs-native Q5-c: no temp-file litter after a successful or a failed atomic Put" {
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("ok.txt", "old\n");
    try h.seed("bad.txt", "old\n");
    try h.put9p("ok.txt", "new\n");
    {
        const fid = try h.walkFs("bad.txt");
        _ = try h.cl.open(fid, msg.OWRITE | msg.OTRUNC);
        _ = try h.cl.write(fid, 0, "partial");
        _ = h.cl.write(fid, unwritable_offset, "x") catch {};
        try h.cl.clunk(fid);
    }
    const names = try listRoot(h);
    defer testing.allocator.free(names);
    try testing.expectEqualStrings("bad.txt ok.txt", names);
    try expectDisk(h, "ok.txt", "new\n");
}

test "hostfs-native Q5-d: a new file is created 0666 & ~umask" {
    const h = try TempExport.create();
    defer h.destroy();
    try h.put9p("fresh.txt", "x");
    const st = try h.tmp.dir.statFile(testing.io, "fresh.txt", .{});
    const mode: u32 = @intCast(st.permissions.toMode());
    try testing.expectEqual(@as(u32, 0o666 & ~umaskNow()), mode & 0o777);
    const names = try listRoot(h);
    defer testing.allocator.free(names);
    try testing.expectEqualStrings("fresh.txt", names);
}

test "hostfs-native Q5-d2: atomic replace preserves the existing file's mode" {
    const h = try TempExport.create();
    defer h.destroy();
    try h.seed("m.txt", "old\n");
    var f = try h.tmp.dir.openFile(testing.io, "m.txt", .{});
    try f.setPermissions(testing.io, .fromMode(0o640));
    f.close(testing.io);
    try h.put9p("m.txt", "new\n");
    try expectDisk(h, "m.txt", "new\n");
    const st = try h.tmp.dir.statFile(testing.io, "m.txt", .{});
    const mode: u32 = @intCast(st.permissions.toMode());
    try testing.expectEqual(@as(u32, 0o640), mode & 0o777);
}
