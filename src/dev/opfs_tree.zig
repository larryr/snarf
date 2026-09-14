//! opfs_tree — the NAMING half of `/mnt/opfs`: paths, qids, stat records and
//! the status→Rerror mapping. `opfs.zig` owns the 9P behaviour and the browser
//! round trips; everything that is pure arithmetic over a path lives here
//! (S-07 §2 size seam).
//!
//! THE QID RULE (draft R-P13-7, carried into R-P14b): the Origin Private File
//! System exposes no inode, so `qid.path` is the FNV-1a 64 hash of the file's
//! ABSOLUTE path inside the OPFS root. That makes qids stable per NAME, not per
//! identity: remove a file and create another with the same name and the qid is
//! unchanged. Documented caveat, accepted — nothing in the editor depends on
//! qid identity across a delete, and the alternative (a synthetic inode table
//! that must survive reloads) buys nothing a browser-local store can keep.
//!
//! A consequence we exploit everywhere: because the qid IS the path's hash, a
//! fid needs no per-fid heap node at all (the `tools/origin/tree.zig` pattern).
//! `PathTable` interns every path the device has ever named, and `fid.qid.path`
//! is the key back to it, so a tentative walk fid owns no path memory. It does
//! own SLOTS (`opfs_slots.zig` keys on `fid.fid`), which is why the framework
//! announces a discarded tentative newfid through `Ops.clunk` since phase 16b
//! [lib9p/srv.c:338 rwalk → fid.c:64 closefid].
//!
//! Imports: std + `ninep` + `shim` (S-07 §6 — the `dev` layer's whole budget).
const std = @import("std");
const ninep = @import("ninep");
const shim = @import("shim");

const FsRecord = shim.abi.FsRecord;
const Qid = ninep.Qid;
const Stat = ninep.stat;
const OpError = ninep.errors.OpError;

/// Owner reported for every file in the tree (draft R-P13-7). OPFS has no
/// notion of a user; this is the device's name, like `devdraw`'s.
pub const owner = "opfs";

/// The tree root, and the prefix every other path carries.
pub const root = "/";

/// File / directory modes (draft R-P13-7). OPFS stores no mode bits, so these
/// are the device's fixed answer rather than something a `create` perm or a
/// `wstat` can change.
pub const file_mode: u32 = 0o644;
pub const dir_mode: u32 = Stat.DMDIR | 0o755;

/// Longest absolute path the device will name. The wire allows 65535 (the
/// record's `pathlen[2]`), but a path buffer that big would sit in the boot
/// context forever; 1 KiB is past anything a browser-local store grows and is
/// the same order as Plan 9's own limit.
pub const max_path: usize = 1024;

/// FNV-1a 64 over the absolute path — the qid. [ref: the standard FNV-1a
/// parameters; std has no 64-bit FNV-1a with this spelling in 0.16]
pub fn hashPath(path: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (path) |b| {
        h ^= b;
        h *%= 0x1000_0000_01b3;
    }
    return h;
}

/// Is `name` a legal single path component (R-P14b-4)? Empty, `.`, `..` and
/// anything containing `/` are refused — `..` is handled by the caller before
/// this is reached, the rest would name something other than one child.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfScalar(u8, name, '/') == null;
}

/// `dir` + `/` + `name`, written into `buf`. Absolute, no trailing slash, so
/// `"/"` + `"a"` is `"/a"` and `"/a"` + `"b"` is `"/a/b"`. `IoError` if the
/// result would pass `max_path` — the one place a path length is refused.
pub fn joinInto(buf: []u8, dir: []const u8, name: []const u8) OpError![]const u8 {
    const sep: usize = if (std.mem.eql(u8, dir, root)) 0 else 1;
    const total = dir.len + sep + name.len;
    if (total > buf.len or total > max_path) return error.IoError;
    @memcpy(buf[0..dir.len], dir);
    if (sep == 1) buf[dir.len] = '/';
    @memcpy(buf[dir.len + sep ..][0..name.len], name);
    return buf[0..total];
}

