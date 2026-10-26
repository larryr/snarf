//! `Replace` — one atomic Put in flight: the per-fid state between a 9P
//! `Topen(OTRUNC)` of an EXISTING host file and the fid's `Tclunk` (phase 20,
//! PM Q5, R-P20-3).
//!
//! acme's Put is `create(name, OWRITE, 0666)` → write loop → close
//! (acme/exec.c:727-789 @337c6ac): the truncate happens at the open, so a Put
//! that dies part-way leaves a short or empty file. DIVERGENCE (contract
//! `agents/contracts/phase20-native-save.md`, "Atomicity (PM Q5)"): the client
//! side stays exactly acme's open-OTRUNC/write/clunk (core `Put.zig` is
//! untouched), and the SERVER makes it atomic —
//!
//!   open(OTRUNC)  check the original is writable (so a read-only file still
//!                 fails at the open, as `create` would), then make an empty
//!                 temp file in the SAME directory with the original's mode;
//!   write         lands in the temp; a failed write poisons the Put;
//!   clunk         rename temp → original (one `rename(2)`: readers see the
//!                 old bytes or the new ones, never a mix), or — if any write
//!                 failed — delete the temp and leave the original untouched.
//!
//! An OTRUNC open + clunk with no writes and no failure is a legitimate EMPTY
//! Put (acme putting an empty buffer) and commits an empty file (orchestrator
//! ruling, phase 20). The target is the original's real path, so Put through a
//! symlink replaces the file the link names and keeps the link.
//!
//! Known costs of rename-over (accepted with the decision): hard links to the
//! original are split off, and the file's owner becomes the writer. When the
//! directory itself is not writable (a writable file in a read-only
//! directory), no temp can exist there; the Put then falls back to acme's own
//! in-place truncate-and-write rather than refusing a write acme would allow.
const Replace = @This();
const std = @import("std");
const ninep = @import("ninep");
const OpError = ninep.errors.OpError;
const HostFs = @import("HostFs.zig");

/// The original's resolved absolute path (owned).
target: [:0]u8,
/// The temp file's absolute path (owned); null in the in-place fallback.
temp: ?[]u8,
/// A write failed: clunk discards instead of committing.
failed: bool = false,

/// Begin a Put onto the existing file `rel` (relative to `fs.root`).
pub fn begin(fs: *HostFs, gpa: std.mem.Allocator, rel: []const u8) OpError!Replace {
    const io = fs.io;
    // The permission check `create` makes on an existing file (open(2) with
    // O_WRONLY): a read-only original is refused HERE, before any temp exists.
    var orig = fs.root.openFile(io, rel, .{ .mode = .read_write }) catch |e| return HostFs.mapErr(e);
    const st = orig.stat(io) catch {
        orig.close(io);
        return error.IoError;
    };
    orig.close(io);

    const target = fs.root.realPathFileAlloc(io, rel, gpa) catch |e| return HostFs.mapErr(e);
    errdefer gpa.free(target);
    const dir = std.fs.path.dirname(target) orelse "/";
    const base = std.fs.path.basename(target);

    var tries: usize = 0;
    while (tries < 64) : (tries += 1) {
        const n = fs.temp_seq.fetchAdd(1, .monotonic);
        const temp = std.fmt.allocPrint(gpa, "{s}/.{s}.snarf-put.{d}", .{ std.mem.trimEnd(u8, dir, "/"), base, n }) catch
            return error.IoError;
        var f = fs.root.createFile(io, temp, .{ .exclusive = true, .permissions = st.permissions }) catch |e| {
            gpa.free(temp);
            switch (e) {
                error.PathAlreadyExists => continue,
                error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return inPlace(fs, rel, target),
                else => return HostFs.mapErr(e),
            }
        };
        // create(2) applied the umask; the replacement keeps the original's
        // exact mode (fchmod is not masked).
        f.setPermissions(io, st.permissions) catch {};
        f.close(io);
        return .{ .target = target, .temp = temp };
    }
    return error.IoError;
}

/// The fallback when no temp can be made beside the original: acme's own
/// open-truncate (non-atomic, but no worse than acme).
fn inPlace(fs: *HostFs, rel: []const u8, target: [:0]u8) OpError!Replace {
    try fs.truncate(rel);
    return .{ .target = target, .temp = null };
}

/// Where this Put's bytes live until clunk.
pub fn dataPath(self: *const Replace) []const u8 {
    return self.temp orelse self.target;
}

/// A Twrite on the Put's fid. Any failure poisons the Put (clunk discards).
pub fn write(self: *Replace, fs: *HostFs, offset: u64, data: []const u8) OpError!usize {
    return fs.writeFile(self.dataPath(), offset, data) catch |e| {
        self.failed = true;
        return e;
    };
}

/// A Tread on the Put's fid sees what has been written so far.
pub fn read(self: *Replace, fs: *HostFs, offset: u64, buf: []u8) OpError!usize {
    return fs.readFile(self.dataPath(), offset, buf);
}

/// The Tclunk: commit (rename over the original) or discard (delete the temp),
/// then free. Clunk cannot report an error (`server.Ops.clunk` is void,
/// server.zig:97; `clunkFid` always replies Rclunk, server_mut.zig:178-185), so
/// commit failures must not lose the Put silently: when the rename fails (e.g.
/// the directory went read-only mid-Put — the gate's dirlock probe), the bytes
/// are copied over the original IN PLACE instead (the file itself is usually
/// still writable; non-atomic, but the save happens — orchestrator fix, phase
/// 20 gate). Only if that too fails does the original stay as it was, and the
/// client's re-stat (`Put.zig` restat, exec.c:790-799) sees no change. The
/// temp's delete is best-effort: in a locked directory it cannot be removed.
pub fn end(self: *Replace, fs: *HostFs, gpa: std.mem.Allocator) void {
    if (self.temp) |temp| {
        if (!self.failed) {
            fs.root.rename(temp, fs.root, self.target, fs.io) catch copyInPlace(fs, temp, self.target);
        }
        fs.root.deleteFile(fs.io, temp) catch {};
        gpa.free(temp);
    }
    gpa.free(self.target);
    self.* = undefined;
}

/// Rename-failure fallback: stream the temp's bytes over the original
/// (truncate + chunked copy). Errors are swallowed — there is no channel left
/// to report them (see `end`), and the original is then simply unchanged.
fn copyInPlace(fs: *HostFs, temp: []const u8, target: []const u8) void {
    fs.truncate(target) catch return;
    var buf: [16384]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = fs.readFile(temp, off, &buf) catch return;
        if (n == 0) return;
        _ = fs.writeFile(target, off, buf[0..n]) catch return;
        off += n;
    }
}

test "Replace: commit renames over the original; discard leaves it" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "old" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var fs = try HostFs.open(io, path);
    defer fs.close();

    var r = try Replace.begin(&fs, a, "f");
    _ = try r.write(&fs, 0, "new!");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("old", buf[0..try fs.readFile("f", 0, &buf)]);
    try std.testing.expectEqualStrings("new!", buf[0..try r.read(&fs, 0, &buf)]);
    r.end(&fs, a);
    try std.testing.expectEqualStrings("new!", buf[0..try fs.readFile("f", 0, &buf)]);

    var r2 = try Replace.begin(&fs, a, "f");
    r2.failed = true;
    r2.end(&fs, a);
    try std.testing.expectEqualStrings("new!", buf[0..try fs.readFile("f", 0, &buf)]);

    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 1), n); // no temp litter
}
