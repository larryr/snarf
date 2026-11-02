//! #60 — union directory listing at native `/` (SnarfDev2). Test plan:
//! `notes/snarfdev2/test-plans/M1-60-union-dir.md` (UD-01..). Pulled into
//! the `accept.zig` test root next to `accept_hostfs.zig`.
//!
//! PM interim ruling (SnarfProdd, 2026-10-31, decisions README): host
//! directories are never hidden; each name appears once at `/`; `dev/` and
//! `mnt/` list snarf's entries first, then the host's, so host paths under
//! them stay reachable.
//!
//! PM rulings on #60 (SnarfProdd, 2026-11-02, decisions README): dedup only
//! at `/`, `dev/`, `mnt/` (other unions keep R-9P-03, UD-17/18); host device
//! nodes, fifos and sockets are listed and stat-able, open ⇒ "not supported"
//! (UD-19..23; device I/O is #76); collisions list snarf's record (UD-03);
//! no nested union, `/dev/draw` stays snarf-only (UD-25, out of scope); a new
//! file in a shadowed folder is created on the host (UD-24); "snarf first"
//! is the raw stream only, windows keep dircmp order (UD-02/04).
//!
//! The host mount point is ONE parameter, `host_mtpt` below. The ruling is
//! interim pending Larry's `/` vs `/n/local` call (#11 Q1). With
//! `host_mtpt = "/n/local"` nothing of snarf's shadows a host directory, so
//! the shadowing cases skip (see `shadowing()`) and the guards still run.
//!
//! EXPECTED-FAIL MECHANISM (as restoremouse_test.zig): a case of unlanded
//! behaviour returns `error.SkipZigTest` while `union_dir_landed` is false and
//! FAILS with `error.UnexpectedPassFlipFlag` once it holds — flip the flag in
//! the PR that lands #60. Guards (behaviour that already holds and must keep
//! holding) run unconditionally.
//!
//! HARNESS: a `std.testing.tmpDir` plays the host root, served by the REAL
//! `hostfs.HostTree`, mounted at `host_mtpt` (+ the `/mnt/host` alias, as
//! `main_native.zig:296-297`). Snarf's devices are MemTrees at `/dev`
//! (`mouse`, `kbd`) and `/dev/draw` (`new`), mounted in `ns_boot` order.
//! Raw listings go through `nsdir.DirReader`; windows through the editor's
//! async `ListDirJob`/`WalkJob` path (R-P13a-2: the two must agree).
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const draw = @import("draw");
const ninep = @import("ninep");
const hostfs = @import("hostfs");
const ns_boot = @import("ns_boot.zig");

const testing = std.testing;
const Io = std.Io;
const Stat = ninep.stat;

/// Where the host file system is mounted. The ONE knob for `/` vs `/n/local`.
const host_mtpt = "/";

/// Flip to true in the PR that lands #60.
const union_dir_landed = false;

/// The union cases only exist while the host is mounted at `/`.
fn shadowing() bool {
    return std.mem.eql(u8, host_mtpt, "/");
}

fn flagged(ok: bool, comptime what: []const u8) !void {
    if (union_dir_landed) {
        if (!ok) std.debug.print("union_dir_test: {s}\n", .{what});
        return testing.expect(ok);
    }
    if (ok) {
        std.debug.print("union_dir_test: '{s}' now holds; set union_dir_landed = true\n", .{what});
        return error.UnexpectedPassFlipFlag;
    }
    return error.SkipZigTest;
}

fn isRoot() bool {
    if (builtin.os.tag == .linux) return std.os.linux.geteuid() == 0;
    return std.c.geteuid() == 0;
}

fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// One listing record, owned.
const Rec = struct { name: []u8, mode: u32, length: u64, qpath: u64 };

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
    drawdev: *core.MemTree.Harness,
    dev: *core.MemTree.Harness,
    tree: core.boot.Tree,
    ed: core.Editor,
    self: ns_boot.SelfTree,
    col: *core.Column,

    /// `seed` runs on the host tmp root before anything is mounted.
    fn create(seed: *const fn (d: Io.Dir) anyerror!void) !*Rig {
        return createAt(seed, null);
    }

    /// `root` overrides the host root (a real directory such as `/dev`,
    /// opened read-only by the tests); the tmp dir still exists for `seed`.
    fn createAt(seed: *const fn (d: Io.Dir) anyerror!void, root: ?[]const u8) !*Rig {
        const a = testing.allocator;
        const r = try a.create(Rig);
        errdefer a.destroy(r);
        r.a = a;
        r.tmp = testing.tmpDir(.{ .iterate = true });
        try seed(r.tmp.dir);
        const path = try r.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        defer a.free(path);
        r.host = try hostfs.HostFs.open(testing.io, root orelse path);
        r.fs = hostfs.HostTree.init(a, &r.host);
        r.pipe = try ninep.chan.Pipe.init(a, 65536);
        r.srv = try ninep.server.Server.init(a, r.pipe.serverEnd(), &hostfs.HostTree.ops, &r.fs, 8192);
        r.cl = try ninep.Client.init(a, r.pipe.clientEnd(), 8192);
        r.cl.pump = .{ .ctx = &r.srv, .run = pumpServer };
        _ = try r.cl.version(8192);
        r.fs_root = (try r.cl.attach("larry", "")).fid;
        r.fx = try draw.Frame.TestFixture.init();
        r.ns = ninep.mount.Namespace.init(a);
        // ns_boot.mountDevices order, then the host (main_native.zig:296-297).
        r.drawdev = try core.MemTree.Harness.create(a, &r.ns, "/dev/draw");
        try r.drawdev.tree.put("new", "draw-new\n");
        r.dev = try core.MemTree.Harness.create(a, &r.ns, "/dev");
        try r.dev.tree.put("mouse", "snarf-mouse\n");
        try r.dev.tree.put("kbd", "snarf-kbd\n");
        try r.ns.mount(host_mtpt, &r.cl, r.fs_root);
        try r.ns.mount("/mnt/host", &r.cl, r.fs_root);
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
        r.drawdev.destroy(r.a);
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

    fn tick(r: *Rig) !void {
        try r.ed.frameEnd(r.fx.disp);
        _ = try r.srv.poll();
        try r.self.poll();
        try r.dev.poll();
        try r.drawdev.poll();
    }

    fn settle(r: *Rig) !void {
        var i: usize = 0;
        while (r.ed.loads.items.len != 0 or r.ed.puts.items.len != 0) : (i += 1) {
            if (i >= 20000) return error.JobsNeverFinished;
            try r.tick();
        }
        for (0..4) |_| try r.tick();
    }

    /// The raw union stream at `path`, read through a `bufsz`-byte buffer.
    fn list(r: *Rig, path: []const u8, bufsz: usize) ![]Rec {
        var out: std.ArrayList(Rec) = .empty;
        errdefer freeRecs(r.a, out.items);
        errdefer out.deinit(r.a);
        var dr = try ninep.nsdir.DirReader.open(r.a, &r.ns, path);
        defer dr.close();
        const buf = try r.a.alloc(u8, bufsz);
        defer r.a.free(buf);
        var off: u64 = 0;
        while (true) {
            const n = try dr.read(off, buf);
            if (n == 0) break;
            off += n;
            var i: usize = 0;
            while (i < n) {
                const st = try Stat.decode(buf[i..n]);
                try out.append(r.a, .{ .name = try r.a.dupe(u8, st.name), .mode = st.mode, .length = st.length, .qpath = st.qid.path });
                i += st.encodedSize();
            }
        }
        return out.toOwnedSlice(r.a);
    }

    fn openWin(r: *Rig, path: []const u8) !*core.Window {
        const w = try core.openfile.readFile(&r.ed, r.col, path);
        try r.settle();
        return w;
    }

    fn body(r: *Rig, w: *core.Window) ![]u8 {
        var aw: Io.Writer.Allocating = .init(r.a);
        defer aw.deinit();
        try w.body.file.buffer.writeRaw(&aw.writer);
        return aw.toOwnedSlice();
    }

    fn bodiesContain(r: *Rig, needle: []const u8) !bool {
        for (r.tree.row.col.items) |c| for (c.w.items) |w| {
            const b = try r.body(w);
            defer r.a.free(b);
            if (std.mem.indexOf(u8, b, needle) != null) return true;
        };
        return false;
    }

    fn run(r: *Rig, t: *core.Text, word: []const u8) !void {
        const n = t.file.buffer.len();
        var sp = [_]u8{' '};
        try t.insertAt(n, &sp, true);
        try t.insertAt(n + 1, word, true);
        try core.exec.execute(&r.ed, t, n + 1, n + 1 + word.len, null);
        try t.deleteRange(n, n + 1 + word.len, true);
    }

    fn disk(r: *Rig, rel: []const u8) ![]u8 {
        return r.tmp.dir.readFileAlloc(testing.io, rel, r.a, .limited(1 << 20));
    }
};

fn freeRecs(a: std.mem.Allocator, recs: []Rec) void {
    for (recs) |x| a.free(x.name);
}

fn freeList(a: std.mem.Allocator, recs: []Rec) void {
    freeRecs(a, recs);
    a.free(recs);
}

fn count(recs: []const Rec, name: []const u8) usize {
    var n: usize = 0;
    for (recs) |x| if (std.mem.eql(u8, x.name, name)) {
        n += 1;
    };
    return n;
}

