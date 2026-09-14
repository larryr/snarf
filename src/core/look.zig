//! `look` / `search` — B3 look3 v1 (look.c:82-229), reduced to the literal,
//! within-window search arm plus its bare-click alnum expansion (look.c:731-756).
//! Namespace module (lowercase), aliased on `Editor` like Text's select/scroll.
//! Ported from larryr/plan9port@337c6ac; cite as `look.c:NN`.
//!
//! Scope. STILL DEFERRED: the external-client arm (look.c:97-146, no 9P
//! clients) and the plumber arm (look.c:147-196). LANDED in phase 13b: the
//! `openfile`/`expandfile` file arm (look.c:200-201, look.c:592-729) — it lives
//! in `expand.zig`/`openfile.zig` and is entered from `look` below. It is the
//! one ASYNCHRONOUS divergence of the port (R-P13b-2): acme answers "is this a
//! file?" with `access()` mid-call, Snarf parks a `StatJob` and resolves it on a
//! later frame, so a look that is NOT a file runs its literal search a frame or
//! two late. Permanently dropped:
//! winlock/unlock (look.c:206-207/220-221, single-threaded). `winsettag` on a hit
//! (look.c:418) is covered for free by the frameEnd tag sweep (R-P9-4).
//!
//! The `e.jump`/`moveto` warp on a hit (look.c:219) is NO LONGER dropped
//! (phase 15, R-P15-3): it is issued as a `/dev/mouse` write through
//! `warp.zig`, which the native host honours and the browser host ignores.
const std = @import("std");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const select = @import("text/select.zig");
const pendinglook = @import("pendinglook.zig");
const warp = @import("warp.zig");

/// look3 (look.c:82-229, minus the deferred arms above). `[q0,q1)` are absolute
/// rune coords in `t`. A bare click inside `t`'s own selection captures it
/// (look.c:738-743); then the FILE arm (`pendinglook.startLook`, look.c:783) gets
/// first refusal and, if the text is not a file name, the literal search arm
/// below runs on the alnum expansion (look.c:786-796). `reverse` selects the
/// backward scan (Shift-B3).
///
/// R-P13b-2: the file arm is ASYNCHRONOUS. acme answers "is this a file?" with
/// `access()` inside this call; Snarf parks a `StatJob` (`expand.zig`) and the
/// verdict — open the file, or run `literal` below — lands on a later frame.
/// With no namespace (`ed.ns == null`, every headless harness) `startLook`
/// declines immediately and this reduces, byte for byte, to the pre-13b look.
pub fn look(ed: *Editor, t: *Text, q0: usize, q1: usize, reverse: bool) Text.Error!void {
    var e0 = q0;
    var e1 = q1;
    var jump = true; // look.c:735 `e->jump = TRUE`
    if (q1 == q0 and t.q1 > t.q0 and t.q0 <= q0 and q0 <= t.q1) {
        // look.c:738-743: a bare click inside the current selection ⇒ the
        // selection itself is the needle, and a bare click in a TAG does not
        // warp (look.c:741-742 `if(t->what == Tag) e->jump = FALSE`) — the
        // pointer is already where the user put it.
        e0 = t.q0;
        e1 = t.q1;
        if (t.what == .tag) jump = false;
    }
    if (try pendinglook.startLook(ed, t, e0, e1, reverse, jump)) return; // look.c:783
    return literal(ed, t, e0, e1, reverse, jump);
}

