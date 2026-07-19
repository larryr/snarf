//! RuneIndex — prefix sums over a Buffer's piece list, for O(log pieces)
//! rune/byte/line address translation (data contract O7 §2, Ruling C).
//!
//! Three parallel prefix-sum arrays, each of length `pieces + 1`: entry `i`
//! holds the running total of runes / stored bytes / newlines contained in
//! pieces `[0, i)`. The final entry is the grand total. `Buffer` rebuilds the
//! whole index after every successful mutation (eager rebuild); every query is
//! `*const`. This type is Buffer-facing only — core.zig does NOT export it
//! (master ruling R-P4-3). file-as-struct (P-1): this file *is* the RuneIndex.
//!
//! Divergence from acme: acme's buff.c keeps no separate index — it binary
//! searches a flat block array directly (buff.c:96 `buffslowload`/`buffsetsize`
//! walk blocks). We factor the prefix walk out so the piece list can later be
//! swapped for a balanced tree behind the same query surface (S-05 §1).
//!
//! Imports: std only (S-07 §6).
const std = @import("std");

const RuneIndex = @This();

/// Zero-state before the first `rebuild`. All queries tolerate it (totals 0,
/// `pieceCount` 0) so `Buffer.initEmpty` need not allocate; the first mutation
/// rebuilds into the `pieces + 1` invariant.
pub const empty: RuneIndex = .{};

/// Per-piece contribution handed to `rebuild` (stored bytes, not decoded).
pub const Counts = struct { runes: usize, bytes: usize, newlines: usize };

/// A rune position resolved to (piece index, rune offset within that piece).
/// `pos == totalRunes()` yields the end sentinel `{ pieceCount(), 0 }`.
pub const Location = struct { piece: usize, rune_off: usize };

/// Prefix sums; `items.len == pieces + 1` after any `rebuild`.
rune_starts: std.ArrayList(usize) = .empty,
byte_starts: std.ArrayList(usize) = .empty,
line_starts: std.ArrayList(usize) = .empty,

pub fn deinit(self: *RuneIndex, allocator: std.mem.Allocator) void {
    self.rune_starts.deinit(allocator);
    self.byte_starts.deinit(allocator);
    self.line_starts.deinit(allocator);
    self.* = undefined;
}

/// Recompute all three prefix arrays from `counts` (one entry per piece).
/// Reuses existing capacity (`clearRetainingCapacity`), so repeated rebuilds
/// after edits do not thrash the allocator.
pub fn rebuild(self: *RuneIndex, allocator: std.mem.Allocator, counts: []const Counts) error{OutOfMemory}!void {
    const n = counts.len + 1;
    inline for (.{ &self.rune_starts, &self.byte_starts, &self.line_starts }) |list| {
        list.clearRetainingCapacity();
        try list.ensureTotalCapacity(allocator, n);
    }
    var r: usize = 0;
    var b: usize = 0;
    var l: usize = 0;
    self.rune_starts.appendAssumeCapacity(0);
    self.byte_starts.appendAssumeCapacity(0);
    self.line_starts.appendAssumeCapacity(0);
    for (counts) |c| {
        r += c.runes;
        b += c.bytes;
        l += c.newlines;
        self.rune_starts.appendAssumeCapacity(r);
        self.byte_starts.appendAssumeCapacity(b);
        self.line_starts.appendAssumeCapacity(l);
    }
}

/// Number of pieces described by the index (0 in the `empty` state).
pub fn pieceCount(self: *const RuneIndex) usize {
    return if (self.rune_starts.items.len == 0) 0 else self.rune_starts.items.len - 1;
}

pub fn totalRunes(self: *const RuneIndex) usize {
    return lastOrZero(self.rune_starts.items);
}

pub fn totalBytes(self: *const RuneIndex) usize {
    return lastOrZero(self.byte_starts.items);
}

pub fn totalNewlines(self: *const RuneIndex) usize {
    return lastOrZero(self.line_starts.items);
}

/// Rune offset at which piece `i` starts (`i` in `[0, pieceCount()]`).
pub fn runeStart(self: *const RuneIndex, i: usize) usize {
    return self.rune_starts.items[i];
}

pub fn byteStart(self: *const RuneIndex, i: usize) usize {
    return self.byte_starts.items[i];
}

pub fn lineStart(self: *const RuneIndex, i: usize) usize {
    return self.line_starts.items[i];
}

