//! The session's dump/load state: `$home` and the one in-flight `Dump` and
//! `Load` (the builtins, rows.c:465-844 at larryr/plan9port@337c6ac).
//! file-as-struct (S-07 P-1): this file *is* the Session; an `Editor` field.
//!
//! R-P17-5 (`$home`). acme's only use of `home = getenv("HOME")` (acme.c:136)
//! is the default dump file `$home/acme.dump` (rows.c:477-479, :573-576). The
//! HOST entry point sets `home`: the browser's is `/mnt/opfs` (the always-
//! available private area, R-9P-09), the native host's is the real `$HOME`
//! (null when unset). Nothing is mounted at `$HOME` natively until the host
//! file server mounts at `/`, so a native `Dump` today warns `can't write dump
//! …/acme.dump: NotMounted` — honest, and the path is right the day it is.
//!
//! One dump and one load at a time; a second one while the first runs warns.
//!
//! Imports: `std` + sibling core files (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("Editor.zig");
const RowDump = @import("RowDump.zig");
const RowLoad = @import("RowLoad.zig");
const Text = @import("text/Text.zig");
const openfile = @import("openfile.zig");

const Session = @This();

/// The default dump file's name inside `home` (rows.c:478, :575).
pub const dump_file = "acme.dump";

/// `$home` (acme.c:136); borrowed — the host keeps it alive for the session.
home: ?[]const u8 = null,
dump: ?*RowDump = null,
load: ?*RowLoad = null,

/// The absolute dump-file path for `arg` (exec.c:937-940 `dump`'s name):
/// relative names resolve against `wdir`; an empty `arg` is the default
/// `home/acme.dump`, or null when there is no `home`. Owned.
pub fn dumpPath(self: *const Session, a: std.mem.Allocator, arg: []const u8) error{OutOfMemory}!?[]u8 {
    if (arg.len != 0) return try openfile.absName(a, arg);
    const home = self.home orelse return null;
    const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ home, dump_file });
    defer a.free(joined);
    return try openfile.absName(a, joined);
}

/// `rowdump(&row, name)` (exec.c:941-942, rows.c:465-512).
pub fn startDump(self: *Session, ed: *Editor, arg: []const u8) Text.Error!void {
    if (self.dump != null) {
        ed.warning("Dump: already in progress\n", .{});
        return;
    }
    const path = (try self.dumpPath(ed.allocator, arg)) orelse {
        ed.warning("can't find file for dump: $home not defined\n", .{}); // rows.c:477
        return;
    };
    defer ed.allocator.free(path);
    self.dump = try RowDump.start(ed, path);
}

/// `rowload(&row, name, FALSE)` (exec.c:943-944, rows.c:559-844).
pub fn startLoad(self: *Session, ed: *Editor, arg: []const u8) Text.Error!void {
    if (self.load != null) {
        ed.warning("Load: already in progress\n", .{});
        return;
    }
    const path = (try self.dumpPath(ed.allocator, arg)) orelse {
        ed.warning("can't find file for load: $home not defined\n", .{}); // rows.c:574
        return;
    };
    defer ed.allocator.free(path);
    self.load = try RowLoad.start(ed, path);
}

/// One state of each in-flight job; reaps the finished. From `Editor.frameEnd`
/// after `Put.stepAll` (before the warnings flush, so a failure surfaces in
/// the same frame).
pub fn step(self: *Session, ed: *Editor) Text.Error!void {
    if (self.dump) |d| {
        d.step(ed);
        if (d.finished) {
            d.deinit();
            ed.allocator.destroy(d);
            self.dump = null;
        }
    }
    if (self.load) |l| {
        try l.step(ed);
        if (l.finished) {
            l.deinit();
            ed.allocator.destroy(l);
            self.load = null;
        }
    }
}

/// Editor teardown: abandon both jobs (each deinit is fire-and-forget).
pub fn deinit(self: *Session, a: std.mem.Allocator) void {
    if (self.dump) |d| {
        d.deinit();
        a.destroy(d);
    }
    if (self.load) |l| {
        l.deinit();
        a.destroy(l);
    }
    self.* = undefined;
}

// ==========================================================================
// Smoke test. The named battery (T17) is the test writer's.
// ==========================================================================
const testing = std.testing;

test "Session: dumpPath defaults to home/acme.dump and resolves relatives" {
    const a = testing.allocator;
    var s = Session{};
    try testing.expectEqual(@as(?[]u8, null), try s.dumpPath(a, ""));
    s.home = "/mnt/x";
    const d = (try s.dumpPath(a, "")).?;
    defer a.free(d);
    try testing.expectEqualStrings("/mnt/x/acme.dump", d);
    const r = (try s.dumpPath(a, "foo")).?;
    defer a.free(r);
    try testing.expectEqualStrings("/foo", r);
}
