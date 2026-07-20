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
//! SCROLL + LINE MOTION (phase 7a): Kup/Kdown/Kpgup/Kpgdown scroll the view
//! without moving the caret (R-P7-3, text.c:694-727); Kscrolloneup/onedown are
//! the wheel-notch runes (one line/notch, R-P7-2); Khome/Kend/^A/^E jump to the
//! ends of the text/line via `Text.show`/`setOrigin` (text.c:728-762). Kleft/
//! Kright now `show` the moved caret rather than just re-selecting it.
//!
//! DEFERRED keys — recognised as no-ops here, ported in later waves (each cites
//! its text.c range):
//!   * Kcmd+c/x/v/z/Z                              snarf / undo / redo   :763-819
//!   * ^F / Kins                                   autocomplete          :828-835
//!   * Kesc                                        select-typed-text     :836-846
//!   * ^U / ^W                                     erase line / word     :847-889
//!   * '\n' autoindent + wincommit                 (F-8, no window)      :890-939
//! Kbs erases one char; printable/'\t'/'\n' insert; scroll/line-motion above.
const std = @import("std");
const draw = @import("draw");
const Text = @import("Text.zig");
const Editor = @import("../Editor.zig");

// Plan 9 key runes (larryr/plan9port@337c6ac include/keyboard.h:18-43).
const KF: u21 = 0xF000;
const Khome: u21 = KF | 0x0D;
const Kup: u21 = KF | 0x0E;
const Kpgup: u21 = KF | 0x0F;
const Kleft: u21 = KF | 0x11;
const Kright: u21 = KF | 0x12;
const Kpgdown: u21 = KF | 0x13;
const Kend: u21 = KF | 0x18;
const Kdown: u21 = 0x80; // also Kview
const Kbs: u21 = 0x08;
const Kdel: u21 = 0x7f;
/// Wheel-notch scroll runes (dat.h:562-563). `pub` so the Editor's wheel arm can
/// synthesize them (acme.c:618-628).
pub const Kscrolloneup: u21 = KF | 0x20;
pub const Kscrollonedown: u21 = KF | 0x21;

/// `mousescrollsize` (larryr/plan9port@337c6ac libdraw/scroll.c:5-29): lines per
/// wheel notch. There is no `$mousescrollsize` env in wasm, so the library
/// default of 1 line/notch stands.
const mouse_scroll_lines: usize = 1;
fn mouseScrollSize(maxlines: usize) usize {
    _ = maxlines; // pcnt path unused: the default is a fixed line count
    return mouse_scroll_lines;
}

// case_Down (text.c:708-711): scroll DOWN so the line `n` rows below the top
// becomes the new origin. Caret is NOT moved and the run is NOT committed.
fn scrollDown(t: *Text, n: usize) Text.Error!void {
    const y = t.fr.r.min.y + @as(i32, @intCast(n)) * @as(i32, t.fr.font.height);
    const q0 = t.org + t.fr.charOfPt(.{ .x = t.fr.r.min.x, .y = y });
    try t.setOrigin(q0, true);
}