/// Locate the piece containing rune `pos`. A position on a piece boundary
/// belongs to the FOLLOWING (non-empty) piece; `pos == totalRunes()` returns
/// the end sentinel `{ pieceCount(), 0 }`.
pub fn pieceOfRune(self: *const RuneIndex, pos: usize) Location {
    const total = self.totalRunes();
    std.debug.assert(pos <= total);
    if (pos == total) return .{ .piece = self.pieceCount(), .rune_off = 0 };
    // First index j with rune_starts[j] > pos; the piece is j-1. Skipping
    // equal entries lands a boundary position on the following non-empty piece.
    const starts = self.rune_starts.items;
    const j = upperBound(starts, pos);
    const piece = j - 1;
    return .{ .piece = piece, .rune_off = pos - starts[piece] };
}

/// Locate the piece containing the `line`-th newline (1-based `line`), i.e. the
/// piece where 0-based text line `line` begins. `line` must be >= 1 — callers
/// resolve line 0 (rune 0) without consulting the index. Returns the piece and
/// the newline total in the pieces before it.
pub fn pieceOfLine(self: *const RuneIndex, line: usize) struct { piece: usize, newlines_before: usize } {
    std.debug.assert(line >= 1);
    const ls = self.line_starts.items;
    // First index j with line_starts[j] >= line; the containing piece is j-1.
    const j = lowerBound(ls, line);
    const piece = j - 1;
    return .{ .piece = piece, .newlines_before = ls[piece] };
}

fn lastOrZero(items: []const usize) usize {
    return if (items.len == 0) 0 else items[items.len - 1];
}

/// Index of the first element strictly greater than `key`.
fn upperBound(items: []const usize, key: usize) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] <= key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Index of the first element greater than or equal to `key`.
fn lowerBound(items: []const usize, key: usize) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

test {
    std.testing.refAllDecls(@This());
}

test "runeindex: prefix sums and totals over synthetic counts" {
    const alloc = std.testing.allocator;
    var idx: RuneIndex = .empty;
    defer idx.deinit(alloc);

    // Three pieces: (2r,2b,0nl), (3r,5b,1nl), (1r,4b,0nl).
    const counts = [_]Counts{
        .{ .runes = 2, .bytes = 2, .newlines = 0 },
        .{ .runes = 3, .bytes = 5, .newlines = 1 },
        .{ .runes = 1, .bytes = 4, .newlines = 0 },
    };
    try idx.rebuild(alloc, &counts);

    try std.testing.expectEqual(@as(usize, 3), idx.pieceCount());
    try std.testing.expectEqual(@as(usize, 6), idx.totalRunes());
    try std.testing.expectEqual(@as(usize, 11), idx.totalBytes());
    try std.testing.expectEqual(@as(usize, 1), idx.totalNewlines());

    // rune_starts = [0,2,5,6]; byte_starts = [0,2,7,11]; line_starts = [0,0,1,1].
    try std.testing.expectEqual(@as(usize, 0), idx.runeStart(0));
    try std.testing.expectEqual(@as(usize, 2), idx.runeStart(1));
    try std.testing.expectEqual(@as(usize, 5), idx.runeStart(2));
    try std.testing.expectEqual(@as(usize, 6), idx.runeStart(3));
    try std.testing.expectEqual(@as(usize, 7), idx.byteStart(2));
    try std.testing.expectEqual(@as(usize, 1), idx.lineStart(2));
    try std.testing.expectEqual(@as(usize, 1), idx.lineStart(3));

    // empty state tolerated.
    var e: RuneIndex = .empty;
    try std.testing.expectEqual(@as(usize, 0), e.pieceCount());
    try std.testing.expectEqual(@as(usize, 0), e.totalRunes());
}

