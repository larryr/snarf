//! Line+rune addresses that survive a reload — `Get`'s `TextAddr` bookkeeping
//! (exec.c:623-630 capture, :656-665 restore) and the two counters it is built
//! from, `nlcount` (ecmd.c:664-690) and `nlcounttopos` (addr.c:58-72).
//! Namespace module (S-07 P-1). Ported from larryr/plan9port@337c6ac.
//!
//! WHY LINES AND NOT OFFSETS. A `Get` of the window's own file replaces the
//! body with whatever is on disk now; a rune offset into the old text means
//! nothing in the new one, but "line 12, 7 runes in" usually still does. acme
//! records dot and the origin that way before `textreset`, and maps them back
//! onto the reloaded text afterwards — clamped, never past a newline.
//!
//! Imports: `std` + sibling core files only (S-07 §6).
const std = @import("std");
const Text = @import("text/Text.zig");

/// `TextAddr` (dat.h): `l*` are line counts, `r*` the runes past the last
/// newline counted. `origin`/`q0` are counted from 0; `q1` from `q0`.
pub const TextAddr = struct {
    lorigin: usize = 0,
    rorigin: usize = 0,
    lq0: usize = 0,
    rq0: usize = 0,
    lq1: usize = 0,
    rq1: usize = 0,
};

/// `nlcount` (ecmd.c:664-690): newlines in `[q0, q1)` and, as `nr`, the runes
/// after the last of them (or after `q0` when there is none).
pub fn nlCount(t: *const Text, q0_in: usize, q1: usize) struct { nl: usize, nr: usize } {
    var q0 = q0_in;
    var start = q0;
    var nl: usize = 0;
    const b = &t.file.buffer;
    while (q0 < q1) : (q0 += 1) {
        if (b.runeAt(q0) == '\n') {
            start = q0 + 1;
            nl += 1;
        }
    }
    return .{ .nl = nl, .nr = q0 - start };
}

/// `nlcounttopos` (addr.c:58-72): from `q0`, skip `nl` newlines, then up to
/// `nr` runes without crossing a newline. Clamped to the text's end.
pub fn nlCountToPos(t: *const Text, q0_in: usize, nl_in: usize, nr_in: usize) usize {
    var q0 = q0_in;
    var nl = nl_in;
    var nr = nr_in;
    const b = &t.file.buffer;
    const nc = b.len();
    while (nl > 0 and q0 < nc) {
        if (b.runeAt(q0) == '\n') nl -= 1;
        q0 += 1;
    }
    if (nl > 0) return q0;
    while (nr > 0 and q0 < nc and b.runeAt(q0) != '\n') {
        q0 += 1;
        nr -= 1;
    }
    return q0;
}

/// exec.c:624-630: record origin, dot start and dot length as line+rune.
pub fn capture(t: *const Text) TextAddr {
    const o = nlCount(t, 0, t.org);
    const a0 = nlCount(t, 0, t.q0);
    const a1 = nlCount(t, t.q0, t.q1);
    return .{ .lorigin = o.nl, .rorigin = o.nr, .lq0 = a0.nl, .rq0 = a0.nr, .lq1 = a1.nl, .rq1 = a1.nr };
}

/// exec.c:659-665 on the reloaded text: dot, then origin (inexact, as acme's
/// `textsetorigin(u, q0, FALSE)`), then the scrollbar.
pub fn restore(t: *Text, a: TextAddr) Text.Error!void {
    const q0 = nlCountToPos(t, 0, a.lq0, a.rq0); // exec.c:659
    const q1 = nlCountToPos(t, q0, a.lq1, a.rq1); // exec.c:660
    try t.setSelect(q0, q1); // exec.c:661
    const org = nlCountToPos(t, 0, a.lorigin, a.rorigin); // exec.c:662
    try t.setOrigin(org, false); // exec.c:663
    try t.scrDraw(); // exec.c:665 textscrdraw
}

// ==========================================================================
// Smoke test. The named battery (T13) is the test writer's.
// ==========================================================================
const testing = std.testing;
const draw = @import("draw");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");

test "getaddr: nlCount / nlCountToPos round-trip" {
    const a = testing.allocator;
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var file = File.init(a, try Buffer.initFromBytes(a, "abc\ndefgh\nij\n"));
    defer file.deinit();
    const rect = draw.proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };
    var t = try Text.init(&file, a, rect, fx.font, &fx.disp.image, fx.cols());
    defer t.deinit();

    const c = nlCount(&t, 0, 7); // "abc\ndef" ⇒ one newline, 3 runes past it
    try testing.expectEqual(@as(usize, 1), c.nl);
    try testing.expectEqual(@as(usize, 3), c.nr);
    try testing.expectEqual(@as(usize, 7), nlCountToPos(&t, 0, c.nl, c.nr));
    // Never crosses a newline: line 2 has only 2 runes.
    try testing.expectEqual(@as(usize, 12), nlCountToPos(&t, 0, 2, 9));
}
