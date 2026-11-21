//! Column drag, C-01 .. C-19. Binding plan: notes/grok/col-resize.md
//! ("Test plan" and "Worked geometry"). Each test drives `Editor.handleMouse`
//! on a 600×400 boot. No network. `ed.ns` stays null except in C-15.
const std = @import("std");
const testing = std.testing;
const draw = @import("draw");
const ninep = @import("ninep");
const Frame = draw.Frame;
const proto = draw.proto;
const Editor = @import("Editor.zig");
const Column = @import("Column.zig");
const Buffer = @import("Buffer.zig");
const boot = @import("boot.zig");
const restoremouse = @import("restoremouse.zig");
const warp = @import("warp.zig");

const B1: u8 = 1;
const B2: u8 = 2;
const B3: u8 = 4;

const col_tag = "New Cut Paste Snarf Sort Zerox Delcol ";

// Worked two-column geometry after `row.add(ed, -1)` on a 600×400 boot.
const split_l = proto.Rect.make(0, 20, 358, 400);
const split_r = proto.Rect.make(360, 20, 600, 400);
const at200_l = proto.Rect.make(0, 20, 200, 400);
const at200_r = proto.Rect.make(202, 20, 600, 400);
const at371_l = proto.Rect.make(0, 20, 371, 400);
const at371_r = proto.Rect.make(373, 20, 600, 400);
const clamp_lo_l = proto.Rect.make(0, 20, 92, 400);
const clamp_lo_r = proto.Rect.make(94, 20, 600, 400);
const clamp_hi_l = proto.Rect.make(0, 20, 508, 400);
const clamp_hi_r = proto.Rect.make(510, 20, 600, 400);
const shuffle_l = proto.Rect.make(0, 20, 398, 400);
const shuffle_r = proto.Rect.make(400, 20, 600, 400);

const Scene = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,

    fn deinit(h: *Scene) void {
        h.ed.deinit();
        h.tree.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
};

fn open() !*Scene {
    const a = testing.allocator;
    const h = try a.create(Scene);
    errdefer a.destroy(h);
    h.fx = try Frame.TestFixture.init();
    errdefer h.fx.deinit();
    h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 600, 400), .{
        .win_name = "file.txt",
        .body = "alpha\n",
    });
    errdefer h.tree.deinit();
    h.ed = Editor.init(a);
    h.ed.row = h.tree.row;
    return h;
}

fn openTwo() !*Scene {
    const h = try open();
    errdefer h.deinit();
    // Worked geometry: c0 max.x 358, c1 min.x 360. The boot window stays in c0.
    if ((try h.tree.row.add(&h.ed, -1)) == null) return error.TestUnexpectedResult;
    return h;
}

fn ev(h: *Scene, x: i32, y: i32, buttons: u8) !void {
    try h.ed.handleMouse(Editor.mev(x, y, buttons));
}

fn btn(c: *Column) proto.Point {
    return Editor.center(c.tag.scrollr);
}

fn expectCols(h: *Scene, left: proto.Rect, right: proto.Rect) !void {
    const items = h.tree.row.col.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(left, items[0].r);
    try testing.expectEqual(right, items[1].r);
}

fn expectColTag(c: *Column) !void {
    const n = c.tag.file.buffer.len();
    try testing.expectEqual(col_tag.len, n);
    var buf: [Buffer.max_bytes_per_rune * col_tag.len]u8 = undefined;
    const got = c.tag.file.buffer.read(0, n, &buf);
    try testing.expectEqualStrings(col_tag, got);
}

fn nwin(h: *Scene) usize {
    var n: usize = 0;
    for (h.tree.row.col.items) |c| n += c.w.items.len;
    return n;
}

fn inRect(r: proto.Rect, x: i32, y: i32) bool {
    return x >= r.min.x and x < r.max.x and y >= r.min.y and y < r.max.y;
}

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// The point written to `/dev/mouse`. Same record `warp.format` sends.
fn warpPoint(rec: *const [warp.rec_len]u8) !proto.Point {
    try testing.expectEqual(@as(u8, 'm'), rec[0]);
    var it = std.mem.tokenizeScalar(u8, rec[1..], ' ');
    const xs = it.next() orelse return error.TestUnexpectedResult;
    const ys = it.next() orelse return error.TestUnexpectedResult;
    return .{
        .x = try std.fmt.parseInt(i32, xs, 10),
        .y = try std.fmt.parseInt(i32, ys, 10),
    };
}