test "runeindex: pieceOfRune boundary convention incl. end sentinel" {
    const alloc = std.testing.allocator;
    var idx: RuneIndex = .empty;
    defer idx.deinit(alloc);
    const counts = [_]Counts{
        .{ .runes = 2, .bytes = 2, .newlines = 0 },
        .{ .runes = 3, .bytes = 3, .newlines = 0 },
    }; // rune_starts = [0,2,5]
    try idx.rebuild(alloc, &counts);

    try std.testing.expectEqual(Location{ .piece = 0, .rune_off = 0 }, idx.pieceOfRune(0));
    try std.testing.expectEqual(Location{ .piece = 0, .rune_off = 1 }, idx.pieceOfRune(1));
    // boundary rune 2 belongs to the FOLLOWING piece (piece 1, offset 0).
    try std.testing.expectEqual(Location{ .piece = 1, .rune_off = 0 }, idx.pieceOfRune(2));
    try std.testing.expectEqual(Location{ .piece = 1, .rune_off = 2 }, idx.pieceOfRune(4));
    // end sentinel.
    try std.testing.expectEqual(Location{ .piece = 2, .rune_off = 0 }, idx.pieceOfRune(5));

    // An empty piece in the middle is skipped by the boundary rule.
    var idx2: RuneIndex = .empty;
    defer idx2.deinit(alloc);
    const counts2 = [_]Counts{
        .{ .runes = 2, .bytes = 2, .newlines = 0 },
        .{ .runes = 0, .bytes = 0, .newlines = 0 },
        .{ .runes = 3, .bytes = 3, .newlines = 0 },
    }; // rune_starts = [0,2,2,5]
    try idx2.rebuild(alloc, &counts2);
    try std.testing.expectEqual(Location{ .piece = 2, .rune_off = 0 }, idx2.pieceOfRune(2));
}

test "runeindex: pieceOfLine across multi-newline pieces" {
    const alloc = std.testing.allocator;
    var idx: RuneIndex = .empty;
    defer idx.deinit(alloc);
    // piece 0: 2 newlines, piece 1: 0 newlines, piece 2: 3 newlines.
    const counts = [_]Counts{
        .{ .runes = 5, .bytes = 5, .newlines = 2 },
        .{ .runes = 4, .bytes = 4, .newlines = 0 },
        .{ .runes = 7, .bytes = 7, .newlines = 3 },
    }; // line_starts = [0,2,2,5]
    try idx.rebuild(alloc, &counts);
    try std.testing.expectEqual(@as(usize, 5), idx.totalNewlines());

    // newlines 1 and 2 live in piece 0.
    try std.testing.expectEqual(@as(usize, 0), idx.pieceOfLine(1).piece);
    try std.testing.expectEqual(@as(usize, 0), idx.pieceOfLine(1).newlines_before);
    try std.testing.expectEqual(@as(usize, 0), idx.pieceOfLine(2).piece);
    // newline 3 is the first in piece 2 (piece 1 has none, so it is skipped).
    try std.testing.expectEqual(@as(usize, 2), idx.pieceOfLine(3).piece);
    try std.testing.expectEqual(@as(usize, 2), idx.pieceOfLine(3).newlines_before);
    try std.testing.expectEqual(@as(usize, 2), idx.pieceOfLine(5).piece);
}

test "runeindex: rebuild reuses and replaces prior state" {
    const alloc = std.testing.allocator;
    var idx: RuneIndex = .empty;
    defer idx.deinit(alloc);

    const first = [_]Counts{
        .{ .runes = 4, .bytes = 4, .newlines = 1 },
        .{ .runes = 4, .bytes = 4, .newlines = 1 },
    };
    try idx.rebuild(alloc, &first);
    try std.testing.expectEqual(@as(usize, 8), idx.totalRunes());
    try std.testing.expectEqual(@as(usize, 2), idx.totalNewlines());
    const cap_after_first = idx.rune_starts.capacity;

    // Rebuild with fewer pieces: totals reflect ONLY the new counts, and the
    // retained capacity is not shrunk (clearRetainingCapacity, not free).
    const second = [_]Counts{.{ .runes = 3, .bytes = 6, .newlines = 0 }};
    try idx.rebuild(alloc, &second);
    try std.testing.expectEqual(@as(usize, 1), idx.pieceCount());
    try std.testing.expectEqual(@as(usize, 3), idx.totalRunes());
    try std.testing.expectEqual(@as(usize, 6), idx.totalBytes());
    try std.testing.expectEqual(@as(usize, 0), idx.totalNewlines());
    try std.testing.expect(idx.rune_starts.capacity >= cap_after_first);

    // Rebuild to empty piece set: single sentinel entry, totals 0.
    try idx.rebuild(alloc, &.{});
    try std.testing.expectEqual(@as(usize, 0), idx.pieceCount());
    try std.testing.expectEqual(@as(usize, 0), idx.totalRunes());
    try std.testing.expectEqual(@as(usize, 1), idx.rune_starts.items.len);
}
