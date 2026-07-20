//! `execute` — the B2 command dispatcher (acme/exec.c:157-259), builtin arm only.
//! namespace module (S-07 P-1): a `lowercase.zig` gateway aliased on `Editor` by
//! the gesture code (9d), the way Text aliases its select/scroll modules. Ported
//! from larryr/plan9port@337c6ac; cite as `exec.c:NN` / `look.c:NN`.
//!
//! A B2 gesture yields an absolute rune range `[aq0,aq1)` in the Text `t` it
//! landed on. `execute` word-expands a bare click, looks the word up in the
//! comptime `builtins.exectab`, marks the command's default target when the entry
//! requires it, and calls the entry's function with the C's `(et=t, t=seltext,
//! argt)` convention. An unknown word is a SILENT NO-OP: the external `run` path
//! (exec.c:249-258) and the winevent branch (exec.c:190-233) are the namespace
//! phase (R-P9-7).
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const Buffer = @import("../Buffer.zig");
const select = @import("../text/select.zig");
const builtins = @import("builtins.zig");

/// `execute` (exec.c:157-259), builtin arm. `[aq0,aq1)` are ABSOLUTE rune coords
/// in `t` (the caller adds `t.org` to a frame range). When `aq0==aq1` (a click):
/// if the click sits inside `t`'s own selection, that selection is the word
/// (exec.c:166-170); otherwise expand both ways over `isexecc` runes, stopping at
/// ':' (exec.c:171-176). An empty expansion returns. The looked-up word not being
/// a builtin is a silent no-op. On a match: bump `ed.seq` + `File.mark` the
/// command's default target when the entry marks and `seltext` is a body
/// (exec.c:236-240), then invoke `e.fn_(ed, et=t, t=seltext, argt, flag1, flag2,
/// arg)` where `arg` is the UTF-8 remainder after the command word (exec.c:241-244).
pub fn execute(ed: *Editor, t: *Text, aq0: usize, aq1: usize, argt: ?*Text) Text.Error!void {
    var q0 = aq0;
    var q1 = aq1;
    if (q1 == q0) { // exec.c:164 expand to find the word
        if (t.q1 > t.q0 and t.q0 <= q0 and q0 <= t.q1) {
            // exec.c:166-170: a click inside the selection ⇒ use the selection.
            q0 = t.q0;
            q1 = t.q1;
        } else {
            const nc = t.file.buffer.len();
            // exec.c:171-172: forward over isexecc runes, stopping at ':'.
            while (q1 < nc) : (q1 += 1) {
                const c = t.file.buffer.runeAt(q1);
                if (!isexecc(c) or c == ':') break;
            }
            // exec.c:173-174: backward likewise.
            while (q0 > 0) {
                const c = t.file.buffer.runeAt(q0 - 1);
                if (!isexecc(c) or c == ':') break;
                q0 -= 1;
            }
            if (q1 == q0) return; // exec.c:175-176 nothing to execute
        }
    }

    // exec.c:177-179: read the executed runes as UTF-8.
    const runes = try readRunes(ed.allocator, t, q0, q1);
    defer ed.allocator.free(runes);

    // exec.c:180 lookup; not a builtin ⇒ silent no-op (external run FLAG-deferred).
    const e = lookup(runes) orelse return;

    // exec.c:236-240: mark the command's default target (seltext) before running.
    if (e.mark) {
        if (ed.seltext) |st| {
            if (st.what == .body) {
                ed.seq += 1; // exec.c:238 seq++
                st.file.mark(ed.seq); // exec.c:239 filemark(seltext->w->body.file)
            }
        }
    }

    // exec.c:241-243: arg = the remainder after the first word (skipbl/findbl/skipbl).
    const arg = argAfter(runes);
    // exec.c:244: (*e->fn)(t, seltext, argt, flag1, flag2, s, n) — et=t, t=seltext.
    try e.fn_(ed, t, ed.seltext, argt, e.flag1, e.flag2, arg);
}

