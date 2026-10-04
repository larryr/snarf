//! The `Get` builtin (exec.c:589-670, exectab row exec.c:109). namespace module
//! (S-07 P-1). Ported from larryr/plan9port@337c6ac; cite as `exec.c:NN`.
//!
//! `Get` reads a file (or directory) into the window's body. Both arms are the
//! asynchronous `Load` (13b's `textload`):
//!
//!  * DIRECTORY windows re-list their own name. The reset and `windirfree`
//!    (exec.c:632-637) are `dirwin.applyListing`'s job, so the current listing
//!    stays on screen until the new one arrives — unchanged since 13b
//!    (R-P13b-5).
//!  * FILE windows (phase 17) take `getname`'s name (`cmd_put.getName`, own
//!    name / `Get foo` / a 2-1 chord). `samename` ⇒ the reload restores dot and
//!    origin by line+rune (`getaddr`, exec.c:623-630/:656-665) and leaves the
//!    window clean; another name fills the window with that file and marks it
//!    MODIFIED while it keeps its own name (exec.c:640-648). `putseq` is not
//!    touched (R-P17-8).
//!
//! DROPPED, as everywhere: `t->file->ntext > 1` (no Zerox, one Text per File)
//! and `xfidlog(w, "get")` (the log file is not served).
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Load = @import("../Load.zig");
const Text = @import("../text/Text.zig");
const getaddr = @import("../getaddr.zig");
const openfile = @import("../openfile.zig");
const cmd_put = @import("cmd_put.zig");

/// `get` (exec.c:589-670). `flag1` is the exectab's TRUE (exec.c:109), i.e.
/// "require a window"; the served `ctl get` passes FALSE (xfid.c:771).
pub fn get(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    argt: ?*Text,
    flag1: bool,
    _: bool,
    arg: []const u8,
) Text.Error!void {
    const w = et.w orelse return; // exec.c:604-606 (flag1 ⇒ et->w must exist)
    _ = flag1;

    // exec.c:607-608: a non-empty, non-directory, DIRTY window gets the
    // two-strike first. `Window.clean` passes a directory outright
    // (wind.c:667-668), so the `!isdir` guard is belt and braces, as in the C.
    if (!w.isdir and w.body.file.buffer.len() > 0 and !w.clean(ed, true)) return;

    if (w.isdir) {
        // The directory arm (R-P13b-5): re-read the window's OWN name.
        const name = w.body.file.name.items;
        if (name.len == 0) {
            ed.warning("no file name\n", .{}); // exec.c:613-615
            return;
        }
        const abs = try openfile.absName(ed.allocator, name);
        defer ed.allocator.free(abs);
        _ = try Load.start(ed, w, abs, null, false); // exec.c:645 textload(t, 0, name, samename)
        ed.needs_flush = true;
        return;
    }

    const t = &w.body;
    const name = (try cmd_put.getName(ed, t, argt, arg, false)) orelse { // exec.c:611
        ed.warning("no file name\n", .{}); // exec.c:613-615
        return;
    };
    defer ed.allocator.free(name);
    const samename = std.mem.eql(u8, name, t.file.name.items); // exec.c:638
    const addr = getaddr.capture(t); // exec.c:623-630, before the reload
    const ld = (try Load.start(ed, w, name, null, false)) orelse return; // exec.c:639 textload
    ld.get = .{ .samename = samename, .addr = addr }; // the exec.c:640-666 tail
    ed.needs_flush = true;
}

// ===========================================================================
// Smoke test. The named battery (T12) is the test writer's; this only keeps the
// decl reachable and pins the file-window refusal, which needs no namespace.
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const boot = @import("../boot.zig");
const Frame = draw.Frame;
const proto = draw.proto;

test "cmd_get: Get on a file window with no namespace warns and keeps the body" {
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "/some/file",
        .body = "keep me\n",
    });
    defer tree.deinit();
    var ed = Editor.init(a);
    defer ed.deinit();
    tree.bind(&ed);

    const w = tree.row.col.items[0].w.items[0];
    try get(&ed, &w.body, null, null, true, false, "");
    try testing.expectEqualStrings("can't open /some/file: no namespace\n", ed.warningText());
    try testing.expectEqual(@as(usize, 8), w.body.file.buffer.len());
    try testing.expectEqual(@as(usize, 0), ed.loads.items.len);
}

// ===========================================================================
// Named battery (phase-13b contract §4, T12).
// ===========================================================================
const ninep = @import("ninep");
const served_fsys = @import("../served/fsys.zig");

fn pumpT12(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

fn bodyOfT12(a: std.mem.Allocator, w: *@import("../Window.zig")) ![]u8 {
    const n = w.body.file.buffer.len();
    if (n == 0) return a.alloc(u8, 0);
    const dest = try a.alloc(u8, n * 4);
    defer a.free(dest);
    return a.dupe(u8, w.body.file.buffer.read(0, n, dest));
}

test "cmd_get: Get on the / dir window re-lists after a new namespace prefix mounts, showing n/ (T12)" {
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();

    var tree = try boot.boot(a, fx.disp, fx.font, proto.Rect.make(0, 0, 640, 480), .{
        .dir_boot = true,
        .ns = &ns,
    });
    defer tree.deinit();
    var ed = Editor.init(a);
    defer ed.deinit();
    tree.bind(&ed);

    // /dev, the same fake tree every phase-13b harness mounts.
    var dev_tree = ninep.nsdir.FakeTree{ .names = &.{"mouse"}, .tag = "m\n" };
    var dev = try ninep.nsdir.FakeServer.init(a, &dev_tree);
    defer dev.deinit();
    try ns.mount("/dev", dev.client, dev.root_fid);

    // /mnt/snarf-self, served for real.
    var fsys = served_fsys.Fsys.init(&ed);
    var pipe = try ninep.chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try ninep.server.Server.init(a, pipe.serverEnd(), &served_fsys.Fsys.ops, &fsys, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pumpT12 };
    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");
    try ns.mount("/mnt/snarf-self", &cl, root.fid);

    const cols = tree.row.col.items;
    const w = try openfile.readFile(&ed, cols[cols.len - 1], "/");

    var i: usize = 0;
    while (i < 24) : (i += 1) {
        try Load.stepAll(&ed);
        _ = try srv.poll();
        _ = try dev.srv.poll();
    }

    try testing.expect(w.isdir);
    const body0 = try bodyOfT12(a, w);
    defer a.free(body0);
    try testing.expectEqualStrings("dev/\tmnt/\n", body0);

    // A new prefix mounts — the origin attaching, in acme's own shape
    // (acme does not auto-refresh a directory window; Get is how it appears).
    var n_tree = ninep.nsdir.FakeTree{ .names = &.{"x"}, .tag = "x\n" };
    var n_srv = try ninep.nsdir.FakeServer.init(a, &n_tree);
    defer n_srv.deinit();
    try ns.mount("/n", n_srv.client, n_srv.root_fid);

    try get(&ed, &w.body, null, null, true, false, "");
    i = 0;
    while (i < 24) : (i += 1) {
        try Load.stepAll(&ed);
        _ = try srv.poll();
        _ = try dev.srv.poll();
        _ = try n_srv.srv.poll();
    }

    const body1 = try bodyOfT12(a, w);
    defer a.free(body1);
    try testing.expectEqualStrings("dev/\tmnt/\tn/\n", body1);
    try testing.expect(w.isdir);
    try testing.expect(!w.dirty);
}