// case_Up (text.c:724-727): scroll UP `n` lines back from the current origin.
fn scrollUp(t: *Text, n: usize) Text.Error!void {
    try t.setOrigin(t.backNL(t.org, n), true);
}

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
            ed.in_typing_run = false; // typecommit (text.c:685)
            if (t.q0 > 0) try t.show(t.q0 - 1, t.q0 - 1, true); // text.c:686-687
            return;
        },
        Kright => {
            ed.in_typing_run = false; // typecommit (text.c:690)
            if (t.q1 < t.file.buffer.len()) try t.show(t.q1 + 1, t.q1 + 1, true); // text.c:691-692
            return;
        },

        // --- scroll (R-P7-3): move the origin only; caret unmoved, run NOT
        //     committed (the C's case_Down/case_Up do no typecommit). ---
        Kdown => return scrollDown(t, t.fr.maxlines / 3), // text.c:694-698
        Kscrollonedown => {
            var n = mouseScrollSize(t.fr.maxlines); // text.c:702
            if (n == 0) n = 1; // text.c:703-704 (n<=0 clamp)
            return scrollDown(t, n);
        },
        Kpgdown => return scrollDown(t, 2 * t.fr.maxlines / 3), // text.c:706-707
        Kup => return scrollUp(t, t.fr.maxlines / 3), // text.c:712-716
        Kscrolloneup => return scrollUp(t, mouseScrollSize(t.fr.maxlines)), // text.c:717-721
        Kpgup => return scrollUp(t, 2 * t.fr.maxlines / 3), // text.c:722-723

        // --- line motion (text.c:728-762): commit the run, then jump. ---
        Khome => {
            ed.in_typing_run = false; // typecommit (text.c:729)
            if (t.org > t.iq1) {
                try t.setOrigin(t.backNL(t.iq1, 1), true); // text.c:730-732
            } else {
                try t.show(0, 0, false); // text.c:734
            }
            return;
        },
        Kend => {
            ed.in_typing_run = false; // typecommit (text.c:737)
            if (t.iq1 > t.org + t.fr.nchars) { // text.c:738
                // should not happen, but does; clamp so backNL can't crash
                // (text.c:739-742).
                if (t.iq1 > t.file.buffer.len()) t.iq1 = t.file.buffer.len();
                try t.setOrigin(t.backNL(t.iq1, 1), true); // text.c:743-744
            } else {
                const nc = t.file.buffer.len();
                try t.show(nc, nc, false); // text.c:746
            }
            return;
        },
        0x01 => { // ^A: beginning of line (text.c:748-755)
            ed.in_typing_run = false; // typecommit (text.c:749)
            // go to where ^U would erase, if not already at BOL.
            var nnb: usize = 0;
            if (t.q0 > 0 and t.file.buffer.runeAt(t.q0 - 1) != '\n') nnb = t.bsWidth(0x15); // text.c:752-753
            try t.show(t.q0 - nnb, t.q0 - nnb, true); // text.c:754
            return;
        },
        0x05 => { // ^E: end of line (text.c:756-762)
            ed.in_typing_run = false; // typecommit (text.c:757)
            var q0 = t.q0; // text.c:758
            const nc = t.file.buffer.len();
            while (q0 < nc and t.file.buffer.runeAt(q0) != '\n') q0 += 1; // text.c:759-760
            try t.show(q0, q0, true); // text.c:761
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

    // Type-over-selection: cut first (text.c:820-825). acme SNARFS the replaced
    // text (cut with dosnarf=TRUE, R-P7-4 — corrects the earlier F-6 placeholder
    // that only deleted). `Editor.cut` snarfs [q0,q1) then deletes it, collapsing
    // the caret to the old q0; it shares this run's seq (the caller already
    // marked), so the delete + the following insert stay one undo transaction.
    if (t.q1 > t.q0) try ed.cut(t, true, true);

    // Autoscroll the caret into view before editing (text.c:826). If it is
    // off-screen (e.g. after scrolling with the wheel), this re-origins.
    try t.show(t.q0, t.q0, true);

    if (r == Kbs) {
        // ^H erase (text.c:847-884, single-char subset). The text.c:820-852
        // quirk: after cutting a selection above, backspace STILL erases one
        // more char before the collapsed caret.
        const q0 = t.q0;
        if (q0 == 0) return; // text.c:850-851 nothing to erase
        try t.deleteRange(q0 - 1, q0, true);
        try t.setSelect(q0 - 1, q0 - 1); // text.c:883
        t.iq1 = t.q0; // text.c:888
        return;
    }

    // Ordinary insertion — printable rune, tab, or newline (text.c:906-937).
    var buf: [4]u8 = undefined;
    const nbytes = std.unicode.utf8Encode(r, &buf) catch return; // bad rune: ignore
    const q0 = t.q0;
    try t.insertAt(q0, buf[0..nbytes], true); // text.c:925 textinsert
    try t.setSelect(q0 + 1, q0 + 1); // text.c:937
    t.iq1 = t.q0; // text.c:940
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

// Harness rect shifted (x 20→4) for the phase-8 scrollbar strip: the 12px
// scrollbar + 4px gap carve leaves the FRAME at (20,20)-(119,470), byte-identical
// to the pre-scrollbar geometry (chrome contract §2).
const rect = proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

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
        // R-P7-4: the replaced text was snarfed, not just deleted.
        try testing.expectEqualStrings("ell", h.ed.snarf.items);
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
        // The type-over cut still snarfs the selection before the extra erase.
        try testing.expectEqualStrings("ell", h.ed.snarf.items);
        _ = try h.file.undo();
        try h.expectText("hello");
    }
}