/// `isfilec` (look.c:442-450): alnum (util.c-faithful, via select.isAlnum) plus
/// the filename punctuation `.-+/:@`. Pub so O19's later `expand()` shares it.
pub fn isfilec(r: u21) bool {
    if (select.isAlnum(r)) return true;
    return switch (r) {
        '.', '-', '+', '/', ':', '@' => true,
        else => false,
    };
}

/// `isexecc` (exec.c:149-155): `isfilec` plus the shell redirect/pipe runes.
pub fn isexecc(r: u21) bool {
    if (isfilec(r)) return true;
    return r == '<' or r == '|' or r == '>';
}

/// `getarg` (exec.c:276-312), v1 (R-P9-11): the RAW `argt` selection `[q0,q1)`
/// bytes (the `expand()` filename arm is O19's upgrade seam, TODO; `doaddr`/
/// `printarg` dropped). Null when `argt` is null or the selection is empty. The
/// caller owns and frees the returned slice. TODO(O19): when `expand` lands,
/// upgrade to the C's filename expansion (exec.c:283-296).
pub fn getArg(ed: *Editor, argt: ?*Text) error{OutOfMemory}!?[]u8 {
    const at = argt orelse return null; // exec.c:285-286
    const q0 = at.q0;
    const q1 = at.q1;
    if (q1 <= q0) return null; // empty selection ⇒ no argument
    return try readRunes(ed.allocator, at, q0, q1);
}

/// `lookup` (exec.c:132-148): skip leading blanks, take the first blank-delimited
/// word, linear-scan the comptime `exectab`. Returns null when the text is blank
/// or the word is not a builtin.
fn lookup(text: []const u8) ?*const builtins.Entry {
    const s = skipbl(text);
    if (s.len == 0) return null; // exec.c:138-139
    const word = firstWord(s);
    for (&builtins.exectab) |*e| {
        if (std.mem.eql(u8, word, e.name)) return e; // exec.c:143-145
    }
    return null; // exec.c:146
}

/// Read runes `[q0,q1)` of `t`'s buffer as decoded UTF-8 (caller frees). Mirrors
/// the chunked capture in `Editor.cut`; blanks and the ASCII command names are
/// single bytes, so byte-level `skipbl`/`findbl` on the result are rune-correct.
fn readRunes(a: std.mem.Allocator, t: *Text, q0: usize, q1: usize) error{OutOfMemory}![]u8 {
    const n = q1 - q0;
    const dest = try a.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer a.free(dest);
    return a.dupe(u8, t.file.buffer.read(q0, n, dest));
}

/// `skipbl` (util.c): drop leading blanks (space/tab).
fn skipbl(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    return s[i..];
}

/// The leading non-blank run of `s` (the C's word = `findbl(s)-s`).
fn firstWord(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and !isBlank(s[i])) i += 1;
    return s[0..i];
}

/// The remainder after the first word (exec.c:241-243 `skipbl(findbl(skipbl))`).
fn argAfter(s: []const u8) []const u8 {
    const a = skipbl(s);
    const word = firstWord(a);
    return skipbl(a[word.len..]);
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

// ===========================================================================
// Tests (exec side §4, master 9c). Direct `execute` calls — no gesture machine
// (that is 9d). A booted tree gives real chrome/geometry for the tree-mutating
// builtins.
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("../File.zig");
const Window = @import("../Window.zig");
const Column = @import("../Column.zig");
const boot = @import("../boot.zig");

// Pull the sibling builtins/command test blocks into this module's test binary
// (the Text.zig convention).
test {
    _ = @import("builtins.zig");
    _ = @import("cmd_edit.zig");
    _ = @import("cmd_window.zig");
}

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

/// A booted scene with the Editor router bound to the tree.
const Scene = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,

    fn init(name: []const u8, body: []const u8) !*Scene {
        const a = testing.allocator;
        const h = try a.create(Scene);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 600, 460), .{
            .win_name = name,
            .body = body,
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
    fn col0(h: *Scene) *Column {
        return h.tree.row.col.items[0];
    }
    fn win0(h: *Scene) *Window {
        return h.col0().w.items[0];
    }
    fn bodyText(t: *Text) ![]u8 {
        const n = t.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, t.file.buffer.read(0, n, dest));
    }
};

