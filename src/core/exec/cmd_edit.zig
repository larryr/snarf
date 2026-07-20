//! Edit builtins: `cut` (Cut/Snarf), `paste` (Paste), `undo` (Undo/Redo).
//! namespace module (S-07 P-1). Ported from larryr/plan9port@337c6ac acme/exec.c
//! (:947-1073 cut/paste, :427-478 seqof/undo) + wind.c:351-372 winundo; cite as
//! `exec.c:NN` / `wind.c:NN`.
//!
//! These are the et/t-redirection WRAPPERS around the phase-7 single-Text cores
//! (`Editor.cut`/`Editor.snarfInsert`, exec.c:947-1073's inner loop): they choose
//! the real target Text (body vs tag vs the command's default `seltext`) and mark
//! it, then delegate. `execute` (exec.zig) has already bumped `ed.seq` +
//! `File.mark`'d `seltext`'s file for `mark`-flagged commands (Cut/Paste), exactly
//! as the C's execute does before calling these.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");

/// `cut` (exec.c:947-1016), Cut (dosnarf=docut=true) and Snarf (dosnarf=true,
/// docut=false). The et/t redirection (exec.c:957-974): when not a mouse chord
/// (`t0 != et`) and snarfing and `et` is a window text, prefer the window BODY
/// selection (re-`mark`ing it for a cut — execute marked `seltext`'s file, which
/// may differ), else the TAG selection, else nothing. `t0` == null (no `seltext`)
/// takes the same window-relative fallback (null != et). A null/empty selection
/// returns. Delegates to `Editor.cut` (the phase-7 core; flags map 1:1). Snarf-only
/// records the cut Text as `ed.argtext` (exec.c:1012-1013), so a later 2-1 chord
/// New can name a window after it.
pub fn cut(
    ed: *Editor,
    et: *Text,
    t0: ?*Text,
    _: ?*Text,
    dosnarf: bool,
    docut: bool,
    _: []const u8,
) Text.Error!void {
    var t: ?*Text = t0;
    if (t0 != et and dosnarf) {
        if (et.w) |w| {
            if (w.body.q1 > w.body.q0) {
                t = &w.body; // exec.c:961-963 body selection
                if (docut) w.body.file.mark(ed.seq); // exec.c:964-965 (execute already seq++'d)
            } else if (w.tag.q1 > w.tag.q0) {
                t = &w.tag; // exec.c:966-967 tag selection
            } else {
                t = null; // exec.c:968-969 nothing selected
            }
        }
    }
    const tt = t orelse return; // exec.c:971-972 no selection
    if (tt.q0 == tt.q1) return; // exec.c:976-980 empty selection
    try ed.cut(tt, dosnarf, docut); // exec.c:982-1011 the phase-7 core
    if (dosnarf and !docut) ed.argtext = tt; // exec.c:1012-1013 Snarf command
}

/// `paste` (exec.c:1018-1073), Paste (selectall=true). `tobody` (flag2, the truthy
/// XXX) redirects a tag Paste into the executing window's BODY and re-`mark`s it
/// (exec.c:1029-1032; execute already seq++'d for the mark-flagged Paste). A null
/// target returns. Delegates to `Editor.snarfInsert` (the phase-7 core; the empty
/// snarf-buffer guard lives there, exec.c:1037-1039).
pub fn paste(
    ed: *Editor,
    et: *Text,
    t0: ?*Text,
    _: ?*Text,
    selectall: bool,
    tobody: bool,
    _: []const u8,
) Text.Error!void {
    var t: ?*Text = t0;
    if (tobody) {
        if (et.w) |w| {
            t = &w.body; // exec.c:1030-1031
            w.body.file.mark(ed.seq); // exec.c:1031 (execute already seq++'d)
        }
    }
    const tt = t orelse return; // exec.c:1033-1034
    try ed.snarfInsert(tt, selectall); // exec.c:1037-1069 the phase-7 core
}

/// `undo` (exec.c:436-478 + seqof :427-434 + winundo wind.c:351-372), v1
/// single-window subset (R-P9-10). Undo (isundo=true) / Redo (isundo=false).
/// Guards on the executing window, checks the seq to reverse (0 ⇒ nothing to do),
/// applies the file op, then `show`s the reversed range (REQUIRED — the file op
/// bypasses the frame; `show` refills + selects, wind.c:361). `w.dirty = f.mod`
/// approximates the C's `v->dirty = (f->seq != v->putseq)` until Put lands.
///
/// FLAG (R-P9-10): the same-seq multi-window walk (exec.c:462-477) is Edit-phase
/// territory (needs shared-File views); v1 undoes only the executing window.
pub fn undo(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    _: ?*Text,
    isundo: bool,
    _: bool,
    _: []const u8,
) Text.Error!void {
    _ = ed;
    const w = et.w orelse return; // exec.c:451-452
    const f = w.body.file;
    // seqof (exec.c:427-434): undo ⇒ the file's current seq, redo ⇒ its redo seq.
    const seq = if (isundo) f.undoSeq() else f.redoSeq();
    if (seq == 0) return; // exec.c:454-457 nothing to undo/redo
    const r = (if (isundo) try f.undo() else try f.redo()) orelse return;
    // winundo wind.c:361: textshow refills the frame + selects the reversed range.
    try w.body.show(r.q0, r.q1, true);
    w.dirty = f.mod; // wind.c:365 v1 putseq approx
}

