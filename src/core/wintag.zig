//! Window TAG COMPOSITION (wind.c:437-593): `parsetag`, `winsettag1`,
//! `winsettag` and the rune helpers they are built from. Namespace module
//! (S-07 P-1) over `*Window` — carved out of `Window.zig` verbatim in phase 16a
//! so that file stays inside the ~400-line cap. `Window` keeps one-line
//! forwarders (`w.parseTag`, `w.setTag1`, `w.setTag`), so no call site moved.
//!
//! The `tag_state` cache the `frameEnd` sweep compares against stays a `Window`
//! field: it is window identity, and `Load`/`dirwin`/`Editor` write it directly.
//!
//! Phase 17 adds the NAME side of the tag: `setName` (`winsetname`,
//! wind.c:376-398), `commit` (`wincommit`'s tag half, wind.c:594-618 — editing
//! the name in a tag renames the window, undoably), `clearTag` (`wincleartag`,
//! wind.c:413-435) and the live ` Put` word (wind.c:514-518).
//!
//! WHERE THE TAG COMMIT FIRES (R-P17-7). acme commits a hand-edited tag name
//! from many places: any button press in a tag (acme.c:644-650), a `\n` or a
//! `typecommit` in the tag (text.c:938-939, :414-419), the 500 ms `KTimer`
//! (acme.c:470-479), the pointer leaving a text (acme.c:583-588), before a dump
//! (rows.c:364) and at the top of every `winsettag1` (wind.c:485-486). The port
//! keeps the button-down, `\n`/typecommit and dump sites, and the `winsettag1`
//! one through `setTagCommit` (the variants of `setTag1` that hold an `Editor`
//! — `setTag1` itself has no `ed` and so cannot bump `seq`). There is no timer
//! and no pointer-leave commit (no timer in the core; the button-down commit
//! covers the gesture that matters) — S-05 §2 records the divergence.
//!
//! Imports: `std` + `draw` + sibling core files only (S-07 §6).
const std = @import("std");
const draw = @import("draw");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const Editor = @import("Editor.zig");

const Rect = draw.Rect;
const Error = Text.Error;

// ===========================================================================
// Tag lifecycle (wind.c:437-593, :666-685). The C works in Rune arrays; this
// port decodes the tag to `[]u21`, does all strstr/compare/splice-index math in
// runes (so the `Text` splice offsets are correct for non-ASCII names), then
// issues `insertAt`/`deleteRange` with rune offsets + UTF-8 byte slices.
// ===========================================================================

/// `parsetag` boundary: the rune index where the file-name ends (wind.c:450-465).
const del_snarf_runes = [_]u21{ ' ', 'D', 'e', 'l', ' ', 'S', 'n', 'a', 'r', 'f' };

/// Decode the tag Text's whole buffer to an owned rune slice (caller frees).
fn tagRunes(w: *Window, a: std.mem.Allocator) error{OutOfMemory}![]u21 {
    const nc = w.tag.file.buffer.len();
    const r = try a.alloc(u21, nc);
    var i: usize = 0;
    while (i < nc) : (i += 1) r[i] = w.tag.file.buffer.runeAt(i);
    return r;
}

/// Encode a rune slice to owned UTF-8 (caller frees). Runes come from `runeAt`
/// (never surrogates), so encoding cannot fail; a stray invalid rune degrades to
/// U+FFFD rather than erroring.
fn runesToUtf8(a: std.mem.Allocator, runes: []const u21) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var tmp: [4]u8 = undefined;
    for (runes) |r| {
        const n = std.unicode.utf8Encode(r, &tmp) catch std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
        try buf.appendSlice(a, tmp[0..n]);
    }
    return buf.toOwnedSlice(a);
}

fn appendAsciiRunes(list: *std.ArrayList(u21), a: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
    for (s) |c| try list.append(a, c);
}

