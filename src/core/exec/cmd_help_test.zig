//! Issue #88: the Help builtin and the +Help window.
//! Plan: notes/grok/issue-88-help.md (tests H-01 .. H-10).
//!
//! Help is swept from the row tag. The test appends the word; the command
//! must leave that tag, and the focused body, as they were.
const std = @import("std");
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const Buffer = @import("../Buffer.zig");
const Window = @import("../Window.zig");
const boot = @import("../boot.zig");
const errors = @import("../errors.zig");
const exec = @import("exec.zig");
const help = @import("cmd_help.zig");
const builtins = @import("builtins.zig");

const seed = "alpha beta\n";

const Scene = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,

    fn init(body: []const u8) !*Scene {
        const a = testing.allocator;
        const h = try a.create(Scene);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        errdefer h.fx.deinit();
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 800, 500), .{
            .win_name = "file.txt",
            .body = body,
        });
        errdefer h.tree.deinit();
        h.ed = Editor.init(a);
        h.ed.row = h.tree.row;
        return h;
    }
    fn deinit(h: *Scene) void {
        h.ed.deinit();
        h.tree.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn win0(h: *Scene) *Window {
        return h.tree.row.col.items[0].w.items[0];
    }
};

/// `exec.zig`'s `Scene.bodyText`: the Text's buffer as UTF-8. Caller frees.
fn bodyText(t: *Text) ![]u8 {
    const n = t.file.buffer.len();
    if (n == 0) return testing.allocator.alloc(u8, 0);
    const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer testing.allocator.free(dest);
    return testing.allocator.dupe(u8, t.file.buffer.read(0, n, dest));
}

/// Absolute rune range of the first ASCII `word` in `t`. ASCII, so a rune
/// offset equals a byte offset.
fn wordRange(t: *Text, word: []const u8) error{WordMissing}![2]usize {
    const nc = t.file.buffer.len();
    var i: usize = 0;
    outer: while (i + word.len <= nc) : (i += 1) {
        for (word, 0..) |ch, j| {
            if (t.file.buffer.runeAt(i + j) != ch) continue :outer;
        }
        return .{ i, i + word.len };
    }
    return error.WordMissing;
}

fn appendHelpWord(h: *Scene) !void {
    const tag = &h.tree.row.tag;
    try tag.insertAt(tag.file.buffer.len(), " Help", true);
}

fn runNewcol(h: *Scene) !void {
    const tag = &h.tree.row.tag;
    const rng = try wordRange(tag, "Newcol");
    try exec.execute(&h.ed, tag, rng[0], rng[1], null);
}

/// Snapshot the row tag (after " Help" is on it), sweep that word, and require
/// the tag and the focused body to come back unchanged.
fn runHelp(h: *Scene, focus: *Text) !void {
    const tag = &h.tree.row.tag;
    const tag_before = try bodyText(tag);
    defer testing.allocator.free(tag_before);
    const body_before = try bodyText(focus);
    defer testing.allocator.free(body_before);

    h.ed.seltext = focus;
    const rng = try wordRange(tag, "Help");
    try exec.execute(&h.ed, tag, rng[0], rng[1], null);

    const tag_after = try bodyText(tag);
    defer testing.allocator.free(tag_after);
    try testing.expectEqualStrings(tag_before, tag_after);
    const body_after = try bodyText(focus);
    defer testing.allocator.free(body_after);
    try testing.expectEqualStrings(body_before, body_after);
}

fn countNamed(h: *Scene, name: []const u8) usize {
    var n: usize = 0;
    for (h.tree.row.col.items) |c| {
        for (c.w.items) |w| {
            if (std.mem.eql(u8, w.body.file.name.items, name)) n += 1;
        }
    }
    return n;
}

fn columnOf(h: *Scene, w: *Window) ?usize {
    for (h.tree.row.col.items, 0..) |c, i| {
        for (c.w.items) |ww| if (ww == w) return i;
    }
    return null;
}

