//! Regression tests for issue #57: Undo/Redo change the body buffer but do not
//! repaint it. Plan: `notes/snarfdev2/test-plans/M0-57-undo-repaint.md`.
//!
//! ACME: `fileundo` (file.c:189) applies every reversed delta through
//! `textdelete` (file.c:236) / `textinsert` (file.c:253) for each Text on the
//! File, so `frdelete`/`frinsert` keep the frame (and therefore the screen) in
//! step with the buffer. The frame draws only from its boxes, so the headless
//! check is: after Undo/Redo the body frame's boxes spell exactly the buffer
//! runes `[org, org+nchars)`, as they do after an ordinary insert/delete.
//!
//! LANDED-FLAG PATTERN (as in clipboard_test.zig): with
//! `undo_repaint_fixed = false` a mismatch SKIPs and a match FAILs with
//! UnexpectedPassFlipFlag, so the fixing PR (#57) must flip the flag.
const std = @import("std");
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const Editor = @import("../Editor.zig");
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");
const Window = @import("../Window.zig");
const Chrome = @import("../Chrome.zig");
const Palette = @import("../Palette.zig");
const Text = @import("../text/Text.zig");
const cmd_edit = @import("cmd_edit.zig");

/// Flip when Undo/Redo repaint the body frame (issue #57, SnarfDev1).
const undo_repaint_fixed = true;

const win_rect = proto.Rect.make(0, 20, 300, 380);
const seed = "banana alpha gamma\nsecond line (paren text) here\n";

const Rig = struct {
    fx: Frame.TestFixture,
    chrome: *Chrome,
    body_file: File,
    w: Window,
    ed: Editor,

    fn init(text: []const u8) !*Rig {
        const a = testing.allocator;
        const r = try a.create(Rig);
        errdefer a.destroy(r);
        r.fx = try Frame.TestFixture.init();
        r.chrome = try Chrome.init(a, r.fx.disp, r.fx.font, Palette.default);
        r.body_file = File.init(a, try Buffer.initFromBytes(a, text));
        try r.w.init(r.chrome, &r.body_file, 1, win_rect);
        _ = try r.w.resize(win_rect, false, false);
        r.ed = Editor.init(a);
        return r;
    }
    fn deinit(r: *Rig) void {
        r.ed.deinit();
        r.w.deinit();
        r.body_file.deinit();
        r.chrome.deinit();
        r.fx.deinit();
        testing.allocator.destroy(r);
    }

    /// The `Edit ,s/a/A/g` of the #57 repro as one undo transaction, done
    /// through the ordinary Text delete/insert paths (back to front).
    fn upcaseAs(r: *Rig) !void {
        r.ed.seq += 1;
        r.w.body.file.mark(r.ed.seq);
        var i: usize = seed.len;
        while (i > 0) {
            i -= 1;
            if (seed[i] != 'a') continue;
            try r.w.body.deleteRange(i, i + 1, true);
            try r.w.body.insertAt(i, "A", true);
        }
    }

    /// Force a full refill, as the manual repro's window resize did.
    fn forceRepaint(r: *Rig) !void {
        _ = try r.w.resize(win_rect, false, false);
    }
};

/// The runes the body frame holds, rebuilt from its boxes (caller frees).
fn frameText(t: *Text) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (t.fr.boxes.items) |*bx| switch (bx.kind) {
        .run => |run| try out.appendSlice(testing.allocator, run.text),
        .brk => |b| try out.append(testing.allocator, b.bc),
    };
    return out.toOwnedSlice(testing.allocator);
}

/// The buffer runes the frame should be showing: `[org, org+nchars)`
/// (caller frees).
fn shownBuffer(t: *Text) ![]u8 {
    const n = t.fr.nchars;
    if (n == 0) return testing.allocator.alloc(u8, 0);
    const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer testing.allocator.free(dest);
    return testing.allocator.dupe(u8, t.file.buffer.read(t.org, n, dest));
}

/// True when the frame mirrors the buffer: same runes, and the frame holds
/// everything left to show (it is full or reaches the end of the buffer).
fn frameMatches(t: *Text) !bool {
    return frameMatchesQ(t, true);
}

/// `report` = print the mismatch (off for expected failures so a green run
/// stays quiet on stderr).
fn frameMatchesQ(t: *Text, report: bool) !bool {
    if (t.org + t.fr.nchars > t.file.buffer.len()) {
        if (report) std.debug.print("undo_repaint_test: frame holds {d} runes past org {d}, buffer has {d}\n", .{ t.fr.nchars, t.org, t.file.buffer.len() });
        return false;
    }
    const got = try frameText(t);
    defer testing.allocator.free(got);
    const want = try shownBuffer(t);
    defer testing.allocator.free(want);
    if (!std.mem.eql(u8, got, want)) {
        if (report) std.debug.print("undo_repaint_test: frame shows \"{s}\", buffer has \"{s}\"\n", .{ got, want });
        return false;
    }
    const reaches_end = t.org + t.fr.nchars == t.file.buffer.len();
    return reaches_end or t.fr.lastlinefull;
}

fn expectRepainted(t: *Text) !void {
    const ok = try frameMatchesQ(t, undo_repaint_fixed);
    if (!undo_repaint_fixed) {
        if (ok) return error.UnexpectedPassFlipFlag;
        return error.SkipZigTest; // expected-fail until #57 lands
    }
    try testing.expect(ok);
}

test "undo repaint UR-01 (control): the ordinary insert/delete path keeps the body frame in step with the buffer" {
    const r = try Rig.init(seed);
    defer r.deinit();
    try testing.expect(try frameMatches(&r.w.body)); // initial fill
    try r.upcaseAs();
    try testing.expect(try frameMatches(&r.w.body)); // frdelete/frinsert ran
}

test "undo repaint UR-02: Undo of a visible edit repaints the body (file.c:236/253)" {
    const r = try Rig.init(seed);
    defer r.deinit();
    try r.upcaseAs();
    try cmd_edit.undo(&r.ed, &r.w.tag, null, null, true, false, "");
    // The buffer really was undone (this half already works on main).
    const want = try shownBuffer(&r.w.body);
    defer testing.allocator.free(want);
    try testing.expect(std.mem.startsWith(u8, seed, want));
    try expectRepainted(&r.w.body);
}

test "undo repaint UR-03: Redo of a visible edit repaints the body" {
    const r = try Rig.init(seed);
    defer r.deinit();
    try r.upcaseAs();
    try cmd_edit.undo(&r.ed, &r.w.tag, null, null, true, false, "");
    // Resync first so a stale (never-undone) frame can't pass Redo vacuously.
    try r.forceRepaint();
    try testing.expect(try frameMatches(&r.w.body));
    try cmd_edit.undo(&r.ed, &r.w.tag, null, null, false, false, "");
    try expectRepainted(&r.w.body);
}

test "undo repaint UR-04: Undo of the typing back to an empty body clears the frame" {
    const r = try Rig.init("");
    defer r.deinit();
    // Type the seed into an empty body as one transaction, then undo it.
    r.ed.seq += 1;
    r.w.body.file.mark(r.ed.seq);
    try r.w.body.insertAt(0, seed, true);
    try testing.expect(try frameMatches(&r.w.body));
    try cmd_edit.undo(&r.ed, &r.w.tag, null, null, true, false, "");
    try testing.expectEqual(@as(usize, 0), r.w.body.file.buffer.len());
    try expectRepainted(&r.w.body);
}