test "dragcol C-01: held move keeps the layout; release at (200, 29) resizes" {
    const h = try openTwo();
    defer h.deinit();
    const c0 = h.tree.row.col.items[0];
    const c1 = h.tree.row.col.items[1];
    const w = c0.w.items[0];
    const p0 = btn(c0);
    const p1 = btn(c1);
    try testing.expectEqual(proto.Point{ .x = 6, .y = 29 }, p0);
    try testing.expectEqual(proto.Point{ .x = 366, .y = 29 }, p1);
    try expectCols(h, split_l, split_r);

    h.ed.needs_flush = false;
    try ev(h, p1.x, p1.y, B1);
    try ev(h, 200, 29, B1);
    try expectCols(h, split_l, split_r);
    try testing.expect(h.ed.activecol == null);

    try ev(h, 200, 29, 0);
    try expectCols(h, at200_l, at200_r);
    try testing.expectEqual(c0.r.min.x, w.r.min.x);
    try testing.expectEqual(c0.r.max.x, w.r.max.x);
    try testing.expect(h.ed.needs_flush);
    try testing.expect(h.ed.seltext == null);
    try testing.expect(h.ed.activecol == c1);
    try expectColTag(c0);
    try expectColTag(c1);
}

test "dragcol C-02: release at (370, 33) is inside the deadzone" {
    const h = try openTwo();
    defer h.deinit();
    const p = btn(h.tree.row.col.items[1]);
    h.ed.needs_flush = false;
    try ev(h, p.x, p.y, B1);
    try ev(h, 370, 33, 0);
    try expectCols(h, split_l, split_r);
    try testing.expect(h.ed.activecol == h.tree.row.col.items[1]);
    try testing.expect(!h.ed.needs_flush);
}

test "dragcol C-03: release at (371, 29) is a 5px resize" {
    const h = try openTwo();
    defer h.deinit();
    const p = btn(h.tree.row.col.items[1]);
    try ev(h, p.x, p.y, B1);
    try ev(h, 371, 29, 0);
    try expectCols(h, at371_l, at371_r);
}

test "dragcol C-04: dragging the leftmost column inside itself does nothing" {
    const h = try openTwo();
    defer h.deinit();
    const c0 = h.tree.row.col.items[0];
    const p = btn(c0);
    try ev(h, p.x, p.y, B1);
    try ev(h, 100, 29, 0);
    try expectCols(h, split_l, split_r);
    try testing.expect(h.ed.activecol == c0);
}

test "dragcol C-05: the only column does not resize" {
    const h = try open();
    defer h.deinit();
    const c = h.tree.row.col.items[0];
    const before = c.r;
    try testing.expectEqual(proto.Rect.make(0, 20, 600, 400), before);
    const p = btn(c);
    try ev(h, p.x, p.y, B1);
    try ev(h, 200, p.y, 0);
    try testing.expectEqual(@as(usize, 1), h.tree.row.col.items.len);
    try testing.expectEqual(before, c.r);
    try testing.expect(h.ed.activecol == c);
}

test "dragcol C-06: release at (10, 29) clamps to the low bound" {
    const h = try openTwo();
    defer h.deinit();
    const p = btn(h.tree.row.col.items[1]);
    try ev(h, p.x, p.y, B1);
    try ev(h, 10, 29, 0);
    try expectCols(h, clamp_lo_l, clamp_lo_r);
}

test "dragcol C-07: release at (590, 29) clamps to the high bound" {
    const h = try openTwo();
    defer h.deinit();
    const p = btn(h.tree.row.col.items[1]);
    try ev(h, p.x, p.y, B1);
    try ev(h, 590, 29, 0);
    try expectCols(h, clamp_hi_l, clamp_hi_r);
}

test "dragcol C-08: a chord cancels, and a later C-01 drag still resizes" {
    const h = try openTwo();
    defer h.deinit();
    const c1 = h.tree.row.col.items[1];
    const p = btn(c1);
    try ev(h, p.x, p.y, B1);
    try ev(h, 200, 29, B1);
    try ev(h, 200, 29, B1 | B2);
    try ev(h, 200, 29, 0);
    try expectCols(h, split_l, split_r);
    try testing.expect(h.ed.activecol == c1);

    // Fresh press: the cancelled drag must not still own the gesture.
    try ev(h, p.x, p.y, B1);
    try ev(h, 200, 29, B1);
    try ev(h, 200, 29, 0);
    try expectCols(h, at200_l, at200_r);
}