fn expectColumn(h: *Scene, w: *Window, i: usize) !void {
    try testing.expectEqual(@as(?usize, i), columnOf(h, w));
    try testing.expect(w.col == h.tree.row.col.items[i]);
}

fn onlyHelp(h: *Scene) !*Window {
    try testing.expectEqual(@as(usize, 1), countNamed(h, "+Help"));
    return errors.lookFile(h.tree.row, "+Help") orelse return error.MissingHelp;
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// A line of `section` contains `a` and then `b`, with any spacing between.
fn lineHasInOrder(section: []const u8, a: []const u8, b: []const u8) bool {
    var it = std.mem.splitScalar(u8, section, '\n');
    while (it.next()) |line| {
        const ai = std.mem.indexOf(u8, line, a) orelse continue;
        const bi = std.mem.indexOf(u8, line, b) orelse continue;
        if (ai < bi) return true;
    }
    return false;
}

test "help H-01: one column opens +Help in a new column" {
    const h = try Scene.init(seed);
    defer h.deinit();
    const row = h.tree.row;
    try testing.expectEqual(@as(usize, 1), row.col.items.len);
    const focused = h.win0();
    const c0 = row.col.items[0];

    try appendHelpWord(h);
    try runHelp(h, &focused.body);

    try testing.expectEqual(@as(usize, 2), row.col.items.len);
    try testing.expectEqual(c0, row.col.items[0]);
    try expectColumn(h, focused, 0);
    const help_w = try onlyHelp(h);
    try expectColumn(h, help_w, 1);
    // The new column is +Help alone, not an extra empty window.
    try testing.expectEqual(@as(usize, 1), row.col.items[1].w.items.len);
    try testing.expectEqual(help_w, row.col.items[1].w.items[0]);

    const body = try bodyText(&focused.body);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(seed, body);
}

test "help H-02: focus in column 0 places +Help in column 1" {
    const h = try Scene.init(seed);
    defer h.deinit();
    const focused = h.win0();
    try runNewcol(h);
    try testing.expectEqual(@as(usize, 2), h.tree.row.col.items.len);

    try appendHelpWord(h);
    try runHelp(h, &focused.body);

    try testing.expectEqual(@as(usize, 2), h.tree.row.col.items.len);
    try expectColumn(h, focused, 0);
    try expectColumn(h, try onlyHelp(h), 1);
}

test "help H-03: focus in the rightmost column places +Help to its left" {
    const h = try Scene.init(seed);
    defer h.deinit();
    try runNewcol(h);
    try testing.expectEqual(@as(usize, 2), h.tree.row.col.items.len);
    const right = h.tree.row.col.items[1].w.items[0];

    try appendHelpWord(h);
    try runHelp(h, &right.body);

    try testing.expectEqual(@as(usize, 2), h.tree.row.col.items.len);
    try expectColumn(h, right, 1);
    try expectColumn(h, try onlyHelp(h), 0);
}

test "help H-04: a second Help reuses the window and keeps its body" {
    const h = try Scene.init(seed);
    defer h.deinit();
    const focused = &h.win0().body;
    try appendHelpWord(h);
    try runHelp(h, focused);

    const first = try onlyHelp(h);
    const cols = h.tree.row.col.items.len;
    const col_i = columnOf(h, first);
    try first.body.insertAt(first.body.file.buffer.len(), "MARK", true);
    try runHelp(h, focused);

    const again = try onlyHelp(h);
    try testing.expectEqual(first, again);
    try testing.expectEqual(cols, h.tree.row.col.items.len);
    try testing.expectEqual(col_i, columnOf(h, again));
    const body = try bodyText(&again.body);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.endsWith(u8, body, "MARK"));
}

test "help H-05: a fresh +Help body is help.text" {
    const h = try Scene.init(seed);
    defer h.deinit();
    try appendHelpWord(h);
    try runHelp(h, &h.win0().body);
    const w = try onlyHelp(h);
    const body = try bodyText(&w.body);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(help.text, body);
    // The design's sheet ends in one newline. Comparing the body to the
    // const would stay green if both dropped it.
    try testing.expect(std.mem.endsWith(u8, help.text, "\n"));
    try testing.expect(!std.mem.endsWith(u8, help.text, "\n\n"));
}

