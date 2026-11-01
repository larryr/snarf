//! Headless acceptance tests for issue #45: warp the pointer to the focused
//! window (acme parity), plus the zero-travel round trip with #9's Del
//! warp-back. Decision (Larry via SnarfProdd, 2026-10-30): opening or focusing
//! a new window, `+Errors` included, warps the pointer into it, and Del warps
//! back. The `+Errors` opt-out is out of scope.
//! Requirement: R-EDIT-25. Test plan:
//! `notes/snarfdev2/test-plans/M3-45-warp-focus.md` (WF-01..12).
//!
//! acme: `coladd` (cols.c:150-154) does `savemouse(w)` and then
//! `moveto(mousectl, addpt(w->tag.scrollr.max, Pt(3, 3)))`; `colclose`
//! (cols.c:178) does `restoremouse(w)`.
//!
//! EXPECTED-FAIL MECHANISM (same as restoremouse_test.zig). Until #45 lands,
//! `warp_focus_landed` is false. A test of unimplemented behaviour calls
//! `xfail`: it SKIPS while the assertion fails, so `zig build test` stays
//! green, and FAILS with `error.UnexpectedPassFlipFlag` once the assertion
//! holds, which tells whoever lands #45 to flip the flag. Already-implemented
//! behaviour (WF-05/06/09/10) is asserted directly.
//!
//! Rig: a booted row with `warp.MouseSink` mounted at `/dev` over a real 9P
//! pipe (as restoremouse_test.zig, openfile.zig T12 and look.zig T9). A
//! headless host doesn't move a pointer, so after a warp the test sets
//! `gesture.mouse_pt` to the warped point, which is what a native host reports
//! next.
const std = @import("std");
const testing = std.testing;
const ninep = @import("ninep");
const draw = @import("draw");
const boot = @import("boot.zig");
const warp = @import("warp.zig");
const errors = @import("errors.zig");
const openfile = @import("openfile.zig");
const cmd_window = @import("exec/cmd_window.zig");
const Editor = @import("Editor.zig");
const Window = @import("Window.zig");
const Column = @import("Column.zig");
const Frame = draw.Frame;
const proto = draw.proto;

/// Flip to true in the PR that lands #45.
const warp_focus_landed = true;

fn xfail(ok: bool) !void {
    if (warp_focus_landed) {
        if (!ok) return error.TestUnexpectedResult;
        return;
    }
    if (ok) {
        std.debug.print("warp_focus_test: behaviour now passes; set warp_focus_landed = true\n", .{});
        return error.UnexpectedPassFlipFlag;
    }
    return error.SkipZigTest; // expected-fail until #45
}

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

const main_name = "/home/larry/main.zig";

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
            .win_name = main_name,
            .body = "main body\nline two\nline three\n",
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

    fn mainWin(h: *Rig) *Window {
        return errors.lookFile(h.tree.row, main_name).?;
    }

    /// A point on the main window's first body line: where the user is
    /// before anything pops up.
    fn p0(h: *Rig) proto.Point {
        const b = h.mainWin().body.fr.r;
        return .{ .x = b.min.x + 5, .y = b.min.y + 3 };
    }

    /// Run the `New` builtin from the main window's tag (a B2 on "New").
    fn new(h: *Rig) !*Window {
        const c = h.mainWin().col.?;
        const before = try testing.allocator.dupe(*Window, c.w.items);
        defer testing.allocator.free(before);
        try cmd_window.new(&h.ed, &h.mainWin().tag, null, null, false, false, "");
        return newest(c, before);
    }

    /// The `Del` builtin, executed from `w`'s own tag with the pointer at `at`.
    fn del(h: *Rig, w: *Window, at: proto.Point) !void {
        h.ed.gesture.mouse_pt = at;
        try cmd_window.del(&h.ed, &w.tag, null, null, false, false, "");
    }

    /// The last `/dev/mouse` write as a point, or null if none was made.
    fn last(h: *Rig) ?proto.Point {
        if (h.sink.writes == 0) return null;
        return parse(&h.sink.last);
    }

    /// What a native host does after a warp: the pointer is now there.
    fn followWarp(h: *Rig) void {
        if (h.last()) |p| h.ed.gesture.mouse_pt = p;
    }

    fn lastInside(h: *Rig, w: *Window, writes_before: usize) bool {
        if (h.sink.writes <= writes_before) return false;
        const p = h.last() orelse return false;
        return ptIn(w.r, p);
    }
};