fn index(recs: []const Rec, name: []const u8) ?usize {
    for (recs, 0..) |x, i| if (std.mem.eql(u8, x.name, name)) return i;
    return null;
}

fn noDuplicates(recs: []const Rec) bool {
    for (recs, 0..) |x, i| for (recs[i + 1 ..]) |y| {
        if (std.mem.eql(u8, x.name, y.name)) return false;
    };
    return true;
}

/// The names in a directory window's body (whitespace-separated, as dirwin
/// columnates them), each once?
fn bodyNamesOnce(b: []const u8, names: []const []const u8) bool {
    for (names) |want| {
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, b, " \t\n");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, want)) n += 1;
        }
        if (n != 1) return false;
    }
    return true;
}

fn mk(d: Io.Dir, rel: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel)) |p| try d.createDirPath(testing.io, p);
    try d.writeFile(testing.io, .{ .sub_path = rel, .data = data });
}

/// A host root with its own `dev/` and `mnt/`, as every real machine has.
fn seedStd(d: Io.Dir) anyerror!void {
    try mk(d, "etc/hosts", "h\n");
    try mk(d, "dev/hostonly.txt", "host-only\n");
    try mk(d, "dev/kbd", "HOST-kbd\n"); // collides with snarf's /dev/kbd
    try mk(d, "dev/shm/deep.txt", "deep\n");
    try mk(d, "mnt/usb/readme", "usb\n");
    try mk(d, "mnt/host/shadowed", "host's own /mnt/host\n"); // collides with the alias
}

// ===========================================================================
// UD-01..04 — the `/` listing
// ===========================================================================

test "union UD-01: `/` lists every name exactly once (dev, mnt not doubled)" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const l = try r.list("/", 8192);
    defer freeList(r.a, l);
    // Guard: everything is there at least once.
    for ([_][]const u8{ "dev", "mnt", "etc" }) |n| try testing.expect(count(l, n) >= 1);
    try flagged(noDuplicates(l), "UD-01 / has no duplicate names");
}

test "union UD-02: `/` stream order — snarf's (synthetic) entries first, then the host's" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const l = try r.list("/", 8192);
    defer freeList(r.a, l);
    // Guard (R-9P-16, S-02 §1.2): synthetic children lead the stream today.
    try testing.expect(l.len >= 3);
    try testing.expectEqualStrings("dev", l[0].name);
    try testing.expectEqualStrings("mnt", l[1].name);
    // Landed: the host's own dev/ and mnt/ do not follow later in the stream.
    try flagged(count(l, "dev") == 1 and count(l, "mnt") == 1 and index(l, "etc") == @as(?usize, 2), "UD-02 host entries follow, minus the shadowed names");
}

test "union UD-03: on a collision the KEPT record is snarf's (synthetic DMDIR|0555, high-bit qid)" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const l = try r.list("/", 8192);
    defer freeList(r.a, l);
    var ok = count(l, "dev") == 1;
    for (l) |x| if (std.mem.eql(u8, x.name, "dev")) {
        ok = ok and x.mode == (Stat.DMDIR | 0o555) and x.qpath == ninep.nsdir.syntheticQidPath("/dev");
    };
    try flagged(ok, "UD-03 the one dev record is the synthetic one");
}

test "union UD-04: the `/` directory window shows each name once (dircmp order)" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const w = try r.openWin("/");
    try testing.expect(w.isdir);
    const b = try r.body(w);
    defer r.a.free(b);
    try flagged(bodyNamesOnce(b, &.{ "dev/", "mnt/", "etc/" }), "UD-04 / window lists dev/ mnt/ etc/ once each");
}

// ===========================================================================
// UD-05..09 — shadowed directories: /dev, /dev/draw, /mnt
// ===========================================================================

test "union UD-05: `/dev` lists snarf's entries first, then the host-only ones, each once" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const l = try r.list("/dev", 8192);
    defer freeList(r.a, l);
    // Guard: snarf's own entries, synthetic `draw` first (T13), then the device.
    try testing.expectEqualStrings("draw", l[0].name);
    try testing.expect(index(l, "mouse") != null and index(l, "kbd") != null);
    const hi = index(l, "hostonly.txt");
    const sh = index(l, "shm");
    const ok = hi != null and sh != null and noDuplicates(l) and
        hi.? > index(l, "kbd").? and hi.? > index(l, "mouse").? and sh.? > index(l, "kbd").?;
    try flagged(ok, "UD-05 /dev = draw, mouse, kbd, then hostonly.txt, shm — once each");
}

test "union UD-06: the `/dev` window lists the union once each" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const w = try r.openWin("/dev");
    const b = try r.body(w);
    defer r.a.free(b);
    try flagged(bodyNamesOnce(b, &.{ "draw/", "mouse", "kbd", "hostonly.txt", "shm/" }), "UD-06 /dev window");
}

