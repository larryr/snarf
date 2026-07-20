//! Keyboard typing — `texttype` (larryr/plan9port@337c6ac acme/text.c:668-942)
//! recast as a single-Text, no-cache, no-window subset. Cite as `text.c:NN`.
//!
//! Attached to `Text` as the method `t.typeRune(ed, r)`.
//!
//! UNDO GROUPING (R-P6-8/T-1). The C bumps the global `seq` and calls
//! `filemark` on EVERY body keystroke (text.c:793-796) but only actually commits
//! the accumulated `ncache` to the file at run end (`wincommit`), so a run of
//! keys lands as ONE undo transaction. This port has no `ncache` (F-6): every
//! key edits the file directly, so to keep one transaction per run we instead
//! bump `ed.seq` + `File.mark` ONCE, on the first key of a run, gated by
//! `ed.in_typing_run`. Arrow keys end the run (clear the flag); the 6c input loop
//! clears it on any mouse event.
//!
//! DEFERRED keys — recognised as no-ops here, ported in later waves (each cites
//! its text.c range):
//!   * Kup/Kdown/Kpgup/Kpgdown/Khome/Kend, ^A/^E   scroll + line motion  :694-762
//!   * Kcmd+c/x/v/z/Z                              snarf / undo / redo   :763-819
//!   * ^F / Kins                                   autocomplete          :828-835
//!   * Kesc                                        select-typed-text     :836-846
//!   * ^U / ^W                                     erase line / word     :847-889
//!   * '\n' autoindent + wincommit                 (F-8, no window)      :890-939
//! Only Kleft/Kright (caret motion), Kbs (erase one), and printable/'\t'/'\n'
//! insertion are live in sub-wave 6b.
const std = @import("std");
const draw = @import("draw");
const Text = @import("Text.zig");
const Editor = @import("../Editor.zig");

// Plan 9 key runes (larryr/plan9port@337c6ac include/keyboard.h:18-43).
const KF: u21 = 0xF000;
const Kleft: u21 = KF | 0x11;
const Kright: u21 = KF | 0x12;
const Kdown: u21 = 0x80; // also Kview
const Kbs: u21 = 0x08;
const Kdel: u21 = 0x7f;

/// True for a rune we insert verbatim: a graphic character, a tab, or a newline.
/// Everything else (control codes, the KF private-use navigation/command block,
/// Kdown/Kdel) is either handled explicitly or a DEFERRED no-op — never inserted.
fn insertable(r: u21) bool {
    if (r == '\n' or r == '\t') return true;
    return r >= 0x20 and r != Kdel and r != Kdown and r < KF;
}

/// `texttype` (text.c:668-942) subset — feed one key rune `r` to `t`.
pub fn typeRune(t: *Text, ed: *Editor, r: u21) Text.Error!void {
    switch (r) {
        // Kleft/Kright: commit the run and move the caret. The C collapses to
        // q0-1 / q1+1 regardless of any selection (text.c:684-693); typecommit
        // there == ending our run here.
        Kleft => {
            ed.in_typing_run = false;
            if (t.q0 > 0) try t.setSelect(t.q0 - 1, t.q0 - 1); // text.c:686-687
            return;
        },
        Kright => {
            ed.in_typing_run = false;
            if (t.q1 < t.file.buffer.len()) try t.setSelect(t.q1 + 1, t.q1 + 1); // text.c:691-692
            return;
        },
        else => {},
    }

    // Deferred keys never start a run or edit (see header). Kbs is a control
    // code but IS handled below, so let it through.
    if (r != Kbs and !insertable(r)) return;

    // Start-or-continue the typing run: one seq bump + File.mark per run
    // (text.c:793-796, regrouped — see header).
    if (!ed.in_typing_run) {
        ed.seq += 1;
        t.file.mark(ed.seq);
        ed.in_typing_run = true;
    }

    // Type-over-selection: cut first (text.c:820-825; cut == delete, F-6). This
    // collapses the caret to the old q0.
    if (t.q1 > t.q0) {
        try t.deleteRange(t.q0, t.q1, true);
    }

    if (r == Kbs) {
        // ^H erase (text.c:847-884, single-char subset). The text.c:820-852
        // quirk: after cutting a selection above, backspace STILL erases one
        // more char before the collapsed caret.
        const q0 = t.q0;
        if (q0 == 0) return; // text.c:850-851 nothing to erase
        try t.deleteRange(q0 - 1, q0, true);
        try t.setSelect(q0 - 1, q0 - 1); // text.c:883
        return;
    }

    // Ordinary insertion — printable rune, tab, or newline (text.c:906-937).
    var buf: [4]u8 = undefined;
    const nbytes = std.unicode.utf8Encode(r, &buf) catch return; // bad rune: ignore
    const q0 = t.q0;
    try t.insertAt(q0, buf[0..nbytes], true); // text.c:925 textinsert
    try t.setSelect(q0 + 1, q0 + 1); // text.c:937
}

// ==========================================================================
// Tests (editing side contract §"B2 named tests"). Frame.TestFixture + a real
// File; the undo-transaction assertions are the heart — undo() after each
// scenario returns exactly the contracted text.
// ==========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");

