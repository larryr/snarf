//! The minimal binding of a `File` to a `draw.Frame`: enough to paint a
//! wrapped view of a real buffer onto a display (phase 4 — no typing, no
//! selection, no scrolling; those land in phases 6/7). file-as-struct (S-07
//! P-1): this file *is* the Text.
//!
//! Ported from larryr/plan9port@337c6ac acme/text.c: `fill` is `textfill`
//! (text.c:424-457) in the v1-tiny shape frozen by the frame contract §"core/
//! text/Text.zig" — it drops the `nofill`/`ncache` (typing cache, phase 6) and
//! `fbufalloc` arena (a stack scratch buffer here) but keeps the chunked
//! read-then-newline-cap-then-insert loop faithfully:
//!
//!   - read at most 2000 runes per chunk (text.c:436-437's "educated guess at
//!     reasonable amount"), sized into a `2000 * Buffer.max_bytes_per_rune`
//!     scratch (R-P4-1: `Buffer.read`'s `dest.len >= 4*nrunes` contract) —
//!     stack-allocated since the cap is a small fixed constant, avoiding an
//!     allocator round-trip on every chunk;
//!   - cap the chunk at the (maxlines - nlines)-th newline (text.c:440-450) so
//!     `frinsert` is never asked to lay out more than the frame could ever
//!     show;
//!   - `fr.insert` the (possibly truncated) chunk at `fr.nchars` (text.c:452);
//!   - loop until `fr.lastlinefull` (text.c:453) or the buffer is exhausted
//!     (text.c:434-435).
//!
//! `\n` is always a single ASCII byte in UTF-8 and never appears as a
//! continuation byte of a multibyte rune, so scanning the decoded UTF-8 chunk
//! for `'\n'` bytes (as done here) counts the same newlines the C counts by
//! scanning decoded runes (text.c:445).
//!
//! Imports: std + `draw` (module) + the sibling `File.zig`/`Buffer.zig` only
//! (S-07 §6 — core never imports dev/shim).
const std = @import("std");
const draw = @import("draw");
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");

const Text = @This();
const Point = draw.Point;

/// textfill's per-chunk read cap (text.c:436-437).
const chunk_runes: usize = 2000;

pub const Error = draw.Frame.Error;

file: *File,
fr: draw.Frame,
/// Rune offset into `file.buffer` of `fr`'s first displayed rune (text.c's
/// `Text.org`). Moved by `setOrigin`/`show` (phase 7 scrolling); callers may
/// also set it directly before a `fill`.
org: usize = 0,
/// The selection [q0, q1) in FILE (buffer) coordinates (text.c's `t->q0`/`t->q1`).
/// `q0 == q1` is a collapsed caret. The frame's own `fr.p0`/`fr.p1` are the
/// SCREEN projection of these (offset by `org`); `setSelect` reconciles the two
/// (text.c:1196 "t->fr.p0/p1 are always right; t->q0/q1 may be off").
q0: usize = 0,
q1: usize = 0,
/// "insertion q1" (text.c's `Text.iq1`, dat.h:191 "last input position"): the
/// file offset just past the most recent keyboard input. Maintained like q0/q1
/// by insert/delete and set by the typing arms; Khome/Kend use it to scroll
/// back to where the user was last typing.
iq1: usize = 0,
/// The live B1 sweep, non-null between `selectBegin` and `selectEnd`.
sel: ?draw.Frame.SelectState = null,
/// Double-click SEAM only (text.c:1017-1034, 1051-1058): the msec/char of the
/// last click. Word/line expansion (`textdoubleclick`) is DEFERRED to phase 7 —
/// these fields exist so the gesture layer has somewhere to record clicks, but
/// nothing reads them yet.
last_click_msec: u32 = 0,
last_click_q: usize = 0,

// --- method aliases: typing/selection attach here so callers write
//     `t.typeRune(ed, r)`, `t.setSelect(q0, q1)`, etc. ---
pub const typeRune = @import("typing.zig").typeRune;
pub const setSelect = @import("select.zig").setSelect;
pub const selectBegin = @import("select.zig").selectBegin;
pub const selectMove = @import("select.zig").selectMove;
pub const selectEnd = @import("select.zig").selectEnd;