test "dragcol C-09: dragging a window-tag button does not move layout" {
    const h = try openTwo();
    defer h.deinit();
    const w = h.tree.row.col.items[0].w.items[0];
    const wr = w.r;
    const p = Editor.center(w.tag.scrollr);
    try ev(h, p.x, p.y, B1);
    try ev(h, p.x + 80, p.y, B1);
    try ev(h, p.x + 80, p.y, 0);
    try testing.expectEqual(wr, w.r);
    try expectCols(h, split_l, split_r);
}

test "dragcol C-10: a drag across the body does not select it" {
    const h = try openTwo();
    defer h.deinit();
    const body = &h.tree.row.col.items[0].w.items[0].body;
    const q0 = body.q0;
    const q1 = body.q1;
    // (200, 200) is over the boot body, between the button and the release.
    try testing.expect(inRect(body.fr.r, 200, 200));
    const p = btn(h.tree.row.col.items[1]);
    try ev(h, p.x, p.y, B1);
    try ev(h, 200, 200, B1);
    try ev(h, 200, 29, 0);
    try testing.expectEqual(q0, body.q0);
    try testing.expectEqual(q1, body.q1);
    try expectCols(h, at200_l, at200_r);
}

test "dragcol C-11: releasing past c0's right edge shuffles it to the right" {
    const h = try openTwo();
    defer h.deinit();
    const c0 = h.tree.row.col.items[0];
    const c1 = h.tree.row.col.items[1];
    const w = c0.w.items[0];
    const p = btn(c0);
    try ev(h, p.x, p.y, B1);
    try ev(h, 400, 29, 0);
    const items = h.tree.row.col.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(c1, items[0]);
    try testing.expectEqual(c0, items[1]);
    try testing.expectEqual(shuffle_l, c1.r);
    try testing.expectEqual(shuffle_r, c0.r);
    try testing.expectEqual(@as(i32, 400), w.r.min.x);
    try testing.expectEqual(@as(i32, 600), w.r.max.x);
    try testing.expect(w.col == c0);
    try testing.expectEqual(@as(usize, 1), c0.w.items.len);
    try testing.expectEqual(w, c0.w.items[0]);
    try testing.expect(h.ed.activecol == c0);
}

test "dragcol C-12: releasing left of c0 shuffles c1 and the 3/5 split returns" {
    const h = try openTwo();
    defer h.deinit();
    const c0 = h.tree.row.col.items[0];
    const c1 = h.tree.row.col.items[1];
    const p = btn(c1);
    try ev(h, p.x, p.y, B1);
    try ev(h, -10, 29, 0);
    const items = h.tree.row.col.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(c0, items[0]);
    try testing.expectEqual(c1, items[1]);
    try expectCols(h, split_l, split_r);
    try testing.expect(h.ed.activecol == c1);
}

test "dragcol C-13: the press clears a saved mouse; a deadzone release stays clear" {
    const h = try openTwo();
    defer h.deinit();
    const w = h.tree.row.col.items[0].w.items[0];
    restoremouse.save(&h.ed, w);
    try testing.expect(h.ed.mousew == w);
    const p = btn(h.tree.row.col.items[1]);
    try ev(h, p.x, p.y, B1);
    try testing.expect(h.ed.mousew == null);
    try ev(h, p.x, p.y, 0);
    try testing.expect(h.ed.mousew == null);
    try expectCols(h, split_l, split_r);
}

test "dragcol C-14: B3 resizes like B1; a chord press does not start a drag" {
    {
        const h = try openTwo();
        defer h.deinit();
        const p = btn(h.tree.row.col.items[1]);
        try ev(h, p.x, p.y, B3);
        try ev(h, 200, 29, 0);
        try expectCols(h, at200_l, at200_r);
    }
    {
        const h = try openTwo();
        defer h.deinit();
        const p = btn(h.tree.row.col.items[1]);
        try ev(h, p.x, p.y, B1 | B2);
        try ev(h, 200, 29, 0);
        try expectCols(h, split_l, split_r);
    }
}