fn newest(c: *Column, before: []const *Window) !*Window {
    outer: for (c.w.items) |w| {
        for (before) |b| if (b == w) continue :outer;
        return w;
    }
    return error.TestUnexpectedResult; // no window was created
}

fn parse(rec: *const [warp.rec_len]u8) ?proto.Point {
    if (rec[0] != 'm') return null;
    var it = std.mem.tokenizeScalar(u8, rec[1..], ' ');
    const xs = it.next() orelse return null;
    const ys = it.next() orelse return null;
    const x = std.fmt.parseInt(i32, xs, 10) catch return null;
    const y = std.fmt.parseInt(i32, ys, 10) catch return null;
    return .{ .x = x, .y = y };
}

fn ptIn(r: proto.Rect, p: proto.Point) bool {
    return p.x >= r.min.x and p.x < r.max.x and p.y >= r.min.y and p.y < r.max.y;
}

fn eqPt(a: proto.Point, b: proto.Point) bool {
    return a.x == b.x and a.y == b.y;
}

test "warp_focus: the MouseSink record parses back to the warped point (rig self-check)" {
    var rec: [warp.rec_len]u8 = undefined;
    warp.format(123, -4, &rec);
    const p = parse(&rec).?;
    try testing.expectEqual(@as(i32, 123), p.x);
    try testing.expectEqual(@as(i32, -4), p.y);
}

test "warp_focus WF-01: New warps the pointer into the new window" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    h.ed.gesture.mouse_pt = h.p0();
    const before = h.sink.writes;
    const w = try h.new();
    try xfail(h.lastInside(w, before));
}

test "warp_focus WF-02: opening a not-yet-open file warps into its new window" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    h.ed.gesture.mouse_pt = h.p0();
    const before = h.sink.writes;
    // jump=false: the selection warp (look.c:897) is suppressed, so only the
    // creation warp (cols.c:153) can land a write here.
    const w = try openfile.openFile(&h.ed, &h.mainWin().body, .{ .name = "/home/larry/wf02.txt", .jump = false });
    try xfail(h.lastInside(w, before));
}

test "warp_focus WF-03: +Errors creation warps into +Errors (no opt-out)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    h.ed.gesture.mouse_pt = h.p0();
    const before = h.sink.writes;
    const w = try errors.errorWin(&h.ed, "/home/larry");
    try xfail(h.lastInside(w, before));
}

test "warp_focus WF-04: the creation warp lands at acme's point, tag.scrollr.max + (3,3)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    h.ed.gesture.mouse_pt = h.p0();
    const w = try h.new();
    const want: proto.Point = .{ .x = w.tag.scrollr.max.x + 3, .y = w.tag.scrollr.max.y + 3 };
    const got = h.last();
    try xfail(got != null and eqPt(got.?, want));
}

test "warp_focus WF-05: focusing an already-open window (openFile, jump) warps into it" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const other = try h.tree.addWindow("/home/larry/other.zig", "other body\n");
    h.ed.gesture.mouse_pt = h.p0();
    const before = h.sink.writes;
    const w = try openfile.openFile(&h.ed, &h.mainWin().body, .{ .name = "/home/larry/other.zig", .jump = true });
    try testing.expect(w == other); // no new window: focus, not open
    try testing.expect(h.lastInside(other, before));
}

test "warp_focus WF-06: focusing with an invalid address suppresses the warp (look.c:887)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.tree.addWindow("/home/larry/other.zig", "one\ntwo\n");
    h.ed.gesture.mouse_pt = h.p0();
    const before = h.sink.writes;
    const bad = [_]u21{ '9', '9' }; // line 99 of a two-line file: out of range
    _ = try openfile.openFile(&h.ed, &h.mainWin().body, .{ .name = "/home/larry/other.zig", .addr = &bad, .jump = true });
    try testing.expectEqual(before, h.sink.writes);
}