/// The literal (within-window search) arm of `look3`: the alnum expansion
/// (look.c:786-791) and `search` (look.c:200-221's else branch). Reached
/// directly when the text is not a file name, and from `pendinglook.stepPending`
/// when the parked existence check says it is not.
pub fn literal(ed: *Editor, t: *Text, q0: usize, q1: usize, reverse: bool, jump: bool) Text.Error!void {
    var e0 = q0;
    var e1 = q1;
    const nc = t.file.buffer.len();
    if (e1 == e0) {
        // look.c:786-791: the bare-click alnum run, reusing select.zig's
        // util.c-faithful isAlnum.
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

    // look.c:218-219: search `ct`, and on a hit with `e.jump` warp the pointer
    // onto the match (R-P15-3; a no-op on a host that cannot warp).
    if (try search(ed, ct, needle, reverse) and jump) warp.toSelection(ed, ct);
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
const ninep = @import("ninep"); // T9 only: mounts warp.MouseSink at /dev

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

// --------------------------------------------------------------------------
// T9 (phase15-native-spike.md §4): a real Look hit issues exactly one
// `/dev/mouse` write, carrying the hit's point, through the namespace — not a
// direct call to `warp.to`/`warp.toSelection`, but `look()` itself.
//
// TWO TRAPS this test must dodge (phase-15 report, "Public API for the test
// writer"):
//   (a) the click must NOT be treated as a file name, or `pendinglook.startLook`
//       parks a `StatJob` and the warp lands a frame or two later via
//       `Load.addressAndShow` instead of synchronously here. `startLook`
//       reaches its namespace/StatJob arm only after `ed.row orelse return
//       false` (expand.zig) — `WinHarness` never sets `ed.row` (no boot, no
//       Row), so `startLook` always bails there and `look()` falls straight
//       through to the literal search arm, every time, regardless of the
//       clicked text.
//   (b) the Text must be windowed and LAID OUT, or `ptOfChar` answers with the
//       frame's origin for every offset instead of the hit's real position —
//       `WinHarness` + `w.resize` (as the b3-in-tag test above already relies
//       on) gives a live `Frame` that `Text.show` (called from `search`'s
//       `landHit`) actually lays text into.
// --------------------------------------------------------------------------

fn pumpMouseSink(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "look: a literal hit warps the pointer through a real /dev/mouse write (T9)" {
    const a = testing.allocator;

    // The /dev/mouse capture, mounted through a genuine 9P round trip (the
    // same rig `warp.zig`'s own namespace test uses) — not a bare function
    // call to `warp.to`, so this exercises the real `look -> search ->
    // warp.toSelection -> namespace -> write` path end to end.
    var sink: warp.MouseSink = .{};
    const pipe = try ninep.chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try ninep.server.Server.init(a, pipe.serverEnd(), &warp.MouseSink.ops, &sink, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pumpMouseSink };
    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");
    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/dev", &cl, root.fid);

    // A real, windowed, laid-out body (trap b). "target" is the sole
    // occurrence, so the forward search re-finds it after one lap.
    const h = try WinHarness.init("wibble target wibble", proto.Rect.make(0, 20, 300, 380));
    defer h.deinit();
    _ = try h.w.resize(proto.Rect.make(0, 20, 300, 380), false, false);
    h.ed.ns = &ns;

    const body = &h.w.body;
    // An explicit, non-empty range (not a bare click) naming "target" at
    // [7,13) — `ed.row == null` (trap a) means this never risks the parked
    // StatJob path regardless of how file-name-like the text looks.
    try look(&h.ed, body, 7, 13, false);

    try testing.expectEqual(@as(usize, 7), body.q0);
    try testing.expectEqual(@as(usize, 13), body.q1);
    try testing.expectEqual(body, h.ed.seltext.?);

    // Exactly one warp write reached the namespace, and it names the SAME
    // point `warp.toSelection` computes from the body's now-laid-out frame
    // (look.c:219's `moveto(mousectl, addpt(frptofchar(...), Pt(4, height-4)))`).
    try testing.expectEqual(@as(usize, 1), sink.writes);
    const pt = body.fr.ptOfChar(body.fr.p0);
    const fh: i32 = body.fr.font.height;
    var want: [warp.rec_len]u8 = undefined;
    warp.format(pt.x + 4, pt.y + fh - 4, &want);
    try testing.expectEqualStrings(&want, &sink.last);
}
