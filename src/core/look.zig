//! `look` / `search` — B3 look3 v1 (look.c:82-229), reduced to the literal,
//! within-window search arm plus its bare-click alnum expansion (look.c:731-756).
//! Namespace module (lowercase), aliased on `Editor` like Text's select/scroll.
//! Ported from larryr/plan9port@337c6ac; cite as `look.c:NN`.
//!
//! v1 scope (master R-P9-8 / look side §3.3). DEFERRED to the namespace phases:
//! the external-client arm (look.c:97-146, no 9P clients), the plumber arm
//! (look.c:147-196), and the openfile/URL/file arm (look.c:200-201 +
//! `expandfile` look.c:592-729). With no host fs `expandfile` always fails
//! (look.c:745), so a bare B3 click faithfully reduces to the alnum run
//! (look.c:748-752) — FLAG-DIVERGENCE noted in the master. Permanently dropped:
//! the `e.jump`/`moveto` mouse warp on a hit (look.c:219, R-P8-6 lineage) and
//! winlock/unlock (look.c:206-207/220-221, single-threaded). `winsettag` on a hit
//! (look.c:418) is covered for free by the frameEnd tag sweep (R-P9-4).
const std = @import("std");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const select = @import("text/select.zig");

/// look3 v1 (look.c:82-229, minus the deferred arms above). `[q0,q1)` are
/// absolute rune coords in `t`. When `q0==q1` the range is expanded (a click
/// inside `t`'s selection captures it, look.c:738-743; otherwise the alnum run,
/// look.c:748-752); a non-empty `[q0,q1)` is taken as the literal needle. B3 in
/// a tag searches the owning window's BODY (look.c:205), with the needle still
/// read from the CLICKED text's file (look.c:217). An empty expansion is a silent
/// no-op (look.c:197-199). `reverse` selects the backward scan (Shift-B3).
pub fn look(ed: *Editor, t: *Text, q0: usize, q1: usize, reverse: bool) Text.Error!void {
    // --- expand (look.c:731-756) — find the needle range [e0,e1) in `t`. ------
    var e0 = q0;
    var e1 = q1;
    const nc = t.file.buffer.len();
    if (q1 == q0 and t.q1 > t.q0 and t.q0 <= q0 and q0 <= t.q1) {
        // look.c:738-743: a bare click inside the current selection ⇒ the
        // selection itself is the needle. (The `e->jump=FALSE` tag tweak only fed
        // the dropped `moveto` warp, so it is irrelevant here.)
        e0 = t.q0;
        e1 = t.q1;
    } else if (q1 == q0) {
        // look.c:745 `expandfile` is the DEFERRED file/URL arm (always fails with
        // no host fs, R-P9-8), so the faithful v1 bare-click expansion is the
        // alnum run (look.c:748-752), reusing select.zig's util.c-faithful
        // isAlnum.
        while (e1 < nc and select.isAlnum(t.file.buffer.runeAt(e1))) e1 += 1;
        while (e0 > 0 and select.isAlnum(t.file.buffer.runeAt(e0 - 1))) e0 -= 1;
    }
    // look.c:197-199: `expanded == FALSE` (nothing to search) ⇒ silent return.
    if (e1 <= e0) return;

    // look.c:203-205: B3 in a tag searches the BODY. The `else t` branch is a
    // documented harness divergence — the C `return`s when `t->w==nil`
    // (look.c:203-204); routing to `t` lets standalone-Text tests exercise this
    // arm directly (R-P9-8 / look side §3.4).
    const ct = if (t.w) |w| &w.body else t;

    // look.c:208-213: only when clicking the body itself (`t == ct`), collapse
    // the caret to the END of the expanded word (its START if reverse) so the
    // search starts PAST the current match. A failed search then faithfully
    // leaves the caret collapsed there (look side §1.4).
    if (t == ct) {
        const q = if (reverse) e0 else e1;
        try ct.setSelect(q, q);
    }

    // look.c:215-217: the needle runes [e0,e1) come from the CLICKED text's file
    // (matters for tag clicks: `t.file` is the tag, `ct` is the body).
    const needle = try ed.allocator.alloc(u21, e1 - e0);
    defer ed.allocator.free(needle);
    for (needle, 0..) |*r, i| r.* = t.file.buffer.runeAt(e0 + i);

    // look.c:218: search `ct`; the `e.jump`/`moveto` warp on a hit is dropped.
    _ = try search(ed, ct, needle, reverse);
}

