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
//! (text.c:668-942 for keys, 1005-1061 for the B1 sweep) reduced to the single
//! phase-6 gesture set (F-9 single-Text; F-7 no scroll; R-P6-6 no chords yet).
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");
const Text = @import("text/Text.zig");

const Editor = @This();
const Point = draw.Point;

/// Native mouse button bit (profiles.B1; devmouse.c B1=1). Only B1 drives a
/// selection sweep in phase 6; B2/B3/wheel are recognised and FLAG-ignored.
const B1: u8 = 1;

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
/// B1 gesture state: `idle` between gestures, `sweeping_b1` between a B1 press
/// inside the text and its release (text.c:1017-1061 `textselect`).
mouse_state: enum { idle, sweeping_b1 } = .idle,
/// Set by any handler that painted into the display's op buffer this tick;
/// `frameEnd` performs at most one `display.flush` per tick when it is set.
needs_flush: bool = false,

pub fn init(allocator: std.mem.Allocator) Editor {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Editor) void {
    self.* = undefined;
}

/// True when device point `(x,y)` lies inside the half-open rect `r`.
fn ptInRect(r: draw.Rect, x: i32, y: i32) bool {
    return x >= r.min.x and x < r.max.x and y >= r.min.y and y < r.max.y;
}

/// Route one mouse sample through the B1 selection state machine (R-P6-12).
///   idle + B1 pressed inside fr.r  => begin sweep (ends any typing run first)
///   sweeping + B1 still held        => extend the sweep (selectMove)
///   sweeping + B1 released          => commit the selection (selectEnd) => idle
/// B1 pressed OUTSIDE fr.r, and every B2/B3/wheel sample, are FLAG-ignored:
/// there is no tag, scrollbar, chord or plumbing in phase 6 (F-7, R-P6-6).
pub fn handleMouse(ed: *Editor, ev: MouseEvent) !void {
    const t = ed.text orelse return;
    const pt = Point{ .x = ev.x, .y = ev.y };
    switch (ed.mouse_state) {
        .idle => {
            if (ev.buttons == B1) {
                // A clean B1 press. Begin a sweep only when it lands in the text
                // body; a press elsewhere has nowhere to go yet.
                if (ptInRect(t.fr.r, ev.x, ev.y)) {
                    ed.in_typing_run = false; // a mouse gesture ends the run (R-P6-8)
                    try t.selectBegin(pt);
                    ed.mouse_state = .sweeping_b1;
                    ed.needs_flush = true;
                }
                // FLAG: B1 press outside fr.r ignored — no tag/scrollbar (F-7).
            }
            // FLAG: buttons & 8/16 (wheel) ignored — org fixed, no scroll (F-7).
            // FLAG: buttons == 2/4 (B2/B3) ignored — chords/plumb deferred (R-P6-6).
        },
        .sweeping_b1 => {
            if (ev.buttons & B1 != 0) {
                try t.selectMove(pt); // extend the live sweep (frselect loop body)
                ed.needs_flush = true;
            } else {
                // B1 released (buttons == 0, or a degenerate swap to another
                // button): commit and return to idle.
                try t.selectEnd(pt);
                ed.mouse_state = .idle;
                ed.needs_flush = true;
            }
        },
    }
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
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");

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
        const pt = h.text.fr.ptOfChar(p);
        return .{ .x = pt.x, .y = pt.y, .buttons = buttons, .msec = 0 };
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