const rect = proto.Rect{ .min = .{ .x = 20, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

/// A live Text over `seed` plus an Editor, wired to a fresh draw fixture.
const Harness = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,
    ed: Editor,

    fn init(seed: []const u8) !*Harness {
        const a = testing.allocator;
        const h = try a.create(Harness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.text = try Text.init(&h.file, a, rect, h.fx.font, &h.fx.disp.image, h.fx.cols());
        h.ed = Editor.init(a);
        try h.text.fill(); // render the seed
        return h;
    }
    fn deinit(h: *Harness) void {
        h.ed.deinit();
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    /// The whole buffer as decoded UTF-8 (caller frees).
    fn bufText(h: *Harness) ![]u8 {
        const n = h.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, h.file.buffer.read(0, n, dest));
    }
    fn expectText(h: *Harness, want: []const u8) !void {
        const got = try h.bufText();
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
    fn typeStr(h: *Harness, s: []const u8) !void {
        for (s) |c| try h.text.typeRune(&h.ed, c);
    }
};

test "typing: runes insert at the tick" {
    const h = try Harness.init("");
    defer h.deinit();

    try h.typeStr("abc");
    try h.expectText("abc");
    try testing.expectEqual(@as(usize, 3), h.text.q0);
    try testing.expectEqual(@as(usize, 3), h.text.q1);
    try testing.expectEqual(@as(usize, 3), h.text.fr.nchars);

    // One transaction: a single undo empties the buffer.
    _ = try h.file.undo();
    try h.expectText("");
    try testing.expectEqual(@as(?File.Range, null), try h.file.undo());
}

test "typing: newline is part of the run" {
    const h = try Harness.init("");
    defer h.deinit();

    try h.typeStr("a\nb");
    try h.expectText("a\nb");
    try testing.expect(h.ed.in_typing_run); // never broken by the newline
    try testing.expectEqual(@as(u32, 1), h.ed.seq); // one seq for the whole run
    try testing.expectEqual(@as(usize, 2), h.text.fr.nlines);

    _ = try h.file.undo();
    try h.expectText("");
    try testing.expectEqual(@as(?File.Range, null), try h.file.undo());
}

test "typing: arrow ends the run" {
    const h = try Harness.init("");
    defer h.deinit();

    try h.typeStr("ab");
    try h.text.typeRune(&h.ed, Kleft); // caret 2 -> 1, ends run
    try testing.expect(!h.ed.in_typing_run);
    try testing.expectEqual(@as(usize, 1), h.text.q0);
    try h.typeStr("c"); // new run, inserts at 1
    try h.expectText("acb");
    try testing.expectEqual(@as(u32, 2), h.ed.seq); // two runs -> two seqs

    // Two transactions: undo drops 'c', then undo drops "ab".
    _ = try h.file.undo();
    try h.expectText("ab");
    _ = try h.file.undo();
    try h.expectText("");
}

test "typing: backspace" {
    const h = try Harness.init("");
    defer h.deinit();

    try h.typeStr("abc");
    try h.text.typeRune(&h.ed, Kbs); // erase 'c'
    try h.expectText("ab");
    try testing.expectEqual(@as(usize, 2), h.text.q0);
    try testing.expectEqual(@as(usize, 2), h.text.q1);
    try testing.expect(h.ed.in_typing_run); // backspace stays inside the run

    // Still ONE transaction (insert "abc" + erase 'c' share the seq).
    _ = try h.file.undo();
    try h.expectText("");
    try testing.expectEqual(@as(?File.Range, null), try h.file.undo());
}

test "typing: type over selection deletes then inserts (and bs quirk)" {
    // 'X' over [1,4): "hello" -> "hXo".
    {
        const h = try Harness.init("hello");
        defer h.deinit();
        try h.text.setSelect(1, 4); // select "ell"
        try h.text.typeRune(&h.ed, 'X');
        try h.expectText("hXo");
        try testing.expectEqual(@as(usize, 2), h.text.q0);
        try testing.expectEqual(@as(usize, 2), h.text.q1);
        // One transaction (delete + insert share the seq): undo restores "hello".
        _ = try h.file.undo();
        try h.expectText("hello");
    }
    // Kbs over [1,4): deletes "ell" THEN erases one more -> "o".
    {
        const h = try Harness.init("hello");
        defer h.deinit();
        try h.text.setSelect(1, 4);
        try h.text.typeRune(&h.ed, Kbs);
        try h.expectText("o");
        try testing.expectEqual(@as(usize, 0), h.text.q0);
        _ = try h.file.undo();
        try h.expectText("hello");
    }
}

test "typing: mouse ends the run" {
    const h = try Harness.init("");
    defer h.deinit();

    try h.typeStr("ab");
    // The 6c input loop clears the flag on any mouse event; simulate that.
    h.ed.in_typing_run = false;
    try h.typeStr("c");
    try h.expectText("abc");
    try testing.expectEqual(@as(u32, 2), h.ed.seq); // two transactions

    _ = try h.file.undo();
    try h.expectText("ab");
    _ = try h.file.undo();
    try h.expectText("");
}