/// The containing directory of `path`, as a sub-slice of it. The root is its
/// own parent (`5/walk`: `..` at the root is the root).
pub fn parentPath(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return root;
    if (cut == 0) return root;
    return path[0..cut];
}

/// The last component of `path`; the root reports `"/"` (the name a 9P stat of
/// a tree root conventionally carries — `tools/origin/tree.zig` does the same).
pub fn baseName(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, root)) return root;
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[cut + 1 ..];
}

/// `5/open`'s create mask, with the containing directory's permissions fixed at
/// this device's `dir_mode`: `perm & (~0666 | (dir.perm & 0666))` for a file,
/// `perm & (~0777 | (dir.perm & 0777))` for a directory. OPFS stores no mode,
/// so the result is advisory — it travels to the shim in the record's `arg1`
/// and the file still stats as `file_mode`/`dir_mode`. Computed anyway because
/// it is the protocol's rule and the shim may one day have somewhere to put it.
pub fn maskPerm(perm: u32, is_dir: bool) u32 {
    const parent = dir_mode & 0o777;
    if (is_dir) return perm & (~@as(u32, 0o777) | (parent & 0o777));
    return perm & (~@as(u32, 0o666) | (parent & 0o666));
}

/// Completion status → the Plan 9 Rerror the client sees (draft R-P13-9). The
/// strings themselves live in `ninep/errors.zig`; this is only the mapping.
pub fn statusError(s: FsRecord.Status) OpError {
    return switch (s) {
        .ok => error.IoError, // never called with ok; a bug here is an i/o error
        .not_found => error.FileDoesNotExist,
        .exists => error.FileExists,
        .not_dir => error.NotADirectory,
        .is_dir => error.FileIsDirectory,
        .permission => error.PermissionDenied,
        .quota => error.NoSpace,
        .not_empty => error.DirNotEmpty,
        .io => error.IoError,
    };
}

/// The qid for a path hash. `mtime_ms` is the browser's `File.lastModified`,
/// truncated to whole seconds for `qid.vers` (draft R-P13-7).
pub fn qidOf(path_hash: u64, is_dir: bool, mtime_ms: u64) Qid {
    return .{
        .path = path_hash,
        .vers = @truncate(mtime_ms / 1000),
        .qtype = .{ .dir = is_dir },
    };
}

/// The directory entry for one file. Directories report length 0 and mtime 0
/// (draft R-P13-7) — OPFS gives a directory handle no timestamp of its own.
pub fn statOf(name: []const u8, qid: Qid, size: u64, mtime_ms: u64) Stat {
    const is_dir = qid.qtype.dir;
    const secs: u32 = @truncate(mtime_ms / 1000);
    return .{
        .qid = qid,
        .mode = if (is_dir) dir_mode else file_mode,
        .atime = if (is_dir) 0 else secs,
        .mtime = if (is_dir) 0 else secs,
        .length = if (is_dir) 0 else size,
        .name = name,
        .uid = owner,
        .gid = owner,
        .muid = owner,
    };
}

// ---------------------------------------------------------------------------
// PathTable — qid.path → the absolute path that hashes to it
// ---------------------------------------------------------------------------