test "typing: type-over-selection snarfs the replaced text" {
    // R-P7-4 focus test: a printable and the Kbs variant both leave the replaced
    // selection in the snarf buffer (acme SNARFS type-over, text.c:823).
    {
        const h = try Harness.init("hello world");
        defer h.deinit();
        try h.text.setSelect(6, 11); // select "world"
        try h.text.typeRune(&h.ed, 'Z');
        try h.expectText("hello Z");
        try testing.expectEqualStrings("world", h.ed.snarf.items);
    }
    {
        const h = try Harness.init("hello world");
        defer h.deinit();
        try h.text.setSelect(6, 11); // select "world"
        try h.text.typeRune(&h.ed, Kbs); // Kbs over a selection also snarfs it
        try h.expectText("hello"); // "world" cut, then one more erase (the space)
        try testing.expectEqualStrings("world", h.ed.snarf.items);
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

// --------------------------------------------------------------------------
// Phase 7a scroll + line-motion tests. The Harness rect is 11×25 (9x18 font).
// "lineNN\n" lines are 7 runes each => one visual line; 60 lines = 420 runes,
// the frame holds 25 lines = 175 runes when full.
// --------------------------------------------------------------------------

/// `count` lines of "lineNN\n" (7 runes each). Caller frees.
fn genLines(a: std.mem.Allocator, count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var line: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&line, "line{d:0>2}\n", .{i}) catch unreachable;
        try buf.appendSlice(a, &line);
    }
    return buf.toOwnedSlice(a);
}

/// A 60-line Harness. Caller `h.deinit()`s; the seed is freed here.
fn scrollHarness() !*Harness {
    const seed = try genLines(testing.allocator, 60);
    defer testing.allocator.free(seed);
    return Harness.init(seed);
}

test "typing: Kdown and Kup scroll a third of the frame" {
    const h = try scrollHarness();
    defer h.deinit();
    const t = &h.text;

    // Kdown: n = maxlines/3 = 8. The origin jumps to line8; the caret does NOT
    // move (R-P7-3) and the typing run is not committed.
    try t.typeRune(&h.ed, Kdown);
    try testing.expectEqual(@as(usize, 56), t.org); // line8 = 8*7
    try testing.expectEqual(@as(usize, 0), t.q0); // caret UNCHANGED
    try testing.expectEqual(@as(usize, 0), t.q1);

    // Kup: back a third => all the way to the top from line8.
    try t.typeRune(&h.ed, Kup);
    try testing.expectEqual(@as(usize, 0), t.org);
    try testing.expectEqual(@as(usize, 0), t.q0);
    try testing.expectEqual(@as(usize, 0), t.q1);
}

test "typing: wheel key runes scroll one line" {
    const h = try scrollHarness();
    defer h.deinit();
    const t = &h.text;

    try t.typeRune(&h.ed, Kscrollonedown);
    try testing.expectEqual(@as(usize, 7), t.org); // line1
    try t.typeRune(&h.ed, Kscrollonedown);
    try testing.expectEqual(@as(usize, 14), t.org); // line2
    try t.typeRune(&h.ed, Kscrolloneup);
    try testing.expectEqual(@as(usize, 7), t.org); // back to line1
    try testing.expectEqual(@as(usize, 0), t.q0); // caret never moved
}

