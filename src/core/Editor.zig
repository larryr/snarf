//! The editor context: owns what ACME's `dat.c` declared as 60 globals (P-3).
//! No globals anywhere else — state hangs off this struct, allocator stored
//! explicitly (P-4). file-as-struct (P-1): this file *is* the Editor.
//! [ref: acme/dat.c + globals]
//!
//! Sub-wave 6c grows this into the interactive editing loop's HOME (R-P6-12):
//! the routing state machine (`handleMouse`/`handleKey`/`frameEnd`) lives here
//! so it is testable natively with no browser and no devinput; `main_wasm` keeps
//! only the adapter that drains the input device into `MouseEvent`s/runes and
//! calls these. The machine is `acme/text.c`'s per-window mouse/keyboard dispatch
//! (text.c:668-942 for keys, 1005-1099 for `textselect`) reduced to the single
//! phase-6/7 gesture set (F-9 single-Text; scroll via the wheel/nav keys).
//!
//! Phase 7b grows the mouse machine into the full `textselect` (text.c:1001-1099):
//! press-time double-click expansion (R-P7-7), and the B1+B2/B3 CUT/PASTE chords
//! with in-gesture toggle-undo (R-P7-6). The C's blocking `readmouse` loop is
//! replayed as an edge-triggered state machine — each distinct button set is one
//! event; ops fire only on a set CHANGE, and the gesture ends only when ALL
//! buttons release (behavioral identity, mechanism divergence). The snarf buffer
//! and the `cut`/`snarfInsert` ops (exec.c:947-1073) live here too; /dev/snarf +
//! clipboard sync are deferred (R-P7-5, S-05 §7).
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");
const Text = @import("text/Text.zig");
const typing = @import("text/typing.zig");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");

const Editor = @This();
const Point = draw.Point;

/// Native mouse button bits (profiles / devmouse.c: B1=1, B2=2, B3=4). B1 drives
/// the selection sweep; B1+B2 is the Cut chord, B1+B3 the Paste chord.
const B1: u8 = 1;
const B2: u8 = 2;
const B3: u8 = 4;

/// snarf capture read chunk (exec.c uses RBUFSIZE; any bound works — see `cut`).
const snarf_chunk_runes: usize = 2000;

/// One logical mouse sample, decoded from a `/dev/mouse` record by the adapter
/// (main_wasm). Button STATE (not edges) per the kernel record; the state
/// machine infers press/release from `mouse_state` + `buttons`.
pub const MouseEvent = struct { x: i32, y: i32, buttons: u8, msec: u32 };

/// The allocator every long-lived editor allocation flows through (P-4).
allocator: std.mem.Allocator,
/// Global edit sequence number (ACME `seq`); bumped per user command.
seq: u32 = 0,
/// True while a run of consecutive keystrokes is being grouped into one undo
/// transaction (R-P6-8/T-1). `typeRune` sets it on the first key of a run (after
/// bumping `seq` and marking the file) and clears it when an arrow key breaks the
/// run; the 6c input loop also clears it when a B1 gesture begins. One
/// `seq`++/`File.mark` per run — not per keystroke.
in_typing_run: bool = false,
/// The single Text the loop routes to (F-9). Bound by the adapter after boot;
/// null before then, in which case every event is a no-op.
text: ?*Text = null,
/// The snarf buffer: Editor-owned UTF-8 (R-P7-5, vs the C's Rune `snarfbuf`).
/// Captured via chunked `Buffer.read` so U+FFFD semantics match `captureText`.
snarf: std.ArrayList(u8) = .empty,
/// Mouse gesture state (`textselect`, text.c:1001-1099):
///   * `idle`          — between gestures.
///   * `sweeping_b1`   — B1 down, extending a selection (frselect loop body).
///   * `double_clicked`— a press-time double-click just fired; a joining B2/B3
///                       opens a chord, a >=3px B1 drag reverts to a sweep.
///   * `chording`      — B1+B2/B3 held; Cut/Paste ops run edge-triggered until
///                       every button releases.
mouse_state: enum { idle, sweeping_b1, double_clicked, chording } = .idle,
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
/// Set by any handler that painted into the display's op buffer this tick;
/// `frameEnd` performs at most one `display.flush` per tick when it is set.
needs_flush: bool = false,