// ===========================================================================
// Tests. The edit builtins are driven directly here; the full B2-dispatch
// integration lives in exec.zig's tests (tests 3-5, 8, 13).
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");
const Window = @import("../Window.zig");
const Chrome = @import("../Chrome.zig");

const win_rect = proto.Rect.make(0, 20, 300, 380);

/// A single windowed scene (tag over body) with an Editor, for the wrappers'
/// et/t routing.
const WinHarness = struct {
    fx: Frame.TestFixture,
    chrome: *Chrome,
    body_file: File,
    w: Window,
    ed: Editor,

    fn init(seed: []const u8) !*WinHarness {
        const a = testing.allocator;
        const h = try a.create(WinHarness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.chrome = try Chrome.init(a, h.fx.disp, h.fx.font);
        h.body_file = File.init(a, try Buffer.initFromBytes(a, seed));
        try h.w.init(h.chrome, &h.body_file, 1, win_rect);
        _ = try h.w.resize(win_rect, false, false);
        h.ed = Editor.init(a);
        return h;
    }
    fn deinit(h: *WinHarness) void {
        h.ed.deinit();
        h.w.deinit();
        h.body_file.deinit();
        h.chrome.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn bodyText(h: *WinHarness) ![]u8 {
        return dump(&h.w.body);
    }
    fn dump(t: *Text) ![]u8 {
        const n = t.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, t.file.buffer.read(0, n, dest));
    }
};

test "cmd_edit: cut redirects a tag exec to the body selection" {
    const h = try WinHarness.init("hello world");
    defer h.deinit();
    const ed = &h.ed;

    // Body selection [0,5) = "hello"; seltext is the body (execute marks it).
    try h.w.body.setSelect(0, 5);
    ed.seq += 1;
    h.w.body.file.mark(ed.seq);

    // Cut executed in the TAG (et = tag, t0 = seltext = body). Redirection prefers
    // the body selection ⇒ the BODY is cut.
    try cut(ed, &h.w.tag, &h.w.body, null, true, true, "");
    try testing.expectEqualStrings("hello", ed.snarf.items);
    const body = try h.bodyText();
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(" world", body);
}

test "cmd_edit: snarf-only records argtext and leaves the text" {
    const h = try WinHarness.init("keepme");
    defer h.deinit();
    const ed = &h.ed;

    try h.w.body.setSelect(0, 4); // "keep"
    // Snarf (dosnarf=true, docut=false) copies without deleting and sets argtext.
    try cut(ed, &h.w.tag, &h.w.body, null, true, false, "");
    try testing.expectEqualStrings("keep", ed.snarf.items);
    try testing.expectEqual(&h.w.body, ed.argtext.?);
    const body = try h.bodyText();
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("keepme", body); // nothing deleted
}

test "cmd_edit: paste tobody lands in the body" {
    const h = try WinHarness.init("ab");
    defer h.deinit();
    const ed = &h.ed;
    try ed.snarf.appendSlice(testing.allocator, "XY");

    try h.w.body.setSelect(1, 1); // caret at 1
    ed.seq += 1;
    // Paste executed in the TAG with tobody ⇒ inserts into the BODY at its caret.
    try paste(ed, &h.w.tag, &h.w.tag, null, true, true, "");
    const body = try h.bodyText();
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("aXYb", body);
}

test "cmd_edit: undo then redo round-trips via the executing window" {
    const h = try WinHarness.init("");
    defer h.deinit();
    const ed = &h.ed;

    // Record one body edit.
    ed.seq += 1;
    h.w.body.file.mark(ed.seq);
    try h.w.body.insertAt(0, "data", true);

    // Undo (executed anywhere in the window — here the tag) reverses it.
    try undo(ed, &h.w.tag, null, null, true, false, "");
    {
        const body = try h.bodyText();
        defer testing.allocator.free(body);
        try testing.expectEqualStrings("", body);
    }
    // Redo re-applies and selects the restored range.
    try undo(ed, &h.w.tag, null, null, false, false, "");
    {
        const body = try h.bodyText();
        defer testing.allocator.free(body);
        try testing.expectEqualStrings("data", body);
    }
    try testing.expectEqual(@as(usize, 0), h.w.body.q0);
    try testing.expectEqual(@as(usize, 4), h.w.body.q1);

    // A further undo/redo with an empty stack is a silent no-op.
    try undo(ed, &h.w.tag, null, null, true, false, ""); // undo "data"
    try undo(ed, &h.w.tag, null, null, true, false, ""); // nothing left
    const body = try h.bodyText();
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("", body);
}