/// Every path the device has named this session. Entries are never evicted: a
/// fid may hold a qid for any of them, and the table is the only way back to
/// the string. It grows with the set of paths VISITED, not with traffic, and
/// is freed whole at `deinit`.
pub const PathTable = struct {
    map: std.AutoHashMapUnmanaged(u64, []u8) = .empty,

    pub fn deinit(self: *PathTable, a: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| a.free(e.value_ptr.*);
        self.map.deinit(a);
        self.* = undefined;
    }

    /// Intern `path` and return its qid.path. A hash collision — two distinct
    /// paths with the same FNV-1a 64 — keeps the FIRST binding, which makes the
    /// second path unreachable rather than silently aliasing the first file's
    /// contents onto it. At 2^64 the case is theoretical; it is handled so the
    /// table can never hand back the wrong string.
    pub fn intern(self: *PathTable, a: std.mem.Allocator, path: []const u8) OpError!u64 {
        const key = hashPath(path);
        const gop = self.map.getOrPut(a, key) catch return error.IoError;
        if (!gop.found_existing) {
            gop.value_ptr.* = a.dupe(u8, path) catch {
                _ = self.map.remove(key);
                return error.IoError;
            };
        } else if (!std.mem.eql(u8, gop.value_ptr.*, path)) {
            return error.FileDoesNotExist; // collision: refuse rather than alias
        }
        return key;
    }

    /// The path a qid names, or null if this qid never came from this device.
    pub fn get(self: *const PathTable, key: u64) ?[]const u8 {
        return self.map.get(key);
    }
};

// ---------------------------------------------------------------------------
// Directory listings
// ---------------------------------------------------------------------------

/// Turn one `list` completion payload into a 9P directory-read stream: the
/// entries' stat records, concatenated in the order the browser reported them.
/// Built ONCE per open fid and then served offset-addressed (`read(5)`).
///
/// Entry stats carry length 0 and mtime 0 — a `list` reply has only the name
/// and the kind, and asking the browser for a `stat` per entry would turn one
/// round trip into N. A client that wants a size walks to the entry and stats
/// it, which is what `Get` and the directory window already do.
pub fn buildListing(
    a: std.mem.Allocator,
    dir: []const u8,
    payload: []const u8,
    scratch: []u8,
) OpError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var it = FsRecord.ListIter{ .buf = payload };
    while (it.next()) |e| {
        if (!validName(e.name)) continue; // a name we could never walk to
        const child = joinInto(scratch, dir, e.name) catch continue;
        const st = statOf(e.name, qidOf(hashPath(child), e.is_dir, 0), 0, 0);
        const n = st.encodedSize();
        out.ensureUnusedCapacity(a, n) catch return error.IoError;
        const dst = out.unusedCapacitySlice()[0..n];
        _ = st.encode(dst) catch return error.IoError;
        out.items.len += n;
    }
    return out.toOwnedSlice(a) catch return error.IoError;
}

/// Serve `buf` from a built listing at `offset`. `read(5)`: a directory read
/// returns WHOLE stat records and the offset must be zero or a value a previous
/// read returned, so a misaligned continuation is a protocol error ("bad
/// message") rather than a stream of garbage.
pub fn readListing(stream: []const u8, offset: u64, buf: []u8) OpError!usize {
    if (offset > stream.len) return error.BadMessage;
    var pos: usize = 0;
    while (pos < offset) {
        const st = Stat.decode(stream[pos..]) catch return error.BadMessage;
        pos += st.encodedSize();
        if (pos > offset) return error.BadMessage; // offset fell inside a record
    }
    var n: usize = 0;
    while (pos + n < stream.len) {
        const st = Stat.decode(stream[pos + n ..]) catch return error.BadMessage;
        const sz = st.encodedSize();
        if (n + sz > buf.len) break; // never split a record
        n += sz;
    }
    @memcpy(buf[0..n], stream[pos..][0..n]);
    return n;
}

// ===========================================================================
// Tests — SMOKE ONLY (the named battery is the test author's, contract §4).
// ===========================================================================
const testing = std.testing;

test "opfs_tree: paths, names and the qid hash" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/a", try joinInto(&buf, "/", "a"));
    try testing.expectEqualStrings("/a/b", try joinInto(&buf, "/a", "b"));
    try testing.expectEqualStrings("/", parentPath("/a"));
    try testing.expectEqualStrings("/a", parentPath("/a/b"));
    try testing.expectEqualStrings("/", parentPath("/"));
    try testing.expectEqualStrings("/", baseName("/"));
    try testing.expectEqualStrings("b", baseName("/a/b"));
    try testing.expect(validName("notes.txt"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("."));
    try testing.expect(!validName(".."));
    try testing.expect(!validName("a/b"));
    try testing.expect(hashPath("/a") != hashPath("/b"));
    try testing.expectEqual(hashPath("/a/b"), hashPath("/a/b"));
    // A path past max_path is refused rather than truncated.
    var big: [max_path + 8]u8 = undefined;
    @memset(&big, 'z');
    var small: [max_path + 8]u8 = undefined;
    try testing.expectError(error.IoError, joinInto(&small, "/", &big));
}

