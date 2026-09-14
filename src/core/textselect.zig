//! `textselect` — the per-Text mouse selection machine (text.c:1001-1099), its
//! chord loop (text.c:1064-1098), and the commit/cancel of a finished colored
//! B2/B3 sweep (`textselect2`/`textselect3`, text.c:1361-1384). Namespace module
//! (S-07 P-1, lowercase): the state it drives lives on the `Gesture` value it is
//! handed (`Gesture.zig`, acme.c's `mousethread` half of the same machine), so
//! this file is text.c's contribution and `Gesture.zig` is acme.c's. Carved out
//! verbatim in phase 12e; entered only through `Gesture.handleMouse`.
//!
//! Ported from larryr/plan9port@337c6ac; cite as `text.c:NN`.
//!
//! Imports: `std`, `draw` and sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const draw = @import("draw");
const Text = @import("text/Text.zig");
const Editor = @import("Editor.zig");
const Gesture = @import("Gesture.zig");
const exec = @import("exec/exec.zig");
const look = @import("look.zig");

const Point = draw.Point;
const MouseEvent = Editor.MouseEvent;
const B1 = Gesture.B1;
const B2 = Gesture.B2;
const B3 = Gesture.B3;

/// The `textselect` state machine (text.c:1001-1099), run against the gesture's
/// pinned Text. The C's blocking `readmouse` loop becomes edge-triggered
/// dispatch: chord ops fire only when the button set changes, and a gesture ends
/// only when ALL buttons release (R-P7-6). B1 pressed OUTSIDE `fr.r` is
/// FLAG-ignored (no sub-frame target, R-P7-1).
pub fn run(g: *Gesture, ed: *Editor, t: *Text, ev: MouseEvent) !void {
    const pt = Point{ .x = ev.x, .y = ev.y };
    const b = ev.buttons;
    switch (g.mouse_state) {
        .idle => {
            if (b == B1) {
                // A clean B1 press. Begin a sweep only when it lands in the text
                // body; a press elsewhere has nowhere to go yet.
                if (Gesture.ptInRect(t.fr.r, ev.x, ev.y)) {
                    ed.in_typing_run = false; // a mouse gesture ends the run (R-P6-8)
                    g.press_pt = pt;
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
                            g.mouse_state = .double_clicked;
                            ed.needs_flush = true;
                            return;
                        }
                    }
                    try t.selectBegin(pt); // text.c:1035-1037 frselect setup
                    g.mouse_state = .sweeping_b1;
                    ed.needs_flush = true;
                }
                // FLAG: B1 press outside fr.r ignored — no sub-frame target (R-P7-1).
            } else if (b == B2 or b == B3) {
                // A B2/B3 press opens the colored execute/look sweep (`xselect`,
                // text.c:1268-1279). Begin only inside the frame; a mouse gesture
                // ends any typing run (R-P6-8). The sweep paints `but2col`/`but3col`
                // (or `t.fr.col(.high)` headless, R-P9-12) as a temporary overlay —
                // never `f.p0`/`f.p1`.
                if (Gesture.ptInRect(t.fr.r, ev.x, ev.y)) {
                    ed.in_typing_run = false;
                    const is_b2 = (b == B2);
                    const col = if (is_b2)
                        (ed.but2col orelse t.fr.col(.high))
                    else
                        (ed.but3col orelse t.fr.col(.high));
                    g.sel23 = try draw.Frame.select23Begin(&t.fr, pt, col, ev.msec);
                    g.sel23_buts = 0; // still pure (textselect23:1350)
                    g.sel23_button = b;
                    g.mouse_state = if (is_b2) .sweeping_b2 else .sweeping_b3;
                    ed.needs_flush = true;
                }
                // FLAG: B2/B3 press outside fr.r ignored (mirrors B1).
            }
            // FLAG: wheel notches are handled by handleMouse before the gesture
            // machine is ever entered.
        },
        .sweeping_b1 => {
            if ((b & B1) != 0 and (b & (B2 | B3)) != 0) {
                // A chord begins mid-sweep. frselect exits on any button-set
                // change (frselect.c:102); commit the swept selection, then hand
                // this same event to the chord step (text.c:1035,1064-1067).
                try t.selectEnd(pt);
                g.sweep_q0 = t.q0;
                g.chord_state = .none;
                g.chord_buttons = 0;
                g.mouse_state = .chording;
                ed.needs_flush = true;
                try chordStep(g, ed, t, ev);
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
                g.mouse_state = .idle;
                ed.needs_flush = true;
            }
        },
        .double_clicked => {
            if ((b & B1) != 0 and (b & (B2 | B3)) != 0) {
                // B2/B3 joins the double-click: chord over the expanded selection.
                g.sweep_q0 = t.q0;
                g.chord_state = .none;
                g.chord_buttons = 0;
                g.mouse_state = .chording;
                ed.needs_flush = true;
                try chordStep(g, ed, t, ev);
            } else if (b == B1) {
                // B1 still down: a drag of >=3px converts to a fresh sweep
                // (text.c:1026-1030 waits here until the mouse moves). DIVERGENCE:
                // the C keeps the double-click as the sweep anchor; the port
                // re-anchors at the press point.
                if (@abs(pt.x - g.press_pt.x) >= 3 or @abs(pt.y - g.press_pt.y) >= 3) {
                    try t.selectBegin(g.press_pt);
                    g.mouse_state = .sweeping_b1;
                    ed.needs_flush = true;
                }
            } else if (b == 0) {
                // Release: back to idle. `last_click` stays null — no triple-click
                // (text.c:1054 clicktext=nil).
                g.mouse_state = .idle;
            }
        },
        .chording => try chordStep(g, ed, t, ev),
        .sweeping_b2, .sweeping_b3 => {
            // The colored sweep body (`xselect`, text.c:1280-1357). While the SAME
            // button is still down alone, extend the live overlay. Any button-set
            // change folds the final sample in, ends the sweep (restoring paint),
            // and freezes `buts` — the C's `buts = mousectl->m.buttons` read right
            // after xselect returns (text.c:1348-1350).
            const only_b: u8 = if (g.mouse_state == .sweeping_b2) B2 else B3;
            if (b == only_b) {
                try draw.Frame.select23Update(&g.sel23.?, pt); // text.c:1281-1313
            } else {
                const r = try draw.Frame.select23End(&g.sel23.?, pt, ev.msec);
                g.sel23_range = .{ .q0 = t.org + r.p0, .q1 = t.org + r.p1 };
                g.sel23_buts = b; // freeze at the FIRST change (textselect23:1350)
                g.sel23 = null;
                if (b == 0) {
                    // Direct release: dispatch now (buts == 0). text.c:1355 loop
                    // never runs.
                    g.mouse_state = .idle;
                    try dispatchSel23(g, ed, t);
                } else {
                    // A button joined: wait for all-up before dispatching
                    // (text.c:1355-1357 `while(buttons) readmouse`).
                    g.mouse_state = .draining;
                }
            }
        },
        .draining => {
            // text.c:1355-1357: swallow every sample until all buttons release;
            // further button-set changes do NOT re-freeze `sel23_buts`. Then
            // dispatch with the frozen mask.
            if (b == 0) {
                g.mouse_state = .idle;
                try dispatchSel23(g, ed, t);
            }
        },
    }
}

