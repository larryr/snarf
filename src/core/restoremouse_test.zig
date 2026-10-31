//! Headless acceptance tests for issue #9 — return-after-Del warp
//! (acme `savemouse`/`restoremouse`, util.c:384-408, cols.c:150/178).
//! Requirement: R-EDIT-25. Test plan:
//! `notes/snarfdev2/test-plans/M0-09-restoremouse.md` (RM-01..08).
//!
//! Ruling (PM/SnarfProdd, 2026-10-31): exact ACME. Q3's 2026-10-14 "restore
//! only if the pointer is still inside the pop-up" is SUPERSEDED: restore
//! happens whenever the deleted window is the saved one (util.c:396). There is ONE save
//! slot (`prevmouse`/`mousew`, util.c:15-16). `savemouse` overwrites it
//! (util.c:383-388), and `restoremouse` warps only for the saved window but
//! ALWAYS clears the slot (util.c:390-402). So deleting any window forgets the
//! save (RM-03), and nested pop-ups don't stack (RM-06).
//!
//! EXPECTED-FAIL MECHANISM. `restoremouse_landed` is false until #9 merges.
//! While false, a test whose behaviour isn't implemented yet calls `xfail`:
//! it SKIPS when the assertion fails (so `zig build test` stays green) and
//! FAILS when the assertion unexpectedly holds, prompting whoever lands #9 to
//! flip the flag to true. Guard tests (no warp expected) run normally.
//!
//! Rig: a booted row (`boot.boot`) with `warp.MouseSink` mounted at `/dev`
//! over a real 9P pipe, the same rig as openfile.zig's T12 and look.zig's T9.
const std = @import("std");
const testing = std.testing;
const ninep = @import("ninep");
const draw = @import("draw");
const boot = @import("boot.zig");
const warp = @import("warp.zig");
const errors = @import("errors.zig");
const Editor = @import("Editor.zig");
const Window = @import("Window.zig");
const Gesture = @import("Gesture.zig");
const Frame = draw.Frame;
const proto = draw.proto;

/// Flip to true in the PR that lands #9.
const restoremouse_landed = true;

fn xfail(ok: bool) !void {
    if (restoremouse_landed) {
        if (!ok) return error.TestUnexpectedResult;
        return;
    }
    if (ok) {
        std.debug.print("restoremouse_test: behaviour now passes; set restoremouse_landed = true\n", .{});
        return error.UnexpectedPassFlipFlag;
    }
    return error.SkipZigTest; // expected-fail until #9
}

/// Flip to true when restoremouse drops PM Q3's pointer-inside gate (exact
/// ACME, PM 2026-10-31). #43 as of ee82794 still has the gate.
const acme_exact_restore_landed = false;

fn acmeExact(ok: bool) !void {
    if (acme_exact_restore_landed) {
        if (!ok) return error.TestUnexpectedResult;
        return;
    }
    if (ok) {
        std.debug.print("restoremouse_test: exact-ACME restore now passes; set acme_exact_restore_landed = true\n", .{});
        return error.UnexpectedPassFlipFlag;
    }
    return error.SkipZigTest; // expected-fail until the gate is removed
}

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

