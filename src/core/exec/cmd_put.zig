//! The `Put` and `Putall` builtins (exec.c:898-925, :1166-1201; exectab rows
//! exec.c:120-121) and `getname` (exec.c:476-539), which `Get` shares.
//! namespace module (S-07 P-1). Ported from larryr/plan9port@337c6ac; cite as
//! `exec.c:NN`.
//!
//! The write itself is `core/Put.zig` — `putfile` turned asynchronous (R-P17-1).
//! These are the command halves: choose the name, choose the windows, start
//! the Puts. Each failure surfaces later as its own `+Errors` line.
//!
//! DROPPED: `trimspaces` under `autoindent` (exec.c:918-919 — Snarf has no
//! autoindent, F-8) and `xfidlog(w, "put")` (the log file is not served).
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Put = @import("../Put.zig");
const Text = @import("../text/Text.zig");
const errors = @import("../errors.zig");
const exec = @import("exec.zig");
const openfile = @import("../openfile.zig");
const wintag = @import("../wintag.zig");

/// `getname` (exec.c:476-539): the file name a `Get`/`Put` acts on. Owned;
/// null for "no name" (exec.c:534-537).
///
///  * the 2-1 chord argument (`getarg`, exec.c:484) wins — verbatim when it
///    contains a `/`;
///  * for a Put, a chord argument WITHOUT a `/` is promoted — "synthesize a
///    name even for a non-existent file" relative to the ARGUMENT text's
///    directory (exec.c:487-501);
///  * otherwise the command's own argument (`Put foo`), relative to `t`'s
///    window's directory (exec.c:511-526), or with none the window's own name
///    (exec.c:504-507), returned as is so `samename` compares exactly.
///
/// Names built here are made absolute and cleaned (`openfile.absName` /
/// `cleanName`, the port's `cleanrname`); the window's own name is not touched.
pub fn getName(ed: *Editor, t: *Text, argt: ?*Text, arg: []const u8, isput: bool) error{OutOfMemory}!?[]u8 {
    const a = ed.allocator;
    const r = try exec.getArg(ed, argt); // exec.c:484
    defer if (r) |x| a.free(x);

    var tt = t;
    var targ = arg;
    var promote = r == null; // exec.c:486
    if (r) |rr| {
        if (isput and std.mem.indexOfScalar(u8, rr, '/') == null) { // exec.c:487-501
            promote = true;
            tt = argt.?;
            targ = rr;
        }
    }
    if (!promote) return try nonEmpty(a, try openfile.absName(a, r.?)); // exec.c:532
    if (targ.len == 0) { // exec.c:504-507: the window's own name, verbatim
        const own = tt.file.name.items;
        return if (own.len == 0) null else try a.dupe(u8, own);
    }
    if (targ[0] == '/') return try nonEmpty(a, try openfile.cleanName(a, targ));
    // exec.c:511-526: prefix with the directory of `tt`'s window.
    const dir = if (tt.w) |w| errors.dirName(w) else "";
    if (dir.len == 0) return try nonEmpty(a, try openfile.absName(a, targ));
    const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, targ });
    defer a.free(joined);
    return try nonEmpty(a, try openfile.absName(a, joined));
}

/// exec.c:534-537: an empty result is "no name".
fn nonEmpty(a: std.mem.Allocator, s: []u8) error{OutOfMemory}!?[]u8 {
    if (s.len != 0) return s;
    a.free(s);
    return null;
}

/// `put` (exec.c:898-925). Silent for a non-window or a directory window
/// (exec.c:911-912).
pub fn put(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    argt: ?*Text,
    _: bool,
    _: bool,
    arg: []const u8,
) Text.Error!void {
    const w = et.w orelse return; // exec.c:911
    if (w.isdir) return; // exec.c:911
    // The B2 press already committed a hand-edited tag name (acme.c:649); this
    // is the served `ctl put` path's safety net (R-P17-7).
    try wintag.commit(ed, w);
    const name = (try getName(ed, &w.body, argt, arg, true)) orelse { // exec.c:915
        ed.warning("no file name\n", .{}); // exec.c:916-917
        return;
    };
    defer ed.allocator.free(name);
    try Put.start(ed, w, name, false); // exec.c:922 putfile(f, 0, f->b.nc, …)
    ed.needs_flush = true;
}

/// `putall` (exec.c:1166-1201): every modified, named, non-scratch file window,
/// columns left→right, windows top→bottom. `access(name, 0)` becomes the write
/// job's `must_exist` (R-P17-3): Putall never creates a file, and a missing one
/// warns `no auto-Put of …` when its Put completes. One failure never stops
/// the loop — each Put reports on its own.
///
/// The `nopen[QWevent]` skip (exec.c:1181-1182) is n/a until `event` is served.
/// `wincommit(w, &w->body)` (exec.c:1190) commits the BODY's cache only — its
/// `t->what == Body` early return (wind.c:606-607) means no tag rename — and
/// Snarf has no body cache, so it has no port here.
pub fn putall(
    ed: *Editor,
    _: *Text,
    _: ?*Text,
    _: ?*Text,
    _: bool,
    _: bool,
    _: []const u8,
) Text.Error!void {
    const row = ed.row orelse return;
    for (row.col.items) |c| {
        for (c.w.items) |w| {
            const f = w.body.file;
            if (w.isscratch or w.isdir or f.name.items.len == 0) continue; // exec.c:1179-1180
            if (!f.mod) continue; // exec.c:1185 (no ncache)
            try Put.start(ed, w, f.name.items, true); // exec.c:1190-1191
        }
    }
    ed.needs_flush = true;
}