test "help H-06: the sheet's macOS and Linux chords" {
    const text = help.text;
    const mac_at = std.mem.indexOf(u8, text, "macOS (devdraw)") orelse return error.MissingSection;
    const linux_at = std.mem.indexOf(u8, text, "Linux (devdraw, X11)") orelse return error.MissingSection;
    const browser_at = std.mem.indexOf(u8, text, "Browser") orelse return error.MissingSection;
    try testing.expect(mac_at < linux_at and linux_at < browser_at);

    const mac = text[mac_at..linux_at];
    const linux = text[linux_at..browser_at];
    try testing.expect(!has(mac, "Ctrl-click"));
    try testing.expect(has(linux, "Ctrl-click"));
    try testing.expect(lineHasInOrder(linux, "Ctrl-click", "B2"));
    // That chord is only in the Linux section, not before it or after it.
    try testing.expect(!has(text[0..linux_at], "Ctrl-click"));
    try testing.expect(!has(text[browser_at..], "Ctrl-click"));

    const needles = [_][]const u8{
        "Option-click",
        "Command-click",
        "Alt-click",
        "Three-finger tap",
        "Four-finger tap",
        "Cut",
        "Paste",
        "Snarf",
        "Esc selects what you just typed",
        "does not do that yet",
    };
    for (needles) |n| try testing.expect(has(text, n));
}

test "help H-07: wantsHelp accepts only -h and --help" {
    try testing.expect(help.wantsHelp(&.{ "snarf", "-h" }));
    try testing.expect(help.wantsHelp(&.{ "snarf", "--help" }));
    try testing.expect(help.wantsHelp(&.{ "snarf", "file", "--help" }));
    try testing.expect(!help.wantsHelp(&.{"snarf"}));
    try testing.expect(!help.wantsHelp(&.{ "snarf", "-help" }));
    try testing.expect(!help.wantsHelp(&.{ "snarf", "--h" }));
    try testing.expect(!help.wantsHelp(&.{ "snarf", "--version" }));
    try testing.expect(!help.wantsHelp(&.{ "snarf", "-colors=sunapee" }));
}

test "help H-08: Help sits between Get and Load and does not mark" {
    // Dispatch through execute is H-01; this only checks the table slot.
    var help_i: ?usize = null;
    for (builtins.exectab, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, "Help")) {
            help_i = i;
            break;
        }
    }
    const i = help_i orelse return error.HelpNotInTable;
    try testing.expect(i > 0 and i + 1 < builtins.exectab.len);
    try testing.expectEqualStrings("Get", builtins.exectab[i - 1].name);
    try testing.expectEqualStrings("Load", builtins.exectab[i + 1].name);
    try testing.expect(!builtins.exectab[i].mark);
}

test "help H-09: +Help is scratch and its tag has no Put or Undo" {
    const h = try Scene.init(seed);
    defer h.deinit();
    try appendHelpWord(h);
    try runHelp(h, &h.win0().body);
    const w = try onlyHelp(h);
    try testing.expect(w.isscratch);
    try testing.expect(!w.filemenu);
    const tag = try bodyText(&w.tag);
    defer testing.allocator.free(tag);
    try testing.expect(std.mem.indexOf(u8, tag, "Put") == null);
    try testing.expect(std.mem.indexOf(u8, tag, "Undo") == null);
}

test "help H-10: Help does not bump seq or dirty the focused file" {
    const h = try Scene.init(seed);
    defer h.deinit();
    // The original window's body file, not the +Help file Help is about to make.
    const focused = &h.win0().body;
    const focused_file = focused.file;
    try appendHelpWord(h);
    const seq = h.ed.seq;
    const mod = focused_file.mod;
    try runHelp(h, focused);
    try testing.expectEqual(seq, h.ed.seq);
    try testing.expectEqual(mod, focused_file.mod);
}