test "dragcol C-15: a resize warps to (208, 29); a deadzone writes no warp" {
    const a = testing.allocator;
    var sink: warp.MouseSink = .{};
    const pipe = try ninep.chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try ninep.server.Server.init(a, pipe.serverEnd(), &warp.MouseSink.ops, &sink, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pump };
    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");
    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/dev", &cl, root.fid);

    const h = try openTwo();
    defer h.deinit();
    h.ed.ns = &ns;

    try testing.expectEqual(@as(usize, 0), sink.writes);
    const c1 = h.tree.row.col.items[1];
    const p = btn(c1);
    try ev(h, p.x, p.y, B1);
    try ev(h, 200, 29, B1);
    try ev(h, 200, 29, 0);
    try expectCols(h, at200_l, at200_r);
    try testing.expectEqual(@as(usize, 1), sink.writes);
    const got = try warpPoint(&sink.last);
    try testing.expectEqual(proto.Point{ .x = 208, .y = 29 }, got);
    try testing.expectEqual(proto.Point{ .x = 208, .y = 29 }, h.ed.gesture.mouse_pt);

    const writes = sink.writes;
    const p2 = btn(c1);
    try ev(h, p2.x, p2.y, B1);
    try ev(h, p2.x, p2.y, 0);
    try testing.expectEqual(writes, sink.writes);
}

test "dragcol C-16: a shuffle that cannot reattach frees the dragged column" {
    const h = try openTwo();
    defer h.deinit();
    const survivor = h.tree.row.col.items[1];
    {
        // `dragged` is freed by the release. Do not read it after this block.
        const dragged = h.tree.row.col.items[0];
        try h.tree.row.resize(&h.ed, proto.Rect.make(0, 0, 80, 400));
        const p = btn(dragged);
        try ev(h, p.x, p.y, B1);
        try ev(h, 100, 29, 0);
    }
    try testing.expectEqual(@as(usize, 1), h.tree.row.col.items.len);
    try testing.expectEqual(survivor, h.tree.row.col.items[0]);
    try testing.expect(h.ed.activecol == null);

    const p = btn(survivor);
    try ev(h, p.x, p.y, B1);
    try ev(h, p.x, p.y, 0);
    try testing.expect(h.ed.activecol == survivor);
}

test "dragcol C-17: a B2 deadzone click adds no window or column" {
    const h = try openTwo();
    defer h.deinit();
    try testing.expectEqual(@as(usize, 2), h.tree.row.col.items.len);
    try testing.expectEqual(@as(usize, 1), nwin(h));
    const p = btn(h.tree.row.col.items[1]);
    try ev(h, p.x, p.y, B2);
    try ev(h, p.x, p.y, 0);
    try testing.expectEqual(@as(usize, 2), h.tree.row.col.items.len);
    try testing.expectEqual(@as(usize, 1), nwin(h));
}

test "dragcol C-18: dragging the row-tag button does not move columns" {
    const h = try openTwo();
    defer h.deinit();
    const p = Editor.center(h.tree.row.tag.scrollr);
    try ev(h, p.x, p.y, B1);
    try ev(h, 200, p.y, B1);
    try ev(h, 200, p.y, 0);
    try expectCols(h, split_l, split_r);
}

test "dragcol C-19: a narrow pair refuses a resize that would panic" {
    const h = try openTwo();
    defer h.deinit();
    try h.tree.row.resize(&h.ed, proto.Rect.make(0, 0, 80, 400));
    const c0 = h.tree.row.col.items[0];
    const c1 = h.tree.row.col.items[1];
    const left = c0.r;
    const right = c1.r;
    const p = btn(c1);
    // Far enough to leave the deadzone, and still inside the pair, so this is
    // a resize rather than a shuffle. The acme clamp then asks for a column
    // narrower than one glyph.
    h.ed.needs_flush = false;
    try ev(h, p.x, p.y, B1);
    try ev(h, 20, p.y, 0);
    try testing.expectEqual(@as(usize, 2), h.tree.row.col.items.len);
    try testing.expectEqual(left, c0.r);
    try testing.expectEqual(right, c1.r);
    try testing.expect(h.ed.activecol == c1);
    try testing.expect(!h.ed.needs_flush);
}