test "warp_focus WF-07: zero-travel round trip — New warps in, Del returns exactly to P0" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const P0 = h.p0();
    h.ed.gesture.mouse_pt = P0;
    const w0 = h.sink.writes;
    const w = try h.new();
    // Exact-ACME restore has no pointer-inside gate, so Del alone would land on
    // P0 even with no warp-in. The round trip needs both halves.
    const warped_in = h.lastInside(w, w0);
    h.followWarp();
    const before = h.sink.writes;
    try h.del(w, h.ed.gesture.mouse_pt);
    const got = h.last();
    try xfail(warped_in and h.sink.writes > before and got != null and eqPt(got.?, P0));
}

test "warp_focus WF-08: zero-travel round trip — +Errors warps in, Del returns exactly to P0" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const P0 = h.p0();
    h.ed.gesture.mouse_pt = P0;
    const w0 = h.sink.writes;
    const w = try errors.errorWin(&h.ed, "/home/larry");
    const warped_in = h.lastInside(w, w0);
    h.followWarp();
    const before = h.sink.writes;
    try h.del(w, h.ed.gesture.mouse_pt);
    const got = h.last();
    try xfail(warped_in and h.sink.writes > before and got != null and eqPt(got.?, P0));
}

test "warp_focus WF-13: nested round trip uses ACME's single save slot — Del inner returns to the outer pop-up, Del outer then stays put" {
    // SnarfProdd 2026-10-31: restoremouse is exact ACME (util.c:383-402). One
    // slot, no stack: opening N from inside +Errors overwrites +Errors' save,
    // so only the innermost Del warps back, and the outer Del does nothing.
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    h.ed.gesture.mouse_pt = h.p0();
    const we = h.sink.writes;
    const e = try errors.errorWin(&h.ed, "/home/larry");
    const e_in = h.lastInside(e, we);
    h.followWarp(); // pointer now in +Errors (after #45)
    const pe = h.ed.gesture.mouse_pt;
    const wn = h.sink.writes;
    const n = try h.new();
    const n_in = h.lastInside(n, wn);
    h.followWarp(); // pointer now in the New window (after #45)
    const w0 = h.sink.writes;
    try h.del(n, h.ed.gesture.mouse_pt);
    const back = h.last();
    const inner_ok = h.sink.writes == w0 + 1 and back != null and eqPt(back.?, pe);
    h.followWarp();
    const pe_in_e = ptIn(e.r, pe); // the pointer is back inside +Errors
    const w1 = h.sink.writes;
    try h.del(e, h.ed.gesture.mouse_pt); // frees e
    const outer_ok = h.sink.writes == w1; // slot already cleared: no warp to P0
    try xfail(e_in and n_in and inner_ok and outer_ok and pe_in_e);
}

test "warp_focus WF-09: user left the new window before Del — still warps back to P0 (exact ACME, no gate)" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const P0 = h.p0();
    h.ed.gesture.mouse_pt = P0;
    const w = try h.new();
    h.followWarp();
    const away: proto.Point = .{ .x = 1, .y = 1 }; // row tag, outside w
    try testing.expect(!ptIn(w.r, away));
    const before = h.sink.writes;
    try h.del(w, away);
    const got = h.last();
    try testing.expect(h.sink.writes == before + 1 and got != null and eqPt(got.?, P0)); // landed in #43 @ e303142
}

test "warp_focus WF-10: no /dev/mouse (browser/headless) — New, +Errors and Del never error" {
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    h.ed.ns = null;
    h.ed.gesture.mouse_pt = h.p0();
    const w = try h.new();
    try h.del(w, .{ .x = w.r.min.x + 10, .y = w.r.min.y + 10 });
    const e = try errors.errorWin(&h.ed, "/home/larry");
    try h.del(e, .{ .x = e.r.min.x + 10, .y = e.r.min.y + 10 });
    try testing.expectEqual(@as(usize, 0), h.sink.writes);
}
