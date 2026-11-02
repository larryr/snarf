//! Input held while a window load is in flight (#83).
//!
//! acme reads a file with a synchronous `textload` (text.c:192-317), called
//! from the thread that is handling the mouse or keyboard event that asked
//! for it (look.c:857, exec.c:632-637 `get`, acme.c:285-300 `readfile`).
//! While it runs, that thread holds `row.lk`; the other input thread blocks on
//! the same lock (acme.c:476-517 keyboardthread, :576-672 mousethread), and
//! devdraw keeps the events queued. Nothing can edit a window between the
//! moment its load starts and the moment the body is in place, and every
//! event that arrived meanwhile is handled afterwards, in order.
//!
//! The port's load is asynchronous (one 9P state per frame, `Load.zig`), so
//! a key typed into the still-empty body went in and was then wiped by
//! `installFile`'s `textreset`, and `finishTail` marked the window clean: the
//! edit was lost without a word (#83). This file restores acme's order: while
//! any load is in flight, `Editor.handleKey`/`handleMouse` queue the event
//! here instead of handling it, and `Load.stepAll` replays the queue once the
//! last load has finished, stopping again if a replayed event starts a new
//! load. Frames keep drawing meanwhile, as devdraw keeps the old screen up.
//!
//! The one liberty: consecutive pointer moves with no button held are
//! coalesced to the last (only its position can matter), so a long load
//! cannot grow the queue without bound while the mouse wanders. Only a BARE
//! move is ever replaced: a queued no-button sample whose previous mouse
//! sample also had no button. A no-button sample after a held button is a
//! release, and it is kept, or a B1 click followed by a move would replay as
//! a sweep and a B2 command would be lost (SnarfDev2, PR #85 review). Samples
//! with a button held (drags, chords) and wheel samples are kept one for one.
//!
//! Imports: `std` + sibling core files (S-07 §6).
const std = @import("std");
const Editor = @import("Editor.zig");

pub const Held = union(enum) {
    key: u21,
    mouse: Editor.MouseEvent,
};

/// acme's `row.lk` held by a `textload`: some window load is in flight.
pub fn holding(ed: *const Editor) bool {
    return ed.loads.items.len != 0;
}

/// Queue `ev` if a load is in flight; true when it was queued (the caller
/// must not handle it now).
pub fn hold(ed: *Editor, ev: Held) error{OutOfMemory}!bool {
    if (!holding(ed)) return false;
    const q = &ed.held_input;
    if (ev == .mouse and ev.mouse.buttons == 0 and q.items.len != 0) {
        const last = &q.items[q.items.len - 1];
        if (last.* == .mouse and isBareMove(q.items[0 .. q.items.len - 1], last.mouse)) {
            last.* = ev; // a bare move replaces a bare move
            return true;
        }
    }
    try q.append(ed.allocator, ev);
    return true;
}

/// `m` (queued after `before`) is a move with no button held and no button
/// change: it has no buttons, and neither has the mouse sample queued before
/// it. With no earlier sample in the queue the state it changed from is not
/// known here, so it counts as a change and is kept: the queue still grows by
/// at most one sample per button change.
fn isBareMove(before: []const Held, m: Editor.MouseEvent) bool {
    if (m.buttons != 0) return false;
    var i = before.len;
    while (i > 0) {
        i -= 1;
        if (before[i] == .mouse) return before[i].mouse.buttons == 0;
    }
    return false;
}

/// Hand the held events to the editor, in arrival order, while no load is in
/// flight. A replayed event that starts a load (a B3 on a file name, a Get)
/// leaves the rest queued for that load's end, as acme's next event would
/// wait for that `textload` too.
pub fn replay(ed: *Editor) !void {
    var n: usize = 0;
    defer if (n != 0) ed.held_input.replaceRangeAssumeCapacity(0, n, &.{});
    while (n < ed.held_input.items.len and !holding(ed)) {
        const ev = ed.held_input.items[n];
        n += 1;
        switch (ev) {
            .key => |r| try ed.keyNow(r),
            .mouse => |m| try ed.gesture.handleMouse(ed, m),
        }
    }
}

/// Editor teardown: drop whatever is still queued.
pub fn deinit(ed: *Editor) void {
    ed.held_input.deinit(ed.allocator);
}
