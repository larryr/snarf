//! The mouse gesture machine — `mousethread` (acme.c:576-672) plus `textselect`
//! (text.c:1001-1099) and the colored B2/B3 sweep (`xselect`, text.c:1260-1384).
//! file-as-struct (S-07 P-1): this file *is* the Gesture, one `Gesture` value
//! hanging off the `Editor` context (P-3, no globals). Carved out of `Editor.zig`
//! verbatim in phase 12e so both files stay inside the ~400-line-per-concern
//! budget; `Editor` keeps one-line forwarders (`handleMouse`, `hitTest`) so no
//! call site moved with it.
//!
//! Phase 7b grew this into the full `textselect` (text.c:1001-1099):
//! press-time double-click expansion (R-P7-7), and the B1+B2/B3 CUT/PASTE chords
//! with in-gesture toggle-undo (R-P7-6). The C's blocking `readmouse` loop is
//! replayed as an edge-triggered state machine — each distinct button set is one
//! event; ops fire only on a set CHANGE, and the gesture ends only when ALL
//! buttons release (behavioral identity, mechanism divergence).
//!
//! Imports: `std`, `draw` and sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const draw = @import("draw");
const Text = @import("text/Text.zig");
const typing = @import("text/typing.zig");
const Editor = @import("Editor.zig");
const place = @import("place.zig");
const exec = @import("exec/exec.zig");
const textselect = @import("textselect.zig");

const Gesture = @This();
const Point = draw.Point;
const MouseEvent = Editor.MouseEvent;

/// Native mouse button bits (profiles / devmouse.c: B1=1, B2=2, B3=4). B1 drives
/// the selection sweep; B1+B2 is the Cut chord, B1+B3 the Paste chord.
pub const B1: u8 = 1;
pub const B2: u8 = 2;
pub const B3: u8 = 4;

/// The Text a mouse gesture is PINNED to, captured at B1-down and held until all
/// buttons release (R-P8-11). While non-null every mouse sample routes here
/// unconditionally, so a chord that drifts off the window still edits the Text it
/// started on (acme confines a gesture to one Text — `mousetext` is frozen for
/// the duration of `textselect`, text.c:1001-1099).
gesture_text: ?*Text = null,
/// The device point of the most recent mouse sample — acme's `mouse->xy` — the
/// point `handleKey` types AT (POINT-TO-TYPE, R-P8-9 / rows.c:279-282).
mouse_pt: Point = .{ .x = 0, .y = 0 },
/// Edge tracker for scrollbar clicks: the button set last acted on inside a
/// body scrollbar. B1/B3 fire once per press edge; B2 (absolute) repeats while
/// held (acme.c:603-612 `textscroll`, collapsed per R-P8-8). Reset to 0 on
/// buttons-up.
scroll_but: u8 = 0,
/// The live colored B2/B3 sweep (`xselect`, text.c:1260-1341), non-null only while
/// `mouse_state` is `.sweeping_b2`/`.sweeping_b3`. Paints a TEMPORARY colored
/// overlay (never touches the frame's real `p0`/`p1`) that `select23End` fully
/// restores. R-P9-1.
sel23: ?draw.Frame.Select23State = null,
/// The button set frozen at the FIRST button-set change during a B2/B3 sweep
/// (`buts`, textselect23 text.c:1350). 0 while the sweep is still pure; captured
/// once at the change and NOT updated again while `.draining` (the C's
/// `while(buttons) readmouse` discards further edges). Drives the dispatch
/// commit/cancel masks (textselect2/3, text.c:1368-1384). R-P9-2.
sel23_buts: u8 = 0,
/// Which button opened the current B2/B3 sweep (`B2` or `B3`) — dispatch after
/// `.draining` needs it once the state name is gone. R-P9-2.
sel23_button: u8 = 0,
/// The absolute rune range yielded by `select23End` (frame range + `t.org`),
/// captured at the button-set change and dispatched at all-buttons-up. R-P9-2.
sel23_range: struct { q0: usize = 0, q1: usize = 0 } = .{},
/// Mouse gesture state (`textselect`, text.c:1001-1099):
///   * `idle`          — between gestures.
///   * `sweeping_b1`   — B1 down, extending a selection (frselect loop body).
///   * `double_clicked`— a press-time double-click just fired; a joining B2/B3
///                       opens a chord, a >=3px B1 drag reverts to a sweep.
///   * `chording`      — B1+B2/B3 held; Cut/Paste ops run edge-triggered until
///                       every button releases.
///   * `sweeping_b2`   — B2 down, painting the red command sweep (xselect).
///   * `sweeping_b3`   — B3 down, painting the green look sweep (xselect).
///   * `draining`      — a B2/B3 sweep ended at a button-set change; wait for all
///                       buttons up before dispatching (text.c:1355-1357).
mouse_state: enum { idle, sweeping_b1, double_clicked, chording, sweeping_b2, sweeping_b3, draining } = .idle,
/// What the current chord has done, so a toggle can undo it (text.c:1007,1063
/// `enum{None,Cut,Paste}`). Reset to `.none` at each chord's start and after a
/// toggle-undo (re-arming the next op's seq/mark, R-P7-6).
chord_state: enum { none, cut, paste } = .none,
/// The chord's anchor: the selection start captured when the chord began, reused
/// as the low end of every reselect after a toggle-undo (text.c's local `q0`).
sweep_q0: usize = 0,
/// The button set last acted on, for edge detection: a chord op fires only when
/// `ev.buttons` differs from this (the C blocks in `while(mouse->buttons==b)`).
chord_buttons: u8 = 0,
/// The device point of the B1 press, for the double-click 3px drag test
/// (text.c:1023-1030).
press_pt: Point = .{ .x = 0, .y = 0 },