test "union UD-07: B3 on host-only entries under `/dev` opens the host's file (walk falls through)" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    var ok = if (ninep.nsdir.walk(&r.ns, "/dev/shm/deep.txt")) |h| blk: {
        ninep.nsdir.close(&r.ns, h);
        break :blk true;
    } else |_| false;
    const w = try r.openWin("/dev/hostonly.txt");
    const b = try r.body(w);
    defer r.a.free(b);
    ok = ok and std.mem.eql(u8, b, "host-only\n");
    try flagged(ok, "UD-07 /dev/hostonly.txt and /dev/shm/deep.txt reachable");
}

test "union UD-08 (guard): a name in both — snarf wins the walk; the host's copy is shadowed" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const h = try ninep.nsdir.walk(&r.ns, "/dev/kbd");
    defer ninep.nsdir.close(&r.ns, h);
    try testing.expectEqual(&r.dev.client, h.fid.client);
    const w = try r.openWin("/dev/kbd");
    const b = try r.body(w);
    defer r.a.free(b);
    try testing.expectEqualStrings("snarf-kbd\n", b);
    // (Not /dev/mouse: the #45 warp writes `m x y` into it.)
    // The host's copy stays reachable through the alias.
    const w2 = try r.openWin("/mnt/host/dev/kbd");
    const b2 = try r.body(w2);
    defer r.a.free(b2);
    try testing.expectEqualStrings("HOST-kbd\n", b2);
}

test "union UD-09: `/mnt` lists host/ snarf-self/ then the host's /mnt entries, each once" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const l = try r.list("/mnt", 8192);
    defer freeList(r.a, l);
    // Guard: the synthetic children lead, the host's usb/ is listed and walkable.
    try testing.expect(index(l, "snarf-self") != null and index(l, "host") != null);
    try testing.expect(index(l, "usb") != null);
    const h = try ninep.nsdir.walk(&r.ns, "/mnt/usb/readme");
    ninep.nsdir.close(&r.ns, h);
    // The host's own mnt/host is shadowed by the alias, and listed once.
    try flagged(noDuplicates(l), "UD-09 /mnt lists host once");
}

test "union UD-10 (guard): the /mnt/host alias is the plain host tree — no snarf entries mixed in" {
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const l = try r.list("/mnt/host/dev", 8192);
    defer freeList(r.a, l);
    try testing.expect(index(l, "draw") == null and index(l, "mouse") == null);
    try testing.expectEqual(@as(usize, 1), count(l, "kbd"));
    try testing.expectEqual(@as(usize, 1), count(l, "hostonly.txt"));
}

// ===========================================================================
// UD-11..13 — synthetic dirs, stat, writes
// ===========================================================================

test "union UD-11 (guard): with no host /mnt, `/mnt` is synthetic DMDIR|0555 with a stable qid" {
    const S = struct {
        fn seed(d: Io.Dir) anyerror!void {
            try mk(d, "etc/hosts", "h\n");
        }
    };
    const r = try Rig.create(S.seed);
    defer r.destroy();
    const h = try ninep.nsdir.walk(&r.ns, "/mnt");
    defer ninep.nsdir.close(&r.ns, h);
    try testing.expect(h == .dir);
    try testing.expectEqual(ninep.nsdir.syntheticQidPath("/mnt"), h.dir.qid.path);
    const l = try r.list("/mnt", 8192);
    defer freeList(r.a, l);
    try testing.expectEqual(@as(usize, 2), l.len);
    for (l) |x| try testing.expectEqual(Stat.DMDIR | 0o555, x.mode);
}

test "union UD-12: a host-only entry's listing record and stat carry the HOST's mode and length" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    try r.tmp.dir.setFilePermissions(testing.io, "dev/hostonly.txt", .fromMode(0o640), .{});
    const l = try r.list("/dev", 8192);
    defer freeList(r.a, l);
    var ok = false;
    for (l) |x| if (std.mem.eql(u8, x.name, "hostonly.txt")) {
        ok = (x.mode & 0o777) == 0o640 and x.length == "host-only\n".len and x.qpath & hostfs.HostFs.qid_tag != 0;
    };
    try flagged(ok, "UD-12 /dev/hostonly.txt record = host stat");
}

test "union UD-13: Put to an existing host-only file under /dev writes the host disk" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const w = try r.openWin("/dev/hostonly.txt");
    r.ed.seq += 1;
    w.body.file.mark(r.ed.seq);
    try w.body.insertAt(0, "X", true);
    try r.tick();
    try r.run(&w.tag, "Put");
    try r.settle();
    const d = try r.disk("dev/hostonly.txt");
    defer r.a.free(d);
    try flagged(std.mem.eql(u8, d, "Xhost-only\n"), "UD-13 Put through the union reaches the host");
}