pub fn init(allocator: std.mem.Allocator) Editor {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Editor) void {
    self.snarf.deinit(self.allocator);
    self.* = undefined;
}

/// True when device point `(x,y)` lies inside the half-open rect `r`.
fn ptInRect(r: draw.Rect, x: i32, y: i32) bool {
    return x >= r.min.x and x < r.max.x and y >= r.min.y and y < r.max.y;
}

/// `cut` (exec.c:947-1016), single-Text subset (no window/tag plumbing, no
/// cross-window lock). Snarf and/or delete the current selection `[q0,q1)`.
///   * `dosnarf` — copy the selection into `ed.snarf` (replacing its contents).
///   * `docut`   — delete the selection and collapse the caret to `q0`.
/// A null selection (q0==q1) returns with the snarf buffer UNTOUCHED
/// (exec.c:984-988). The CALLER bumps `ed.seq` + `File.mark` first, exactly as
/// `execute`/`texttype` do in the C — `cut` never marks. /dev/snarf sync
/// (`acmeputsnarf`, exec.c:1003) is deferred (R-P7-5).
pub fn cut(ed: *Editor, t: *Text, dosnarf: bool, docut: bool) !void {
    const q0 = t.q0;
    const q1 = t.q1;
    if (q0 == q1) return; // exec.c:984-988 no selection: snarf left as-is
    if (dosnarf) {
        ed.snarf.clearRetainingCapacity(); // exec.c:992 bufdelete(&snarfbuf,...)
        // chunked read of [q0,q1) into the snarf buffer (exec.c:993-1002).
        var scratch: [snarf_chunk_runes * Buffer.max_bytes_per_rune]u8 = undefined;
        var p = q0;
        while (p < q1) {
            const n = @min(q1 - p, snarf_chunk_runes);
            const bytes = t.file.buffer.read(p, n, &scratch);
            try ed.snarf.appendSlice(ed.allocator, bytes);
            p += n;
        }
        // exec.c:1003 acmeputsnarf — /dev/snarf + clipboard sync DEFERRED (R-P7-5).
    }
    if (docut) {
        try t.deleteRange(q0, q1, true); // exec.c:1006 textdelete
        try t.setSelect(q0, q0); // exec.c:1007 textsetselect
        // exec.c:1009 textscrdraw / winsettag — FLAG: scrollbar/tag deferred (R-P7-1).
    }
}

/// `paste` (exec.c:1018-1073), single-Text subset (no `tobody`, no cross-window
/// lock, no /dev/snarf fetch). Replace the current selection with the snarf
/// buffer at the caret. `selectall` selects the inserted text (the chord path,
/// text.c:1087); otherwise the caret lands after it. The CALLER marks first.
pub fn snarfInsert(ed: *Editor, t: *Text, selectall: bool) !void {
    // exec.c:1037-1039 acmegetsnarf + empty guard (dev fetch DEFERRED, R-P7-5).
    if (ed.snarf.items.len == 0) return;
    try ed.cut(t, false, true); // exec.c:1046 cut(t,t,nil,FALSE,TRUE) — no snarf
    const q0 = t.q0;
    const n = std.unicode.utf8CountCodepoints(ed.snarf.items) catch unreachable;
    try t.insertAt(q0, ed.snarf.items, true); // exec.c:1051-1061 textinsert
    if (selectall) {
        try t.setSelect(q0, q0 + n); // exec.c:1063-1064
    } else {
        try t.setSelect(q0 + n, q0 + n); // exec.c:1065-1066
    }
    // exec.c:1068 textscrdraw / winsettag — FLAG: scrollbar/tag deferred (R-P7-1).
}