/// True when device point `(x,y)` lies inside the half-open rect `r`.
pub fn ptInRect(r: draw.Rect, x: i32, y: i32) bool {
    return x >= r.min.x and x < r.max.x and y >= r.min.y and y < r.max.y;
}

/// A hit region within a `Text` (R-P8-10). `scrollbar` is the scrollbar strip
/// (a body's elevator, or a tag/columntag/rowtag button square); `tag`/`body`
/// are the frame proper.
pub const Region = enum { tag, body, scrollbar };

/// The `Text` under a point and which of its regions the point fell in.
pub const Hit = struct { text: *Text, region: Region };

/// `rowwhich` + region classification (rows.c:255-266, acme.c:603/630). With a
/// window tree (`row != null`) walk the real chrome; otherwise (F-9 harnesses /
/// pre-boot) resolve every point to `text` as a body — so the phase-6/7 tests,
/// which have no chrome, route exactly as before. The scrollbar strip wins over
/// the frame (`ptInRect(text.scrollr)`); otherwise the region follows `what`
/// (tag/columntag/rowtag ⇒ .tag, body ⇒ .body).
pub fn hitTest(ed: *Editor, p: Point) ?Hit {
    if (ed.row) |row| {
        const t = row.which(p) orelse return null; // rows.c:255-266
        if (ptInRect(t.scrollr, p.x, p.y)) return .{ .text = t, .region = .scrollbar };
        const region: Region = switch (t.what) {
            .body => .body,
            .tag, .columntag, .rowtag => .tag,
        };
        return .{ .text = t, .region = region };
    }
    // Fallback (no chrome): the single bound Text, body region.
    if (ed.text) |t| return .{ .text = t, .region = .body };
    return null;
}

/// `textclose`'s backpointer hygiene for the pinned gesture Text (text.c:109/113,
/// R-P9-13) — the `gesture_text` arm of `Editor.dropTextRefs`, which moved here
/// with the field it nils.
pub fn dropTextRefs(g: *Gesture, tag: *Text, body: *Text) void {
    if (g.gesture_text) |t| {
        if (t == tag or t == body) g.gesture_text = null;
    }
}