test "typing: Kpgdown and Kpgup scroll two thirds" {
    const h = try scrollHarness();
    defer h.deinit();
    const t = &h.text;

    // n = 2*maxlines/3 = 16.
    try t.typeRune(&h.ed, Kpgdown);
    try testing.expectEqual(@as(usize, 112), t.org); // line16 = 16*7
    try t.typeRune(&h.ed, Kpgup);
    try testing.expectEqual(@as(usize, 0), t.org);
    try testing.expectEqual(@as(usize, 0), t.q0);
}

test "typing: Khome and Kend jump to the ends" {
    // Kend else-branch (iq1 <= org+nchars): show(len,len,false) puts EOF in view.
    {
        const h = try scrollHarness();
        defer h.deinit();
        try h.text.typeRune(&h.ed, Kend);
        try testing.expectEqual(@as(usize, 378), h.text.org); // line54
    }
    // Kend iq1-branch (iq1 > org+nchars): scroll to just above iq1's line.
    {
        const h = try scrollHarness();
        defer h.deinit();
        h.text.iq1 = 280; // line40, below the frame
        try h.text.typeRune(&h.ed, Kend);
        try testing.expectEqual(@as(usize, 273), h.text.org); // backNL(280,1) => line39
    }
    // Khome org>iq1 branch: after scrolling to EOF, Home returns near iq1 (0).
    {
        const h = try scrollHarness();
        defer h.deinit();
        try h.text.typeRune(&h.ed, Kend); // org => 378
        try h.text.typeRune(&h.ed, Khome);
        try testing.expectEqual(@as(usize, 0), h.text.org);
    }
    // Khome else-branch (org<=iq1): show(0,0,false); already at top => no move.
    {
        const h = try scrollHarness();
        defer h.deinit();
        h.text.iq1 = 100;
        try h.text.typeRune(&h.ed, Khome);
        try testing.expectEqual(@as(usize, 0), h.text.org);
    }
}

test "typing: ctrl-a and ctrl-e move to line boundaries" {
    // "abc def\nxyz": indices a0 b1 c2 sp3 d4 e5 f6 \n7 x8 y9 z10.
    const h = try Harness.init("abc def\nxyz");
    defer h.deinit();
    const t = &h.text;

    try t.setSelect(5, 5); // mid first line
    try t.typeRune(&h.ed, 0x01); // ^A: to BOL
    try testing.expectEqual(@as(usize, 0), t.q0);
    try testing.expectEqual(@as(usize, 0), t.q1);

    try t.typeRune(&h.ed, 0x05); // ^E: to just before the '\n'
    try testing.expectEqual(@as(usize, 7), t.q0);

    // Second line: ^A lands after the '\n' (start of "xyz").
    try t.setSelect(10, 10);
    try t.typeRune(&h.ed, 0x01);
    try testing.expectEqual(@as(usize, 8), t.q0);
    try t.typeRune(&h.ed, 0x05); // ^E: to EOF (no trailing '\n')
    try testing.expectEqual(@as(usize, 11), t.q0);
}

test "typing: typing at an off-screen caret autoscrolls" {
    const h = try scrollHarness();
    defer h.deinit();
    const t = &h.text;

    try t.typeRune(&h.ed, Kpgdown); // org => 112, caret (0) now above the frame
    try testing.expectEqual(@as(usize, 112), t.org);

    try t.typeRune(&h.ed, 'Q'); // must scroll the caret back into view first
    try testing.expectEqual(@as(usize, 0), t.org);
    try testing.expectEqual(@as(u21, 'Q'), t.file.buffer.runeAt(0));
    try testing.expectEqual(@as(usize, 1), t.q0);
}

test "typing: arrows scroll the caret visible" {
    const h = try scrollHarness();
    defer h.deinit();
    const t = &h.text;

    try t.typeRune(&h.ed, Kpgdown); // org => 112, caret (0) off the top
    try t.typeRune(&h.ed, Kright); // move caret to 1 and show it
    try testing.expectEqual(@as(usize, 0), t.org); // scrolled back to the caret
    try testing.expectEqual(@as(usize, 1), t.q0);
    try testing.expectEqual(@as(usize, 1), t.q1);
}