/// Route one mouse sample through the full `textselect` machine (text.c:1001-
/// 1099). See the `mouse_state` doc for the state set. The C's blocking
/// `readmouse` loop becomes edge-triggered dispatch: chord ops fire only when the
/// button set changes, and a gesture ends only when ALL buttons release (R-P7-6).
/// B1 pressed OUTSIDE fr.r is FLAG-ignored (no tag/scrollbar, R-P7-1).
pub fn handleMouse(ed: *Editor, ev: MouseEvent) !void {
    const t = ed.text orelse return;
    const pt = Point{ .x = ev.x, .y = ev.y };
    const b = ev.buttons;
    switch (ed.mouse_state) {
        .idle => {
            if (b == B1) {
                // A clean B1 press. Begin a sweep only when it lands in the text
                // body; a press elsewhere has nowhere to go yet.
                if (ptInRect(t.fr.r, ev.x, ev.y)) {
                    ed.in_typing_run = false; // a mouse gesture ends the run (R-P6-8)
                    ed.press_pt = pt;
                    // Press-time double-click (text.c:1018-1034): a second caret
                    // click at the same char within 500ms expands the word/pair/
                    // line NOW rather than at release. DIVERGENCE: the C keys only
                    // on `clicktext`+`clickmsec`; the port also gates on the click
                    // char (`last_click.q`), a stricter same-position test.
                    const q = t.org + t.fr.charOfPt(pt);
                    if (t.last_click) |lc| {
                        if (q == lc.q and (ev.msec -% lc.msec) < 500 and t.q0 == t.q1 and t.q0 == q) {
                            var q0 = q;
                            var q1 = q;
                            t.doubleClick(&q0, &q1); // text.c:1020
                            try t.setSelect(q0, q1); // text.c:1021
                            t.last_click = null; // one double-click per window
                            ed.mouse_state = .double_clicked;
                            ed.needs_flush = true;
                            return;
                        }
                    }
                    try t.selectBegin(pt); // text.c:1035-1037 frselect setup
                    ed.mouse_state = .sweeping_b1;
                    ed.needs_flush = true;
                }
                // FLAG: B1 press outside fr.r ignored — no tag/scrollbar (R-P7-1).
            } else if (b & (8 | 16) != 0) {
                // Wheel notch: feed a synthetic Kscrollone rune to typing
                // (acme.c:618-628). Bit 8 = wheel-up, bit 16 = wheel-down; one
                // line/notch (R-P7-2). This does NOT clear `in_typing_run` — a
                // wheel scroll never breaks a run of keystrokes.
                const rune = if (b & 8 != 0) typing.Kscrolloneup else typing.Kscrollonedown;
                try t.typeRune(ed, rune);
                ed.needs_flush = true;
                return;
            }
            // FLAG: a lone B2/B3 press (execute/plumb) is deferred to the windows
            // phase — only the B1-anchored chords are ported here.
        },
        .sweeping_b1 => {
            if ((b & B1) != 0 and (b & (B2 | B3)) != 0) {
                // A chord begins mid-sweep. frselect exits on any button-set
                // change (frselect.c:102); commit the swept selection, then hand
                // this same event to the chord step (text.c:1035,1064-1067).
                try t.selectEnd(pt);
                ed.sweep_q0 = t.q0;
                ed.chord_state = .none;
                ed.chord_buttons = 0;
                ed.mouse_state = .chording;
                ed.needs_flush = true;
                try ed.chordStep(t, ev);
            } else if (b & B1 != 0) {
                try t.selectMove(pt); // extend the live sweep (frselect loop body)
                ed.needs_flush = true;
            } else {
                // B1 released with no chord: commit, then record or clear the
                // double-click window (text.c:1051-1060).
                try t.selectEnd(pt);
                if (t.q0 == t.q1) {
                    t.last_click = .{ .q = t.q0, .msec = ev.msec }; // text.c:1056-1057
                } else {
                    t.last_click = null; // text.c:1059-1060 a real selection cancels it
                }
                ed.mouse_state = .idle;
                ed.needs_flush = true;
            }
        },
        .double_clicked => {
            if ((b & B1) != 0 and (b & (B2 | B3)) != 0) {
                // B2/B3 joins the double-click: chord over the expanded selection.
                ed.sweep_q0 = t.q0;
                ed.chord_state = .none;
                ed.chord_buttons = 0;
                ed.mouse_state = .chording;
                ed.needs_flush = true;
                try ed.chordStep(t, ev);
            } else if (b == B1) {
                // B1 still down: a drag of >=3px converts to a fresh sweep
                // (text.c:1026-1030 waits here until the mouse moves). DIVERGENCE:
                // the C keeps the double-click as the sweep anchor; the port
                // re-anchors at the press point.
                if (@abs(pt.x - ed.press_pt.x) >= 3 or @abs(pt.y - ed.press_pt.y) >= 3) {
                    try t.selectBegin(ed.press_pt);
                    ed.mouse_state = .sweeping_b1;
                    ed.needs_flush = true;
                }
            } else if (b == 0) {
                // Release: back to idle. `last_click` stays null — no triple-click
                // (text.c:1054 clicktext=nil).
                ed.mouse_state = .idle;
            }
        },
        .chording => try ed.chordStep(t, ev),
    }
}

