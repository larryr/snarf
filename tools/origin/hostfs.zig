//! `fs/` — the host directory export (S-02 §5). Plain files and directories
//! under one root directory, read/write; everything else (symlinks, devices)
//! is invisible. Qid paths are the host inodes tagged into their own range so
//! they never collide with the synthetic tree; `qid.vers` is the mtime in
//! seconds so a client can cheaply notice changes.
//!
//! Every operation re-opens the path: the origin is a dev server, and stateless
//! calls keep fids from pinning host file descriptors.
const std = @import("std");
const Io = std.Io;
const ninep = @import("ninep");
const Qid = ninep.Qid;
const Stat = ninep.stat;
const OpError = ninep.errors.OpError;
const DirReader = @import("dirread.zig").DirReader;

/// High bit range for host qids (synthetic nodes live below 2^32).
pub const qid_tag: u64 = 1 << 40;

pub const HostFs = struct {
    io: Io,
    root: Io.Dir,

    pub fn open(io: Io, path: []const u8) !HostFs {
        return .{ .io = io, .root = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) };
    }

    pub fn close(self: *HostFs) void {
        self.root.close(self.io);
    }

    /// Directory entry for `rel` ("" is the export root), named `name`.
    pub fn statOf(self: *HostFs, rel: []const u8, name: []const u8) OpError!Stat {
        const st = self.root.statFile(self.io, subPath(rel), .{}) catch |e| return mapErr(e);
        if (st.kind != .directory and st.kind != .file) return error.FileDoesNotExist;
        return toStat(st, name);
    }

    pub fn qidOf(self: *HostFs, rel: []const u8) OpError!Qid {
        return (try self.statOf(rel, "")).qid;
    }

    /// One directory read: whole stat records from `offset` (see dirread.zig).
    pub fn readDir(self: *HostFs, rel: []const u8, offset: u64, buf: []u8) OpError!usize {
        var dir = self.root.openDir(self.io, subPath(rel), .{ .iterate = true }) catch |e| return mapErr(e);
        defer dir.close(self.io);
        var it = dir.iterate();
        var dr = DirReader.init(offset, buf);
        while (it.next(self.io) catch return error.IoError) |ent| {
            // Racing deletions and non-file kinds simply vanish from the listing.
            const st = dir.statFile(self.io, ent.name, .{}) catch continue;
            if (st.kind != .directory and st.kind != .file) continue;
            if (!dr.emit(toStat(st, ent.name))) break;
        }
        return dr.len();
    }

    pub fn readFile(self: *HostFs, rel: []const u8, offset: u64, buf: []u8) OpError!usize {
        var f = self.root.openFile(self.io, rel, .{}) catch |e| return mapErr(e);
        defer f.close(self.io);
        return f.readPositionalAll(self.io, buf, offset) catch return error.IoError;
    }

    pub fn writeFile(self: *HostFs, rel: []const u8, offset: u64, data: []const u8) OpError!usize {
        var f = self.root.openFile(self.io, rel, .{ .mode = .read_write }) catch |e| return mapErr(e);
        defer f.close(self.io);
        f.writePositionalAll(self.io, data, offset) catch return error.IoError;
        return data.len;
    }

    /// OTRUNC on open (S-01 §2.1).
    pub fn truncate(self: *HostFs, rel: []const u8) OpError!void {
        var f = self.root.openFile(self.io, rel, .{ .mode = .read_write }) catch |e| return mapErr(e);
        defer f.close(self.io);
        f.setLength(self.io, 0) catch return error.IoError;
    }

    fn subPath(rel: []const u8) []const u8 {
        return if (rel.len == 0) "." else rel;
    }

    fn toStat(st: Io.File.Stat, name: []const u8) Stat {
        const dir = st.kind == .directory;
        const mtime = seconds(st.mtime);
        return .{
            .qid = .{
                .path = qid_tag | @as(u64, @intCast(st.inode)),
                .vers = mtime,
                .qtype = .{ .dir = dir },
            },
            .mode = if (dir) Stat.DMDIR | 0o755 else 0o644,
            .atime = if (st.atime) |a| seconds(a) else mtime,
            .mtime = mtime,
            .length = if (dir) 0 else st.size,
            .name = name,
        };
    }

    fn seconds(t: Io.Timestamp) u32 {
        const s = @divTrunc(t.nanoseconds, std.time.ns_per_s);
        if (s <= 0) return 0;
        return @intCast(@min(s, std.math.maxInt(u32)));
    }

    fn mapErr(e: anyerror) OpError {
        return switch (e) {
            error.FileNotFound => error.FileDoesNotExist,
            error.AccessDenied, error.PermissionDenied => error.PermissionDenied,
            error.IsDir => error.FileIsDirectory,
            error.NotDir => error.WalkNoDir,
            else => error.IoError,
        };
    }
};

test "hostfs: stat, list, read, write, truncate on a temp export" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello\n" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/leaf", .data = "leaf\n" });

    const path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var fs = try HostFs.open(io, path);
    defer fs.close();

    const root = try fs.statOf("", "fs");
    try std.testing.expect(root.qid.qtype.dir);
    try std.testing.expectEqualStrings("fs", root.name);

    var buf: [1024]u8 = undefined;
    const n = try fs.readDir("", 0, &buf);
    var names: usize = 0;
    var pos: usize = 0;
    while (pos < n) : (names += 1) {
        const st = try Stat.decode(buf[pos..n]);
        try std.testing.expect(std.mem.eql(u8, st.name, "hello.txt") or std.mem.eql(u8, st.name, "sub"));
        pos += st.encodedSize();
    }
    try std.testing.expectEqual(@as(usize, 2), names);

    const r = try fs.readFile("sub/leaf", 0, &buf);
    try std.testing.expectEqualStrings("leaf\n", buf[0..r]);
    try std.testing.expectEqual(@as(usize, 0), try fs.readFile("hello.txt", 6, &buf)); // EOF

    try fs.truncate("hello.txt");
    _ = try fs.writeFile("hello.txt", 0, "bye\n");
    const r2 = try fs.readFile("hello.txt", 0, &buf);
    try std.testing.expectEqualStrings("bye\n", buf[0..r2]);

    try std.testing.expectError(error.FileDoesNotExist, fs.readFile("nope", 0, &buf));
    try std.testing.expectError(error.FileDoesNotExist, fs.qidOf("missing"));
}