/// The absolute rune range of the first occurrence of ASCII `word` in `t`'s
/// buffer (a swept command). Runes of ASCII equal their byte values.
fn wordRange(t: *Text, word: []const u8) [2]usize {
    const nc = t.file.buffer.len();
    var i: usize = 0;
    outer: while (i + word.len <= nc) : (i += 1) {
        for (word, 0..) |ch, j| {
            if (t.file.buffer.runeAt(i + j) != ch) continue :outer;
        }
        return .{ i, i + word.len };
    }
    unreachable;
}

// --- isexecc / expansion pins ------------------------------------------------

test "exec: word expansion stops at blanks and colon" {
    // isexecc pin: alnum + `.-+/:@<|>` are word runes; blanks are not; ':' stops.
    try testing.expect(isexecc('U') and isexecc('/') and isexecc('.') and isexecc('|'));
    try testing.expect(isexecc(':')); // isfilec includes ':'
    try testing.expect(!isexecc(' ') and !isexecc('\t') and !isexecc('\n'));

    // Body "Undo file.txt:12". A click mid-"Undo" expands to exactly "Undo".
    const h = try Scene.init("scratch", "Undo file.txt:12\n");
    defer h.deinit();
    const t = &h.win0().body;
    try t.setSelect(2, 2); // caret inside "Undo"
    try execute(&h.ed, t, 2, 2, null); // expands, runs Undo (no-op: nothing to undo)

    // "file.txt:12" — a click inside "txt" expands over isexecc but STOPS at the
    // ':' both ways, yielding "file.txt" (never "file.txt:12"), which is not a
    // builtin ⇒ silent no-op. Verify via lookup on the read slice.
    const r = try readRunes(testing.allocator, t, 5, 13); // "file.txt"
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("file.txt", r);
    try testing.expect(lookup(r) == null);
}

test "exec: unknown word is a no-op" {
    // A swept word that is not a builtin does nothing — no crash, no warning spam
    // (the external run path is the namespace phase, R-P9-7).
    const h = try Scene.init("scratch", "Frobnicate the gizmo\n");
    defer h.deinit();
    const t = &h.win0().body;
    const before_seq = h.ed.seq;
    const rng = wordRange(t, "Frobnicate");
    try execute(&h.ed, t, rng[0], rng[1], null);
    try testing.expectEqual(before_seq, h.ed.seq); // nothing marked
    try testing.expectEqual(@as(usize, 0), h.ed.warnings.items.len); // no warning
    // The buffer is untouched.
    const body = try Scene.bodyText(t);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("Frobnicate the gizmo\n", body);
}

// --- Snarf/Cut dispatch pins -------------------------------------------------

test "exec: B2 sweep executes exactly the swept text" {
    // Body "Cut junk": B2-sweep the word "Cut" [0,3). Cut runs against the body
    // selection; the sweep range itself never becomes the persistent selection.
    const h = try Scene.init("scratch", "Cut junk");
    defer h.deinit();
    const t = &h.win0().body;

    // A real body selection [4,8) = "junk" is the command's default target.
    try t.setSelect(4, 8);
    h.ed.seltext = t; // the last B1-selected Text (9d sets this)

    // Sweep "Cut" = [0,3) and dispatch. The swept range is passed as [q0,q1);
    // t.q0/q1 (the selection) is what Cut operates on and is untouched by the
    // sweep itself.
    try execute(&h.ed, t, 0, 3, null);
    try testing.expectEqualStrings("junk", h.ed.snarf.items);
    const body = try Scene.bodyText(t);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("Cut ", body); // "junk" cut
    try testing.expectEqual(@as(u32, 1), h.ed.seq); // Cut marked once
}

