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

test "Session: home==null warns '$home not defined' for both Dump and Load; a second Dump while one runs warns; a bad load file warns with its line and keeps whatever was built (T17)" {
    const draw = @import("draw");
    const boot = @import("boot.zig");
    const MemTree = @import("MemTree.zig");
    const ninep = @import("ninep");
    const a = testing.allocator;
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 640, 480), .{ .ns = &ns });
    defer tree.deinit();
    var ed = Editor.init(a);
    defer ed.deinit();
    tree.bind(&ed);

    // home == null: both of acme's own warnings, verbatim (rows.c:477, :574).
    try ed.session.startDump(&ed, "");
    try testing.expectEqualStrings("can't find file for dump: $home not defined\n", ed.warningText());
    try ed.frameEnd(fx.disp);
    try ed.session.startLoad(&ed, "");
    try testing.expectEqualStrings("can't find file for load: $home not defined\n", ed.warningText());
    try ed.frameEnd(fx.disp);

    const m = try MemTree.Harness.create(a, &ns, "/m");
    defer m.destroy(a);
    ed.session.home = "/m";

    // A second Dump while one is already running warns and does not replace it.
    try ed.session.startDump(&ed, "");
    try testing.expect(ed.session.dump != null);
    try ed.session.startDump(&ed, "");
    try testing.expectEqualStrings("Dump: already in progress\n", ed.warningText());
    for (0..40) |_| {
        try ed.frameEnd(fx.disp);
        try m.poll();
    }
    try testing.expect(ed.session.dump == null); // finished and reaped
    try testing.expect(m.tree.find("acme.dump") != null);

    // A bad load file: malformed at a known line, reports that line, and
    // stops without trapping (rows.c:839-842).
    // Line 4 (the percent line) is EMPTY — too short for even one field
    // (`parsePcts` needs `len+1 >= 12`) — a clean, unambiguous malformed line
    // ("NOT A PERCENT LINE" would actually parse: `atof` falls back to 0.0
    // on no numeric prefix, which is a VALID percent).
    try m.tree.put("acme.dump", "/\nfixed9x18\nfixed9x18\n\n");
    try ed.session.startLoad(&ed, "");
    for (0..40) |_| { // step, not frameEnd: inspect the warning before it drains
        try ed.session.step(&ed);
        try m.poll();
    }
    try testing.expectEqualStrings("bad load file /m/acme.dump:4\n", ed.warningText());
    try testing.expect(ed.session.load == null);
}

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