/// `search` (look.c:313-441) as a plain `Buffer.runeAt` scan. The C's `fbuf`
/// windowing (look.c:391-407) is a bufread optimization — Buffer already
/// block-caches, so it is dropped, and with it the `2*n > RBUFSIZE` "string too
/// long" cap (look.c:320-322). Forward from `ct.q1` with wraparound (look.c:
/// 381-436); reverse from `ct.q0` (look.c:330-380). Both terminate after one full
/// lap; a SOLE occurrence re-finds itself after wrapping (look.c:432-435). On a
/// hit: `ct.show(...)`/`ct.q0,q1` + `ed.seltext = ct` (look.c:421-427/369-375);
/// on a miss nothing changes and `false` is returned.
pub fn search(ed: *Editor, ct: *Text, needle: []const u21, reverse: bool) Text.Error!bool {
    const n = needle.len;
    const nc = ct.file.buffer.len();
    // look.c:317-319: empty needle or a needle longer than the file ⇒ no match.
    if (n == 0 or n > nc) return false;

    var around = false;
    if (reverse) {
        // look.c:330-380: `q1` is the (past-the-)end of the window being tested;
        // the match is `[q1-n, q1)`. Start at `ct.q0`, wrap to `nc` at 0, break
        // after one lap when `q1` returns to 0 (look.c:377-379 `q1<=0`).
        var q1: usize = ct.q0;
        while (true) {
            if (q1 == 0) { // look.c:333-337
                q1 = nc;
                around = true;
            }
            if (q1 >= n and runesAt(ct, q1 - n, needle)) { // look.c:366
                try landHit(ed, ct, q1 - n, q1); // look.c:367-375
                return true;
            }
            q1 -= 1; // look.c:376
            if (around and q1 == 0) break; // look.c:377-379
        }
    } else {
        // look.c:381-436: the match is `[q, q+n)`. Start at `ct.q1`, wrap to 0 at
        // `nc`, break after one lap when `q` returns to `ct.q1`. Positions with no
        // room (`q + n > nc`) never match and simply advance to the wrap.
        const start = ct.q1;
        var q: usize = start;
        while (true) {
            if (q >= nc) { // look.c:385-389
                q = 0;
                around = true;
            }
            if (q + n <= nc and runesAt(ct, q, needle)) { // look.c:420
                try landHit(ed, ct, q, q + n); // look.c:421-427
                return true;
            }
            q += 1; // look.c:433
            if (around and q >= start) break; // look.c:434-435
        }
    }
    return false;
}

/// True when `ct`'s buffer holds `needle` verbatim at `[at, at+needle.len)`.
/// Caller guarantees `at + needle.len <= ct.file.buffer.len()`.
fn runesAt(ct: *Text, at: usize, needle: []const u21) bool {
    for (needle, 0..) |r, i| {
        if (ct.file.buffer.runeAt(at + i) != r) return false;
    }
    return true;
}

/// Land a search hit on `[a,b)` (look.c:421-427 / :367-375): scroll+select via
/// `textshow` when `ct` is windowed, else set `q0/q1` directly (headless Text),
/// then record `ct` as the command target `seltext`.
fn landHit(ed: *Editor, ct: *Text, a: usize, b: usize) Text.Error!void {
    if (ct.w != null) {
        try ct.show(a, b, true); // look.c:421-424 textshow(ct, .., 1)
    } else {
        ct.q0 = a; // look.c:425-426 (the C's `ct->w==nil` branch)
        ct.q1 = b;
    }
    ed.seltext = ct; // look.c:427/375
}

