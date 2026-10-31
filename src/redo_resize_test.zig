//! #67 — Redo right after a window resize (SnarfDev2).
//!
//! Regression guards, not a repro: no headless trigger was found (see #67). Every
//! scenario drives B2 Undo/Redo through `Editor.handleMouse` exactly as the X11
//! pump does, perturbs the layout (window resize, column resize, a new
//! window, a focus change, a half-finished B1 sweep cut short by the resize)
//! and then checks that B2 Redo on the same tag restores the body (exec.c undo():
//! Redo acts on the window whose tag was executed, `et->w`).
const std = @import("std");
const core = @import("core");
const draw = @import("draw");
const ninep = @import("ninep");
const dev = @import("dev");
const testing = std.testing;

fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

const Scene = struct {
    hb: dev.draw_backend.HeadlessBackend,
    dd: dev.draw.DevDraw,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,
    d: *draw.Display,
    font: draw.Font,
    tree: core.boot.Tree,
    ed: core.Editor,
    msec: u32 = 1000,

    fn init(s: *Scene, w: u32, h: u32) !void {
        const alloc = testing.allocator;
        s.* = undefined;
        s.msec = 1000;
        s.hb = try dev.draw_backend.HeadlessBackend.init(alloc, w, h);
        s.dd = dev.draw.DevDraw.init(alloc, s.hb.backend());
        s.pipe = try ninep.chan.Pipe.init(alloc, 16384);
        s.srv = try ninep.server.Server.init(alloc, s.pipe.serverEnd(), &dev.draw.DevDraw.ops, &s.dd, 8192);
        s.cl = try ninep.Client.init(alloc, s.pipe.clientEnd(), 8192);
        s.cl.pump = .{ .ctx = &s.srv, .run = pumpServer };
        _ = try s.cl.version(8192);
        const root = try s.cl.attach("larry", "");
        s.d = try draw.Display.init(alloc, &s.cl, root.fid);
        s.font = try draw.Font.init(alloc, s.d, draw.Font.default_subfont);
        s.tree = try core.boot.boot(alloc, s.d, &s.font, draw.proto.Rect.make(0, 0, @intCast(w), @intCast(h)), .{ .win_name = "scratch", .body = "" });
        s.ed = core.Editor.init(alloc);
        s.ed.row = s.tree.row;
        s.ed.but2col = s.tree.chrome.but2col;
        s.ed.but3col = s.tree.chrome.but3col;
        try s.ed.frameEnd(s.d);
    }
    fn deinit(s: *Scene) void {
        s.ed.deinit();
        s.tree.deinit();
        s.font.deinit();
        s.d.deinit();
        s.cl.deinit();
        s.srv.deinit();
        s.pipe.deinit();
        s.dd.deinit();
        s.hb.deinit();
    }
    fn mouse(s: *Scene, x: i32, y: i32, b: u8) !void {
        s.msec += 50;
        try s.ed.handleMouse(.{ .x = x, .y = y, .buttons = b, .msec = s.msec });
        try s.ed.frameEnd(s.d);
    }
    fn click(s: *Scene, p: draw.proto.Point, b: u8) !void {
        try s.mouse(p.x, p.y, b);
        try s.mouse(p.x, p.y, 0);
    }
    fn typeStr(s: *Scene, str: []const u8) !void {
        for (str) |c| try s.ed.handleKey(c);
        try s.ed.frameEnd(s.d);
    }
    fn resize(s: *Scene, w: u32, h: u32) !void {
        try s.hb.resize(w, h);
        s.dd.noteResize(dev.draw_backend.Rect.init(0, 0, @intCast(w), @intCast(h)));
        const r = try s.d.getWindow();
        try treeResize(&s.tree, &s.ed, r);
        s.ed.needs_flush = true;
        try s.ed.frameEnd(s.d);
    }
};

/// #64 (#53) threads the Editor through `Tree.resize`/`Row.add`; stay
/// source-compatible with main and with #64.
fn treeResize(tree: *core.boot.Tree, ed: *core.Editor, r: draw.proto.Rect) !void {
    const F = @TypeOf(core.boot.Tree.resize);
    if (@typeInfo(F).@"fn".params.len == 3) try tree.resize(ed, r) else try tree.resize(r);
}
fn rowAdd(row: anytype, ed: *core.Editor) !?*core.Column {
    const R = @TypeOf(row.*);
    if (@typeInfo(@TypeOf(R.add)).@"fn".params.len == 3) return row.add(ed, -1);
    return row.add(-1);
}

fn tagStr(w: *core.Window, buf: []u8) []const u8 {
    return w.tag.file.buffer.read(0, w.tag.file.buffer.len(), buf);
}
fn bodyStr(w: *core.Window, buf: []u8) []const u8 {
    return w.body.file.buffer.read(0, w.body.file.buffer.len(), buf);
}
/// Point on char `off` of `word` in w's tag (null if absent).
fn tagWordPt(w: *core.Window, word: []const u8, off: usize) ?draw.proto.Point {
    var buf: [512]u8 = undefined;
    const tg = tagStr(w, &buf);
    const i = std.mem.indexOf(u8, tg, word) orelse return null;
    const p = w.tag.fr.ptOfChar(i + off - w.tag.org);
    return .{ .x = p.x + 2, .y = p.y + 4 };
}