// ===========================================================================
// UD-14..17 — symlinks (#28), large dirs, unreadable entries
// ===========================================================================

test "union UD-14: local symlinks under a shadowed dir are followed (#28 trusted-local)" {
    if (!shadowing()) return error.SkipZigTest;
    const S = struct {
        fn seed(d: Io.Dir) anyerror!void {
            try seedStd(d);
            try mk(d, "target.txt", "via link\n");
            try d.symLink(testing.io, "../target.txt", "dev/link.txt", .{});
            try d.symLink(testing.io, "shm", "dev/shmlink", .{});
            try d.symLink(testing.io, "/nonexistent-ud14", "dev/dangling", .{});
        }
    };
    const r = try Rig.create(S.seed);
    defer r.destroy();
    const l = try r.list("/dev", 8192);
    defer freeList(r.a, l);
    // A dangling link is invisible either way (HostFs stats through links).
    try testing.expect(index(l, "dangling") == null);
    var ok = index(l, "link.txt") != null and index(l, "shmlink") != null;
    if (ok) {
        const w = try r.openWin("/dev/link.txt");
        const b = try r.body(w);
        defer r.a.free(b);
        ok = std.mem.eql(u8, b, "via link\n");
    }
    try flagged(ok, "UD-14 /dev/link.txt listed and opens its target");
}

test "union UD-15: a 3000-entry shadowed dir lists every name once, across small reads" {
    if (!shadowing()) return error.SkipZigTest;
    const S = struct {
        fn seed(d: Io.Dir) anyerror!void {
            try d.createDirPath(testing.io, "dev");
            var name: [32]u8 = undefined;
            for (0..3000) |i| {
                const n = try std.fmt.bufPrint(&name, "dev/tty{d:0>5}", .{i});
                try d.writeFile(testing.io, .{ .sub_path = n, .data = "" });
            }
            try mk(d, "dev/kbd", "HOST-kbd\n"); // a collision somewhere in the stream
        }
    };
    const r = try Rig.create(S.seed);
    defer r.destroy();
    const t0 = Io.Timestamp.now(testing.io, .awake);
    // 200-byte buffer: many reads, collisions land after the first 8 KiB chunk.
    const small = try r.list("/dev", 200);
    defer freeList(r.a, small);
    const big = try r.list("/dev", 65536);
    defer freeList(r.a, big);
    const ms = t0.untilNow(testing.io, .awake).toMilliseconds();
    // Guard: the two read sizes agree on the stream (T12) and it is not slow.
    try testing.expectEqual(big.len, small.len);
    for (big, small) |x, y| try testing.expectEqualStrings(x.name, y.name);
    try testing.expect(ms < 10_000);
    var ttys: usize = 0;
    for (small) |x| if (std.mem.startsWith(u8, x.name, "tty")) {
        ttys += 1;
    };
    try flagged(ttys == 3000 and count(small, "kbd") == 1 and noDuplicates(small), "UD-15 3000 host entries once, kbd once");
}

test "union UD-16: unreadable host entries — an unreadable shadowed dir drops out, an unreadable child is listed and fails cleanly" {
    if (!shadowing() or isRoot()) return error.SkipZigTest;
    const S = struct {
        fn seed(d: Io.Dir) anyerror!void {
            try seedStd(d);
            try mk(d, "dev/secret/x", "x\n");
            try d.setFilePermissions(testing.io, "dev/secret", .fromMode(0o000), .{});
        }
    };
    const r = try Rig.create(S.seed);
    defer r.destroy();
    defer r.tmp.dir.setFilePermissions(testing.io, "dev/secret", .fromMode(0o755), .{}) catch {};
    defer r.tmp.dir.setFilePermissions(testing.io, "dev", .fromMode(0o755), .{}) catch {};
    // B3 on the unreadable child: a warning, no crash, no half-window.
    _ = try r.openWin("/dev/secret");
    const warned = try r.bodiesContain("/dev/secret");
    const l = try r.list("/dev", 8192);
    defer freeList(r.a, l);
    const listed = count(l, "secret") == 1;
    // The whole host /dev unreadable: snarf's entries only, no error (sysfile.c:340).
    try r.tmp.dir.setFilePermissions(testing.io, "dev", .fromMode(0o000), .{});
    const l2 = try r.list("/dev", 8192);
    defer freeList(r.a, l2);
    try testing.expect(index(l2, "mouse") != null and index(l2, "draw") != null);
    try flagged(listed and warned, "UD-16 /dev/secret listed once; B3 on it warns");
}

