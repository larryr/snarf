//! Acceptance tests for issue #13 — small builtins Sort, Zerox, Kill, Exit.
//! Requirements: R-EDIT-02 (tag words), R-EDIT-11 (shared undo across views),
//! R-EDIT-17 + roadmap process rule 1 (ctl verb per builtin — added once the
//! verbs exist). Plan: `notes/snarfdev2/test-plans/M1-13-builtins.md`.
//! PM rule (2026-10-14, Q4): ACME behaviour — two-strike Exit (wind.c:666
//! winclean via rowclean), colsort order (cols.c), Zerox as acme allows
//! (exec.c zeroxx: refused on a directory window).
//!
//! LANDED-FLAG PATTERN (as in restoremouse_test.zig): each builtin has a flag.
//! Flag false + word absent from `exectab` ⇒ SKIP. Flag false + word present
//! ⇒ FAIL ("flip the flag"), so landing PRs must turn these tests on.
const std = @import("std");
const testing = std.testing;
const draw = @import("draw");
const boot = @import("../boot.zig");
const Editor = @import("../Editor.zig");
const Window = @import("../Window.zig");
const Text = @import("../text/Text.zig");
const builtins = @import("builtins.zig");
const Chrome = @import("../Chrome.zig");
const Frame = draw.Frame;
const proto = draw.proto;

const exit_landed = true;
const sort_landed = true;
const zerox_landed = false;
const kill_landed = true;

fn entry(comptime name: []const u8, comptime landed: bool) !*const builtins.Entry {
    for (&builtins.exectab) |*e| {
        if (std.mem.eql(u8, e.name, name)) {
            if (!landed) {
                std.debug.print("builtins_m1_test: {s} is in exectab; set its landed flag\n", .{name});
                return error.UnexpectedPassFlipFlag;
            }
            return e;
        }
    }
    if (landed) return error.BuiltinMissing;
    return error.SkipZigTest; // expected-fail until #13 lands this word
}

fn run(ed: *Editor, e: *const builtins.Entry, et: *Text, arg: []const u8) !void {
    try e.fn_(ed, et, ed.seltext, null, e.flag1, e.flag2, arg);
}

const Rig = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,

    fn init(h: *Rig) !void {
        h.fx = try Frame.TestFixture.init();
        h.tree = try boot.boot(testing.allocator, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 640, 480), .{
            .win_name = "/tmp/c.txt",
            .body = "cee\n",
        });
        h.ed = Editor.init(testing.allocator);
        h.tree.bind(&h.ed);
    }
    fn deinit(h: *Rig) void {
        h.ed.deinit();
        h.tree.deinit();
        h.fx.deinit();
    }
    fn names(h: *Rig, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        for (h.tree.row.col.items[0].w.items, 0..) |win, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(win.body.file.name.items);
        }
        return w.buffered();
    }
};