/// One iteration of `textselect`'s chord loop (text.c:1064-1098), edge-triggered.
/// Fires a Cut/Paste (or a toggle-undo) only when the button set CHANGES to a
/// B1+B2/B3 combo; ends the gesture (=> idle) once every button releases.
fn chordStep(ed: *Editor, t: *Text, ev: MouseEvent) !void {
    const b = ev.buttons;
    // text.c:1065 mouse->msec=0 / :1097 clicktext=nil — a chord voids any pending
    // double-click, both entering and leaving the loop body.
    t.last_click = null;
    if (b == 0) { // text.c:1064 while(mouse->buttons): all up => gesture over
        ed.mouse_state = .idle;
        ed.chord_state = .none;
        ed.chord_buttons = 0;
        return;
    }
    if (b != ed.chord_buttons and (b & B1) != 0 and (b & (B2 | B3)) != 0) { // text.c:1067
        if (ed.chord_state == .none) {
            ed.seq += 1; // text.c:1069 seq++
            t.file.mark(ed.seq); // text.c:1070 filemark
        }
        if (b & B2 != 0) { // 1-2 chord == Cut (text.c:1072-1080)
            if (ed.chord_state == .paste) {
                const r = try t.file.undo(); // text.c:1074 winundo
                try t.setSelect(ed.sweep_q0, if (r) |rr| rr.q1 else ed.sweep_q0); // text.c:1075
                ed.chord_state = .none; // text.c:1076
            } else if (ed.chord_state != .cut) {
                try ed.cut(t, true, true); // text.c:1078 cut(dosnarf,docut)
                ed.chord_state = .cut; // text.c:1079
            }
        } else { // b & B3 == 1-3 chord == Paste (text.c:1081-1090)
            if (ed.chord_state == .cut) {
                const r = try t.file.undo(); // text.c:1083 winundo
                try t.setSelect(ed.sweep_q0, if (r) |rr| rr.q1 else ed.sweep_q0); // text.c:1084
                ed.chord_state = .none; // text.c:1085
            } else if (ed.chord_state != .paste) {
                try ed.snarfInsert(t, true); // text.c:1087 paste(selectall=TRUE)
                ed.chord_state = .paste; // text.c:1088
            }
        }
        // text.c:1091 textscrdraw / :1092 clearmouse — FLAG (R-P7-1).
        ed.needs_flush = true;
    }
    ed.chord_buttons = b; // text.c:1066/1095 advance the edge tracker
}

/// Route one key rune to typing (text.c:668-942 via `Text.typeRune`). Keys only
/// edit when idle: a live B1 drag owns the gesture, so keys arriving mid-sweep
/// are FLAG-dropped rather than interleaved into the selection.
pub fn handleKey(ed: *Editor, r: u21) !void {
    const t = ed.text orelse return;
    if (ed.mouse_state != .idle) return; // FLAG: keys during a sweep are dropped
    try t.typeRune(ed, r);
    ed.needs_flush = true;
}