fn appendUtf8AsRunes(list: *std.ArrayList(u21), a: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
    const view = std.unicode.Utf8View.init(s) catch {
        for (s) |_| try list.append(a, 0xFFFD);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try list.append(a, cp);
}

fn indexOfRune(hay: []const u21, needle: u21) ?usize {
    for (hay, 0..) |r, i| if (r == needle) return i;
    return null;
}

fn indexOfRunes(hay: []const u21, needle: []const u21) ?usize {
    if (needle.len == 0) return 0;
    if (hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.mem.eql(u21, hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// The earliest " |" or "\t|" — the left-half terminator (wind.c:455-457).
fn pipeDelim(runes: []const u21) ?usize {
    const sp = indexOfRunes(runes, &[_]u21{ ' ', '|' });
    const tb = indexOfRunes(runes, &[_]u21{ '\t', '|' });
    if (sp) |s| return if (tb) |t| @min(s, t) else s;
    return tb;
}

/// `parsetag`'s name-end computation (wind.c:450-465), rune index.
fn nameEndRune(runes: []const u21) usize {
    const pipe = pipeDelim(runes);
    if (indexOfRunes(runes, &del_snarf_runes)) |ds| {
        if (pipe == null or ds < pipe.?) return ds;
    }
    var i: usize = 0;
    while (i < runes.len) : (i += 1) {
        if (runes[i] == ' ' or runes[i] == '\t') return i;
    }
    return runes.len;
}

/// `parsetag` (wind.c:437-467): return the whole tag as UTF-8 plus the name-end
/// index. NOTE: `name_len` is a RUNE index (the C's `*len`), equal to the byte
/// index for the ASCII tags of v1. Caller frees `text`.
/// What `parseTag` hands back: the tag's whole text (caller frees) and the
/// rune length of its file-name half. Named (it was an anonymous struct in
/// `Window.zig`) only so the `Window.parseTag` forwarder can name it.
pub const Parsed = struct { text: []u8, name_len: usize };

pub fn parseTag(w: *Window, a: std.mem.Allocator) error{OutOfMemory}!Parsed {
    const runes = try tagRunes(w, a);
    defer a.free(runes);
    const nl = nameEndRune(runes);
    const text = try runesToUtf8(a, runes);
    return .{ .text = text, .name_len = nl };
}

/// `winsettag1` (wind.c:469-577), ported per exec contract §3c. No tag cache, so
/// the C's ncache sync and `needundo` dance are n/a; the `tag.file->mod ⇒
/// wincommit` entry (wind.c:485-486) needs `ed` and lives in `setTagCommit`.
/// The Put arm is live since phase 17 (wind.c:514-518). taglines==1 ⇒ the final
/// `winresize` arm (wind.c:573-576) is dead, but `drawButton` (wind.c:572) is not.
pub fn setTag1(w: *Window) Error!void {
    const a = w.chrome.allocator;

    // old = current tag runes; name-splice if the tag's name half differs from
    // body.file.name (wind.c:487-495).
    var old = try tagRunes(w, a);
    defer a.free(old);
    {
        const i = nameEndRune(old);
        const old_name = try runesToUtf8(a, old[0..i]);
        defer a.free(old_name);
        if (!std.mem.eql(u8, old_name, w.body.file.name.items)) {
            try w.tag.deleteRange(0, i, true); // wind.c:489 textdelete
            try w.tag.insertAt(0, w.body.file.name.items, true); // wind.c:490 textinsert
            const fresh = try tagRunes(w, a); // wind.c:492-494 re-read
            a.free(old);
            old = fresh;
        }
    }

    // Compose `new` (wind.c:497-536).
    var new: std.ArrayList(u21) = .empty;
    defer new.deinit(a);
    try appendUtf8AsRunes(&new, a, w.body.file.name.items); // wind.c:500-502 name
    try appendAsciiRunes(&new, a, " Del Snarf"); // wind.c:503
    // wind.c:505: the whole Undo/Redo/Put menu hangs off `filemenu` (FALSE for
    // the generated `+Errors` windows, util.c:99).
    if (w.filemenu) {
        if (w.body.file.undoSeq() != 0) try appendAsciiRunes(&new, a, " Undo"); // wind.c:506-508
        if (w.body.file.redoSeq() != 0) try appendAsciiRunes(&new, a, " Redo"); // wind.c:510-512
        if (putShown(w)) try appendAsciiRunes(&new, a, " Put"); // wind.c:514-518
    }
    // wind.c:520-523: `Get` sits OUTSIDE the filemenu arm, so a directory
    // window — which has `filemenu == FALSE` (text.c:219) — still shows it.
    if (w.isdir) try appendAsciiRunes(&new, a, " Get"); // wind.c:521-522
    try appendAsciiRunes(&new, a, " |"); // wind.c:524
    // user-suffix preservation: k = just past the old '|'; else append " Look "
    // for a fresh window (wind.c:526-535).
    var k: usize = undefined;
    if (indexOfRune(old, '|')) |bar| {
        k = bar + 1;
    } else {
        k = old.len;
        if (w.body.file.seq == 0) try appendAsciiRunes(&new, a, " Look "); // wind.c:531-534
    }
    const i_new = new.items.len;

    // Replace [j,k) from the first differing rune if new != old[0..k]
    // (wind.c:538-562).
    if (!std.mem.eql(u21, new.items, old[0..k])) {
        const n = @min(k, i_new);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (old[j] != new.items[j]) break;
        }
        const q0 = w.tag.q0;
        const q1 = w.tag.q1;
        try w.tag.deleteRange(j, k, true); // wind.c:550
        const ins = try runesToUtf8(a, new.items[j..i_new]);
        defer a.free(ins);
        try w.tag.insertAt(j, ins, true); // wind.c:551
        // Preserve the user's tag selection past the bar (wind.c:552-561).
        if (indexOfRune(old, '|')) |bar_old| {
            if (q0 > bar_old) {
                const bar_new = indexOfRune(new.items, '|').?;
                const shift = @as(isize, @intCast(bar_new)) - @as(isize, @intCast(bar_old));
                w.tag.q0 = shiftClamp(q0, shift);
                w.tag.q1 = shiftClamp(q1, shift);
            }
        }
    }

    // Clear the tag file's mod flag, clamp + reselect, redraw the button
    // (wind.c:565-572). No ncache ⇒ n is just the tag length.
    w.tag_file.mod = false;
    const n_total = w.tag.file.buffer.len();
    if (w.tag.q0 > n_total) w.tag.q0 = n_total;
    if (w.tag.q1 > n_total) w.tag.q1 = n_total;
    try w.tag.setSelect(w.tag.q0, w.tag.q1);
    try w.drawButton();
}

/// wind.c:514-518 inside the `filemenu` block: `dirty = nname && (ncache ||
/// file->seq != putseq)` (no `ncache` in the port) and `!isdir && dirty`.
/// Also the sweep's `put` term — one predicate for both.
fn putShown(w: *Window) bool {
    const f = w.body.file;
    return w.filemenu and !w.isdir and f.name.items.len != 0 and f.seq != w.putseq;
}

fn shiftClamp(v: usize, shift: isize) usize {
    const r = @as(isize, @intCast(v)) + shift;
    return if (r < 0) 0 else @intCast(r);
}

/// `winsettag` (wind.c:577-593): the `file->ntext` fan-out collapses to one
/// `setTag1` (a single Text per File in v1).
pub fn setTag(w: *Window) Error!void {
    try w.setTag1();
}

/// `winsettag1` WITH its wind.c:485-486 entry: a tag whose text changed since
/// the last composition is committed first (a typed-but-uncommitted name
/// becomes the window's name instead of being spliced back over). For the call
/// sites that hold an `Editor` (the sweep, Put, Undo).
pub fn setTagCommit(ed: *Editor, w: *Window) Error!void {
    if (w.tag_file.mod) try commit(ed, w); // wind.c:485-486
    try setTag1(w);
}

/// `winsetname` (wind.c:376-398): equal ⇒ nothing; else `isscratch` from the
/// `/guide` / `+Errors` suffix, `filesetname` (which records the undoable
/// rename when `seq > 0`, file.c:139-148) and a retag. The single seam every
/// Window-level rename goes through (openfile, place, dirwin, served `name`,
/// `commit`, RowLoad).
pub fn setName(w: *Window, name: []const u8) Error!void {
    if (std.mem.eql(u8, name, w.body.file.name.items)) return; // wind.c:385-386
    w.isscratch = std.mem.endsWith(u8, name, "/guide") or std.mem.endsWith(u8, name, "+Errors"); // wind.c:387-391
    try w.body.file.setName(name); // wind.c:392
    try setTag1(w); // wind.c:393-396
}

/// `wincommit`'s TAG half (wind.c:608-616): the tag's name half differs from
/// the body file's name ⇒ the user renamed the window by editing its tag.
/// `seq++`, `filemark`, `mod = dirty = TRUE`, then `winsetname` — whose
/// `filesetname` records the old name, so `Undo` brings it back.
pub fn commit(ed: *Editor, w: *Window) Error!void {
    const a = w.chrome.allocator;
    const p = try parseTag(w, a); // wind.c:608
    defer a.free(p.text);
    const name = p.text[0..runeByteOffset(p.text, p.name_len)];
    if (std.mem.eql(u8, name, w.body.file.name.items)) {
        // In sync: nothing to rename. acme's next `winsettag1` would clear the
        // tag's mod (wind.c:565) — and acme runs one after every tag keystroke
        // (wind.c:401-408 `wintype`). Snarf retags lazily, so clear it here,
        // or a later `setTagCommit` (say, after an Undo that restored the OLD
        // name) would read the stale tag text as a fresh rename.
        w.tag_file.mod = false;
        return; // wind.c:609
    }
    ed.seq += 1; // wind.c:610
    w.body.file.mark(ed.seq); // wind.c:611
    w.body.file.mod = true; // wind.c:612
    w.dirty = true; // wind.c:613
    try setName(w, name); // wind.c:614
    try setTag1(w); // wind.c:615 (a no-op recomposition when setName already ran)
}

/// `wincleartag` (wind.c:413-435): drop everything after the first `|` that
/// follows the name — the user's tag suffix — leaving the composed menu. The
/// window must be committed (wind.c:420). RowLoad uses it before re-inserting
/// the dumped suffix (rows.c:800).
pub fn clearTag(w: *Window) Error!void {
    const a = w.chrome.allocator;
    const runes = try tagRunes(w, a);
    defer a.free(runes);
    const n = runes.len;
    var i = nameEndRune(runes); // wind.c:421 parsetag
    while (i < n and runes[i] != '|') i += 1; // wind.c:422-424
    if (i == n) return; // wind.c:425-426
    i += 1;
    try w.tag.deleteRange(i, n, true); // wind.c:428
    w.tag_file.mod = false; // wind.c:430
    if (w.tag.q0 > i) w.tag.q0 = i; // wind.c:431-432
    if (w.tag.q1 > i) w.tag.q1 = i; // wind.c:433-434
    try w.tag.setSelect(w.tag.q0, w.tag.q1); // wind.c:435
}

/// Byte offset of rune index `nr` in UTF-8 `s` (clamped to `s.len`).
fn runeByteOffset(s: []const u8, nr: usize) usize {
    var off: usize = 0;
    var k: usize = 0;
    while (k < nr and off < s.len) : (k += 1) {
        off += std.unicode.utf8ByteSequenceLength(s[off]) catch 1;
    }
    return @min(off, s.len);
}

/// The `frameEnd` LIVE-TAG SWEEP (R-P9-4; acme.c:512-515 redraws after draining
/// its warnings): for every window whose `{undo, redo, mod, put}` tuple differs
/// from the cached `w.tag_state`, recompose the tag (`setTagCommit`, wind.c:
/// 485-536 — a pending hand-edited name is committed first, as winsettag1
/// does) and update the cache. The C rewrites a tag on the events that change it; the
/// cache is what keeps this per-frame scan from doing a tag rewrite every tick.
/// Moved out of `Editor.frameEnd` in phase 16a — it is tag composition.
pub fn sweep(ed: *Editor) Error!void {
    if (ed.row) |row| {
        for (row.col.items) |c| {
            for (c.w.items) |w| {
                const f = w.body.file;
                const undo = f.undoSeq() != 0;
                const redo = f.redoSeq() != 0;
                const mod = f.mod;
                const put = putShown(w);
                if (undo != w.tag_state.undo or
                    redo != w.tag_state.redo or
                    mod != w.tag_state.mod or
                    put != w.tag_state.put)
                {
                    try setTagCommit(ed, w); // wind.c:485-536 recompose Undo/Redo/Put/mod
                    // Re-read: a commit marks the file (a new undo record).
                    w.tag_state = .{
                        .undo = f.undoSeq() != 0,
                        .redo = f.redoSeq() != 0,
                        .mod = f.mod,
                        .put = putShown(w),
                    };
                    ed.needs_flush = true;
                }
            }
        }
    }
}

// ===========================================================================
// Tests (wind.c:437-593). The fixture is `Window.WinHarness`, shared with
// `Window.zig`'s own tests; both files' cases were written against it.
// ===========================================================================
const testing = std.testing;
const proto = draw.proto;
const WinHarness = Window.WinHarness;
const win_rect = Window.win_rect;

test "window: parsetag finds the name end" {
    const a = testing.allocator;

    // " Del Snarf" (before the " |" pipe) ends the name.
    {
        const h = try WinHarness.init("body\n", win_rect);
        defer h.deinit();
        try h.w.tag.insertAt(0, "foo Del Snarf | Look ", true);
        const pt = try h.w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqual(@as(usize, 3), pt.name_len); // "foo"
        try testing.expectEqualStrings("foo Del Snarf | Look ", pt.text);
    }

    // "\t|" is a valid pipe terminator; a " Del Snarf" AFTER the pipe is ignored,
    // so the name ends at the first blank.
    {
        const h = try WinHarness.init("body\n", win_rect);
        defer h.deinit();
        try h.w.tag.insertAt(0, "a b\t| Del Snarf", true);
        const pt = try h.w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqual(@as(usize, 1), pt.name_len); // "a"
    }

    // A name with no blanks and no pipe: the whole tag is the name.
    {
        const h = try WinHarness.init("body\n", win_rect);
        defer h.deinit();
        try h.w.tag.insertAt(0, "foobar", true);
        const pt = try h.w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqual(@as(usize, 6), pt.name_len);
    }
}

test "window: putShown — named+edited is true, putseq==seq/unnamed/dir are false (T5)" {
    const h = try WinHarness.init("hello\n", win_rect);
    defer h.deinit();
    const w = &h.w;
    try h.body_file.setName("f");

    // Fresh: seq==0==putseq ⇒ false (even though named).
    try testing.expect(!putShown(w));

    // Named + a recorded edit (seq != putseq) ⇒ true.
    h.body_file.mark(1);
    try w.body.insertAt(0, "X", true);
    try testing.expect(putShown(w));

    // putseq caught up to seq (a completed Put) ⇒ false again.
    w.putseq = h.body_file.seq;
    try testing.expect(!putShown(w));
    w.putseq = 0; // restore for the cases below

    // Unnamed (empty name) ⇒ false regardless of seq/putseq.
    try h.body_file.setName("");
    try testing.expect(!putShown(w));
    try h.body_file.setName("f");

    // A directory window never shows Put, named or not.
    w.isdir = true;
    try testing.expect(!putShown(w));
    w.isdir = false;

    // filemenu==false (the `+Errors`/`guide` shape) never shows Put either —
    // guarded at the `setTag1` call site, not inside `putShown` itself, so
    // exercise it there.
    w.filemenu = false;
    try w.setTag1();
    {
        const pt = try w.parseTag(testing.allocator);
        defer testing.allocator.free(pt.text);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Put") == null);
    }
}

test "window: sweep recomposes the tag when putseq changes alone, with no new edit/undo/redo (T5)" {
    const h = try Editor.TwoWin.init();
    defer h.deinit();

    try h.w1.body.file.setName("one"); // TwoWin already names it "one"; explicit for clarity
    h.ed.seq += 1;
    h.w1.body.file.mark(h.ed.seq);
    try h.w1.body.insertAt(0, "X", true);

    try sweep(&h.ed);
    try testing.expect(h.w1.tag_state.put);
    {
        const pt = try h.w1.parseTag(testing.allocator);
        defer testing.allocator.free(pt.text);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Put") != null);
    }

    // Nothing else changes (no new mark, no undo/redo) — only putseq catching
    // up to the file's seq, as `Put`'s own completion does (R-P17-1 tail).
    h.w1.putseq = h.w1.body.file.seq;
    try sweep(&h.ed);
    try testing.expect(!h.w1.tag_state.put);
    {
        const pt = try h.w1.parseTag(testing.allocator);
        defer testing.allocator.free(pt.text);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Put") == null);
    }
}

test "window: commit — a hand-edited tag name is adopted on button-down, undoably; the suffix past '|' never renames (T6)" {
    const a = testing.allocator;
    const h = try WinHarness.init("hello\n", win_rect);
    defer h.deinit();
    const w = &h.w;
    try h.body_file.setName("f");
    try w.setTag1(); // "f Del Snarf | Look "

    var ed = Editor.init(a);
    defer ed.deinit();

    // Edit the tag's NAME half: "f" -> "g" (simulates typing, then B2/B1
    // button-down landing in the tag before textselect.run — acme.c:644-650).
    try w.tag.deleteRange(0, 1, true);
    try w.tag.insertAt(0, "g", true);
    try testing.expect(w.tag_file.mod);

    try commit(&ed, w);
    try testing.expectEqualStrings("g", w.body.file.name.items);
    try testing.expectEqual(@as(u32, 1), ed.seq);
    try testing.expectEqual(@as(u32, 1), w.body.file.seq);
    try testing.expect(w.body.file.mod);
    try testing.expect(w.dirty);
    try testing.expect(!w.tag_file.mod); // cleared by the setTag1 tail
    {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        try testing.expect(std.mem.indexOf(u8, pt.text, "Undo") != null);
        try testing.expect(std.mem.indexOf(u8, pt.text, "Put") != null);
        try testing.expect(std.mem.startsWith(u8, pt.text, "g "));
    }

    // Undo restores the OLD name — in the File immediately, and in the tag
    // once recomposed.
    _ = try h.body_file.undo();
    try testing.expectEqualStrings("f", w.body.file.name.items);
    try w.setTag1();
    {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        try testing.expect(std.mem.startsWith(u8, pt.text, "f "));
    }

    // A rename to an isscratch-shaped name (+Errors suffix) sets isscratch.
    try w.tag.deleteRange(0, 1, true);
    try w.tag.insertAt(0, "+Errors", true);
    try testing.expect(!w.isscratch);
    try commit(&ed, w);
    try testing.expect(w.isscratch);

    // Editing the SUFFIX (right of '|') is not a rename: the name half is
    // unchanged, so commit is a no-op on seq/name, and it still clears mod.
    const seq_before = ed.seq;
    const file_seq_before = w.body.file.seq;
    const bar = blk: {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        break :blk std.mem.indexOfScalar(u8, pt.text, '|').?;
    };
    try w.tag.insertAt(bar + 2, "xyz", true); // past "| "
    try testing.expect(w.tag_file.mod);
    try commit(&ed, w);
    try testing.expectEqual(seq_before, ed.seq);
    try testing.expectEqual(file_seq_before, w.body.file.seq);
    try testing.expectEqualStrings("+Errors", w.body.file.name.items);
    try testing.expect(!w.tag_file.mod);
}

test "window: setTag1 recomposition" {
    const a = testing.allocator;
    const h = try WinHarness.init("hello\n", win_rect);
    defer h.deinit();
    const w = &h.w;
    try h.body_file.setName("f");

    // Fresh window (seq==0, no undo/redo): the composed tag is byte-exact.
    try w.setTag1();
    {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqualStrings("f Del Snarf | Look ", pt.text);
    }

    // A user types a suffix after the '|'.
    try w.tag.insertAt(w.tag.file.buffer.len(), "xyz", true); // "f Del Snarf | Look xyz"

    // Select the user suffix "xyz" (both ends are past the bar).
    try w.tag.setSelect(19, 22);

    // A recorded body edit ⇒ undoSeq()!=0 ⇒ " Undo" appears before the pipe —
    // and, the window being NAMED with `seq != putseq`, " Put" too (wind.c:514,
    // phase 17); the user suffix after '|' survives verbatim, and the selection
    // shifts by the bar displacement (+9 for " Undo Put", wind.c:554-562).
    h.body_file.mark(1);
    try w.body.insertAt(0, "X", true);
    try w.setTag1();
    {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqualStrings("f Del Snarf Undo Put | Look xyz", pt.text);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Undo") != null);
    }
    try testing.expectEqual(@as(usize, 28), w.tag.q0); // 19 + 9
    try testing.expectEqual(@as(usize, 31), w.tag.q1); // 22 + 9

    // Undo the body edit ⇒ redoSeq()!=0, undoSeq()==0 ⇒ " Redo" replaces " Undo".
    _ = try h.body_file.undo();
    try w.setTag1();
    {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqualStrings("f Del Snarf Redo | Look xyz", pt.text);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Undo") == null);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Redo") != null);
        // The user suffix after the pipe is still there.
        try testing.expect(std.mem.endsWith(u8, pt.text, " Look xyz"));
    }
}