const Perturb = enum { none, win_resize, win_grow_only, col_resize, new_window, focus_other, b1_sweep_cut_by_resize };

const text1 = "banana alpha gamma\nsecond line (paren text) here";

fn clickColNew(s: *Scene, c: *core.Column) !void {
    var cb: [256]u8 = undefined;
    const ctag = c.tag.file.buffer.read(0, c.tag.file.buffer.len(), &cb);
    const i = std.mem.indexOf(u8, ctag, "New").?;
    const pt = c.tag.fr.ptOfChar(i + 1 - c.tag.org);
    try s.click(.{ .x = pt.x + 2, .y = pt.y + 4 }, 2);
}

/// Type, Edit, Undo/Redo/Undo/Undo (body empty, two redos queued), Look, then
/// `p`, then B2 Redo on the window's own tag: body must be the typed text again.
fn scenario(p: Perturb) !void {
    var s: Scene = undefined;
    try s.init(1024, 768);
    defer s.deinit();
    _ = (try rowAdd(s.tree.row, &s.ed)).?;
    try s.ed.frameEnd(s.d);
    const w = s.tree.row.col.items[0].w.items[0];
    const bp = w.body.fr.r.min;
    try s.click(.{ .x = bp.x + 5, .y = bp.y + 5 }, 1);
    try s.typeStr(text1);
    try w.tag.insertAt(w.tag.file.buffer.len(), " Edit ,s/a/A/g", true);
    try s.ed.frameEnd(s.d);
    const p0 = tagWordPt(w, "Edit", 0).?;
    const p1 = tagWordPt(w, "/g", 2).?;
    try s.mouse(p0.x, p0.y, 2);
    try s.mouse(p1.x, p1.y, 2);
    try s.mouse(p1.x, p1.y, 0);
    var b: [512]u8 = undefined;
    try testing.expectEqualStrings("bAnAnA AlphA gAmmA\nsecond line (pAren text) here", bodyStr(w, &b));
    try s.click(tagWordPt(w, "Undo", 2).?, 2);
    try s.click(tagWordPt(w, "Redo", 2).?, 2);
    try s.click(tagWordPt(w, "Undo", 2).?, 2);
    try s.click(tagWordPt(w, "Undo", 2).?, 2);
    try testing.expectEqualStrings("", bodyStr(w, &b));
    try s.click(tagWordPt(w, "Look", 1).?, 2);

    switch (p) {
        .none => {},
        .win_resize => {
            try s.resize(1000, 760);
            try s.resize(1024, 768);
        },
        .win_grow_only => try s.resize(1280, 900),
        .col_resize => {
            const c = s.tree.row.col.items[0];
            var r = c.r;
            r.max.x -= 120;
            try c.resize(r);
            try s.ed.frameEnd(s.d);
        },
        .new_window => {
            try clickColNew(&s, s.tree.row.col.items[0]);
            try testing.expectEqual(@as(usize, 2), s.tree.row.col.items[0].w.items.len);
            try s.resize(1000, 760);
        },
        .focus_other => {
            try clickColNew(&s, s.tree.row.col.items[1]);
            const w2 = s.tree.row.col.items[1].w.items[0];
            const q = w2.body.fr.r.min;
            try s.click(.{ .x = q.x + 5, .y = q.y + 5 }, 1);
            try s.resize(1000, 760);
            try s.resize(1024, 768);
        },
        .b1_sweep_cut_by_resize => {
            // B1 down on the tag, the resize lands mid-sweep, B1 comes up after.
            const q = tagWordPt(w, "Look", 0).?;
            try s.mouse(q.x, q.y, 1);
            try s.resize(1000, 760);
            try s.mouse(q.x + 9, q.y, 1);
            try s.mouse(q.x + 9, q.y, 0);
            try testing.expect(s.ed.gesture.mouse_state == .idle);
        },
    }
    // The Redo point is re-read after the perturbation (the tag may have moved).
    try s.click(tagWordPt(w, "Redo", 2).?, 2);
    try testing.expectEqualStrings(text1, bodyStr(w, &b));
}

test "#67 RR-01: B2 Redo after Undo, no resize (baseline)" {
    try scenario(.none);
}
test "#67 RR-02: B2 Redo after a window shrink+grow" {
    try scenario(.win_resize);
}
test "#67 RR-03: B2 Redo after a window grow only" {
    try scenario(.win_grow_only);
}
test "#67 RR-04: B2 Redo after a column resize" {
    try scenario(.col_resize);
}
test "#67 RR-05: B2 Redo after New splits the column, then a window resize" {
    try scenario(.new_window);
}
test "#67 RR-06: B2 Redo after focus moved to the other column, then a resize" {
    try scenario(.focus_other);
}
test "#67 RR-07: B2 Redo after a B1 sweep that a resize interrupted" {
    try scenario(.b1_sweep_cut_by_resize);
}