/// End-of-tick: flush the display AT MOST ONCE, only if a handler painted this
/// tick. Clears the flag so a tick with no input does no I/O.
pub fn frameEnd(ed: *Editor, display: *draw.Display) !void {
    if (!ed.needs_flush) return;
    try display.flush();
    ed.needs_flush = false;
}

// Compile-time proof the allowed dependencies resolve through this module.
comptime {
    std.debug.assert(@hasDecl(draw, "proto"));
    std.debug.assert(@hasDecl(ninep, "msg"));
}

// ===========================================================================
// Tests (editing side contract §"6c scope"). Frame.TestFixture + a real
// Text/File, mirroring B2's typing/select harness style.
// ===========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;

const rect = proto.Rect{ .min = .{ .x = 20, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

/// A live Text over `seed`, an Editor bound to it, on a fresh draw fixture.
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
        h.ed.text = &h.text; // bind the routing target
        try h.text.fill();
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
    /// Synthesize a mouse sample at the device point of screen char `p`.
    fn evAtChar(h: *Harness, p: usize, buttons: u8) MouseEvent {
        return h.evAtCharMsec(p, buttons, 0);
    }
    /// Same, carrying an explicit millisecond timestamp (double-click gating).
    fn evAtCharMsec(h: *Harness, p: usize, buttons: u8, msec: u32) MouseEvent {
        const pt = h.text.fr.ptOfChar(p);
        return .{ .x = pt.x, .y = pt.y, .buttons = buttons, .msec = msec };
    }
    /// The current snarf buffer contents.
    fn snarf(h: *Harness) []const u8 {
        return h.ed.snarf.items;
    }
};

test "editor init/deinit round-trip" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try std.testing.expectEqual(@as(u32, 0), ed.seq);
    ed.seq += 1;
    try std.testing.expectEqual(@as(u32, 1), ed.seq);
}

test "editor: b1 click-move-release drives one selection" {
    const h = try Harness.init("abcde");
    defer h.deinit();

    // Press B1 at char 1, drag to char 3, release: one sweep [1,3).
    try h.ed.handleMouse(h.evAtChar(1, 1)); // down inside fr.r
    try testing.expect(h.ed.mouse_state == .sweeping_b1);
    try testing.expect(h.text.sel != null);

    try h.ed.handleMouse(h.evAtChar(3, 1)); // move with B1 held
    try h.ed.handleMouse(h.evAtChar(3, 0)); // release

    try testing.expect(h.ed.mouse_state == .idle);
    try testing.expect(h.text.sel == null);
    try testing.expectEqual(@as(usize, 1), h.text.q0);
    try testing.expectEqual(@as(usize, 3), h.text.q1);

    // A B1 press OUTSIDE fr.r is ignored — no sweep, state stays idle.
    try h.ed.handleMouse(.{ .x = 5, .y = 5, .buttons = 1, .msec = 0 });
    try testing.expect(h.ed.mouse_state == .idle);
    try testing.expect(h.text.sel == null);
}

test "editor: kbd runes route to typing and mouse breaks the run" {
    const h = try Harness.init("");
    defer h.deinit();

    try h.ed.handleKey('a');
    try h.ed.handleKey('b');
    try h.expectText("ab");
    try testing.expect(h.ed.in_typing_run);
    try testing.expectEqual(@as(u32, 1), h.ed.seq); // one run so far

    // A B1 click (press + release at the caret) ends the typing run.
    try h.ed.handleMouse(h.evAtChar(2, 1));
    try h.ed.handleMouse(h.evAtChar(2, 0));
    try testing.expect(!h.ed.in_typing_run);
    try testing.expect(h.ed.mouse_state == .idle);

    // The next key starts a fresh run (second seq) and inserts at the caret.
    try h.ed.handleKey('c');
    try h.expectText("abc");
    try testing.expectEqual(@as(u32, 2), h.ed.seq);

    // Two transactions: undo drops 'c', then undo drops "ab".
    _ = try h.file.undo();
    try h.expectText("ab");
    _ = try h.file.undo();
    try h.expectText("");
}