/// Route one mouse sample (acme.c:576-672 `mousethread`, in the C's order).
/// (1) `mouse_pt` always tracks the sample. (2) A pinned gesture owns every
/// sample until all buttons release (R-P8-11). (3) hit-test. (4) wheel notch.
/// (5) body scrollbar click. (6) B1-down begins a gesture. B2/B3 execute/look are
/// deferred to phase 9; the C's focus-log / tag-commit / 500ms timer arms are
/// correctly absent (no tag cache — see the contract's doc note).
pub fn handleMouse(g: *Gesture, ed: *Editor, ev: MouseEvent) !void {
    const pt = Point{ .x = ev.x, .y = ev.y };
    g.mouse_pt = pt; // (1) acme `mouse->xy` always tracks
    const b = ev.buttons;
    if (b == 0) g.scroll_but = 0; // release clears scrollbar edge tracking

    // (2) A pinned gesture owns every sample until all buttons release (R-P8-11):
    // a chord that drifts off-window still edits the Text it began on.
    if (g.gesture_text) |gt| {
        try textselect.run(g, ed, gt, ev);
        if (b == 0) g.gesture_text = null; // buttons up ⇒ gesture over
        return;
    }

    // (3) Resolve the Text (and region) under the pointer.
    const hit = hitTest(ed, pt) orelse return;
    const t = hit.text;

    // (4) Wheel notch (acme.c:618-629): scroll the Text under the pointer via a
    // synthetic Kscrollone rune — NO focus change, NO run break, NO gesture. The
    // C's `w != nil` guard skips the row/column tags; the port's equivalent is
    // `w != null OR what == .body`, so the F-9 standalone-body harnesses (which
    // have `w == null`) still wheel-scroll while the chrome row/col tags (neither
    // windowed nor bodies) are skipped.
    if (b & (8 | 16) != 0) {
        if (t.w != null or t.what == .body) {
            const rune = if (b & 8 != 0) typing.Kscrolloneup else typing.Kscrollonedown;
            try t.typeRune(ed, rune);
            ed.needs_flush = true;
        }
        return;
    }

    // (5) Body scrollbar click (acme.c:603-612 → scrl.c `textscroll`, collapsed to
    // one action per event, R-P8-8). B1/B3 fire on the press edge; B2 (absolute)
    // repeats while held so a drag tracks. A tag's scrollr is the window button
    // square — no-op v1 (dragcol/dragwin deferred, R-P8-5). Wheels never reach
    // here (handled above); a wheel over a body scrollbar therefore scrolls, a
    // benign divergence from the C (which no-ops it).
    if (hit.region == .scrollbar) {
        if (t.what == .body) {
            const but: u3 = switch (b) {
                B1 => 1,
                B2 => 2,
                B3 => 3,
                else => 0,
            };
            if (but != 0 and (b != g.scroll_but or but == 2)) {
                try t.scrollClick(but, pt); // scrl.c:110-147
                ed.needs_flush = true;
            }
            g.scroll_but = b;
        }
        return;
    }

    // (6) A button press begins a gesture pinned to this Text (acme.c:648-668, in
    // the C's dispatch order). B1 also records `argtext`/`seltext` — the last
    // B1-selected Text — the command target a later B2 execute / 2-1 chord reads
    // (acme.c:656-657). B2/B3 open the colored execute/look sweep (acme.c:661-668);
    // they are valid in tags, columntags, rowtags AND bodies (no region guard — the
    // scrollbar strip was already routed at step 5).
    if (b == B1) {
        ed.focus = t;
        g.gesture_text = t;
        ed.argtext = t; // acme.c:656
        ed.seltext = t; // acme.c:657
        if (place.colOf(t)) |c| ed.activecol = c; // acme.c:658-659 "button 1 only"
        try textselect.run(g, ed, t, ev);
    } else if (b == B2 or b == B3) {
        g.gesture_text = t;
        try textselect.run(g, ed, t, ev);
    }
}

// ===========================================================================
// Tests. The gesture-machine half of `Editor.zig`'s suite, moved verbatim in
// phase 12e (names unchanged); the fixtures they run on stay in `Editor.zig`'s
// test section — the `draw.Frame.TestFixture` pattern — and are aliased here.
// ===========================================================================
const testing = std.testing;
const File = @import("File.zig");
const Harness = Editor.Harness;
const TwoWin = Editor.TwoWin;
const scrollHarness = Editor.scrollHarness;
const mev = Editor.mev;
const center = Editor.center;

