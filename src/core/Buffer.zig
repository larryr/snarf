//! NAIVE PLACEHOLDER — replaced by A1's piece table; contract signatures only.
//!
//! This file exists ONLY so that File.zig's colocated tests can run for real in
//! the 4a sub-wave, where A1's real `src/core/Buffer.zig` (piece table +
//! RuneIndex) is built concurrently and may not be present in this worktree.
//! It implements the EXACT frozen signatures from `phase4-text-data.md` §1 with
//! a plain `std.ArrayList(u8)` of stored bytes and O(n) rune walks: correct but
//! slow. The orchestrator takes A1's real Buffer at merge; this placeholder is
//! discarded there. Do NOT build on its internals — only its public signatures
//! are contractual. Rune decoding follows Ruling A (one U+FFFD per invalid byte)
//! so read/len/runeAt stay mutually consistent, but nothing here is optimized.
const std = @import("std");

const Buffer = @This();

pub const max_load_piece: usize = 64 << 10;
pub const max_bytes_per_rune: usize = 4;

allocator: std.mem.Allocator,
/// Stored bytes, verbatim (Ruling A: original store keeps loaded bytes).
data: std.ArrayList(u8) = .empty,

pub fn initEmpty(allocator: std.mem.Allocator) Buffer {
    return .{ .allocator = allocator };
}

pub fn initFromBytes(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Buffer {
    var self = Buffer{ .allocator = allocator };
    try self.data.appendSlice(allocator, bytes);
    return self;
}

pub fn deinit(self: *Buffer) void {
    self.data.deinit(self.allocator);
    self.* = undefined;
}

/// Decode one rune at byte offset `i`; invalid start/sequence ⇒ (U+FFFD, 1 byte).
fn decodeAt(bytes: []const u8, i: usize) struct { cp: u21, size: usize } {
    const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return .{ .cp = 0xFFFD, .size = 1 };
    if (i + n > bytes.len) return .{ .cp = 0xFFFD, .size = 1 };
    const cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch return .{ .cp = 0xFFFD, .size = 1 };
    return .{ .cp = cp, .size = n };
}

/// Byte offset of rune index `pos` (pos == len ⇒ data.items.len).
fn byteOffsetOf(self: *const Buffer, pos: usize) usize {
    const bytes = self.data.items;
    var i: usize = 0;
    var r: usize = 0;
    while (r < pos) : (r += 1) {
        std.debug.assert(i < bytes.len);
        i += decodeAt(bytes, i).size;
    }
    return i;
}

pub fn len(self: *const Buffer) usize {
    const bytes = self.data.items;
    var i: usize = 0;
    var r: usize = 0;
    while (i < bytes.len) : (r += 1) i += decodeAt(bytes, i).size;
    return r;
}

pub fn rawByteLen(self: *const Buffer) usize {
    return self.data.items.len;
}

pub fn insert(self: *Buffer, pos: usize, bytes: []const u8) error{OutOfMemory}!void {
    std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
    std.debug.assert(pos <= self.len());
    const off = self.byteOffsetOf(pos);
    try self.data.insertSlice(self.allocator, off, bytes);
}

pub fn delete(self: *Buffer, pos: usize, nrunes: usize) error{OutOfMemory}!void {
    std.debug.assert(pos + nrunes <= self.len());
    const start = self.byteOffsetOf(pos);
    const end = blk: {
        var i = start;
        var r: usize = 0;
        while (r < nrunes) : (r += 1) i += decodeAt(self.data.items, i).size;
        break :blk i;
    };
    self.data.replaceRangeAssumeCapacity(start, end - start, &.{});
}

pub fn read(self: *const Buffer, pos: usize, nrunes: usize, dest: []u8) []u8 {
    std.debug.assert(pos + nrunes <= self.len());
    std.debug.assert(dest.len >= max_bytes_per_rune * nrunes);
    const bytes = self.data.items;
    var i = self.byteOffsetOf(pos);
    var out: usize = 0;
    var r: usize = 0;
    while (r < nrunes) : (r += 1) {
        const d = decodeAt(bytes, i);
        // Decoded output: re-encode (substitutes U+FFFD for invalid bytes).
        out += std.unicode.utf8Encode(d.cp, dest[out..]) catch unreachable;
        i += d.size;
    }
    return dest[0..out];
}

pub fn runeAt(self: *const Buffer, pos: usize) u21 {
    std.debug.assert(pos < self.len());
    return decodeAt(self.data.items, self.byteOffsetOf(pos)).cp;
}

pub fn lineCount(self: *const Buffer) usize {
    var n: usize = 1;
    for (self.data.items) |b| {
        if (b == '\n') n += 1;
    }
    return n;
}

pub fn lineOfRune(self: *const Buffer, pos: usize) usize {
    const bytes = self.data.items;
    const off = self.byteOffsetOf(pos);
    var line: usize = 0;
    var i: usize = 0;
    while (i < off) : (i += 1) {
        if (bytes[i] == '\n') line += 1;
    }
    return line;
}

pub fn runeOfLine(self: *const Buffer, line: usize) usize {
    if (line == 0) return 0;
    const bytes = self.data.items;
    var seen: usize = 0;
    var i: usize = 0;
    var r: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\n') {
            seen += 1;
            if (seen == line) return r + 1;
        }
        i += decodeAt(bytes, i).size;
        r += 1;
    }
    return r;
}

pub fn writeRaw(self: *const Buffer, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(self.data.items);
}