test "editor: frameEnd flushes once" {
    const h = try Harness.init("");
    defer h.deinit();

    // A keystroke paints and asks for a flush.
    try h.ed.handleKey('x');
    try testing.expect(h.ed.needs_flush);

    // First frameEnd flushes (writes reach the fake tree) and clears the flag.
    const before = h.fx.tree.writes.items.len;
    try h.ed.frameEnd(h.fx.disp);
    try testing.expect(!h.ed.needs_flush);
    const after_one = h.fx.tree.writes.items.len;
    try testing.expect(after_one > before); // the flush produced device writes

    // A second frameEnd with nothing pending is a no-op: no further writes.
    try h.ed.frameEnd(h.fx.disp);
    try testing.expectEqual(after_one, h.fx.tree.writes.items.len);
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
    try testing.expect(h.ed.mouse_state == .chording);
    try testing.expect(h.ed.chord_state == .cut);
    try testing.expectEqualStrings("hello", h.snarf());
    try h.expectText(" world");
    try testing.expectEqual(@as(usize, 0), h.text.q0); // caret collapsed to q0
    try testing.expectEqual(@as(usize, 0), h.text.q1);

    // The gesture ends only when every button releases.
    try h.ed.handleMouse(h.evAtChar(0, 0));
    try testing.expect(h.ed.mouse_state == .idle);
}

test "editor: chord paste inserts snarf selected" {
    const h = try Harness.init("ab");
    defer h.deinit();
    try h.ed.snarf.appendSlice(testing.allocator, "XYZ"); // preload the snarf buffer

    // Caret at char 1 (press+no-move), then B1+B3 = the Paste chord.
    try h.ed.handleMouse(h.evAtChar(1, B1));
    try h.ed.handleMouse(h.evAtChar(1, B1 | B3));
    try testing.expect(h.ed.chord_state == .paste);
    try h.expectText("aXYZb");
    // selectall (text.c:1087): the inserted text is selected [1,4).
    try testing.expectEqual(@as(usize, 1), h.text.q0);
    try testing.expectEqual(@as(usize, 4), h.text.q1);

    try h.ed.handleMouse(h.evAtChar(1, 0));
    try testing.expect(h.ed.mouse_state == .idle);
}

test "editor: chord toggle undoes within the gesture" {
    const h = try Harness.init("hello world");
    defer h.deinit();

    // Cut "hello" via a B1+B2 chord.
    try h.ed.handleMouse(h.evAtChar(0, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1));
    try h.ed.handleMouse(h.evAtChar(5, B1 | B2));
    try h.expectText(" world");
    try testing.expect(h.ed.chord_state == .cut);

    // Without releasing, switch to B1+B3 (Paste chord): this TOGGLES — it undoes
    // the cut and reselects the restored text. The reselect end is exactly the
    // File.undo Range.q1 (here 5, the end of the re-inserted "hello"), matching
    // the C's `textsetselect(t, q0, t->q1)` after `winundo`.
    try h.ed.handleMouse(h.evAtChar(5, B1 | B3));
    try h.expectText("hello world");
    try testing.expect(h.ed.chord_state == .none);
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
    try testing.expect(h.ed.mouse_state == .idle);
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
    try testing.expect(h.ed.chord_state == .cut);
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
    try testing.expect(h.ed.mouse_state == .chording);

    // Release B2 but keep B1 down: still chording (no op — B1 alone is not a
    // chord combo, and the gesture is not over).
    try h.ed.handleMouse(h.evAtChar(5, B1));
    try testing.expect(h.ed.mouse_state == .chording);
    try testing.expect(h.ed.chord_state == .cut); // unchanged

    // Only when ALL buttons release does the gesture end.
    try h.ed.handleMouse(h.evAtChar(5, 0));
    try testing.expect(h.ed.mouse_state == .idle);
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
        try testing.expect(h.ed.mouse_state == .double_clicked);
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
        try testing.expect(h.ed.mouse_state == .sweeping_b1);
    }
    // Different q: the second click lands elsewhere — no double-click.
    {
        const h = try Harness.init("foo bar");
        defer h.deinit();
        try h.ed.handleMouse(h.evAtCharMsec(1, B1, 100));
        try h.ed.handleMouse(h.evAtCharMsec(1, 0, 100));
        try h.ed.handleMouse(h.evAtCharMsec(4, B1, 200)); // same time window, diff char
        try testing.expect(h.ed.mouse_state == .sweeping_b1);
    }
}