/// Bind `file` to a fresh `Frame` over `r`/`font`/`b`/`cols` (frame contract
/// §"core/text/Text.zig"). `org` starts at 0. DIVERGENCE F-5: the tick images
/// are built HERE via `fr.initTick()` (the C builds them inside `frinit`), so
/// `init` is fallible.
pub fn init(
    file: *File,
    allocator: std.mem.Allocator,
    r: draw.Rect,
    font: *draw.Font,
    b: *draw.Image,
    cols: [draw.Frame.ncol]*draw.Image,
) Error!Text {
    var t = Text{
        .file = file,
        .fr = draw.Frame.init(allocator, r, font, b, cols),
        .org = 0,
    };
    try t.fr.initTick(); // F-5: tick images built here, not in Frame.init
    return t;
}

/// Release the frame's box list (text.c's texts don't own their Frame's
/// storage any differently — `fr.clear` frees every run box's owned text).
pub fn deinit(self: *Text) void {
    self.fr.clear(true);
}

/// `textfill` (text.c:424-457), v1-tiny: repeatedly read a chunk of the
/// buffer starting after what's already shown, cap it at the frame's
/// remaining line budget, and insert it — until the frame's last line fills
/// or the buffer runs out. A no-op if the frame is already full.
pub fn fill(self: *Text) Error!void {
    if (self.fr.lastlinefull) return;

    while (true) {
        const shown = self.org + self.fr.nchars;
        const remaining = self.file.buffer.len() - shown;
        if (remaining == 0) break;
        const n = @min(remaining, chunk_runes);

        var dest: [chunk_runes * Buffer.max_bytes_per_rune]u8 = undefined;
        const bytes = self.file.buffer.read(shown, n, &dest);

        // Count newlines only up to the frame's remaining line budget
        // (text.c:440-450) — cheaper than inserting more than fits.
        const nl = self.fr.maxlines - self.fr.nlines;
        var cut = bytes.len;
        var seen: usize = 0;
        for (bytes, 0..) |ch, i| {
            if (ch == '\n') {
                seen += 1;
                if (seen >= nl) {
                    cut = i + 1;
                    break;
                }
            }
        }

        try self.fr.insert(bytes[0..cut], self.fr.nchars);
        if (self.fr.lastlinefull) break;
    }
}

/// Full-frame redraw (text.c calls through `frame.c`'s `frredraw`; P4 has no
/// selection, so this is a thin pass-through).
pub fn redraw(self: *Text) Error!void {
    try self.fr.redraw();
}

/// `textinsert` (text.c:366-413), SINGLE-Text subset: insert `bytes` (valid
/// UTF-8) at FILE offset `q0`. When `tofile`, record it through `File.insert`
/// (undoable); then slide `iq1`/the selection/the origin (text.c:393-402, the
/// multi-Text/window-event paths dropped) and, if the edit lands inside the
/// displayed region, `frinsert` at the SCREEN offset `q0-org`. The `q0<org`
/// origin-shift arm is now LIVE (phase 7 scrolling — an edit above the view
/// slides `org` down by `n`).
pub fn insertAt(self: *Text, q0: usize, bytes: []const u8, tofile: bool) Error!void {
    const n = std.unicode.utf8CountCodepoints(bytes) catch unreachable; // valid by contract
    if (n == 0) return; // text.c:373-374
    if (tofile) try self.file.insert(q0, bytes); // text.c:376 fileinsert
    if (q0 < self.iq1) self.iq1 += n; // text.c:393-394
    if (q0 < self.q1) self.q1 += n; // text.c:395-396
    if (q0 < self.q0) self.q0 += n; // text.c:397-398
    if (q0 < self.org) {
        self.org += n; // text.c:399-400 (LIVE with scrolling: an edit above the
        // origin slides the view down so the same text stays on screen)
    } else if (q0 <= self.org + self.fr.nchars) {
        try self.fr.insert(bytes, q0 - self.org); // text.c:401-402 frinsert
    }
}