// ===========================================================================
// Smoke test. The named battery (T11/T12) is the test writer's.
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const boot = @import("../boot.zig");

test "cmd_put: getName — own name, relative arg, absolute arg" {
    const a = testing.allocator;
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "/d/file",
        .body = "x\n",
    });
    defer tree.deinit();
    var ed = Editor.init(a);
    defer ed.deinit();
    const w = tree.row.col.items[0].w.items[0];

    const own = (try getName(&ed, &w.body, null, "", true)).?;
    defer a.free(own);
    try testing.expectEqualStrings("/d/file", own);
    const rel = (try getName(&ed, &w.body, null, "foo", true)).?;
    defer a.free(rel);
    try testing.expectEqualStrings("/d/foo", rel);
    const abs = (try getName(&ed, &w.body, null, "/x/y", true)).?;
    defer a.free(abs);
    try testing.expectEqualStrings("/x/y", abs);

    // A 2-1 chord argument with a '/' wins verbatim, regardless of `t`.
    const w2 = try tree.addWindow("/e/argwin", "bar here\n");
    try w2.body.setSelect(0, 3); // "bar" (no slash — promoted, relative to w2)
    const chord_noslash = (try getName(&ed, &w.body, &w2.body, "", true)).?;
    defer a.free(chord_noslash);
    try testing.expectEqualStrings("/e/bar", chord_noslash);

    try w2.body.setSelect(4, 8); // "here" — still no slash
    const chord_noslash2 = (try getName(&ed, &w.body, &w2.body, "", true)).?;
    defer a.free(chord_noslash2);
    try testing.expectEqualStrings("/e/here", chord_noslash2);

    try w2.body.insertAt(w2.body.file.buffer.len(), " /q/r", true); // "bar here\n /q/r"
    try w2.body.setSelect(10, 14); // "/q/r" (byte 9 is the leading space)
    const chord_slash = (try getName(&ed, &w.body, &w2.body, "", true)).?;
    defer a.free(chord_slash);
    try testing.expectEqualStrings("/q/r", chord_slash);
}

test "cmd_put: put — unnamed warns 'no file name', a dir window is silent, isscratch/missing are excluded from Putall (T11/T12)" {
    const a = testing.allocator;
    const place = @import("../place.zig");
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "/d/named",
        .body = "x\n",
    });
    defer tree.deinit();
    var ed = Editor.init(a);
    defer ed.deinit();
    tree.bind(&ed);
    const col = tree.row.col.items[0];

    // Unnamed window ⇒ "no file name".
    const unnamed = try place.mintWindow(col, 0, "");
    try put(&ed, &unnamed.body, null, null, false, false, "");
    try testing.expectEqualStrings("no file name\n", ed.warningText());
    try ed.frameEnd(fx.disp); // drain

    // A directory window ⇒ silent return (no warning, nothing started).
    const dirw = tree.row.col.items[0].w.items[0];
    dirw.isdir = true;
    try put(&ed, &dirw.body, null, null, false, false, "");
    try testing.expectEqual(@as(usize, 0), ed.puts.items.len);
    try testing.expect(!ed.warningsPending());
    dirw.isdir = false;
}

test "cmd_put: putall writes only the eligible dirty/named/non-scratch windows whose file exists, in column/window order; Putall never creates (T12)" {
    const draw_ = draw;
    const ninep = @import("ninep");
    const place = @import("../place.zig");
    const MemTree = @import("../MemTree.zig");
    const Window = @import("../Window.zig");
    const a = testing.allocator;
    var fx = try draw_.Frame.TestFixture.init();
    defer fx.deinit();
    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, draw_.proto.Rect.make(0, 0, 640, 480), .{ .ns = &ns });
    defer tree.deinit();
    var ed = Editor.init(a);
    defer ed.deinit();
    tree.bind(&ed);
    const m = try MemTree.Harness.create(a, &ns, "/m");
    defer m.destroy(a);
    try m.tree.put("a", "A\n");

    const col = tree.row.col.items[0];
    // Properly LOADED (unread=false, disk recorded) so Putall's write goes
    // straight through instead of tripping the "not written; file already
    // exists" stale check — that is `Get`'s job, tested elsewhere (T9).
    const w_existing = try openfile.readFile(&ed, col, "/m/a");
    const w_unnamed = try place.mintWindow(col, 0, ""); // unnamed ⇒ skipped
    const w_errors = try place.mintWindow(col, 0, "+Errors"); // isscratch ⇒ skipped
    const w_missing = try place.mintWindow(col, 0, "/m/b"); // dirty, missing ⇒ "no auto-Put"
    for (0..10) |_| { // let w_existing's Load finish before marking it dirty
        try ed.frameEnd(fx.disp);
        try m.poll();
    }

    for ([_]*Window{ w_existing, w_unnamed, w_errors, w_missing }) |w| {
        ed.seq += 1;
        w.body.file.mark(ed.seq);
        try w.body.insertAt(0, "X", true);
    }
    try testing.expect(w_errors.isscratch); // wintag.setName's suffix rule

    try putall(&ed, &w_existing.body, null, null, false, false, "");
    for (0..40) |_| {
        try Put.stepAll(&ed);
        try m.poll();
    }
    try testing.expectEqualStrings("XA\n", m.tree.find("a").?.data.items);
    try testing.expect(std.mem.indexOf(u8, ed.warningText(), "no auto-Put of /m/b: file does not exist") != null);
    try testing.expect(w_unnamed.dirty); // never attempted
    try testing.expect(w_errors.dirty); // isscratch skipped — stays dirty
    try testing.expect(m.tree.find("b") == null); // Putall never creates
}