/// Commit or cancel a finished B2/B3 sweep (textselect2/textselect3 +
/// mousethread, text.c:1361-1384 / acme.c:661-668). `t` is the gesture's Text.
/// B2: a B3-join cancels (`buts & 4`, text.c:1368-1369); a B1-join passes
/// `ed.argtext` as the command argument (`buts & 1`, text.c:1370-1373); otherwise
/// no argument. B3: a B1- OR B2-join cancels (`buts & (1|2)`, text.c:1382).
/// CRITICAL (R-P9-2): after a committed B2 `execute`, the window may be gone
/// (Del/Delcol ran `dropTextRefs`, nilling the Editor's Text pointers) — this is
/// the LAST use of `t`; the caller must not touch it afterward.
fn dispatchSel23(g: *Gesture, ed: *Editor, t: *Text) Text.Error!void {
    const buts = g.sel23_buts;
    const q0 = g.sel23_range.q0;
    const q1 = g.sel23_range.q1;
    if (g.sel23_button == B2) {
        if (buts & B3 != 0) return; // text.c:1368-1369 B3-join cancels
        const argt: ?*Text = if (buts & B1 != 0) ed.argtext else null; // text.c:1370-1373
        try exec.execute(ed, t, q0, q1, argt); // acme.c:662
    } else {
        if (buts & (B1 | B2) != 0) return; // text.c:1382 B1/B2-join cancels
        try look.look(ed, t, q0, q1, false); // acme.c:666
    }
}

/// One iteration of `textselect`'s chord loop (text.c:1064-1098), edge-triggered.
/// Fires a Cut/Paste (or a toggle-undo) only when the button set CHANGES to a
/// B1+B2/B3 combo; ends the gesture (=> idle) once every button releases.
fn chordStep(g: *Gesture, ed: *Editor, t: *Text, ev: MouseEvent) !void {
    const b = ev.buttons;
    // text.c:1065 mouse->msec=0 / :1097 clicktext=nil — a chord voids any pending
    // double-click, both entering and leaving the loop body.
    t.last_click = null;
    if (b == 0) { // text.c:1064 while(mouse->buttons): all up => gesture over
        g.mouse_state = .idle;
        g.chord_state = .none;
        g.chord_buttons = 0;
        return;
    }
    if (b != g.chord_buttons and (b & B1) != 0 and (b & (B2 | B3)) != 0) { // text.c:1067
        if (g.chord_state == .none) {
            ed.seq += 1; // text.c:1069 seq++
            t.file.mark(ed.seq); // text.c:1070 filemark
        }
        if (b & B2 != 0) { // 1-2 chord == Cut (text.c:1072-1080)
            if (g.chord_state == .paste) {
                const r = try t.file.undo(); // text.c:1074 winundo
                try t.setSelect(g.sweep_q0, if (r) |rr| rr.q1 else g.sweep_q0); // text.c:1075
                g.chord_state = .none; // text.c:1076
            } else if (g.chord_state != .cut) {
                try ed.cut(t, true, true); // text.c:1078 cut(dosnarf,docut)
                g.chord_state = .cut; // text.c:1079
            }
        } else { // b & B3 == 1-3 chord == Paste (text.c:1081-1090)
            if (g.chord_state == .cut) {
                const r = try t.file.undo(); // text.c:1083 winundo
                try t.setSelect(g.sweep_q0, if (r) |rr| rr.q1 else g.sweep_q0); // text.c:1084
                g.chord_state = .none; // text.c:1085
            } else if (g.chord_state != .paste) {
                try ed.snarfInsert(t, true); // text.c:1087 paste(selectall=TRUE)
                g.chord_state = .paste; // text.c:1088
            }
        }
        try t.scrDraw(); // text.c:1091 textscrdraw (LIVE; no-op when w==null). clearmouse deferred.
        ed.needs_flush = true;
    }
    g.chord_buttons = b; // text.c:1066/1095 advance the edge tracker
}