test "editor: b1 click-move-release drives one selection" {
    const h = try Harness.init("abcde");
    defer h.deinit();

    // Press B1 at char 1, drag to char 3, release: one sweep [1,3).
    try h.ed.handleMouse(h.evAtChar(1, 1)); // down inside fr.r
    try testing.expect(h.ed.gesture.mouse_state == .sweeping_b1);
    try testing.expect(h.text.sel != null);

    try h.ed.handleMouse(h.evAtChar(3, 1)); // move with B1 held
    try h.ed.handleMouse(h.evAtChar(3, 0)); // release

    try testing.expect(h.ed.gesture.mouse_state == .idle);
    try testing.expect(h.text.sel == null);
    try testing.expectEqual(@as(usize, 1), h.text.q0);
    try testing.expectEqual(@as(usize, 3), h.text.q1);

    // A B1 press OUTSIDE fr.r is ignored — no sweep, state stays idle.
    try h.ed.handleMouse(.{ .x = 5, .y = 5, .buttons = 1, .msec = 0 });
    try testing.expect(h.ed.gesture.mouse_state == .idle);
    try testing.expect(h.text.sel == null);
}

// --------------------------------------------------------------------------
// Phase 7b: chord cut/paste + double-click (textselect, text.c:1001-1099).
// --------------------------------------------------------------------------

test "editor: chord cut mid-sweep snarfs and ends the sweep" {
    const h = try Harness.init("hello world");
    defer h.deinit();

    // Sweep-select "hello" = [0,5): press B1 at 0, drag to 5.
    try h.ed.handleMouse(h.evAtChar(0, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1));
    // Add B2 (the Cut chord). frselect exits; the chord cuts the swept range.
    try h.ed.handleMouse(h.evAtChar(5, B1 | B2));
    try testing.expect(h.ed.gesture.mouse_state == .chording);
    try testing.expect(h.ed.gesture.chord_state == .cut);
    try testing.expectEqualStrings("hello", h.snarf());
    try h.expectText(" world");
    try testing.expectEqual(@as(usize, 0), h.text.q0); // caret collapsed to q0
    try testing.expectEqual(@as(usize, 0), h.text.q1);

    // The gesture ends only when every button releases.
    try h.ed.handleMouse(h.evAtChar(0, 0));
    try testing.expect(h.ed.gesture.mouse_state == .idle);
}

test "editor: chord paste inserts snarf selected" {
    const h = try Harness.init("ab");
    defer h.deinit();
    try h.ed.snarf.appendSlice(testing.allocator, "XYZ"); // preload the snarf buffer

    // Caret at char 1 (press+no-move), then B1+B3 = the Paste chord.
    try h.ed.handleMouse(h.evAtChar(1, B1));
    try h.ed.handleMouse(h.evAtChar(1, B1 | B3));
    try testing.expect(h.ed.gesture.chord_state == .paste);
    try h.expectText("aXYZb");
    // selectall (text.c:1087): the inserted text is selected [1,4).
    try testing.expectEqual(@as(usize, 1), h.text.q0);
    try testing.expectEqual(@as(usize, 4), h.text.q1);

    try h.ed.handleMouse(h.evAtChar(1, 0));
    try testing.expect(h.ed.gesture.mouse_state == .idle);
}

test "editor: chord toggle undoes within the gesture" {
    const h = try Harness.init("hello world");
    defer h.deinit();

    // Cut "hello" via a B1+B2 chord.
    try h.ed.handleMouse(h.evAtChar(0, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1 | B2));
    try h.expectText(" world");
    try testing.expect(h.ed.gesture.chord_state == .cut);

    // Without releasing, switch to B1+B3 (Paste chord): this TOGGLES — it undoes
    // the cut and reselects the restored text. The reselect end is exactly the
    // File.undo Range.q1 (here 5, the end of the re-inserted "hello"), matching
    // the C's `textsetselect(t, q0, t->q1)` after `winundo`.
    try h.ed.handleMouse(h.evAtChar(5, B1 | B3));
    try h.expectText("hello world");
    try testing.expect(h.ed.gesture.chord_state == .none);
    try testing.expectEqual(@as(usize, 0), h.text.q0); // sweep_q0
    try testing.expectEqual(@as(usize, 5), h.text.q1); // == undo Range.q1

    // Cross-check the equivalence directly against a fresh, identical edit.
    {
        const g = try Harness.init("hello world");
        defer g.deinit();
        g.ed.seq += 1;
        g.file.mark(g.ed.seq);
        try g.text.setSelect(0, 5);
        try g.ed.cut(&g.text, true, true); // same cut the chord performed
        const r = (try g.file.undo()).?; // the same undo the toggle performed
        try testing.expectEqual(@as(usize, 5), r.q1); // reselect end source
    }

    try h.ed.handleMouse(h.evAtChar(0, 0));
    try testing.expect(h.ed.gesture.mouse_state == .idle);
}

