//! #53 and #45 (SnarfDev1): the layout `clearmouse` sites and the creation
//! warp's held-button guard. R-EDIT-25.
//!
//! acme forgets a saved pop-up whenever the layout changes: `colresize`
//! (cols.c:242) and `rowadd` (rows.c:99) both call `clearmouse()`
//! (util.c:404-408), so a later `Del` of the pop-up does NOT warp back. Each
//! case below saves a pop-up, changes the layout, deletes the pop-up with the
//! pointer elsewhere, and asserts no `/dev/mouse` write. The control case (no
//! layout change) shows the same Del does warp, so the others can't pass
//! vacuously.
//!
//! Rig: a booted two-column row with `warp.MouseSink` mounted at `/dev`
//! (as restoremouse_test.zig and warp_focus_test.zig).
const std = @import("std");
const testing = std.testing;
const ninep = @import("ninep");
const draw = @import("draw");
const boot = @import("boot.zig");
const warp = @import("warp.zig");
const errors = @import("errors.zig");
const Editor = @import("Editor.zig");
const Window = @import("Window.zig");
const Frame = draw.Frame;
const proto = draw.proto;

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
        _ = (try h.tree.row.addAtBoot(-1)).?; // a second (rightmost) column for +Errors
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

    /// Pop up `/home/larry/+Errors` with the pointer at `P0` (savemouse,
    /// cols.c:150).
    fn popup(h: *Rig) !*Window {
        h.ed.gesture.mouse_pt = P0;
        const w = try errors.errorWin(&h.ed, "/home/larry");
        try testing.expect(h.ed.mousew == w); // saved
        return w;
    }

    /// Del `w` (colclose, cols.c:178) with the pointer at the row tag; returns
    /// how many `/dev/mouse` writes the Del made.
    fn delWrites(h: *Rig, w: *Window) !usize {
        h.ed.gesture.mouse_pt = .{ .x = 1, .y = 1 };
        const before = h.sink.writes;
        try w.col.?.close(&h.ed, w, true);
        return h.sink.writes - before;
    }
};

const P0: proto.Point = .{ .x = 37, .y = 41 };

test "restoremouse layout: control — with no layout change, Del of the saved pop-up warps back" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup();
    try testing.expectEqual(@as(usize, 1), try h.delWrites(w));
    var want: [warp.rec_len]u8 = undefined;
    warp.format(P0.x, P0.y, &want);
    try testing.expectEqualStrings(&want, &h.sink.last);
}

test "restoremouse layout #53: a column resize between save and Del forgets the save (cols.c:242)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup();
    const c = w.col.?;
    var r = c.r;
    r.max.y -= 20; // any colresize, even of the pop-up's own column
    try c.resize(&h.ed, r);
    try testing.expect(h.ed.mousew == null);
    try testing.expectEqual(@as(usize, 0), try h.delWrites(w));
}

test "restoremouse layout #53: a column resize elsewhere also forgets the save (cols.c:242)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup();
    const other = h.tree.row.col.items[0];
    try testing.expect(other != w.col.?);
    try other.resize(&h.ed, other.r);
    try testing.expectEqual(@as(usize, 0), try h.delWrites(w));
}

test "restoremouse layout #53: adding a column between save and Del forgets the save (rows.c:99)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup();
    _ = (try h.tree.row.add(&h.ed, -1)).?; // rowadd(row, nil, -1)
    try testing.expect(h.ed.mousew == null);
    try testing.expectEqual(@as(usize, 0), try h.delWrites(w));
}

test "restoremouse layout #53: a screen resize between save and Del forgets the save (rowresize → colresize)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup();
    try h.tree.resize(&h.ed, proto.Rect.make(0, 0, 800, 600));
    try testing.expect(h.ed.mousew == null);
    try testing.expectEqual(@as(usize, 0), try h.delWrites(w));
}

test "restoremouse layout #53: a refused rowadd (column too narrow) leaves the save alone (rows.c:74-75 returns before :99)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = try h.popup();
    // Shrink the screen so the rightmost column is under 100 px: rowadd refuses.
    // The screen resize itself clears (cols.c:242), so save again after it.
    try h.tree.resize(&h.ed, proto.Rect.make(0, 0, 200, 480));
    h.ed.gesture.mouse_pt = P0;
    @import("restoremouse.zig").save(&h.ed, w);
    try testing.expect((try h.tree.row.add(&h.ed, -1)) == null);
    try testing.expect(h.ed.mousew == w);
    try testing.expectEqual(@as(usize, 1), try h.delWrites(w));
}

test "warp_focus #45: no creation warp while a mouse button is held (cols.c:152-153)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    h.ed.gesture.buttons = 2; // B2 still down
    h.ed.gesture.mouse_pt = P0;
    const before = h.sink.writes;
    const w = try errors.errorWin(&h.ed, "/home/larry");
    try testing.expectEqual(before, h.sink.writes); // no moveto
    try testing.expect(h.ed.mousew == w); // savemouse still ran (cols.c:150)
}

test "warp_focus #45: Gesture.handleMouse records the button set acme's coladd reads" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    try h.ed.handleMouse(.{ .x = 1, .y = 1, .buttons = 4, .msec = 0 });
    try testing.expectEqual(@as(u8, 4), h.ed.gesture.buttons);
    try h.ed.handleMouse(.{ .x = 1, .y = 1, .buttons = 0, .msec = 1 });
    try testing.expectEqual(@as(u8, 0), h.ed.gesture.buttons);
}
