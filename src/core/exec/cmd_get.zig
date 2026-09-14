//! The `Get` builtin (exec.c:589-670, exectab row exec.c:109) — DIRECTORY
//! WINDOWS ONLY (R-P13b-5). namespace module (S-07 P-1). Ported from
//! larryr/plan9port@337c6ac; cite as `exec.c:NN`.
//!
//! `Get` re-reads a window's own name into its body. For a directory that means
//! rebuilding the listing, which is the half this wave needs: the boot `/`
//! window is minted before `/n/origin` and `/bin` exist, so `Get` is how `n/`
//! and `bin/` appear once the origin attaches. (acme does not auto-refresh a
//! directory window either — the user re-Gets it.)
//!
//! The FILE half waits for the Put/Get wave: it needs `putseq`/`sha1` to decide
//! `samename`, the `TextAddr` line/rune bookkeeping that restores dot and origin
//! across a reload (exec.c:623-635, :651-666), and a `Put` to be worth having.
//! Until then a `Get` on a file window says so and changes nothing.
//!
//! DROPPED here, as everywhere: `t->file->ntext > 1` (no Zerox, one Text per
//! File), `xfidlog(w, "get")` (the log file is not served), and `getname`'s
//! argt/arg promotion (exec.c:476-530) — a directory `Get` re-reads the window's
//! OWN name, which is what `getname` returns for `narg == 0`.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Load = @import("../Load.zig");
const Text = @import("../text/Text.zig");
const openfile = @import("../openfile.zig");

/// `get` (exec.c:589-670), directory arm. `flag1` is the exectab's TRUE
/// (exec.c:109), i.e. "require a window".
pub fn get(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    _: ?*Text,
    flag1: bool,
    _: bool,
    _: []const u8,
) Text.Error!void {
    const w = et.w orelse return; // exec.c:604-606 (flag1 ⇒ et->w must exist)
    _ = flag1;

    // exec.c:607-608: a non-empty, non-directory, DIRTY window gets the
    // two-strike first. `Window.clean` passes a directory outright
    // (wind.c:667-668), so the `!isdir` guard is belt and braces, as in the C.
    if (!w.isdir and w.body.file.buffer.len() > 0 and !w.clean(ed, true)) return;

    const name = w.body.file.name.items; // exec.c:611 getname(t, argt, arg, 0, FALSE)
    if (name.len == 0) {
        ed.warning("no file name\n", .{}); // exec.c:613-615
        return;
    }
    if (!w.isdir) {
        // R-P13b-5: the file arm is deferred with Put (see the header).
        ed.warning("Get: files await the Put/Get wave\n", .{});
        return;
    }

    // exec.c:637-642 `textreset(u); windirfree(u->w);` then `textload`. Here the
    // reset and the `windirfree` are `dirwin.applyListing`'s job, so the CURRENT
    // listing stays on screen until the new one has actually arrived — the
    // asynchronous load may take several frames and an empty window in between
    // would be a regression, not fidelity.
    const abs = try openfile.absName(ed.allocator, name);
    defer ed.allocator.free(abs);
    try Load.start(ed, w, abs, null, false); // exec.c:645 textload(t, 0, name, samename)
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

test "cmd_get: Get on a file window warns and changes nothing" {
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
    try testing.expectEqualStrings("Get: files await the Put/Get wave\n", ed.warningText());
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