test "editor: repeated chord press while held is a no-op" {
    const h = try Harness.init("hello world");
    defer h.deinit();

    try h.ed.handleMouse(h.evAtChar(0, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1 | B2)); // cut
    try h.expectText(" world");
    const seq_after = h.ed.seq;

    // The identical button set arrives again (finger jitter): edge-triggered, so
    // nothing happens — no second cut, no extra seq, snarf unchanged.
    try h.ed.handleMouse(h.evAtChar(5, B1 | B2));
    try h.expectText(" world");
    try testing.expect(h.ed.gesture.chord_state == .cut);
    try testing.expectEqual(seq_after, h.ed.seq);
    try testing.expectEqualStrings("hello", h.snarf());
}

test "editor: null-selection chord cut preserves snarf" {
    const h = try Harness.init("hello world");
    defer h.deinit();
    try h.ed.snarf.appendSlice(testing.allocator, "keep"); // pre-existing snarf

    // Caret (empty selection) at char 2, then a Cut chord. cut() hits the
    // q0==q1 guard and leaves the snarf buffer untouched (exec.c:984-988).
    try h.ed.handleMouse(h.evAtChar(2, B1));
    try h.ed.handleMouse(h.evAtChar(2, B1 | B2));
    try h.expectText("hello world"); // nothing deleted
    try testing.expectEqualStrings("keep", h.snarf()); // snarf preserved
}

test "editor: chord gesture ends only when all buttons release" {
    const h = try Harness.init("hello world");
    defer h.deinit();

    try h.ed.handleMouse(h.evAtChar(0, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1 | B2)); // cut chord
    try testing.expect(h.ed.gesture.mouse_state == .chording);

    // Release B2 but keep B1 down: still chording (no op — B1 alone is not a
    // chord combo, and the gesture is not over).
    try h.ed.handleMouse(h.evAtChar(5, B1));
    try testing.expect(h.ed.gesture.mouse_state == .chording);
    try testing.expect(h.ed.gesture.chord_state == .cut); // unchanged

    // Only when ALL buttons release does the gesture end.
    try h.ed.handleMouse(h.evAtChar(5, 0));
    try testing.expect(h.ed.gesture.mouse_state == .idle);
}

test "editor: undo grouping around chords" {
    const h = try Harness.init("hello world");
    defer h.deinit();

    // Sweep-select "world" = [6,11) and cut it in one chord.
    try h.ed.handleMouse(h.evAtChar(6, B1));
    try h.ed.handleMouse(h.evAtChar(11, B1));
    try h.ed.handleMouse(h.evAtChar(11, B1 | B2));
    try h.ed.handleMouse(h.evAtChar(6, 0)); // end the gesture
    try h.expectText("hello ");
    try testing.expectEqual(@as(u32, 1), h.ed.seq); // exactly one transaction

    // A single user undo restores the whole cut; a second finds nothing.
    _ = try h.file.undo();
    try h.expectText("hello world");
    try testing.expectEqual(@as(?File.Range, null), try h.file.undo());
}

test "editor: double-click trigger gates on 500ms and same q" {
    // Same q, within 500ms: the second press expands the word "foo" = [0,3).
    // (Clicking INSIDE the word at char 1 — a click at char 0 would line-select,
    // since the char to the left of position 0 reads as '\n'.)
    {
        const h = try Harness.init("foo bar");
        defer h.deinit();
        try h.ed.handleMouse(h.evAtCharMsec(1, B1, 100)); // click 1 down
        try h.ed.handleMouse(h.evAtCharMsec(1, 0, 100)); // click 1 up -> caret, arms
        try h.ed.handleMouse(h.evAtCharMsec(1, B1, 300)); // click 2 within 500ms
        try testing.expect(h.ed.gesture.mouse_state == .double_clicked);
        try testing.expectEqual(@as(usize, 0), h.text.q0);
        try testing.expectEqual(@as(usize, 3), h.text.q1); // "foo"
    }
    // Too late (>=500ms): no double-click — a normal sweep begins instead.
    {
        const h = try Harness.init("foo bar");
        defer h.deinit();
        try h.ed.handleMouse(h.evAtCharMsec(1, B1, 100));
        try h.ed.handleMouse(h.evAtCharMsec(1, 0, 100));
        try h.ed.handleMouse(h.evAtCharMsec(1, B1, 700)); // 600ms later
        try testing.expect(h.ed.gesture.mouse_state == .sweeping_b1);
    }
    // Different q: the second click lands elsewhere — no double-click.
    {
        const h = try Harness.init("foo bar");
        defer h.deinit();
        try h.ed.handleMouse(h.evAtCharMsec(1, B1, 100));
        try h.ed.handleMouse(h.evAtCharMsec(1, 0, 100));
        try h.ed.handleMouse(h.evAtCharMsec(4, B1, 200)); // same time window, diff char
        try testing.expect(h.ed.gesture.mouse_state == .sweeping_b1);
    }
}

