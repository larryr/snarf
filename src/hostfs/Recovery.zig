//! `Recovery` — where an unfinished Put's bytes go when the session ends
//! under it (#58). Owner decision 2026-10-31 (Larry): keep partial Put in a
//! recovery file, vim-style (cf. vim's `.name.swp`), and leave the original
//! untouched.
//!
//! `HostTree.endSession` releases every fid; a Put whose client never sent
//! its Tclunk is DISCARDED (never renamed over the original — `Replace`).
//! Before its temp is deleted, `save` copies the bytes it had received into a
//! NEW file, never overwriting anything:
//!
//!   1. beside the original:  `<dir>/.<base>.snarf-partial`, then
//!      `.snarf-partial.1`, `.2`, … while the name is taken;
//!   2. if that directory refuses (read-only, or any other create/copy
//!      failure): `<tmp_dir>/snarf-partial-<pid>-<base>` with the same
//!      numbering — `tmp_dir` is `$TMPDIR` or `/tmp` (the host sets it);
//!   3. else: report the error; the caller says so on stderr.
//!
//! Every candidate is made with an exclusive create, mode 0600 (the partial
//! buffer may be private; vim's swap files are 0600 too). A Put that had
//! received zero bytes leaves no file. Nothing here can fail the teardown:
//! every error comes back as a value and every allocation is freed.
const Recovery = @This();
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const HostFs = @import("HostFs.zig");

/// The fallback directory (absolute). Borrowed; must outlive the session.
tmp_dir: []const u8 = "/tmp",
/// The `<pid>` in a fallback name.
pid: u32,

/// Numbered names tried per location before giving up on it.
pub const max_suffix: usize = 1000;
pub const mode: std.posix.mode_t = 0o600;

pub fn init() Recovery {
    return .{ .pid = currentPid() };
}

pub fn currentPid() u32 {
    if (builtin.os.tag == .linux) return @intCast(std.os.linux.getpid());
    if (builtin.link_libc) return @intCast(std.c.getpid());
    return 0;
}

/// What `save` did.
pub const Saved = union(enum) {
    /// The Put had received no bytes: nothing to keep, nothing written.
    empty,
    /// Saved; the recovery file's path as the user should see it (owned —
    /// `deinit`): export-root form (`/dir/.f.snarf-partial`) beside the
    /// original, an absolute host path for the tmp fallback.
    saved: []u8,
    /// Nowhere would take it; the last error.
    failed: anyerror,

    pub fn deinit(self: Saved, gpa: std.mem.Allocator) void {
        switch (self) {
            .saved => |p| gpa.free(p),
            else => {},
        }
    }
};

/// Copy the bytes at `src` (an absolute host path: the Put's temp) into a new
/// recovery file for the original `rel` (export-root relative, "" never).
pub fn save(self: *const Recovery, fs: *HostFs, gpa: std.mem.Allocator, src: []const u8, rel: []const u8) Saved {
    const io = fs.io;
    var in = fs.root.openFile(io, src, .{}) catch |e| return .{ .failed = e };
    defer in.close(io);
    const size = (in.stat(io) catch |e| return .{ .failed = e }).size;
    if (size == 0) return .empty;

    const base = std.fs.path.basename(rel);
    const dir = std.fs.path.dirname(rel) orelse "";
    // 1. Beside the original, inside the export root.
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const beside = std.fmt.bufPrint(&prefix_buf, "{s}{s}.{s}.snarf-partial", .{ dir, if (dir.len == 0) "" else "/", base }) catch
        return .{ .failed = error.NameTooLong };
    if (place(fs.root, io, gpa, in, beside)) |name| {
        defer gpa.free(name);
        return if (std.fmt.allocPrint(gpa, "/{s}", .{name})) |p| .{ .saved = p } else |e| .{ .failed = e };
    } else |_| {} // any refusal here: try the fallback
    // 2. The tmp fallback (absolute, so the root dir handle is ignored).
    // Only an absolute `$TMPDIR` is honoured: a relative one would resolve
    // against the export root and could not be printed as a B3-able path.
    const tmp_dir = if (self.tmp_dir.len != 0 and self.tmp_dir[0] == '/') self.tmp_dir else "/tmp";
    const tmp = std.mem.trimEnd(u8, tmp_dir, "/");
    const fallback = std.fmt.bufPrint(&prefix_buf, "{s}/snarf-partial-{d}-{s}", .{ tmp, self.pid, base }) catch
        return .{ .failed = error.NameTooLong };
    if (place(fs.root, io, gpa, in, fallback)) |name| return .{ .saved = name } else |e| return .{ .failed = e };
}

/// Exclusive-create `prefix`, `prefix.1`, … in `dir` and copy `in` into the
/// first free one. Returns its name (owned). A copy that fails part-way
/// deletes what it made: no half-saved recovery file is left behind.
fn place(dir: Io.Dir, io: Io, gpa: std.mem.Allocator, in: Io.File, prefix: []const u8) ![]u8 {
    var n: usize = 0;
    while (n < max_suffix) : (n += 1) {
        const name = if (n == 0) try gpa.dupe(u8, prefix) else try std.fmt.allocPrint(gpa, "{s}.{d}", .{ prefix, n });
        errdefer gpa.free(name);
        var out = dir.createFile(io, name, .{
            .exclusive = true,
            .permissions = Io.File.Permissions.fromMode(mode),
        }) catch |e| switch (e) {
            error.PathAlreadyExists => {
                gpa.free(name);
                continue;
            },
            else => return e,
        };
        copy(io, in, out) catch |e| {
            out.close(io);
            dir.deleteFile(io, name) catch {};
            return e;
        };
        out.close(io);
        return name;
    }
    return error.PathAlreadyExists;
}

fn copy(io: Io, in: Io.File, out: Io.File) !void {
    var buf: [16384]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const got = try in.readPositionalAll(io, &buf, off);
        if (got == 0) return;
        try out.writePositionalAll(io, buf[0..got], off);
        off += got;
        if (got < buf.len) return;
    }
}