// ===========================================================================
// UD-17/18 — scope (PM ruling 2026-11-02 #1): dedup only at `/`, `dev/`,
// `mnt/`; every other union keeps R-9P-03 (duplicates listed)
// ===========================================================================

test "union UD-17 (guard): browser shape (no host) — `/` is synthetic and the /bin union keeps R-9P-03 duplicates (ruling #1)" {
    const a = testing.allocator;
    const FakeTree = ninep.nsdir.FakeTree;
    var t1 = FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var t2 = FakeTree{ .names = &.{"rc"}, .tag = "two\n" };
    var s1 = try ninep.nsdir.FakeServer.init(a, &t1);
    defer s1.deinit();
    var s2 = try ninep.nsdir.FakeServer.init(a, &t2);
    defer s2.deinit();
    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();
    // The browser boot namespace shape (S-02 §1.3, origin up).
    try ns.mount("/dev", s1.client, s1.root_fid);
    try ns.mount("/mnt/snarf-self", s1.client, s1.root_fid);
    try ns.mount("/n/origin", s2.client, s2.root_fid);
    try ns.bind("/bin", s1.client, s1.root_fid, .after);
    try ns.bind("/bin", s2.client, s2.root_fid, .after);
    var buf: [1024]u8 = undefined;
    var dr = try ninep.nsdir.DirReader.open(a, &ns, "/");
    defer dr.close();
    const n = try dr.read(0, &buf);
    var i: usize = 0;
    var names: [8][]const u8 = undefined;
    var k: usize = 0;
    while (i < n) : (k += 1) {
        const st = try Stat.decode(buf[i..n]);
        names[k] = st.name;
        i += st.encodedSize();
    }
    try testing.expectEqual(@as(usize, 4), k); // dev mnt n bin, once each
    var db = try ninep.nsdir.DirReader.open(a, &ns, "/bin");
    defer db.close();
    const bn = try db.read(0, &buf);
    const first = try Stat.decode(buf[0..bn]);
    const second = try Stat.decode(buf[first.encodedSize()..bn]);
    try testing.expectEqualStrings("rc", first.name);
    try testing.expectEqualStrings("rc", second.name); // R-9P-03: still listed twice
}

test "union UD-18 (guard): host at `/` — a union outside `/`, `dev/`, `mnt/` (here /bin) still lists duplicates (ruling #1, R-9P-03)" {
    if (!shadowing()) return error.SkipZigTest;
    const a = testing.allocator;
    const FakeTree = ninep.nsdir.FakeTree;
    var t1 = FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var t2 = FakeTree{ .names = &.{"rc"}, .tag = "two\n" };
    var s1 = try ninep.nsdir.FakeServer.init(a, &t1);
    defer s1.deinit();
    var s2 = try ninep.nsdir.FakeServer.init(a, &t2);
    defer s2.deinit();
    const r = try Rig.create(seedStd);
    defer r.destroy();
    try r.ns.bind("/bin", s1.client, s1.root_fid, .after);
    try r.ns.bind("/bin", s2.client, s2.root_fid, .after);
    const l = try r.list("/bin", 8192);
    defer freeList(r.a, l);
    try testing.expectEqual(@as(usize, 2), count(l, "rc"));
}

// ===========================================================================
// UD-19..23 — host device nodes, fifos, sockets (PM ruling 2026-11-02 #2):
// listed, stat-able, open ⇒ a clear "not supported" error. Device I/O is a
// later feature (#76).
// ===========================================================================

const Special = enum { fifo, sock, chr };

