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

/// textfill's per-chunk read cap (text.c:436-437).
const chunk_runes: usize = 2000;

pub const Error = draw.Frame.Error;

file: *File,
fr: draw.Frame,
/// Rune offset into `file.buffer` of `fr`'s first displayed rune (text.c's
/// `Text.org`). Phase 4 has no scrolling, so callers set this directly.
org: usize = 0,

/// Bind `file` to a fresh `Frame` over `r`/`font`/`b`/`cols` (frame contract
/// §"core/text/Text.zig"). `org` starts at 0.
pub fn init(
    file: *File,
    allocator: std.mem.Allocator,
    r: draw.Rect,
    font: *draw.Font,
    b: *draw.Image,
    cols: [draw.Frame.ncol]*draw.Image,
) Text {
    return .{
        .file = file,
        .fr = draw.Frame.init(allocator, r, font, b, cols),
        .org = 0,
    };
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;

fn makeFile(allocator: std.mem.Allocator, bytes: []const u8) !File {
    return File.init(allocator, try Buffer.initFromBytes(allocator, bytes));
}

test "text: fill renders a buffer" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var f = try makeFile(testing.allocator, "hello, acme wraps\nsecond line\ttab");
    defer f.deinit();

    var t = Text.init(&f, testing.allocator, proto.Rect.make(20, 20, 119, 470), fx.font, &fx.disp.image, fx.cols());
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

    var t = Text.init(&f, testing.allocator, proto.Rect.make(20, 20, 119, 470), fx.font, &fx.disp.image, fx.cols());
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

    var t = Text.init(&f, testing.allocator, r, fx.font, &fx.disp.image, fx.cols());
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

    var t = Text.init(&f, testing.allocator, proto.Rect.make(20, 20, 119, 470), fx.font, &fx.disp.image, fx.cols());
    defer t.deinit();

    try t.fill();
    try testing.expectEqual(@as(usize, 275), t.fr.nchars);
    try testing.expect(t.fr.lastlinefull);
}
