//! #83 regression (SnarfDev1): input that arrives while a window's file is
//! still loading. acme's `textload` is synchronous (text.c:192-317), so a key
//! typed then is handled after the body is in place, lands in the loaded
//! text, and leaves the window dirty. Before the fix the key went into the
//! empty body, `installFile` wiped it and `finishTail` marked the window
//! clean: the edit was lost with no warning (SnarfDev2's repro in #83).
const std = @import("std");
const ninep = @import("ninep");
const draw = @import("draw");
const Editor = @import("Editor.zig");
const MemTree = @import("MemTree.zig");
const Window = @import("Window.zig");
const Text = @import("text/Text.zig");
const boot = @import("boot.zig");
const openfile = @import("openfile.zig");
const cmd_get = @import("exec/cmd_get.zig");

const testing = std.testing;
const a = testing.allocator;

const Rig = struct {
    fx: draw.Frame.TestFixture,
    ns: ninep.mount.Namespace,
    tree: boot.Tree,
    ed: Editor,
    m: *MemTree.Harness,

    fn create() !*Rig {
        const r = try a.create(Rig);
        errdefer a.destroy(r);
        r.fx = try draw.Frame.TestFixture.init();
        r.ns = ninep.mount.Namespace.init(a);
        r.tree = try boot.boot(a, r.fx.disp, r.fx.font, draw.proto.Rect.make(0, 0, 640, 480), .{ .ns = &r.ns });
        r.ed = Editor.init(a);
        r.tree.bind(&r.ed);
        r.m = try MemTree.Harness.create(a, &r.ns, "/m");
        return r;
    }

    fn destroy(r: *Rig) void {
        r.ed.deinit();
        r.m.destroy(a);
        r.tree.deinit();
        r.ns.deinit();
        r.fx.deinit();
        a.destroy(r);
    }

    /// One frame: the editor steps its loads, the file server answers.
    fn frame(r: *Rig) !void {
        try r.ed.frameEnd(r.fx.disp);
        try r.m.poll();
    }

    fn settle(r: *Rig) !void {
        var i: usize = 0;
        while (r.ed.loads.items.len != 0) : (i += 1) {
            if (i >= 1000) return error.LoadNeverFinished;
            try r.frame();
        }
        try r.frame();
    }

    fn open(r: *Rig, name: []const u8) !*Window {
        const w = try openfile.readFile(&r.ed, r.tree.row.col.items[0], name);
        try testing.expect(r.ed.loads.items.len != 0); // the load is in flight
        return w;
    }

    fn pointAt(r: *Rig, t: *Text) void {
        const fr = t.fr.r;
        r.ed.gesture.mouse_pt = .{ .x = @divTrunc(fr.min.x + fr.max.x, 2), .y = @divTrunc(fr.min.y + fr.max.y, 2) };
    }

    fn move(r: *Rig, t: *Text) !void {
        const fr = t.fr.r;
        try r.ed.handleMouse(.{ .x = fr.min.x + 2, .y = @divTrunc(fr.min.y + fr.max.y, 2), .buttons = 0, .msec = 0 });
    }
};

fn textOf(t: *Text, buf: []u8) []const u8 {
    return t.file.buffer.read(0, t.file.buffer.len(), buf);
}

test "#83: a key typed while the file is loading lands in the loaded text and the window is dirty" {
    const r = try Rig.create();
    defer r.destroy();
    try r.m.tree.put("f", "hello\n");
    const w = try r.open("/m/f");
    r.pointAt(&w.body);
    try r.ed.handleKey('Q'); // the body is still empty: the load has not answered
    try testing.expectEqual(@as(usize, 0), w.body.file.buffer.len()); // held, as acme's row.lk holds it
    try r.settle();
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Qhello\n", textOf(&w.body, &buf));
    try testing.expect(w.dirty);
    try testing.expect(w.body.file.mod);
    try testing.expect(w.body.file.undoSeq() != 0); // the edit can be undone
}

test "#83: input held during a load replays in order: each key goes where the pointer was" {
    const r = try Rig.create();
    defer r.destroy();
    try r.m.tree.put("f", "hello\n");
    const w = try r.open("/m/f");
    try r.move(&w.body);
    try r.ed.handleKey('Q');
    try r.move(&w.tag);
    try r.move(&w.tag); // two bare moves in a row are kept as one
    try testing.expectEqual(@as(usize, 3), r.ed.held_input.items.len);
    try r.ed.handleKey('T');
    try r.settle();
    try testing.expectEqual(@as(usize, 0), r.ed.held_input.items.len);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Qhello\n", textOf(&w.body, &buf));
    var tbuf: [256]u8 = undefined;
    const tag = textOf(&w.tag, &tbuf);
    try testing.expect(std.mem.endsWith(u8, tag, "T")); // 'T' went to the tag, at its caret
    try testing.expect(w.dirty);
}

test "#83: a key typed during a Get is kept and the window stays dirty" {
    const r = try Rig.create();
    defer r.destroy();
    try r.m.tree.put("f", "one\n");
    const w = try r.open("/m/f");
    try r.settle();
    try testing.expect(!w.dirty);
    try r.m.tree.put("f", "two\n");
    try cmd_get.get(&r.ed, &w.body, null, null, true, false, "");
    try testing.expect(r.ed.loads.items.len != 0);
    r.pointAt(&w.body);
    try r.ed.handleKey('Q');
    try r.settle();
    var buf: [64]u8 = undefined;
    const got = textOf(&w.body, &buf);
    try testing.expect(std.mem.indexOfScalar(u8, got, 'Q') != null);
    try testing.expect(std.mem.indexOf(u8, got, "two\n") != null);
    try testing.expect(w.dirty);
}