const Rig = struct {
    fx: Frame.TestFixture,
    ns: ninep.mount.Namespace,
    tree: boot.Tree,
    ed: Editor,
    sink: warp.MouseSink,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,

    fn init(h: *Rig) !void {
        const a = testing.allocator;
        h.fx = try Frame.TestFixture.init();
        h.ns = ninep.mount.Namespace.init(a);
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 640, 480), .{
            .ns = &h.ns,
            .win_name = "/home/larry/main.zig",
            .body = "main body\n",
        });
        h.ed = Editor.init(a);
        h.tree.bind(&h.ed);
        h.sink = .{};
        h.pipe = try ninep.chan.Pipe.init(a, 16384);
        h.srv = try ninep.server.Server.init(a, h.pipe.serverEnd(), &warp.MouseSink.ops, &h.sink, 8192);
        h.cl = try ninep.Client.init(a, h.pipe.clientEnd(), 8192);
        h.cl.pump = .{ .ctx = &h.srv, .run = pump };
        _ = try h.cl.version(8192);
        const root = try h.cl.attach("larry", "");
        try h.ns.mount("/dev", &h.cl, root.fid);
    }

    fn deinit(h: *Rig) void {
        h.ed.deinit();
        h.cl.deinit();
        h.srv.deinit();
        h.pipe.deinit();
        h.tree.deinit();
        h.ns.deinit();
        h.fx.deinit();
    }

    /// Pop up `<dir>/+Errors` with the pointer at `p0` (the savemouse point).
    fn popup(h: *Rig, dir: []const u8, p0: proto.Point) !*Window {
        h.ed.gesture.mouse_pt = p0;
        return errors.errorWin(&h.ed, dir);
    }

    /// Del `w` (colclose path, cmd_window.zig:55) with the pointer at `at`.
    fn del(h: *Rig, w: *Window, at: proto.Point) !void {
        h.ed.gesture.mouse_pt = at;
        try w.col.?.close(&h.ed, w, true);
    }

    fn lastIs(h: *Rig, p: proto.Point) bool {
        var want: [warp.rec_len]u8 = undefined;
        warp.format(p.x, p.y, &want);
        return h.sink.writes > 0 and std.mem.eql(u8, &want, &h.sink.last);
    }
};

fn inside(w: *Window) proto.Point {
    return .{ .x = w.r.min.x + 10, .y = w.r.min.y + 10 };
}

const P0: proto.Point = .{ .x = 37, .y = 41 };

test "restoremouse RM-01/02: Del of a pop-up with the pointer still in it warps back to the saved point" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup("/home/larry", P0);
    const before = h.sink.writes;
    try h.del(w, inside(w));
    try xfail(h.sink.writes > before and h.lastIs(P0));
}

test "restoremouse RM-03: deleting a different window does not warp AND clears the save (util.c:400)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const pop = try h.popup("/home/larry", P0);
    const other = try h.tree.addWindow("/tmp/other", "x\n");
    const before = h.sink.writes;
    try h.del(other, inside(other));
    try testing.expectEqual(before, h.sink.writes); // no warp at all
    // The slot was cleared, so Del of the original pop-up, with the pointer
    // inside it (which RM-01/02 shows would otherwise warp), does nothing.
    try h.del(pop, inside(pop));
    try xfail(h.sink.writes == before);
}

test "restoremouse RM-04: Del of the saved pop-up warps back even after the pointer left it (exact ACME, util.c:396)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup("/home/larry", P0);
    const away: proto.Point = .{ .x = 1, .y = 1 }; // row tag, outside w.r
    try testing.expect(!Gesture.ptInRect(w.r, away.x, away.y)); // really outside
    const before = h.sink.writes;
    try h.del(w, away); // e.g. a Del typed elsewhere and executed on w's tag
    try acmeExact(h.sink.writes == before + 1 and h.lastIs(P0));
}

test "restoremouse RM-05: saved window freed by Delcol leaves no dangling state; later Del does not warp" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup("/home/larry", P0);
    const col = w.col.?;
    // Free the saved window via the column path (dropTextRefs must clear it).
    try col.close(&h.ed, w, true);
    const before = h.sink.writes;
    // A fresh unrelated window; deleting it must not use the stale save.
    const other = try h.tree.addWindow("/tmp/after", "y\n");
    try h.del(other, inside(other));
    try testing.expect(!(h.sink.writes > before and h.lastIs(P0)));
}

test "restoremouse RM-06: single save slot — Del B warps to P1, then Del A does nothing (no stack)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const P1: proto.Point = .{ .x = 222, .y = 111 };
    const a = try h.popup("/home/larry", P0);
    const b = try h.popup("/tmp", P1); // savemouse overwrites the one slot
    const before = h.sink.writes;
    try h.del(b, inside(b));
    try xfail(h.sink.writes == before + 1 and h.lastIs(P1));
    // restoremouse cleared the slot: A's P0 was overwritten, not stacked.
    try h.del(a, inside(a));
    try xfail(h.sink.writes == before + 1);
}

test "restoremouse RM-07: no /dev/mouse (browser/headless) — Del of a pop-up never errors" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    h.ed.ns = null;
    const w = try h.popup("/home/larry", P0);
    try h.del(w, inside(w));
}