/// Make a fifo / unix socket / char device (1,3) at `rel` under the rig's
/// host tmp root. `error.SkipZigTest` where the platform or path can't.
fn mkSpecial(r: *Rig, rel: []const u8, kind: Special) !void {
    const root = try r.tmp.dir.realPathFileAlloc(testing.io, ".", r.a);
    defer r.a.free(root);
    const abs = try std.fmt.allocPrintSentinel(r.a, "{s}/{s}", .{ root, rel }, 0);
    defer r.a.free(abs);
    switch (builtin.os.tag) {
        .linux => {
            const L = std.os.linux;
            switch (kind) {
                .fifo => if (L.errno(L.mknodat(L.AT.FDCWD, abs, L.S.IFIFO | 0o644, 0)) != .SUCCESS) return error.SkipZigTest,
                .chr => if (L.errno(L.mknodat(L.AT.FDCWD, abs, L.S.IFCHR | 0o666, (1 << 8) | 3)) != .SUCCESS) return error.SkipZigTest,
                .sock => {
                    var sa = L.sockaddr.un{ .path = @splat(0) };
                    if (abs.len >= sa.path.len) return error.SkipZigTest;
                    @memcpy(sa.path[0..abs.len], abs);
                    const fd = L.socket(L.AF.UNIX, L.SOCK.STREAM, 0);
                    if (L.errno(fd) != .SUCCESS) return error.SkipZigTest;
                    defer _ = L.close(@intCast(fd));
                    if (L.errno(L.bind(@intCast(fd), @ptrCast(&sa), @sizeOf(L.sockaddr.un))) != .SUCCESS) return error.SkipZigTest;
                },
            }
        },
        .macos => {
            const C = struct {
                extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
                extern "c" fn mknod(path: [*:0]const u8, mode: std.c.mode_t, dev: i32) c_int;
                extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
            };
            switch (kind) {
                .fifo => if (C.mkfifo(abs, 0o644) != 0) return error.SkipZigTest,
                .chr => if (C.mknod(abs, std.c.S.IFCHR | 0o666, (3 << 24) | 2) != 0) return error.SkipZigTest,
                .sock => {
                    var sa = std.c.sockaddr.un{ .path = @splat(0) };
                    if (abs.len >= sa.path.len) return error.SkipZigTest;
                    @memcpy(sa.path[0..abs.len], abs);
                    const fd = C.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
                    if (fd < 0) return error.SkipZigTest;
                    defer _ = std.c.close(fd);
                    if (std.c.bind(fd, @ptrCast(&sa), @sizeOf(std.c.sockaddr.un)) != 0) return error.SkipZigTest;
                },
            }
        },
        else => return error.SkipZigTest,
    }
}

/// Raw 9P open (OREAD) of `path` through the namespace: true iff it FAILS and
/// the server's error string says "not supported" (case-insensitive).
fn openNotSupported(r: *Rig, path: []const u8) !bool {
    const h = ninep.nsdir.walk(&r.ns, path) catch return false; // not even walkable
    defer ninep.nsdir.close(&r.ns, h);
    const f = switch (h) {
        .fid => |f| f,
        .dir => return false,
    };
    _ = f.client.open(f.fid, 0) catch {
        return std.ascii.indexOfIgnoreCase(f.client.lastErrorString(), "not supported") != null;
    };
    return false;
}

/// Walk + Tstat succeed, the name matches and it is not a directory.
fn statsAsFile(r: *Rig, path: []const u8) bool {
    const h = ninep.nsdir.walk(&r.ns, path) catch return false;
    defer ninep.nsdir.close(&r.ns, h);
    const f = switch (h) {
        .fid => |f| f,
        .dir => return false,
    };
    const st = f.client.stat(f.fid) catch return false;
    return std.mem.eql(u8, st.name, std.fs.path.basename(path)) and st.mode & Stat.DMDIR == 0;
}

/// Hold the fifo open read-write so a (buggy) blocking open of it by the
/// server cannot hang the suite.
fn holdFifo(r: *Rig, rel: []const u8) !?std.posix.fd_t {
    const root = try r.tmp.dir.realPathFileAlloc(testing.io, ".", r.a);
    defer r.a.free(root);
    const abs = try std.fmt.allocPrintSentinel(r.a, "{s}/{s}", .{ root, rel }, 0);
    defer r.a.free(abs);
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.open(abs, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
            if (std.os.linux.errno(rc) != .SUCCESS) return null;
            return @intCast(rc);
        },
        .macos => {
            const fd = std.c.open(abs, .{ .ACCMODE = .RDWR, .NONBLOCK = true });
            return if (fd < 0) null else fd;
        },
        else => return null,
    }
}

fn unhold(fd: ?std.posix.fd_t) void {
    const f = fd orelse return;
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.close(f),
        .macos => _ = std.c.close(f),
        else => {},
    }
}

test "union UD-19: host fifos and unix sockets are LISTED, in the host tree and in the /dev union (ruling #2)" {
    const r = try Rig.create(seedStd);
    defer r.destroy();
    try mkSpecial(r, "dev/pipe", .fifo);
    try mkSpecial(r, "dev/sock", .sock);
    const l = try r.list("/mnt/host/dev", 8192);
    defer freeList(r.a, l);
    // Guard: regular entries still list beside them.
    try testing.expect(index(l, "hostonly.txt") != null);
    var ok = count(l, "pipe") == 1 and count(l, "sock") == 1;
    for (l) |x| if (std.mem.eql(u8, x.name, "pipe") or std.mem.eql(u8, x.name, "sock")) {
        ok = ok and x.mode & Stat.DMDIR == 0;
    };
    if (shadowing()) {
        const u = try r.list("/dev", 8192);
        defer freeList(r.a, u);
        ok = ok and count(u, "pipe") == 1 and count(u, "sock") == 1;
    }
    try flagged(ok, "UD-19 fifo + socket listed once");
}