// ==========================================================================
// Tests (look side §5). Direct `look`/`search` calls — no gesture machine.
// A headless Text (`w == null`) exercises the else-`t` arm; a Window drives the
// tag→body arm.
// ==========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");
const Window = @import("Window.zig");
const Chrome = @import("Chrome.zig");

const rect = proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

/// A standalone Text bound to a File, `w == null` (the headless search arm), with
/// a minimal Editor for `seltext`/allocation.
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
        try h.text.fill();
        h.ed = Editor.init(a);
        return h;
    }
    fn deinit(h: *Harness) void {
        h.ed.deinit();
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
};

test "look: search wraps around and skips the current selection" {
    // "foo bar foo baz foo": foo at [0,3), [8,11), [16,19).
    const h = try Harness.init("foo bar foo baz foo");
    defer h.deinit();
    const t = &h.text;

    // Selection on the MIDDLE foo ⇒ forward search starts at q1==11.
    try t.setSelect(8, 11);
    const needle = [_]u21{ 'f', 'o', 'o' };
    try testing.expect(try search(&h.ed, t, &needle, false));
    // Finds the THIRD occurrence (next after the selection).
    try testing.expectEqual(@as(usize, 16), t.q0);
    try testing.expectEqual(@as(usize, 19), t.q1);
    try testing.expectEqual(t, h.ed.seltext.?);

    // Called again from [16,19): no room forward ⇒ wrap to the FIRST.
    try testing.expect(try search(&h.ed, t, &needle, false));
    try testing.expectEqual(@as(usize, 0), t.q0);
    try testing.expectEqual(@as(usize, 3), t.q1);
}

test "look: search single occurrence re-finds itself after wrap" {
    // "hello foo world": the only "foo" is at [6,9).
    const h = try Harness.init("hello foo world");
    defer h.deinit();
    const t = &h.text;

    try t.setSelect(6, 9); // selection ON the sole match; q1==9
    const needle = [_]u21{ 'f', 'o', 'o' };
    // The lap wraps and re-finds the same occurrence (look.c:432-435 corollary).
    try testing.expect(try search(&h.ed, t, &needle, false));
    try testing.expectEqual(@as(usize, 6), t.q0);
    try testing.expectEqual(@as(usize, 9), t.q1);
}

test "look: search not-found returns false and moves nothing" {
    const h = try Harness.init("foo bar foo baz foo");
    defer h.deinit();
    const t = &h.text;

    try t.setSelect(4, 7); // "bar"
    const org0 = t.org;
    const needle = [_]u21{ 'z', 'z', 'z' }; // absent
    try testing.expect(!(try search(&h.ed, t, &needle, false)));
    // Nothing moved.
    try testing.expectEqual(@as(usize, 4), t.q0);
    try testing.expectEqual(@as(usize, 7), t.q1);
    try testing.expectEqual(org0, t.org);
    try testing.expect(h.ed.seltext == null);
}

test "look: bare click inside the current selection searches the selection" {
    // Selection "foo" at [8,11); a bare click (q0==q1) at 9 falls inside it, so
    // the needle is the selection (look.c:738-743). Forward search from q1==11
    // ⇒ the third foo.
    const h = try Harness.init("foo bar foo baz foo");
    defer h.deinit();
    const t = &h.text;

    try t.setSelect(8, 11);
    try look(&h.ed, t, 9, 9, false);
    try testing.expectEqual(@as(usize, 16), t.q0);
    try testing.expectEqual(@as(usize, 19), t.q1);
    try testing.expectEqual(t, h.ed.seltext.?);
}

