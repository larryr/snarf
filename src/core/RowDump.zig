//! One in-flight `Dump` — `rowdump` + `rowdump1` (rows.c:317-512 at
//! larryr/plan9port@337c6ac). file-as-struct (S-07 P-1): this file *is* the
//! RowDump. Cite as `rows.c:NN`.
//!
//! The row is serialized SYNCHRONOUSLY into an owned buffer the moment `Dump`
//! runs (it is all in memory — rows.c:317-462 does no I/O but the final
//! writes), so the dump is a snapshot of that instant; only the write to the
//! namespace is asynchronous (one `nsjob.WriteFileJob`, stepped from
//! `Session.step`). The format is `dumpfmt.zig`'s — acme's own (R-P17-6).
//!
//! DIVERGENCES:
//!  * No temp file + `dirwstat` rename (rows.c:483-505): `/mnt/opfs` has no
//!    rename (R-P14b-4), so the dump is written in place, truncating. The
//!    C's "can't create temp file for %s" becomes "can't write dump %s".
//!  * `access(name, 0)` (rows.c:406) is `file.disk != null` (R-P17-4): a
//!    window loaded or Put successfully has a disk identity; an unread or
//!    dirty one is dumped inline as an `F` record with its body.
//!  * No `x` (zerox) or `e` (external-program) records — Snarf has neither.
//!  * One font: lines 2-3 both carry its name, and every window record's
//!    font field is empty (acme's "the default font", rows.c:388-390).
//!
//! Imports: `std` + `ninep` + sibling core files (S-07 §6 — never dev/shim).
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");
const Row = @import("Row.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const dumpfmt = @import("dumpfmt.zig");
const wintag = @import("wintag.zig");

const RowDump = @This();
const nsjob = ninep.nsjob;

/// The working directory line (rows.c:329 `wdir`) — Snarf's is `/`
/// (R-P13b-3, `openfile.wdir`).
pub const wdir = "/";
/// The one font's name (rows.c:330-331), the literal `Window.ctlPrint` uses
/// too (`Font` carries no name, R-P10-F).
pub const font_name = "fixed9x18";

allocator: std.mem.Allocator,
/// Absolute path being written. OWNED; borrowed by the job.
path: []u8,
/// The serialized row. OWNED; borrowed by the job.
buf: []u8,
job: nsjob.WriteFileJob,
finished: bool = false,

/// `rowdump(&row, file)` (rows.c:465-512) to the absolute `path`. Returns null
/// when there is nothing to do: no columns (rows.c:472, silently) or the write
/// could not even be set up (warned).
pub fn start(ed: *Editor, path: []const u8) Text.Error!?*RowDump {
    const a = ed.allocator;
    const row = ed.row orelse return null;
    if (row.col.items.len == 0) return null; // rows.c:472-473
    const ns = ed.ns orelse {
        ed.warning("can't write dump {s}: no namespace\n", .{path});
        return null;
    };
    const self = try a.create(RowDump);
    errdefer a.destroy(self);
    self.* = .{ .allocator = a, .path = try a.dupe(u8, path), .buf = undefined, .job = undefined };
    errdefer a.free(self.path);
    self.buf = try serialize(ed, row);
    errdefer a.free(self.buf);
    self.job = nsjob.WriteFileJob.init(ns, self.path, self.buf, .{ .truncate = true }) catch |e| {
        ed.warning("can't write dump {s}: {s}\n", .{ path, @errorName(e) });
        a.free(self.buf);
        a.free(self.path);
        a.destroy(self);
        return null;
    };
    return self;
}

/// One 9P state of the write; failures warn (rows.c:486, :504).
pub fn step(self: *RowDump, ed: *Editor) void {
    if (self.finished) return;
    const st = self.job.step() catch |e| {
        ed.warning("can't write dump {s}: {s}\n", .{ self.path, @errorName(e) });
        self.finished = true;
        return;
    };
    if (st == .done) self.finished = true;
}

pub fn deinit(self: *RowDump) void {
    self.job.deinit();
    self.allocator.free(self.buf);
    self.allocator.free(self.path);
    self.* = undefined;
}

/// `rowdump1` (rows.c:317-462) into an owned buffer. Commits every window's
/// tag first (rows.c:364 `wincommit(w, &w->tag)`), so a hand-edited name is
/// dumped as the name.
pub fn serialize(ed: *Editor, row: *Row) Text.Error![]u8 {
    const a = ed.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    serializeTo(ed, row, &aw.writer) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => |x| return x,
    };
    return aw.toOwnedSlice();
}

fn serializeTo(ed: *Editor, row: *Row, w: *std.Io.Writer) (Text.Error || std.Io.Writer.Error)!void {
    const a = ed.allocator;
    try w.print("{s}\n{s}\n{s}\n", .{ wdir, font_name, font_name }); // rows.c:329-331
    for (row.col.items, 0..) |c, i| { // rows.c:332-339
        try dumpfmt.writePct(w, pct(c.r.min.x - row.r.min.x, row.r.max.x - row.r.min.x));
        try w.writeByte(if (i == row.col.items.len - 1) '\n' else ' ');
    }
    {
        const tag = try textUtf8(a, &row.tag);
        defer a.free(tag);
        try w.print("w {s}\n", .{dumpfmt.firstLine(tag)}); // rows.c:344-349
    }
    for (row.col.items, 0..) |c, i| { // rows.c:350-359
        const tag = try textUtf8(a, &c.tag);
        defer a.free(tag);
        try w.writeByte('c');
        try dumpfmt.writeInt(w, i);
        try w.print(" {s}\n", .{dumpfmt.firstLine(tag)});
    }
    for (row.col.items, 0..) |c, i| {
        for (c.w.items, 0..) |win, j| try dumpWindow(ed, w, c.r, i, j, win);
    }
}