test "exec: click inside the selection executes the selection" {
    // exec.c:166-170: when the click (q0==q1) lands inside t's selection, the
    // selection is taken as the command word. Here the selection is literally the
    // word "Snarf", so a click inside it runs Snarf.
    const h = try Scene.init("scratch", "Snarf me\n");
    defer h.deinit();
    const t = &h.win0().body;

    try t.setSelect(0, 5); // select "Snarf"
    h.ed.seltext = t;
    try execute(&h.ed, t, 2, 2, null); // click inside the selection
    // Snarf copies the selection ("Snarf") into the snarf buffer, no delete.
    try testing.expectEqualStrings("Snarf", h.ed.snarf.items);
    const body = try Scene.bodyText(t);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("Snarf me\n", body); // unchanged (Snarf, not Cut)
}

test "exec: tag exec routes to the body (et/t routing)" {
    // Cut executed in a window TAG (exec.c:957-974). With a BODY selection ⇒ the
    // body is cut; with only a TAG selection ⇒ the tag is cut.
    {
        const h = try Scene.init("one", "hello world\n");
        defer h.deinit();
        const w = h.win0();
        // Append "Cut" to the tag; we sweep it to identify the command.
        const tw = w.tag.file.buffer.len();
        try w.tag.insertAt(tw, "Cut", true);
        try w.body.setSelect(0, 5); // "hello"
        try w.tag.setSelect(0, 0); // no tag selection
        h.ed.seltext = &w.body;
        try execute(&h.ed, &w.tag, tw, tw + 3, null); // B2 "Cut" in the tag
        try testing.expectEqualStrings("hello", h.ed.snarf.items);
        const body = try Scene.bodyText(&w.body);
        defer testing.allocator.free(body);
        try testing.expectEqualStrings(" world\n", body); // the BODY was cut
    }
    {
        const h = try Scene.init("one", "hello world\n");
        defer h.deinit();
        const w = h.win0();
        const tw = w.tag.file.buffer.len();
        try w.tag.insertAt(tw, "Cut", true); // [tw, tw+3) = "Cut"
        try w.body.setSelect(0, 0); // NO body selection
        try w.tag.setSelect(tw, tw + 3); // tag selection = the "Cut" word
        h.ed.seltext = &w.body; // seltext is the body, but it has no selection
        try execute(&h.ed, &w.tag, tw, tw + 3, null);
        // Body has no selection ⇒ redirection falls to the TAG selection: the tag
        // text ("Cut") is cut into the snarf buffer.
        try testing.expectEqualStrings("Cut", h.ed.snarf.items);
        try testing.expect(w.tag.file.buffer.len() == tw); // "Cut" removed from the tag
    }
}

// --- window/column lifecycle pins --------------------------------------------

test "exec: Delete closes a dirty window immediately" {
    // Delete (flag1) skips the two-strike clean check: a dirty window is gone at
    // once, and the neighbor grows back over it.
    const seed1 = try genLines(testing.allocator, 20);
    defer testing.allocator.free(seed1);
    const h = try Scene.init("one", seed1);
    defer h.deinit();
    const c = h.col0();
    const seed2 = try genLines(testing.allocator, 20);
    defer testing.allocator.free(seed2);
    const w2 = try h.tree.addWindow("two", seed2);
    const w1 = c.w.items[0];
    try testing.expectEqual(@as(usize, 2), c.w.items.len);

    // Dirty window 2 (named, so a two-strike Del WOULD warn — Delete must not).
    try w2.body.file.setName("two");
    h.ed.seq += 1;
    w2.body.file.mark(h.ed.seq);
    try w2.body.insertAt(0, "X", true);
    try testing.expect(w2.dirty);

    // Append "Delete" to window 2's tag and sweep it. Delete (flag1) closes the
    // dirty window immediately with no two-strike and no warning.
    const tw = w2.tag.file.buffer.len();
    try w2.tag.insertAt(tw, " Delete", true);
    const rng = wordRange(&w2.tag, "Delete");
    try execute(&h.ed, &w2.tag, rng[0], rng[1], null);

    // Window 2 is gone at once; window 1 grew back to cover the column region.
    try testing.expectEqual(@as(usize, 1), c.w.items.len);
    try testing.expectEqual(w1, c.w.items[0]);
    try testing.expectEqual(c.r.max.y, w1.r.max.y); // extended down over the freed rect
    try testing.expectEqual(@as(usize, 0), h.ed.warnings.items.len); // Delete never warns
}