/// `textdelete` (text.c:460-508), SINGLE-Text subset: delete FILE range
/// `[q0, q1)`. When `tofile`, record it through `File.delete` (undoable, which
/// also captures the doomed text for undo); then slide `iq1`/the selection/the
/// origin (text.c:488-495, multi-Text/window-event paths dropped) and, if the
/// range overlaps the displayed region, `frdelete` the clipped screen range
/// (text.c:496-505) and `textfill` to top the frame back up (text.c:506). The
/// `q1<=org` arm that re-anchors the origin is now LIVE (phase 7 scrolling).
pub fn deleteRange(self: *Text, q0: usize, q1: usize, tofile: bool) Error!void {
    const n = q1 - q0; // text.c:468
    if (n == 0) return; // text.c:469-470
    if (tofile) try self.file.delete(q0, n); // text.c:472 filedelete
    if (q0 < self.iq1) self.iq1 -= @min(n, self.iq1 - q0); // text.c:488-489
    if (q0 < self.q0) self.q0 -= @min(n, self.q0 - q0); // text.c:490-491
    if (q0 < self.q1) self.q1 -= @min(n, self.q1 - q0); // text.c:492-493
    if (q1 <= self.org) {
        self.org -= n; // text.c:494-495 (LIVE with scrolling: a delete entirely
        // above the origin slides the view up to keep the same text on screen)
    } else if (q0 < self.org + self.fr.nchars) { // text.c:496
        var p1 = q1 - self.org; // text.c:497
        if (p1 > self.fr.nchars) p1 = self.fr.nchars; // text.c:498-499
        var p0: usize = undefined;
        if (q0 < self.org) { // text.c:500-502
            self.org = q0;
            p0 = 0;
        } else {
            p0 = q0 - self.org; // text.c:503-504
        }
        _ = try self.fr.delete(p0, p1); // text.c:505 frdelete
        try self.fill(); // text.c:506 textfill
    }
}

/// `textbacknl` (text.c:1590-1609): walk back `n` lines from file offset `p`,
/// returning the offset of the resulting line start. `n==0` means "start of the
/// line containing `p`" (unless `p` already sits just after a '\n'). Each line
/// is capped at 128 chars so a pathologically long line still "counts" as one.
pub fn backNL(self: *Text, p_in: usize, n_in: usize) usize {
    var p = p_in;
    var n = n_in;
    // look for start of this line if n==0 (text.c:1595-1597).
    if (n == 0 and p > 0 and self.file.buffer.runeAt(p - 1) != '\n') n = 1;
    var i = n;
    while (i > 0 and p > 0) : (i -= 1) {
        p -= 1; // it's at a newline now; back over it (text.c:1600)
        if (p == 0) break; // text.c:1601-1602
        // at 128 chars, call it a line anyway (text.c:1603-1606).
        var j: usize = 128;
        while (true) {
            j -= 1;
            if (!(j > 0 and p > 0)) break;
            if (self.file.buffer.runeAt(p - 1) == '\n') break;
            p -= 1;
        }
    }
    return p;
}

