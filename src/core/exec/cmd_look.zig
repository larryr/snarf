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
// Tests. The named `Look` tests (T1-T5 of the phase-12b contract) are written
// separately; this smoke test only keeps the module reachable.
// ===========================================================================
const testing = std.testing;

test "cmd_look: utf8 needle decodes to runes" {
    const r = try runesOfUtf8(testing.allocator, "aé\u{4e2d}");
    defer testing.allocator.free(r);
    try testing.expectEqualSlices(u21, &[_]u21{ 'a', 0xE9, 0x4E2D }, r);
}