test "editor: double-click then chord cuts the word" {
    const h = try Harness.init("foo bar");
    defer h.deinit();

    // Double-click in "bar": click at 4, release, click at 4 within 500ms.
    try h.ed.handleMouse(h.evAtCharMsec(4, B1, 100));
    try h.ed.handleMouse(h.evAtCharMsec(4, 0, 100));
    try h.ed.handleMouse(h.evAtCharMsec(4, B1, 250));
    try testing.expect(h.ed.mouse_state == .double_clicked);
    try testing.expectEqual(@as(usize, 4), h.text.q0);
    try testing.expectEqual(@as(usize, 7), h.text.q1); // "bar" selected

    // B2 joins the double-click: the Cut chord snarfs and deletes the word.
    try h.ed.handleMouse(h.evAtCharMsec(4, B1 | B2, 260));
    try testing.expect(h.ed.mouse_state == .chording);
    try testing.expectEqualStrings("bar", h.snarf());
    try h.expectText("foo ");

    try h.ed.handleMouse(h.evAtCharMsec(4, 0, 270));
    try testing.expect(h.ed.mouse_state == .idle);
}

// --------------------------------------------------------------------------
// Phase 7a scroll tests. "lineNN\n" lines are 7 runes (one 11-wide visual line);
// the 11×25 frame holds 25 lines = 175 runes. See text/typing.zig for the pins.
// --------------------------------------------------------------------------

/// `count` lines of "lineNN\n". Caller frees.
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

fn scrollHarness() !*Harness {
    const seed = try genLines(testing.allocator, 60);
    defer testing.allocator.free(seed);
    return Harness.init(seed);
}

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

test "editor: acceptance 60-line scroll scene" {
    const h = try scrollHarness();
    defer h.deinit();
    const t = &h.text;
    const len = t.file.buffer.len(); // 420
    try t.setSelect(len, len); // the user's caret is at the end of the file

    // Three wheel-down notches scroll to line3 (one line/notch, R-P7-2).
    var i: usize = 0;
    while (i < 3) : (i += 1) try h.ed.handleMouse(.{ .x = 0, .y = 0, .buttons = 16, .msec = 0 });
    try testing.expectEqual(@as(usize, 21), t.org); // runeOfLine(3) = 3*7
    try testing.expectEqualStrings("line03", t.fr.boxes.items[0].kind.run.text);

    // Kend shows the end of the file: the last displayed rune is EOF.
    try h.ed.handleKey(Kend_rune);
    try testing.expectEqual(len, t.org + t.fr.nchars);

    // Typing 'X' at the (visible) end appends without scrolling: org unchanged.
    const org_before = t.org;
    try h.ed.handleKey('X');
    try testing.expectEqual(org_before, t.org);
    try testing.expectEqual(len + 1, t.file.buffer.len());
    try testing.expectEqual(@as(u21, 'X'), t.file.buffer.runeAt(len));

    // FROZEN write-stream hash (R-P2-7): flush everything, then hash the whole
    // device byte-stream. Re-freezing requires orchestrator re-verification.
    try h.fx.disp.flush();
    var hasher = std.hash.Wyhash.init(0);
    for (h.fx.tree.writes.items) |w| hasher.update(w);
    try testing.expectEqual(@as(u64, 0xc06586b7b6a07f73), hasher.final());
}

const Kend_rune: u21 = 0xF000 | 0x18; // keyboard.h Kend