/// `textsetorigin` (text.c:1611-1648, single-Text): move the view so `org` is
/// the first displayed rune, sliding the frame's box list incrementally where
/// possible. `exact==false` means `org` is only an estimate of a char position
/// (e.g. from a pixel), so scan forward up to 256 runes for a '\n' and start
/// just past it. Then one of three cases: a small forward jump deletes from the
/// top; a small backward jump reads the intervening runes and inserts them at
/// the top; anything larger clears the frame. Always: set `org`, refill, and
/// re-project the selection; the fixup tail repaints the last selected char,
/// which `frdelete` can leave in the wrong mode (text.c:1633).
pub fn setOrigin(self: *Text, org_in: usize, exact: bool) Error!void {
    var org = org_in;
    // inexact: org is a char-position estimate — hunt forward for a newline
    // (text.c:1618-1628, "don't try harder than 256 chars").
    if (org > 0 and !exact and self.file.buffer.runeAt(org - 1) != '\n') {
        var i: usize = 0;
        while (i < 256 and org < self.file.buffer.len()) : (i += 1) {
            if (self.file.buffer.runeAt(org) == '\n') {
                org += 1;
                break;
            }
            org += 1;
        }
    }
    const a: i64 = @as(i64, @intCast(org)) - @as(i64, @intCast(self.org)); // text.c:1629
    const nchars: i64 = @intCast(self.fr.nchars);
    var fixup = false; // text.c:1630
    if (a >= 0 and a < nchars) {
        _ = try self.fr.delete(0, @intCast(a)); // text.c:1632 frdelete
        // frdelete can leave the end of the last line in the wrong selection
        // mode; it doesn't know what follows (text.c:1633).
        fixup = true;
    } else if (a < 0 and -a < nchars) {
        const nn = self.org - org; // text.c:1636
        // bufread into heap scratch (4x rule, R-P4-1), then frinsert at 0
        // (text.c:1637-1640). Heap, not stack: `nn` is bounded only by nchars.
        const dest = try self.fr.allocator.alloc(u8, nn * Buffer.max_bytes_per_rune);
        defer self.fr.allocator.free(dest);
        const bytes = self.file.buffer.read(org, nn, dest); // text.c:1638 bufread
        try self.fr.insert(bytes, 0); // text.c:1639 frinsert
    } else {
        _ = try self.fr.delete(0, self.fr.nchars); // text.c:1642 frdelete
    }
    self.org = org; // text.c:1643
    try self.fill(); // text.c:1644 textfill
    // text.c:1645 textscrdraw — FLAG: scrollbar strip deferred to windows (R-P7-1).
    try self.setSelect(self.q0, self.q1); // text.c:1646 textsetselect
    if (fixup and self.fr.p1 > self.fr.p0) {
        // repaint the last selected char in the correct mode (text.c:1647-1648).
        try self.fr.drawSel(self.fr.ptOfChar(self.fr.p1 - 1), self.fr.p1 - 1, self.fr.p1, true);
    }
}

/// `textshow` (text.c:1101-1147, single-Text): ensure `[q0,q1)` is visible,
/// optionally selecting it. If it already lies within the displayed region
/// (the `tsd` test) there is nothing to scroll. Otherwise re-origin so `q0`
/// lands about a quarter of the way down the frame (`maxlines/4`), then the
/// `while` walk creeps the origin forward one estimated line at a time in case
/// `q0` sits on a line too long to have fit from the `backNL` estimate.
pub fn show(self: *Text, q0: usize, q1: usize, doselect: bool) Error!void {
    // Single-Text: no `what != Body` early return, no `colgrow` (R-P7-1).
    if (doselect) try self.setSelect(q0, q1); // text.c:1117-1118
    const qe = self.org + self.fr.nchars; // text.c:1119
    var tsd = false; // do we call textscrdraw? (text.c:1120)
    const nc = self.file.buffer.len(); // text.c:1121 (no ncache, F-6)
    if (self.org <= q0) { // text.c:1122
        if (nc == 0 or q0 < qe) {
            tsd = true; // text.c:1123-1124
        } else if (q0 == qe and qe == nc) { // text.c:1125
            if (self.file.buffer.runeAt(nc - 1) == '\n') {
                if (self.fr.nlines < self.fr.maxlines) tsd = true; // text.c:1127-1128
            } else {
                tsd = true; // text.c:1129-1130
            }
        }
    }
    if (tsd) {
        // text.c:1133-1134 textscrdraw — FLAG (R-P7-1); the caret is already
        // on-screen so there is nothing to scroll.
    } else {
        const nl = self.fr.maxlines / 4; // text.c:1139 (single-Text: no QWevent 3/4)
        const q = self.backNL(q0, nl); // text.c:1140
        // avoid going backwards if trying to go forwards — long lines! (text.c:1141-1143)
        if (!(q0 > self.org and q < self.org)) try self.setOrigin(q, true);
        while (q0 > self.org + self.fr.nchars) try self.setOrigin(self.org + 1, false); // text.c:1144-1145
    }
}