test "editor: double-click then chord cuts the word" {
    const h = try Harness.init("foo bar");
    defer h.deinit();

    // Double-click in "bar": click at 4, release, click at 4 within 500ms.
    try h.ed.handleMouse(h.evAtCharMsec(4, B1, 100));
    try h.ed.handleMouse(h.evAtCharMsec(4, 0, 100));
    try h.ed.handleMouse(h.evAtCharMsec(4, B1, 250));
    try testing.expect(h.ed.gesture.mouse_state == .double_clicked);
    try testing.expectEqual(@as(usize, 4), h.text.q0);
    try testing.expectEqual(@as(usize, 7), h.text.q1); // "bar" selected

    // B2 joins the double-click: the Cut chord snarfs and deletes the word.
    try h.ed.handleMouse(h.evAtCharMsec(4, B1 | B2, 260));
    try testing.expect(h.ed.gesture.mouse_state == .chording);
    try testing.expectEqualStrings("bar", h.snarf());
    try h.expectText("foo ");

    try h.ed.handleMouse(h.evAtCharMsec(4, 0, 270));
    try testing.expect(h.ed.gesture.mouse_state == .idle);
}

// --------------------------------------------------------------------------
// Phase 7a scroll tests. "lineNN\n" lines are 7 runes (one 11-wide visual line);
// the 11×25 frame holds 25 lines = 175 runes. See text/typing.zig for the pins.
// --------------------------------------------------------------------------

test "editor: wheel scrolls one line without breaking the typing run" {
    const h = try scrollHarness();
    defer h.deinit();

    // Start a typing run: 'x' inserts at 0 and arms in_typing_run.
    try h.ed.handleKey('x');
    try testing.expect(h.ed.in_typing_run);
    try testing.expectEqual(@as(u32, 1), h.ed.seq);

    // A wheel-down notch (buttons bit 16) scrolls one line via a synthetic
    // Kscrollonedown rune and must NOT clear the run (R-P7-2). Line0 is now
    // "xline00" (7 glyphs + break = 8 runes), so line1 begins at screen char 8.
    try h.ed.handleMouse(.{ .x = 0, .y = 0, .buttons = 16, .msec = 0 });
    try testing.expectEqual(@as(usize, 8), h.text.org);
    try testing.expect(h.ed.in_typing_run); // run survives the wheel
    try testing.expectEqual(@as(u32, 1), h.ed.seq); // still one transaction
    try testing.expect(h.ed.needs_flush);
}

// --------------------------------------------------------------------------
// Phase 8: multi-Text routing over a real window tree (boot + Row/Column/Window).
// The router hit-tests against `ed.row`; every gesture pins to one Text.
// --------------------------------------------------------------------------