test "exec: New/Newcol/Delcol mutate the tree" {
    const seed = try genLines(testing.allocator, 20);
    defer testing.allocator.free(seed);
    const h = try Scene.init("one", seed);
    defer h.deinit();
    const row = h.tree.row;
    const c0 = h.col0();

    // --- New: a swept "New" on the column tag adds one unnamed empty window. ---
    {
        const before = c0.w.items.len;
        const rng = wordRange(&c0.tag, "New");
        try execute(&h.ed, &c0.tag, rng[0], rng[1], null);
        try testing.expectEqual(before + 1, c0.w.items.len);
        const nw = c0.w.items[c0.w.items.len - 1];
        try testing.expectEqual(@as(usize, 0), nw.body.file.buffer.len()); // empty
    }

    // --- Newcol: a swept "Newcol" on the row tag adds a column with one empty
    //     window. ---
    {
        const before = row.col.items.len;
        const rng = wordRange(&row.tag, "Newcol");
        try execute(&h.ed, &row.tag, rng[0], rng[1], null);
        try testing.expectEqual(before + 1, row.col.items.len);
        const c1 = row.col.items[row.col.items.len - 1];
        try testing.expectEqual(@as(usize, 1), c1.w.items.len); // carries one window
        try testing.expectEqual(@as(usize, 0), c1.w.items[0].body.file.buffer.len());
    }

    // --- Delcol two-strike: dirty the new column's window, Delcol refuses+warns
    //     once (colclean strikes with no short-circuit), then succeeds. ---
    {
        const c1 = row.col.items[row.col.items.len - 1];
        try c1.w.items[0].body.file.setName("dirtyone");
        h.ed.seq += 1;
        c1.w.items[0].body.file.mark(h.ed.seq);
        try c1.w.items[0].body.insertAt(0, "Z", true);
        try testing.expect(c1.w.items[0].dirty);

        const cols_before = row.col.items.len;
        const rng = wordRange(&c1.tag, "Delcol");
        try execute(&h.ed, &c1.tag, rng[0], rng[1], null); // first strike: refuse
        try testing.expectEqual(cols_before, row.col.items.len); // still there
        try testing.expect(!c1.w.items[0].dirty); // struck
        try testing.expect(std.mem.indexOf(u8, h.ed.warnings.items, "dirtyone modified") != null);

        // Second Delcol (c1 now clean) closes the column; c0 grows to the right.
        try execute(&h.ed, &c1.tag, rng[0], rng[1], null);
        try testing.expectEqual(cols_before - 1, row.col.items.len);
        try testing.expectEqual(c0, row.col.items[0]);
        try testing.expectEqual(row.r.max.x, c0.r.max.x); // neighbor extended right
    }

    // --- Delcol white-fills when last: c0 is clean (its windows untouched), so a
    //     final Delcol empties the row. ---
    {
        const rng = wordRange(&c0.tag, "Delcol");
        try execute(&h.ed, &c0.tag, rng[0], rng[1], null);
        try testing.expectEqual(@as(usize, 0), row.col.items.len);
    }
}