/// `textbswidth` (text.c:535-564): how many runes an erase key would remove,
/// starting at the caret `q0`. `^H` (0x08) erases one; `^U` (0x15) erases to
/// the line start, eating at most one preceding '\n'; `^W` (0x17) erases one
/// alnum word (skipping trailing non-alnum first). DIVERGENCE: `isalnum` here
/// is ASCII-only (r < 0x80) — Plan 9's `isalnum` is Latin-1; full Unicode word
/// classes are deferred.
pub fn bsWidth(self: *Text, c: u21) usize {
    // there is known to be at least one character to erase (text.c:542-544).
    if (c == 0x08) return 1; // ^H: erase character
    var q = self.q0; // text.c:545
    var skipping = true; // text.c:546
    while (q > 0) { // text.c:547
        const r = self.file.buffer.runeAt(q - 1); // text.c:548 textreadc
        if (r == '\n') { // eat at most one more character (text.c:549-553)
            if (q == self.q0) q -= 1; // eat the newline
            break;
        }
        if (c == 0x17) { // ^W (text.c:554-560)
            const eq = isalnum(r);
            if (eq and skipping) {
                skipping = false; // found one; stop skipping
            } else if (!eq and !skipping) {
                break;
            }
        }
        q -= 1; // text.c:561
    }
    return self.q0 - q; // text.c:563
}

/// ASCII-only `isalnum` (see `bsWidth` DIVERGENCE note).
fn isalnum(r: u21) bool {
    return r < 0x80 and std.ascii.isAlphanumeric(@intCast(r));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;

// Pull the sibling typing/selection test blocks into this module's test binary.
test {
    _ = @import("typing.zig");
    _ = @import("select.zig");
}

fn makeFile(allocator: std.mem.Allocator, bytes: []const u8) !File {
    return File.init(allocator, try Buffer.initFromBytes(allocator, bytes));
}

test "text: fill renders a buffer" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var f = try makeFile(testing.allocator, "hello, acme wraps\nsecond line\ttab");
    defer f.deinit();

    var t = try Text.init(&f, testing.allocator, proto.Rect.make(20, 20, 119, 470), fx.font, &fx.disp.image, fx.cols());
    defer t.deinit();

    try t.fill();
    try testing.expectEqual(@as(usize, 33), t.fr.nchars);
    try testing.expectEqual(@as(usize, 4), t.fr.nlines);
}

test "text: fill honors org" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var f = try makeFile(testing.allocator, "hello, acme wraps\nsecond line\ttab");
    defer f.deinit();

    var t = try Text.init(&f, testing.allocator, proto.Rect.make(20, 20, 119, 470), fx.font, &fx.disp.image, fx.cols());
    defer t.deinit();
    t.org = 18; // skip "hello, acme wraps\n" -> first shown text is "second line..."

    try t.fill();
    try testing.expectEqual(@as(usize, 15), t.fr.nchars);
    try testing.expectEqualStrings("second line", t.fr.boxes.items[0].kind.run.text);
    try testing.expectEqual(proto.Point{ .x = 20, .y = 20 }, t.fr.ptOfChar(0));
}

test "text: fill stops at frame full" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    // A 3-line frame: 3*18 = 54px tall, 11 chars/line (99px / 9px).
    const r = proto.Rect.make(20, 20, 119, 20 + 3 * 18);

    // 100 lines of exactly 11 chars + '\n' (12 runes/line): the chunk-newline
    // cap (nl = maxlines - nlines = 3) cuts the read right after the 3rd
    // newline, i.e. exactly 3 full lines (36 runes) — which also lands the
    // pen exactly on the frame's bottom edge, setting lastlinefull.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var line: usize = 0;
    while (line < 100) : (line += 1) try buf.appendSlice(testing.allocator, "0123456789A\n");

    var f = try makeFile(testing.allocator, buf.items);
    defer f.deinit();

    var t = try Text.init(&f, testing.allocator, r, fx.font, &fx.disp.image, fx.cols());
    defer t.deinit();

    try t.fill();
    try testing.expectEqual(@as(usize, 36), t.fr.nchars);
    try testing.expect(t.fr.lastlinefull);

    // A second fill is a no-op: the frame is already full.
    const nchars_before = t.fr.nchars;
    try t.fill();
    try testing.expectEqual(nchars_before, t.fr.nchars);
}

test "text: fill chunk cap" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    // A single 4000-rune line (no newlines) into a 25-line frame.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 4000) : (i += 1) try buf.append(testing.allocator, 'x');

    var f = try makeFile(testing.allocator, buf.items);
    defer f.deinit();

    var t = try Text.init(&f, testing.allocator, proto.Rect.make(20, 20, 119, 470), fx.font, &fx.disp.image, fx.cols());
    defer t.deinit();

    try t.fill();
    try testing.expectEqual(@as(usize, 275), t.fr.nchars);
    try testing.expect(t.fr.lastlinefull);
}

