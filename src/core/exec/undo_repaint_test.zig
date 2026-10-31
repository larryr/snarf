//! #57 regression: Undo/Redo must repaint the body FRAME, not just the buffer.
//!
//! acme's `fileundo` (larryr/plan9port@337c6ac acme/file.c:189-279) mirrors
//! every reversed edit into each Text on the file — `textdelete(…, FALSE)` at
//! file.c:233-234, `textinsert(…, FALSE)` at file.c:247-248 — so the frame is
//! updated in place before `winundo`'s `textshow` (wind.c:360-361). The port
//! used to edit the buffer alone and rely on `show`, which only refills when
//! the range is off-screen: an Undo inside the visible region left stale
//! glyphs until a resize. These tests compare what the frame HOLDS (its box
//! list, i.e. what gets drawn) after each step, not just the buffer.
//!
//! Repro from the issue: type two lines, `Edit ,s/a/A/g`, Undo, Redo, Undo,
//! then a second Undo that empties the body.
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
const exec = @import("exec.zig");
const cmd_edit = @import("cmd_edit.zig");

const typed = "banana alpha gamma\nsecond line (paren text) here";
const edited = "bAnAnA AlphA gAmmA\nsecond line (pAren text) here";

const Scene = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,

    fn init() !*Scene {
        const a = testing.allocator;
        const h = try a.create(Scene);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 600, 460), .{
            .win_name = "scratch",
            .body = "",
        });
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
    fn win(h: *Scene) *Window {
        return h.tree.row.col.items[0].w.items[0];
    }
};

/// The frame's contents as drawn: every run box's text plus each break box's
/// char, in box order (Frame I-1: the boxes partition [0, nchars)).
fn frameText(t: *Text) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (t.fr.boxes.items) |*bx| switch (bx.kind) {
        .run => |r| try out.appendSlice(testing.allocator, r.text),
        .brk => |b| try out.append(testing.allocator, b.bc),
    };
    return out.toOwnedSlice(testing.allocator);
}

fn bufferText(t: *Text) ![]u8 {
    const n = t.file.buffer.len();
    if (n == 0) return testing.allocator.alloc(u8, 0);
    const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer testing.allocator.free(dest);
    return testing.allocator.dupe(u8, t.file.buffer.read(0, n, dest));
}

/// Both the buffer AND the frame hold `want` (the whole body fits on screen,
/// org 0), and the frame's rune count agrees with its boxes.
fn expectShown(t: *Text, want: []const u8) !void {
    const buf = try bufferText(t);
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings(want, buf);
    try testing.expectEqual(@as(usize, 0), t.org);
    const fr = try frameText(t);
    defer testing.allocator.free(fr);
    try testing.expectEqualStrings(want, fr);
    try testing.expectEqual(t.fr.strLen(0), t.fr.nchars);
    try testing.expectEqual(t.file.buffer.len(), t.fr.nchars);
}

fn findWord(t: *Text, word: []const u8) ?[2]usize {
    const nc = t.file.buffer.len();
    var i: usize = 0;
    outer: while (i + word.len <= nc) : (i += 1) {
        for (word, 0..) |ch, j| {
            if (t.file.buffer.runeAt(i + j) != ch) continue :outer;
        }
        return .{ i, i + word.len };
    }
    return null;
}

/// B2-execute `word` from the window's tag, appending it first if the retag
/// has not put it there.
fn execTag(h: *Scene, word: []const u8) !void {
    const w = h.win();
    const rng = findWord(&w.tag, word) orelse blk: {
        try w.tag.insertAt(w.tag.file.buffer.len(), " ", true);
        try w.tag.insertAt(w.tag.file.buffer.len(), word, true);
        break :blk findWord(&w.tag, word).?;
    };
    try exec.execute(&h.ed, &w.tag, rng[0], rng[1], null);
}

test "undo_repaint (#57): Edit ,s/a/A/g then Undo/Redo/Undo/Undo repaint the body frame" {
    const h = try Scene.init();
    defer h.deinit();
    const w = h.win();

    // Step 1: "type" the two lines as one undoable transaction.
    h.ed.seq += 1;
    w.body.file.mark(h.ed.seq);
    try w.body.insertAt(0, typed, true);
    try expectShown(&w.body, typed);

    // Step 2: Edit ,s/a/A/g (the frame already tracked this — the control).
    try execTag(h, "Edit ,s/a/A/g");
    try expectShown(&w.body, edited);

    // Step 3: Undo — the frame must show the lowercase text again.
    try execTag(h, "Undo");
    try expectShown(&w.body, typed);

    // Step 5: Redo — back to the substituted text, on screen too.
    try execTag(h, "Redo");
    try expectShown(&w.body, edited);

    // Undo, then a second Undo reverses the typing: the frame must be EMPTY.
    try execTag(h, "Undo");
    try expectShown(&w.body, typed);
    try execTag(h, "Undo");
    try expectShown(&w.body, "");

    // And Redo of the typing repaints it back.
    try execTag(h, "Redo");
    try expectShown(&w.body, typed);
}

test "undo_repaint (#57): undo of a mid-body delete and insert repaints in place" {
    const h = try Scene.init();
    defer h.deinit();
    const w = h.win();
    const ed = &h.ed;

    ed.seq += 1;
    w.body.file.mark(ed.seq);
    try w.body.insertAt(0, "one\ntwo\nthree\n", true);

    // Transaction: delete "two\n" then insert "TWO!\n" in its place.
    ed.seq += 1;
    w.body.file.mark(ed.seq);
    try w.body.deleteRange(4, 8, true);
    try w.body.insertAt(4, "TWO!\n", true);
    try expectShown(&w.body, "one\nTWO!\nthree\n");

    // Undo straight through cmd_edit.undo (isundo) — frame follows the buffer,
    // and dot selects the restored range (winundo's textshow, wind.c:361).
    try cmd_edit.undo(ed, &w.tag, null, null, true, false, "");
    try expectShown(&w.body, "one\ntwo\nthree\n");
    try testing.expectEqual(@as(usize, 4), w.body.q0);
    try testing.expectEqual(@as(usize, 8), w.body.q1);

    try cmd_edit.undo(ed, &w.tag, null, null, false, false, "");
    try expectShown(&w.body, "one\nTWO!\nthree\n");
}