/// One window's records (rows.c:362-458).
fn dumpWindow(ed: *Editor, w: *std.Io.Writer, cr: draw.Rect, i: usize, j: usize, win: *Window) (Text.Error || std.Io.Writer.Error)!void {
    const a = ed.allocator;
    try wintag.commit(ed, win); // rows.c:364
    const f = win.body.file;
    const y = pct(win.r.min.y - cr.min.y, cr.max.y - cr.min.y);
    // rows.c:406 — R-P17-4: `access()` becomes "has a disk identity".
    const inline_body = !((!win.dirty and f.disk != null) or win.isdir);
    try dumpfmt.writeWinRec(w, .{
        .kind = if (inline_body) .F else .f,
        .col = i,
        .id = if (inline_body) j else win.id, // rows.c:409 / :417
        .q0 = win.body.q0,
        .q1 = win.body.q1,
        .pct = y,
        .ndumped = if (inline_body) f.buffer.len() else null, // RUNES (rows.c:419)
        .font = "", // the default font (rows.c:388-390)
    });
    var ctl: [Window.ctl_size]u8 = undefined;
    try w.writeAll(win.ctlPrint(&ctl, false)); // rows.c:423-424
    const tag = try textUtf8(a, &win.tag);
    defer a.free(tag);
    try dumpfmt.writeTag(w, tag); // rows.c:425-437
    try w.writeByte('\n');
    if (inline_body) try f.buffer.writeRaw(w); // rows.c:439-450
}

/// `100.0 * num / den` (rows.c:333, :411), 0 for an empty extent.
fn pct(num: i32, den: i32) f64 {
    if (den <= 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

/// A Text's whole buffer as decoded UTF-8 (caller frees).
fn textUtf8(a: std.mem.Allocator, t: *Text) error{OutOfMemory}![]u8 {
    const n = t.file.buffer.len();
    if (n == 0) return a.alloc(u8, 0);
    const dest = try a.alloc(u8, n * 4);
    defer a.free(dest);
    return a.dupe(u8, t.file.buffer.read(0, n, dest));
}

// ==========================================================================
// Smoke test. The named battery (T16) is the test writer's.
// ==========================================================================
const testing = std.testing;

test "RowDump: a clean loaded window dumps as f (no body), a dirty/never-Put window dumps as F with its body, a dir window dumps as f regardless (T16)" {
    const boot = @import("boot.zig");
    const ninep_ = @import("ninep");
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var ns = ninep_.mount.Namespace.init(testing.allocator);
    defer ns.deinit();
    var tree = try boot.boot(testing.allocator, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 640, 480), .{ .ns = &ns });
    defer tree.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    tree.bind(&ed);

    const col = tree.row.col.items[0];
    const w_clean = try @import("place.zig").mintWindow(col, 0, "/a/clean");
    w_clean.body.file.disk = .{ .qid = .{ .path = 1, .vers = 1 }, .mtime = 1, .length = 0, .sha1 = [_]u8{0} ** 20 };
    w_clean.dirty = false;

    const w_dirty = try @import("place.zig").mintWindow(col, 0, "/a/dirty");
    try w_dirty.body.insertAt(0, "unsaved\n", true);
    w_dirty.dirty = true;
    w_dirty.body.file.disk = null;

    const w_dir = try @import("place.zig").mintWindow(col, 0, "/a/adir");
    w_dir.isdir = true;
    w_dir.dirty = true; // even dirty, a dir window dumps as f (R-P17-4)
    w_dir.body.file.disk = null;

    const out = try serialize(&ed, tree.row);
    defer testing.allocator.free(out);

    var it = std.mem.splitScalar(u8, out, '\n');
    var f_count: usize = 0;
    var cap_count: usize = 0;
    while (it.next()) |line| {
        const rec = dumpfmt.parseWinRec(line) orelse continue;
        switch (rec.kind) {
            .f => f_count += 1,
            .F => cap_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), f_count); // clean + dir
    // 2, not 1: `boot.boot`'s default "scratch" window is itself never-read
    // (disk == null, !dirty) ⇒ also an F record (R-P17-4) alongside w_dirty.
    try testing.expectEqual(@as(usize, 2), cap_count);
    try testing.expect(std.mem.indexOf(u8, out, "unsaved\n") != null); // F's body inline
}

test "RowDump: a booted row serializes in acme's shape" {
    const boot = @import("boot.zig");
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(testing.allocator, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "/a/file",
        .body = "hello\n",
    });
    defer tree.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    tree.bind(&ed);
    const out = try serialize(&ed, tree.row);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "/\nfixed9x18\nfixed9x18\n"));
    // Never read from disk ⇒ dumped inline with its 6-rune body.
    try testing.expect(std.mem.indexOf(u8, out, "\nF") != null);
    try testing.expect(std.mem.endsWith(u8, out, "hello\n"));
}