test "builtins #13 BI-01/02: Exit two-strikes on a dirty window (acme rowclean/winclean)" {
    const e = try entry("Exit", exit_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = h.tree.row.col.items[0].w.items[0];
    w.dirty = true;
    try run(&h.ed, e, &h.tree.row.tag, "");
    // First strike: warns naming the modified file, does not quit.
    try testing.expect(std.mem.indexOf(u8, h.ed.warningText(), "/tmp/c.txt") != null);
    try testing.expect(std.mem.indexOf(u8, h.ed.warningText(), "modified") != null);
    try testing.expect(!h.ed.exit_requested);
    // Second strike succeeds (winclean cleared the strike): the quit request
    // is `Editor.exit_requested` (acme's cexit), which the host's loop ends on.
    try run(&h.ed, e, &h.tree.row.tag, "");
    try testing.expect(h.ed.exit_requested and h.ed.exitReady());
}

test "builtins #13 BI-01: Exit with every window clean quits at once" {
    const e = try entry("Exit", exit_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    try run(&h.ed, e, &h.tree.row.col.items[0].w.items[0].body, "");
    try testing.expect(h.ed.exit_requested);
    try testing.expect(!h.ed.warningsPending());
}

test "builtins #13 BI-03: Sort orders a column's windows by name (acme colsort)" {
    const e = try entry("Sort", sort_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.tree.addWindow("/tmp/b.txt", "");
    _ = try h.tree.addWindow("/tmp/a.txt", "");
    const c = h.tree.row.col.items[0];
    try run(&h.ed, e, &c.tag, "");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/a.txt,/tmp/b.txt,/tmp/c.txt", try h.names(&buf));
}

test "builtins #13 BI-03: Sort keeps each window's height; the last takes the rest (cols.c:313-322)" {
    const e = try entry("Sort", sort_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.tree.addWindow("/tmp/b.txt", "");
    _ = try h.tree.addWindow("/tmp/a.txt", "");
    const c = h.tree.row.col.items[0];
    var dy: [3]i32 = undefined; // heights keyed by the final (sorted) slot
    for (c.w.items) |w| {
        const slot: usize = switch (w.body.file.name.items[5]) {
            'a' => 0,
            'b' => 1,
            else => 2,
        };
        dy[slot] = w.r.max.y - w.r.min.y;
    }
    try run(&h.ed, e, &c.w.items[1].body, ""); // from a window body: et->col
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/a.txt,/tmp/b.txt,/tmp/c.txt", try h.names(&buf));
    const ws = c.w.items;
    // /tmp/b.txt was a middle window and stays one: exactly its height. The
    // old last window (/tmp/a.txt) carried the column's leftover pixels; it is
    // re-laid without `keepextra` (cols.c:322 winresize(…, FALSE, …)), which
    // trims the body to whole lines, so it keeps its height to within a line.
    try testing.expectEqual(dy[1], ws[1].r.max.y - ws[1].r.min.y);
    const a_dy = ws[0].r.max.y - ws[0].r.min.y;
    try testing.expect(a_dy <= dy[0] and a_dy > dy[0] - ws[0].chrome.font.height);
    try testing.expectEqual(c.tag.fr.r.max.y + Chrome.border, ws[0].r.min.y); // Border band above each
    try testing.expectEqual(ws[0].r.max.y + Chrome.border, ws[1].r.min.y);
    try testing.expectEqual(ws[1].r.max.y + Chrome.border, ws[2].r.min.y);
    try testing.expectEqual(c.r.max.y, ws[2].r.max.y);
}

test "builtins #13 BI-04: Sort is colcmp order — a name before its extensions, '/' by code point, equal names stable" {
    const e = try entry("Sort", sort_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    // boot's window is /tmp/c.txt.
    const d1 = try h.tree.addWindow("/tmp/c.txt", ""); // a second, equal name
    _ = try h.tree.addWindow("/tmp/", ""); // a directory window: no special case
    _ = try h.tree.addWindow("/tmp/c", ""); // proper prefix of /tmp/c.txt
    _ = try h.tree.addWindow("/tmp/C.txt", ""); // upper case sorts first
    const c = h.tree.row.col.items[0];
    c.w.items[2].isdir = true;
    const first = c.w.items[0];
    try run(&h.ed, e, &c.tag, "");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/,/tmp/C.txt,/tmp/c,/tmp/c.txt,/tmp/c.txt", try h.names(&buf));
    try testing.expect(c.w.items[3] == first and c.w.items[4] == d1);
}

test "builtins #13: Sort from the row tag does nothing (no et->col, exec.c:421)" {
    const e = try entry("Sort", sort_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.tree.addWindow("/tmp/a.txt", "");
    try run(&h.ed, e, &h.tree.row.tag, "");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/c.txt,/tmp/a.txt", try h.names(&buf));
}

test "builtins #13 BI-05/06: Zerox opens a second view sharing the same File" {
    const e = try entry("Zerox", zerox_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const c = h.tree.row.col.items[0];
    const w = c.w.items[0];
    const before = c.w.items.len;
    try run(&h.ed, e, &w.tag, "");
    try testing.expectEqual(before + 1, c.w.items.len);
    var other: ?*Window = null;
    for (c.w.items) |x| if (x != w) {
        other = x;
    };
    try testing.expect(other.?.body.file == w.body.file); // one File, two views
    try testing.expectEqualStrings(w.body.file.name.items, other.?.body.file.name.items);
}

test "builtins #13 BI-10: Zerox on a directory window is refused (acme zeroxx)" {
    const e = try entry("Zerox", zerox_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const c = h.tree.row.col.items[0];
    const w = c.w.items[0];
    w.isdir = true;
    const before = c.w.items.len;
    try run(&h.ed, e, &w.tag, "");
    try testing.expectEqual(before, c.w.items.len);
    try testing.expect(std.mem.indexOf(u8, h.ed.warningText(), "Zerox illegal") != null);
}

test "builtins #13 BI-11: Kill with nothing running is a silent no-op" {
    const e = try entry("Kill", kill_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    try run(&h.ed, e, &h.tree.row.tag, "");
    try testing.expect(!h.ed.warningsPending());
}

test "builtins #13: Kill <names> warns once per name it cannot find (acme.c:745)" {
    const e = try entry("Kill", kill_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    try run(&h.ed, e, &h.tree.row.tag, "mk  win\tcc");
    try testing.expectEqualStrings("Kill: no process mk\nKill: no process win\nKill: no process cc\n", h.ed.warningText());
}

test "builtins #13: Kill takes the 2-1 chord argument first (exec.c:1250-1252)" {
    const e = try entry("Kill", kill_landed);
    var h: Rig = undefined;
    try h.init();
    defer h.deinit();
    const w = h.tree.row.col.items[0].w.items[0];
    try w.body.setSelect(0, 3); // "cee"
    try e.fn_(&h.ed, &h.tree.row.tag, null, &w.body, e.flag1, e.flag2, "mk");
    try testing.expectEqualStrings("Kill: no process cee\nKill: no process mk\n", h.ed.warningText());
}

test "builtins #13: none of Sort/Zerox/Kill/Exit is wired yet (baseline guard)" {
    // Documents the 2026-10-14 baseline; becomes moot as flags flip.
    inline for (.{ "Sort", "Zerox", "Kill", "Exit" }) |n| {
        var found = false;
        for (&builtins.exectab) |*x| found = found or std.mem.eql(u8, x.name, n);
        const landed = comptime blk: {
            if (std.mem.eql(u8, n, "Sort")) break :blk sort_landed;
            if (std.mem.eql(u8, n, "Zerox")) break :blk zerox_landed;
            if (std.mem.eql(u8, n, "Kill")) break :blk kill_landed;
            break :blk exit_landed;
        };
        if (!landed) try testing.expect(!found);
    }
}
