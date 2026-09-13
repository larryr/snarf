//! The `Look` builtin (exec.c:1076-1097, exectab row exec.c:116) — the typed /
//! B2-executed twin of the B3 look gesture (R-EDIT-07). namespace module
//! (S-07 P-1). Ported from larryr/plan9port@337c6ac; cite as `exec.c:NN`.
//!
//! `Look` is pure search: it never expands a click and never opens a file. The
//! needle comes from one of three places, in the C's order — the inline argument
//! (`Look foo` swept or typed), a 2-1 chord argument (`argt`'s selection), or,
//! failing both, the BODY's own current selection. The search itself is
//! `look.search` (R-P12b-1: one search engine, never a second) with `reverse ==
//! FALSE` (exec.c:1087/1096); a miss is silent (look.c:317-319 returns FALSE with
//! no warning), and a hit scrolls+selects through `landHit`/`textshow`.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const exec = @import("exec.zig");
const look_mod = @import("../look.zig");

/// `look` (exec.c:1076-1097). `et` is the Text B2 fired in; everything happens in
/// `et->w->body` — the C takes `t = &et->w->body` (exec.c:1085), so a `Look` in a
/// TAG searches that window's body, and a `Look` with no window does nothing
/// (exec.c:1084 `if(et && et->w)`).
pub fn look(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    argt: ?*Text,
    _: bool,
    _: bool,
    arg: []const u8,
) Text.Error!void {
    const w = et.w orelse return; // exec.c:1084
    const t = &w.body; // exec.c:1085
    const a = ed.allocator;

    const needle: []u21 = blk: {
        // exec.c:1086-1089: an inline argument wins outright and RETURNS —
        // `getarg` is never consulted.
        if (arg.len > 0) break :blk try runesOfUtf8(a, arg);
        // exec.c:1090: the 2-1 chord argument (`getarg(argt, FALSE, FALSE, …)`).
        // `exec.getArg` is the same reduction New uses; a null/empty selection
        // gives the C's `r == nil`.
        if (try exec.getArg(ed, argt)) |bytes| {
            defer a.free(bytes);
            break :blk try runesOfUtf8(a, bytes);
        }
        // exec.c:1091-1094: no argument at all ⇒ the body's own selection
        // `[t->q0,t->q1)`, read straight out of the file.
        break :blk try runesOfRange(a, t, t.q0, t.q1);
    };
    defer a.free(needle);

    // exec.c:1096 `search(t, r, n, FALSE)`. An empty needle returns FALSE at
    // look.c:317 — the port's `search` short-circuits identically, so the C's
    // `n == 0` case needs no guard here.
    _ = try look_mod.search(ed, t, needle, false);
}

/// Decode valid UTF-8 into freshly allocated runes (the C's argument is already
/// `Rune*`; the port's exec layer carries UTF-8, S-07 §3).
fn runesOfUtf8(a: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u21 {
    const n = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
    const out = try a.alloc(u21, n);
    errdefer a.free(out);
    var view = std.unicode.Utf8View.initUnchecked(bytes);
    var it = view.iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) out[i] = cp;
    return out[0..i];
}

/// Read runes `[q0,q1)` out of `t`'s buffer (the C's `bufread` into a
/// `runemalloc`ed needle, exec.c:1092-1094).
fn runesOfRange(a: std.mem.Allocator, t: *Text, q0: usize, q1: usize) error{OutOfMemory}![]u21 {
    const n = if (q1 > q0) q1 - q0 else 0;
    const out = try a.alloc(u21, n);
    errdefer a.free(out);
    for (out, 0..) |*r, i| r.* = t.file.buffer.runeAt(q0 + i);
    return out;
}

// ===========================================================================
// Tests (T1-T5, phase-12b contract §4). A real Window (WinHarness, mirroring
// look.zig's harness) so `et.w` resolves and `look_mod.search`'s `textshow`
// arm runs for real.
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");
const Window = @import("../Window.zig");
const Chrome = @import("../Chrome.zig");

test "cmd_look: utf8 needle decodes to runes" {
    const r = try runesOfUtf8(testing.allocator, "aé\u{4e2d}");
    defer testing.allocator.free(r);
    try testing.expectEqualSlices(u21, &[_]u21{ 'a', 0xE9, 0x4E2D }, r);
}