test "union UD-20: stat (walk + Tstat) works on a host fifo and unix socket (ruling #2)" {
    const r = try Rig.create(seedStd);
    defer r.destroy();
    try mkSpecial(r, "dev/pipe", .fifo);
    try mkSpecial(r, "dev/sock", .sock);
    var ok = statsAsFile(r, "/mnt/host/dev/pipe") and statsAsFile(r, "/mnt/host/dev/sock");
    if (shadowing()) ok = ok and statsAsFile(r, "/dev/pipe") and statsAsFile(r, "/dev/sock");
    try flagged(ok, "UD-20 stat of fifo + socket");
}

test "union UD-21: opening a host fifo or socket fails with a clear \"not supported\" error — 9P and B3 (ruling #2)" {
    const r = try Rig.create(seedStd);
    defer r.destroy();
    try mkSpecial(r, "dev/pipe", .fifo);
    try mkSpecial(r, "dev/sock", .sock);
    const held = try holdFifo(r, "dev/pipe");
    defer unhold(held);
    var ok = try openNotSupported(r, "/mnt/host/dev/sock");
    ok = ok and try openNotSupported(r, "/mnt/host/dev/pipe");
    const p = if (shadowing()) "/dev/sock" else "/mnt/host/dev/sock";
    _ = try r.openWin(p);
    ok = ok and (try r.bodiesContain("not supported") or try r.bodiesContain("Not supported"));
    try flagged(ok, "UD-21 open of fifo/socket = not supported");
}

test "union UD-22: a host char device (mknod 1,3) is listed, stats, and refuses open (ruling #2; needs root)" {
    if (!isRoot()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    try mkSpecial(r, "dev/null", .chr);
    const l = try r.list("/mnt/host/dev", 8192);
    defer freeList(r.a, l);
    const ok = count(l, "null") == 1 and statsAsFile(r, "/mnt/host/dev/null") and try openNotSupported(r, "/mnt/host/dev/null");
    try flagged(ok, "UD-22 char device listed/stat/not supported");
}

test "union UD-23: the REAL host /dev — `null` is listed, stats, and refuses open (ruling #2; no root, read-only)" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const S = struct {
        fn none(_: Io.Dir) anyerror!void {}
    };
    const r = try Rig.createAt(S.none, "/dev");
    defer r.destroy();
    const l = try r.list("/mnt/host", 65536);
    defer freeList(r.a, l);
    const ok = count(l, "null") == 1 and statsAsFile(r, "/mnt/host/null") and try openNotSupported(r, "/mnt/host/null");
    try flagged(ok, "UD-23 real /dev/null listed/stat/not supported");
}

// ===========================================================================
// UD-24 — create in a shadowed folder goes to the host (ruling #5, Plan 9
// MCREATE). UD-25 — no nested union (ruling #4, out of scope).
// ===========================================================================

test "union UD-24: Put of a NEW file in a shadowed folder (/dev/new.txt) creates it on the host (ruling #5)" {
    if (!shadowing()) return error.SkipZigTest;
    const r = try Rig.create(seedStd);
    defer r.destroy();
    const w = try r.openWin("/dev/hostonly.txt");
    try core.wintag.setName(w, "/dev/new.txt");
    r.ed.seq += 1;
    w.body.file.mark(r.ed.seq);
    try w.body.insertAt(0, "fresh ", true);
    try r.tick();
    try r.run(&w.tag, "Put");
    try r.settle();
    const d = r.disk("dev/new.txt") catch "";
    defer if (d.len != 0) r.a.free(d);
    // Guard: the source file is untouched whatever happens.
    const src = try r.disk("dev/hostonly.txt");
    defer r.a.free(src);
    try testing.expectEqualStrings("host-only\n", src);
    try flagged(std.mem.eql(u8, d, "fresh host-only\n") and !w.dirty, "UD-24 /dev/new.txt created on the host");
}

test "union UD-25 (guard): no nested union — /dev/draw stays snarf-only; the host's dev/draw is only at /mnt/host (ruling #4, out of scope)" {
    if (!shadowing()) return error.SkipZigTest;
    const S = struct {
        fn seed(d: Io.Dir) anyerror!void {
            try seedStd(d);
            try mk(d, "dev/draw/hostdraw.txt", "host draw\n");
        }
    };
    const r = try Rig.create(S.seed);
    defer r.destroy();
    const l = try r.list("/dev/draw", 8192);
    defer freeList(r.a, l);
    try testing.expectEqual(@as(usize, 1), l.len);
    try testing.expectEqualStrings("new", l[0].name);
    try testing.expectError(error.NotFound, ninep.nsdir.walk(&r.ns, "/dev/draw/hostdraw.txt"));
    const h = try ninep.nsdir.walk(&r.ns, "/mnt/host/dev/draw/hostdraw.txt");
    ninep.nsdir.close(&r.ns, h);
}