test "opfs_tree: perm masking and status mapping" {
    // `5/open` with a 0755 parent: 0666 -> 0644, 0777 (dir) -> 0755.
    try testing.expectEqual(@as(u32, 0o644), maskPerm(0o666, false));
    try testing.expectEqual(@as(u32, 0o600), maskPerm(0o600, false));
    try testing.expectEqual(@as(u32, 0o755), maskPerm(0o777, true));
    const es = ninep.errors.errorString;
    try testing.expectEqualStrings("file does not exist", es(statusError(.not_found)));
    try testing.expectEqualStrings("file already exists", es(statusError(.exists)));
    try testing.expectEqualStrings("not a directory", es(statusError(.not_dir)));
    try testing.expectEqualStrings("file is a directory", es(statusError(.is_dir)));
    try testing.expectEqualStrings("permission denied", es(statusError(.permission)));
    try testing.expectEqualStrings("no space on device", es(statusError(.quota)));
    try testing.expectEqualStrings("directory not empty", es(statusError(.not_empty)));
    try testing.expectEqualStrings("i/o error", es(statusError(.io)));
}

test "opfs_tree: PathTable interns and round-trips" {
    var t: PathTable = .{};
    defer t.deinit(testing.allocator);
    const k = try t.intern(testing.allocator, "/a/b");
    try testing.expectEqual(k, try t.intern(testing.allocator, "/a/b")); // idempotent
    try testing.expectEqualStrings("/a/b", t.get(k).?);
    try testing.expectEqual(@as(?[]const u8, null), t.get(k ^ 1));
}

test "opfs_tree: listing build + offset-addressed read" {
    const a = testing.allocator;
    var payload: [64]u8 = undefined;
    var p: usize = 0;
    p += try (FsRecord.ListEntry{ .is_dir = true, .name = "sub" }).encode(payload[p..]);
    p += try (FsRecord.ListEntry{ .is_dir = false, .name = "f.txt" }).encode(payload[p..]);
    p += try (FsRecord.ListEntry{ .is_dir = false, .name = ".." }).encode(payload[p..]); // dropped

    var scratch: [max_path]u8 = undefined;
    const stream = try buildListing(a, "/", payload[0..p], &scratch);
    defer a.free(stream);

    var buf: [256]u8 = undefined;
    const n = try readListing(stream, 0, &buf);
    try testing.expectEqual(stream.len, n);
    const first = try Stat.decode(buf[0..n]);
    try testing.expectEqualStrings("sub", first.name);
    try testing.expect(first.qid.qtype.dir);
    try testing.expectEqual(hashPath("/sub"), first.qid.path);
    try testing.expectEqualStrings(owner, first.uid);

    // Continue from the first record's end; EOF after the last.
    const n2 = try readListing(stream, first.encodedSize(), &buf);
    const second = try Stat.decode(buf[0..n2]);
    try testing.expectEqualStrings("f.txt", second.name);
    try testing.expectEqual(@as(u32, file_mode), second.mode);
    try testing.expectEqual(@as(usize, 0), try readListing(stream, stream.len, &buf));

    // A short buffer stops on a record boundary; a misaligned offset is refused.
    try testing.expectEqual(first.encodedSize(), try readListing(stream, 0, buf[0 .. stream.len - 1]));
    try testing.expectError(error.BadMessage, readListing(stream, 1, &buf));
    try testing.expectError(error.BadMessage, readListing(stream, stream.len + 1, &buf));
}