const win_rect = proto.Rect.make(0, 20, 300, 380);

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
};

test "look builtin: tag Look searches the body selection (T1)" {
    // "foo bar foo\n": body selection on the FIRST foo [0,3); `Look` executed
    // from the tag (et = &w.tag, exec.c:1085 `t = &et->w->body`) with no arg and
    // no chord ⇒ the needle is the body's own selection, searched forward from
    // q1==3, landing on the SECOND foo [8,11).
    const h = try WinHarness.init("foo bar foo\n");
    defer h.deinit();
    try h.w.body.setSelect(0, 3);

    try look(&h.ed, &h.w.tag, null, null, false, false, "");
    try testing.expectEqual(@as(usize, 8), h.w.body.q0);
    try testing.expectEqual(@as(usize, 11), h.w.body.q1);
}

test "look builtin: inline arg wins outright over the selection (T2)" {
    // "foo bar foo\n": selection sits on a foo, but the inline arg "bar" is
    // used regardless (exec.c:1086-1089 returns before `getarg`/the selection
    // arm are ever consulted).
    const h = try WinHarness.init("foo bar foo\n");
    defer h.deinit();
    try h.w.body.setSelect(0, 3);

    try look(&h.ed, &h.w.body, null, null, false, false, "bar");
    try testing.expectEqual(@as(usize, 4), h.w.body.q0);
    try testing.expectEqual(@as(usize, 7), h.w.body.q1);
}

test "look builtin: 2-1 chord argument supplies the needle (T3)" {
    // No inline arg, no body selection to speak of (caret only) ⇒ `getArg`
    // reads the chord argument Text's own selection "bar" (exec.c:1090).
    const h = try WinHarness.init("foo bar foo\n");
    defer h.deinit();
    try h.w.body.setSelect(0, 0);

    var argfile = File.init(testing.allocator, try Buffer.initFromBytes(testing.allocator, "xxx bar yyy"));
    defer argfile.deinit();
    var argtext = try chordArgText(h, "bar", &argfile);
    defer argtext.deinit();

    try look(&h.ed, &h.w.body, null, &argtext, false, false, "");
    try testing.expectEqual(@as(usize, 4), h.w.body.q0);
    try testing.expectEqual(@as(usize, 7), h.w.body.q1);
}

/// Build a standalone Text over `file` with its selection set to the first
/// occurrence of `word` (a minimal 2-1 chord argument source).
fn chordArgText(h: *WinHarness, word: []const u8, file: *File) !Text {
    var t = try Text.init(file, testing.allocator, win_rect, h.fx.font, &h.fx.disp.image, h.fx.cols());
    try t.fill();
    const idx = blk: {
        var buf: [64]u8 = undefined;
        const n = file.buffer.len();
        const text = file.buffer.read(0, n, &buf);
        break :blk std.mem.indexOf(u8, text, word).?;
    };
    try t.setSelect(idx, idx + word.len);
    return t;
}

test "look builtin: a miss leaves q0/q1 alone and adds no warning (T4)" {
    const h = try WinHarness.init("foo bar foo\n");
    defer h.deinit();
    try h.w.body.setSelect(2, 2);

    try look(&h.ed, &h.w.body, null, null, false, false, "zzz");
    try testing.expectEqual(@as(usize, 2), h.w.body.q0);
    try testing.expectEqual(@as(usize, 2), h.w.body.q1);
    try testing.expectEqual(@as(usize, 0), h.ed.warningText().len);
}

test "look builtin: wraps from the last occurrence to the first (T5)" {
    // Selection on the LAST foo [8,11) ⇒ forward search from q1==11 wraps
    // around and lands on the FIRST foo [0,3) (look.c:385-389).
    const h = try WinHarness.init("foo bar foo\n");
    defer h.deinit();
    try h.w.body.setSelect(8, 11);

    try look(&h.ed, &h.w.body, null, null, false, false, "");
    try testing.expectEqual(@as(usize, 0), h.w.body.q0);
    try testing.expectEqual(@as(usize, 3), h.w.body.q1);
}