test "editor: hit-test routes clicks across two windows" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;

    // Body / tag / scrollbar of each window resolve to the right Text + region.
    const p1 = center(h.w1.body.fr.r);
    const hit1 = ed.hitTest(p1).?;
    try testing.expectEqual(&h.w1.body, hit1.text);
    try testing.expect(hit1.region == .body);

    const p2 = center(h.w2.body.fr.r);
    const hit2 = ed.hitTest(p2).?;
    try testing.expectEqual(&h.w2.body, hit2.text);
    try testing.expect(hit2.region == .body);

    const hitt = ed.hitTest(center(h.w1.tag.fr.r)).?;
    try testing.expectEqual(&h.w1.tag, hitt.text);
    try testing.expect(hitt.region == .tag);

    const hits = ed.hitTest(center(h.w2.body.scrollr)).?;
    try testing.expectEqual(&h.w2.body, hits.text);
    try testing.expect(hits.region == .scrollbar);

    // The row tag and column tag resolve through rowwhich/colwhich.
    try testing.expectEqual(&h.tree.row.tag, ed.hitTest(center(h.tree.row.tag.fr.r)).?.text);
    const ctag = &h.tree.row.col.items[0].tag;
    try testing.expectEqual(ctag, ed.hitTest(center(ctag.fr.r)).?.text);

    // A B1 click in window 1's body pins the gesture there and sets focus; the
    // release clears the pin.
    try ed.handleMouse(mev(p1.x, p1.y, B1));
    try testing.expectEqual(&h.w1.body, ed.gesture.gesture_text.?);
    try testing.expectEqual(&h.w1.body, ed.focus.?);
    try ed.handleMouse(mev(p1.x, p1.y, 0));
    try testing.expect(ed.gesture.gesture_text == null);
}

test "editor: wheel scrolls the text under the pointer, focus elsewhere" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;

    ed.focus = &h.w1.body;
    try testing.expectEqual(@as(usize, 0), h.w1.body.org);
    try testing.expectEqual(@as(usize, 0), h.w2.body.org);

    // Wheel-down (bit 16) with the pointer over window 2 scrolls window 2 only.
    const p2 = center(h.w2.body.fr.r);
    try ed.handleMouse(mev(p2.x, p2.y, 16));
    try testing.expect(h.w2.body.org > 0); // window 2 scrolled
    try testing.expectEqual(@as(usize, 0), h.w1.body.org); // window 1 did not
    try testing.expectEqual(&h.w1.body, ed.focus.?); // focus unchanged
    try testing.expect(ed.gesture.gesture_text == null); // no gesture opened
}

test "editor: chord confined to its gesture text" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;

    const before2 = try TwoWin.text(&h.w2.body);
    defer testing.allocator.free(before2);

    // Sweep-select a range in window 1's body.
    const a = h.w1.body.fr.ptOfChar(0);
    const bpt = h.w1.body.fr.ptOfChar(5);
    try ed.handleMouse(mev(a.x, a.y, B1));
    try testing.expectEqual(&h.w1.body, ed.gesture.gesture_text.?);
    try ed.handleMouse(mev(bpt.x, bpt.y, B1));

    // Add B2 with the pointer now over WINDOW 2. The gesture is pinned to window
    // 1, so the Cut edits window 1; window 2 is byte-for-byte untouched.
    const p2 = center(h.w2.body.fr.r);
    try ed.handleMouse(mev(p2.x, p2.y, B1 | B2));
    try testing.expect(ed.gesture.mouse_state == .chording);
    try testing.expect(ed.gesture.chord_state == .cut);
    try testing.expect(ed.snarf.items.len > 0); // something was cut from window 1

    const after2 = try TwoWin.text(&h.w2.body);
    defer testing.allocator.free(after2);
    try testing.expectEqualStrings(before2, after2); // window 2 unchanged

    try ed.handleMouse(mev(p2.x, p2.y, 0)); // release ends the gesture
    try testing.expect(ed.gesture.mouse_state == .idle);
    try testing.expect(ed.gesture.gesture_text == null);
}

test "editor: scrollbar click scrolls the body" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;
    const fh: i32 = h.fx.font.height;
    const sr = h.w1.body.scrollr;

    // window 1 body starts at org 0. A B3 click low in its scrollbar sets the
    // char under the cursor as the new top (scrl.c:143-146) ⇒ org advances.
    try testing.expectEqual(@as(usize, 0), h.w1.body.org);
    try ed.handleMouse(mev(sr.min.x + 1, sr.max.y - fh, B3));
    const org_b3 = h.w1.body.org;
    try testing.expect(org_b3 > 0);
    try testing.expect(ed.gesture.gesture_text == null); // a scrollbar click opens no gesture

    // A B1 click a few lines down in the scrollbar backs the view up by that many
    // rows (scrl.c:141-146) ⇒ org decreases. Different button ⇒ a fresh edge, so
    // it fires without an intervening release.
    try ed.handleMouse(mev(sr.min.x + 1, sr.min.y + 3 * fh, B1));
    try testing.expect(h.w1.body.org < org_b3);
    try testing.expect(ed.gesture.gesture_text == null);
}