test "look: reverse search walks backwards from q0" {
    // "foo bar foo baz foo"; reverse from the middle foo (q0==8) finds the FIRST
    // occurrence [0,3), scanning windows down from q1==8 (look.c:330-380).
    const h = try Harness.init("foo bar foo baz foo");
    defer h.deinit();
    const t = &h.text;

    try t.setSelect(8, 11);
    const needle = [_]u21{ 'f', 'o', 'o' };
    try testing.expect(try search(&h.ed, t, &needle, true));
    try testing.expectEqual(@as(usize, 0), t.q0);
    try testing.expectEqual(@as(usize, 3), t.q1);
    try testing.expectEqual(t, h.ed.seltext.?);
}

test "look: bare click expands the alnum word and searches it" {
    // No selection; a bare click inside "bar" expands to the alnum run [4,7)
    // (look.c:748-752). Only one "bar" ⇒ it re-finds itself after the wrap.
    const h = try Harness.init("foo bar foo baz foo bar");
    defer h.deinit();
    const t = &h.text;

    try t.setSelect(0, 0); // caret at 0, no range
    try look(&h.ed, t, 5, 5, false); // click inside the first "bar" (chars 4-6)
    // Caret collapsed to word end (7), then forward search finds the next "bar".
    try testing.expectEqual(@as(usize, 20), t.q0);
    try testing.expectEqual(@as(usize, 23), t.q1);
}

test "look: empty expansion is a silent no-op" {
    // A bare click between two spaces expands to nothing (look.c:197-199):
    // "foo   bar" has spaces at 3,4,5; a caret at 4 has a non-alnum rune on both
    // sides, so neither alnum walk moves.
    const h = try Harness.init("foo   bar");
    defer h.deinit();
    const t = &h.text;

    try t.setSelect(4, 4); // caret between spaces
    try look(&h.ed, t, 4, 4, false);
    // No search ran: caret unchanged, no target recorded.
    try testing.expectEqual(@as(usize, 4), t.q0);
    try testing.expectEqual(@as(usize, 4), t.q1);
    try testing.expect(h.ed.seltext == null);
}

// --- tag → body arm (look.c:205) via the Window harness -----------------------

const WinHarness = struct {
    fx: Frame.TestFixture,
    chrome: *Chrome,
    body_file: File,
    w: Window,
    ed: Editor,

    fn init(seed: []const u8, r: proto.Rect) !*WinHarness {
        const a = testing.allocator;
        const h = try a.create(WinHarness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.chrome = try Chrome.init(a, h.fx.disp, h.fx.font);
        h.body_file = File.init(a, try Buffer.initFromBytes(a, seed));
        try h.w.init(h.chrome, &h.body_file, 1, r);
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

test "look: b3 in the tag searches the body" {
    // Body holds "needle" at [4,10). We append the literal "needle" to the tag and
    // B3 it: `look` reads the needle from the TAG's file but searches the BODY
    // (look.c:205, :217). The needle range is passed explicitly (q0!=q1) so the
    // test does not depend on tag composition.
    const h = try WinHarness.init("foo needle bar", proto.Rect.make(0, 20, 300, 380));
    defer h.deinit();
    _ = try h.w.resize(proto.Rect.make(0, 20, 300, 380), false, false);
    const tag = &h.w.tag;
    const body = &h.w.body;

    const tw0 = tag.file.buffer.len(); // start of the appended word
    try tag.insertAt(tw0, "needle", true);
    const tag_q0 = tag.q0;
    const tag_q1 = tag.q1;

    // B3 the tag's "needle" (t == tag, t.w != null ⇒ ct == body).
    try look(&h.ed, tag, tw0, tw0 + 6, false);

    // The BODY selection jumped to its "needle" occurrence [4,10); seltext is the
    // body; the tag's own selection was NOT collapsed (t != ct, look.c:208).
    try testing.expectEqual(@as(usize, 4), body.q0);
    try testing.expectEqual(@as(usize, 10), body.q1);
    try testing.expectEqual(body, h.ed.seltext.?);
    try testing.expectEqual(tag_q0, tag.q0);
    try testing.expectEqual(tag_q1, tag.q1);
}