// --------------------------------------------------------------------------
// Phase 7a scroll tests. 9x18 fixed font: 9px/glyph, 18px/line. The default
// rect (20,20)-(119,470) is 11 glyphs (99/9) × 25 lines (450/18). "lineNN\n"
// lines are 6 glyphs + break = 7 runes each, exactly one visual line.
// --------------------------------------------------------------------------

/// A `Text` over `seed` on a fresh draw fixture, filled from `org`.
const ScrollHarness = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,

    fn init(seed: []const u8, r: proto.Rect, org: usize) !*ScrollHarness {
        const a = testing.allocator;
        const h = try a.create(ScrollHarness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.text = try Text.init(&h.file, a, r, h.fx.font, &h.fx.disp.image, h.fx.cols());
        h.text.org = org;
        try h.text.fill();
        return h;
    }
    fn deinit(h: *ScrollHarness) void {
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn firstBox(h: *ScrollHarness) []const u8 {
        return h.text.fr.boxes.items[0].kind.run.text;
    }
};

/// `count` lines of "lineNN\n" (7 runes each). Caller frees.
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

const r25 = proto.Rect.make(20, 20, 119, 470); // 11×25
const r3 = proto.Rect.make(20, 20, 119, 74); // 11×3

test "text: backNL counts lines" {
    // "aaa\n"×4 + "eee": line starts at 0,4,8,12,16; len 19.
    const h = try ScrollHarness.init("aaa\nbbb\nccc\nddd\neee", r25, 0);
    defer h.deinit();
    const t = &h.text;

    // n==0 => start of the line containing p (unless p is already a BOL).
    try testing.expectEqual(@as(usize, 16), t.backNL(18, 0)); // in "eee"
    try testing.expectEqual(@as(usize, 0), t.backNL(3, 0)); // in "aaa"
    try testing.expectEqual(@as(usize, 4), t.backNL(4, 0)); // already at a BOL
    // n lines back from a BOL.
    try testing.expectEqual(@as(usize, 8), t.backNL(16, 2)); // 2 up from "eee" => "ccc"
    try testing.expectEqual(@as(usize, 0), t.backNL(8, 100)); // clamps at start

    // The 128-char line cap: a 200-char line with no newline backs at most 127
    // chars per line-step (plus the initial --p) => 200-1-127 = 72.
    const long = try genLongLine(testing.allocator, 200);
    defer testing.allocator.free(long);
    const h2 = try ScrollHarness.init(long, r25, 0);
    defer h2.deinit();
    try testing.expectEqual(@as(usize, 72), h2.text.backNL(200, 1));
}

fn genLongLine(a: std.mem.Allocator, n: usize) ![]u8 {
    const s = try a.alloc(u8, n);
    @memset(s, 'a');
    return s;
}

test "text: setOrigin forward scroll deletes from the top" {
    const seed = try genLines(testing.allocator, 30);
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, r25, 0);
    defer h.deinit();
    const t = &h.text;

    // Frame full at org 0: 25 lines = 175 runes, first box "line00".
    try testing.expectEqual(@as(usize, 175), t.fr.nchars);
    try testing.expectEqualStrings("line00", h.firstBox());

    // A small forward jump (a in [0,nchars)) frdeletes from the top and refills.
    try t.setOrigin(7, true); // one line down
    try testing.expectEqual(@as(usize, 7), t.org);
    try testing.expectEqualStrings("line01", h.firstBox());
    try testing.expectEqual(@as(usize, 25), t.fr.nlines); // topped back up
}

test "text: setOrigin backward scroll inserts at the top" {
    const seed = try genLines(testing.allocator, 30);
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, r25, 70); // start at line10
    defer h.deinit();
    const t = &h.text;
    try testing.expectEqualStrings("line10", h.firstBox());

    // A small backward jump (a<0, -a<nchars) bufreads the intervening runes and
    // frinserts them at the top.
    try t.setOrigin(63, true); // one line up => line09
    try testing.expectEqual(@as(usize, 63), t.org);
    try testing.expectEqualStrings("line09", h.firstBox());
}