test "#83: with no load in flight a key is handled at once" {
    const r = try Rig.create();
    defer r.destroy();
    try r.m.tree.put("f", "hello\n");
    const w = try r.open("/m/f");
    try r.settle();
    r.pointAt(&w.body);
    try r.ed.handleKey('Q');
    try testing.expectEqual(@as(usize, 7), w.body.file.buffer.len());
    try testing.expectEqual(@as(usize, 0), r.ed.held_input.items.len);
}

// ---- mouse buttons during a load (SnarfDev2, PR #85 review) ----
// acme hands every mouse sample to the editor in order once row.lk is free,
// so the same samples during a load must end up the same as with no load in
// flight. Each test runs them twice: on a rig whose file has loaded (live),
// and during the load on a second rig with the same layout (held).

const Point = draw.proto.Point;

fn at(p: Point, buttons: u8) Editor.MouseEvent {
    return .{ .x = p.x, .y = p.y + 2, .buttons = buttons, .msec = 0 };
}

const Pair = struct {
    live: *Rig,
    held: *Rig,
    lw: *Window,
    hw: *Window,

    fn create(content: []const u8) !Pair {
        const live = try Rig.create();
        errdefer live.destroy();
        const held = try Rig.create();
        errdefer held.destroy();
        try live.m.tree.put("f", content);
        try held.m.tree.put("f", content);
        const lw = try live.open("/m/f");
        try live.settle();
        const hw = try held.open("/m/f");
        return .{ .live = live, .held = held, .lw = lw, .hw = hw };
    }

    fn destroy(p: Pair) void {
        p.held.destroy();
        p.live.destroy();
    }

    /// The samples, live and then held during the load; the held rig is
    /// settled after them.
    fn run(p: Pair, evs: []const Editor.MouseEvent) !void {
        for (evs) |e| try p.live.ed.handleMouse(e);
        try p.live.settle();
        try testing.expect(p.held.ed.loads.items.len != 0);
        for (evs) |e| try p.held.ed.handleMouse(e);
        try testing.expectEqual(@as(usize, 0), p.hw.body.file.buffer.len()); // still held
        try p.held.settle();
    }

    /// A point in the LOADED body (the live rig's), at rune `q`.
    fn body(p: Pair, q: usize) Point {
        return p.lw.body.fr.ptOfChar(q - p.lw.body.org);
    }
};

test "#85 review: a B1 click then a move during a load is a click, not a sweep" {
    const p = try Pair.create("hello world\nsecond line\n");
    defer p.destroy();
    const c = p.body(2);
    const away = p.body(9);
    try p.run(&.{ at(c, 0), at(c, 1), at(c, 0), at(away, 0), at(p.body(18), 0) });
    try testing.expectEqual(@as(usize, 2), p.lw.body.q0); // the live reference
    try testing.expectEqual(@as(usize, 2), p.lw.body.q1);
    try testing.expectEqual(p.lw.body.q0, p.hw.body.q0); // the caret lands at the click
    try testing.expectEqual(p.lw.body.q1, p.hw.body.q1);
}

test "#85 review: a B2 command then a move during a load runs (Newcol)" {
    const p = try Pair.create("hello\n");
    defer p.destroy();
    const ncol = p.live.tree.row.col.items.len;
    const newcol = p.live.tree.row.tag.fr.ptOfChar(2); // inside "Newcol"
    const away = p.body(3);
    try p.run(&.{ at(newcol, 0), at(newcol, 2), at(newcol, 0), at(away, 0), at(p.body(1), 0) });
    try testing.expectEqual(ncol + 1, p.live.tree.row.col.items.len); // the live reference
    try testing.expectEqual(ncol + 1, p.held.tree.row.col.items.len); // the command ran
}

test "#85 review: a B1 drag during a load selects what the same drag selects live" {
    const p = try Pair.create("hello world\nsecond line\n");
    defer p.destroy();
    const b = 1;
    try p.run(&.{
        at(p.body(1), 0),
        at(p.body(1), b), // B1 down
        at(p.body(3), b),
        at(p.body(5), b),
        at(p.body(15), b), // onto the second line
        at(p.body(15), 0), // B1 up
        at(p.body(20), 0),
        at(p.body(21), 0),
    });
    try testing.expectEqual(@as(usize, 1), p.lw.body.q0); // the live reference
    try testing.expectEqual(@as(usize, 15), p.lw.body.q1);
    try testing.expectEqual(p.lw.body.q0, p.hw.body.q0);
    try testing.expectEqual(p.lw.body.q1, p.hw.body.q1);
}

test "#85 review: bare moves still coalesce, but a release is never replaced" {
    const r = try Rig.create();
    defer r.destroy();
    try r.m.tree.put("f", "hello\n");
    const w = try r.open("/m/f");
    const pt = Point{ .x = w.body.fr.r.min.x + 2, .y = w.body.fr.r.min.y + 2 };
    try r.ed.handleMouse(at(pt, 1));
    try r.ed.handleMouse(at(pt, 0)); // the release
    try r.ed.handleMouse(at(pt, 0)); // a move after it: kept apart
    try testing.expectEqual(@as(usize, 3), r.ed.held_input.items.len);
    for (0..1000) |_| try r.ed.handleMouse(at(pt, 0)); // bare moves: one slot
    try testing.expectEqual(@as(usize, 3), r.ed.held_input.items.len);
    try r.settle();
}