test "text: setOrigin large jump clears and refills" {
    const seed = try genLines(testing.allocator, 30);
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, r25, 0);
    defer h.deinit();
    const t = &h.text;

    // a >= nchars => frdelete the whole frame, then refill from the new org.
    try t.setOrigin(175, true); // line25, past the full frame
    try testing.expectEqual(@as(usize, 175), t.org);
    try testing.expectEqualStrings("line25", h.firstBox());
    try testing.expectEqual(@as(usize, 5), t.fr.nlines); // only 5 lines left
}

test "text: setOrigin inexact hunts forward to a newline" {
    const seed = try genLines(testing.allocator, 30);
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, r25, 0);
    defer h.deinit();
    const t = &h.text;

    // org=3 is mid-"line00"; inexact scans forward to just past the '\n' at 6.
    try t.setOrigin(3, false);
    try testing.expectEqual(@as(usize, 7), t.org);
    try testing.expectEqualStrings("line01", h.firstBox());
}

test "text: setOrigin re-projects the selection (fixup)" {
    const seed = try genLines(testing.allocator, 30);
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, r25, 0);
    defer h.deinit();
    const t = &h.text;

    try t.setSelect(10, 14); // select within line01
    try t.setOrigin(7, true); // forward one line => fixup arm (a>=0)

    // File selection is unchanged; the screen projection follows org.
    try testing.expectEqual(@as(usize, 10), t.q0);
    try testing.expectEqual(@as(usize, 14), t.q1);
    try testing.expectEqual(@as(usize, 3), t.fr.p0); // 10-7
    try testing.expectEqual(@as(usize, 7), t.fr.p1); // 14-7
}

test "text: show places an off-screen caret a quarter from the top" {
    // (a) off-screen caret => backNL(q0, maxlines/4) becomes the origin.
    const seed = try genLines(testing.allocator, 60);
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, r25, 0);
    defer h.deinit();
    const t = &h.text;

    // Caret at line40 (rune 280) is below the 25-line frame. maxlines/4 == 6, so
    // backNL(280,6) == line34 (rune 238) becomes org => caret sits 6 lines down.
    try t.show(280, 280, true);
    try testing.expectEqual(@as(usize, 238), t.org);
    try testing.expectEqualStrings("line34", h.firstBox());

    // (b) tsd no-op: the caret is now visible, so show does not move the origin.
    try t.show(280, 280, true);
    try testing.expectEqual(@as(usize, 238), t.org);

    // (c) long-line walk: a 60-char unbroken line in a 3-line frame. backNL can
    // only estimate; the `while (q0 > org+nchars)` loop then creeps org forward
    // (via inexact setOrigin, which jumps to the line's end) until the caret is
    // no longer below the frame.
    const long = try genLongLine(testing.allocator, 60);
    defer testing.allocator.free(long);
    const wide = try std.mem.concat(testing.allocator, u8, &.{ long, "\nEND" });
    defer testing.allocator.free(wide);
    const h2 = try ScrollHarness.init(wide, r3, 0);
    defer h2.deinit();
    const t2 = &h2.text;

    try t2.show(59, 59, true); // caret at the last 'a', far below a 3-line frame
    try testing.expect(!(59 > t2.org + t2.fr.nchars)); // loop terminated
    try testing.expectEqual(@as(usize, 61), t2.org); // jumped past the long line
}

test "text: insert/delete before org slide org" {
    const seed = try genLines(testing.allocator, 30);
    defer testing.allocator.free(seed);
    const h = try ScrollHarness.init(seed, r25, 70); // org at line10
    defer h.deinit();
    const t = &h.text;
    t.iq1 = 70;

    // An insert entirely above org slides org (and iq1) down by n (text.c:393-400).
    try t.insertAt(0, "XYZ", true);
    try testing.expectEqual(@as(usize, 73), t.org);
    try testing.expectEqual(@as(usize, 73), t.iq1);

    // A delete entirely above org slides org (and iq1) back up (text.c:488-495).
    try t.deleteRange(0, 3, true);
    try testing.expectEqual(@as(usize, 70), t.org);
    try testing.expectEqual(@as(usize, 70), t.iq1);
}
