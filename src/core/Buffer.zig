//! Buffer — the editor's rune-addressed text store, as a piece table over two
//! immutable byte backings (data contract O7 §1, master rulings R-P4-1..3).
//!
//! `original` holds the loaded file verbatim; `add` is an append-only log of
//! inserted (always-valid-UTF-8) bytes. `pieces` is a flat ArrayList of spans
//! into one backing or the other (Ruling B: O(pieces) memmove per edit is fine
//! at this scale — acme's own buff.c uses a flat block array, buff.c:37). The
//! public API is rune-addressed; a balanced tree could replace the flat list
//! behind these exact signatures (S-05 §1 — a deliberate divergence from acme's
//! disk-block Buffer, so cite buff.c for API lineage, not line-porting).
//!
//! Invalid UTF-8 (Ruling A): loaded bytes are stored byte-for-byte and each
//! invalid byte counts as ONE rune (matching cvttorunes' one-Runeerror-per-bad-
//! byte). Decoding happens at READ time — `read`/`runeAt` substitute U+FFFD on
//! the fly; `writeRaw` reproduces the stored bytes byte-identically (NULs kept).
//! Split halves keep their `src`/`off`, so untouched pieces preserve raw bytes
//! by construction; only edited regions lose invalid-byte fidelity (File's undo
//! re-inserts decoded U+FFFD, same as acme file.c:126-134).
//!
//! `RuneIndex` (rebuilt eagerly after every mutation) answers rune/byte/line
//! address translation; all queries are `*const`. file-as-struct (P-1).
//!
//! Imports: std + RuneIndex (a sibling core file) only (S-07 §6).
const std = @import("std");
const RuneIndex = @import("RuneIndex.zig");

const Buffer = @This();

/// Loaded `original` is split into pieces of at most this many stored bytes, at
/// rune boundaries, so no single piece dominates a memmove (Ruling B).
pub const max_load_piece: usize = 64 << 10;
/// Worst-case bytes a single rune can occupy when decoded (4-byte UTF-8). The
/// `read` sizing rule is `dest.len >= max_bytes_per_rune * nrunes`.
pub const max_bytes_per_rune: usize = 4;

allocator: std.mem.Allocator,
/// Owned, verbatim loaded bytes; empty (`&.{}`) for `initEmpty`.
original: []u8,
/// Append-only inserted bytes; always valid UTF-8 (callers guarantee it).
add: std.ArrayList(u8) = .empty,
/// The ordered span list. Private: nothing public exposes a `Piece`.
pieces: std.ArrayList(Piece) = .empty,
/// Prefix-sum index over `pieces`; rebuilt after every mutation.
index: RuneIndex = .empty,
/// Count of invalid bytes found at load, for a later caller warning.
invalid_bytes: usize = 0,

/// One span into a backing store. `runes`/`newlines`/`clean` are cached decode
/// facts over the span's stored bytes. `clean` (no invalid bytes) plus all
/// `add` spans take a whole-span memcpy fast path in `read`.
const Piece = struct {
    src: enum(u1) { original, add },
    off: usize,
    bytes: usize,
    runes: usize,
    newlines: usize,
    clean: bool,
};

const RuneStep = struct { step: usize, valid: bool };
const Scan = struct { runes: usize, newlines: usize, clean: bool };

pub fn initEmpty(allocator: std.mem.Allocator) Buffer {
    return .{ .allocator = allocator, .original = &.{} };
}

pub fn initFromBytes(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Buffer {
    var self = Buffer.initEmpty(allocator);
    self.original = try allocator.dupe(u8, bytes);
    errdefer self.deinit();
    try self.loadPieces();
    try self.rebuildIndex();
    return self;
}

pub fn deinit(self: *Buffer) void {
    if (self.original.len != 0) self.allocator.free(self.original);
    self.add.deinit(self.allocator);
    self.pieces.deinit(self.allocator);
    self.index.deinit(self.allocator);
    self.* = undefined;
}

pub fn len(self: *const Buffer) usize {
    return self.index.totalRunes();
}

pub fn rawByteLen(self: *const Buffer) usize {
    return self.index.totalBytes();
}

pub fn lineCount(self: *const Buffer) usize {
    return self.index.totalNewlines() + 1;
}

pub fn insert(self: *Buffer, pos: usize, bytes: []const u8) error{OutOfMemory}!void {
    std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
    std.debug.assert(pos <= self.len());
    if (bytes.len == 0) return;

    const add_off = self.add.items.len;
    try self.add.appendSlice(self.allocator, bytes);
    const sc = scanCounts(bytes); // clean == true for valid UTF-8
    const new_piece = Piece{
        .src = .add,
        .off = add_off,
        .bytes = bytes.len,
        .runes = sc.runes,
        .newlines = sc.newlines,
        .clean = true,
    };

    const loc = self.index.pieceOfRune(pos);
    if (loc.rune_off == 0) {
        const ip = loc.piece;
        // Coalesce sequential typing: extend the previous span if it is `add`
        // bytes ending exactly where these begin (append-only ⇒ contiguous).
        if (ip > 0) {
            const prev = &self.pieces.items[ip - 1];
            if (prev.src == .add and prev.off + prev.bytes == add_off) {
                prev.bytes += bytes.len;
                prev.runes += sc.runes;
                prev.newlines += sc.newlines;
                return self.rebuildIndex();
            }
        }
        try self.pieces.insert(self.allocator, ip, new_piece);
    } else {
        // Mid-piece: split into two references to the same backing range and
        // drop the new span between; halves keep src/off (verbatim), counts
        // recomputed by scanning ONLY this piece.
        const p = self.pieces.items[loc.piece];
        const left = self.leftPart(p, loc.rune_off);
        const right = self.rightPart(p, loc.rune_off);
        self.pieces.items[loc.piece] = left;
        try self.pieces.insertSlice(self.allocator, loc.piece + 1, &.{ new_piece, right });
    }
    return self.rebuildIndex();
}

pub fn delete(self: *Buffer, pos: usize, nrunes: usize) error{OutOfMemory}!void {
    std.debug.assert(pos + nrunes <= self.len());
    if (nrunes == 0) return;

    const s = self.index.pieceOfRune(pos);
    const e = self.index.pieceOfRune(pos + nrunes);

    var repl: [2]Piece = undefined;
    var n: usize = 0;
    if (s.rune_off > 0) {
        repl[n] = self.leftPart(self.pieces.items[s.piece], s.rune_off);
        n += 1;
    }
    const lo = s.piece;
    var hi: usize = undefined;
    if (e.rune_off > 0) {
        repl[n] = self.rightPart(self.pieces.items[e.piece], e.rune_off);
        n += 1;
        hi = e.piece;
    } else {
        // Deletion ends on a boundary: piece e.piece (or the end sentinel)
        // stays whole; remove up to the piece before it.
        hi = e.piece - 1;
    }
    try self.pieces.replaceRange(self.allocator, lo, hi - lo + 1, repl[0..n]);
    return self.rebuildIndex();
}

pub fn read(self: *const Buffer, pos: usize, nrunes: usize, dest: []u8) []u8 {
    std.debug.assert(pos + nrunes <= self.len());
    std.debug.assert(dest.len >= max_bytes_per_rune * nrunes);
    if (nrunes == 0) return dest[0..0];

    const loc = self.index.pieceOfRune(pos);
    var pi = loc.piece;
    var start_rune = loc.rune_off;
    var out: usize = 0;
    var remaining = nrunes;
    while (remaining > 0) {
        const p = self.pieces.items[pi];
        const pbytes = self.pieceBytes(p);
        const startb = self.byteOffsetInPiece(p, start_rune);
        const avail = p.runes - start_rune;
        const take = @min(remaining, avail);
        if (p.clean and take == avail) {
            const seg = pbytes[startb..];
            @memcpy(dest[out..][0..seg.len], seg);
            out += seg.len;
        } else {
            var i = startb;
            var t: usize = 0;
            while (t < take) : (t += 1) {
                const rs = runeStep(pbytes, i);
                if (rs.valid) {
                    @memcpy(dest[out..][0..rs.step], pbytes[i..][0..rs.step]);
                    out += rs.step;
                } else {
                    dest[out] = 0xEF;
                    dest[out + 1] = 0xBF;
                    dest[out + 2] = 0xBD; // U+FFFD REPLACEMENT CHARACTER
                    out += 3;
                }
                i += rs.step;
            }
        }
        remaining -= take;
        pi += 1;
        start_rune = 0;
    }
    return dest[0..out];
}

pub fn runeAt(self: *const Buffer, pos: usize) u21 {
    std.debug.assert(pos < self.len());
    const loc = self.index.pieceOfRune(pos);
    const p = self.pieces.items[loc.piece];
    const pbytes = self.pieceBytes(p);
    const boff = self.byteOffsetInPiece(p, loc.rune_off);
    const rs = runeStep(pbytes, boff);
    if (rs.valid) return std.unicode.utf8Decode(pbytes[boff..][0..rs.step]) catch 0xFFFD;
    return 0xFFFD;
}

pub fn lineOfRune(self: *const Buffer, pos: usize) usize {
    std.debug.assert(pos <= self.len());
    const loc = self.index.pieceOfRune(pos);
    var lines = self.index.lineStart(loc.piece);
    if (loc.rune_off > 0) {
        const p = self.pieces.items[loc.piece];
        const boff = self.byteOffsetInPiece(p, loc.rune_off);
        lines += scanCounts(self.pieceBytes(p)[0..boff]).newlines;
    }
    return lines;
}

pub fn runeOfLine(self: *const Buffer, line: usize) usize {
    std.debug.assert(line < self.lineCount());
    if (line == 0) return 0;
    const pl = self.index.pieceOfLine(line);
    const base = self.index.runeStart(pl.piece);
    const target = line - pl.newlines_before; // 1-based newline within the piece
    const p = self.pieces.items[pl.piece];
    const pbytes = self.pieceBytes(p);
    var i: usize = 0;
    var runes_seen: usize = 0;
    var nl: usize = 0;
    while (i < pbytes.len) {
        const rs = runeStep(pbytes, i);
        runes_seen += 1;
        if (rs.valid and pbytes[i] == '\n') {
            nl += 1;
            if (nl == target) return base + runes_seen;
        }
        i += rs.step;
    }
    return base + runes_seen; // unreachable for an in-range line
}

pub fn writeRaw(self: *const Buffer, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (self.pieces.items) |p| try w.writeAll(self.pieceBytes(p));
}

// --- internals -----------------------------------------------------------

/// Split `original` into pieces of <= `max_load_piece` stored bytes at rune
/// boundaries, tallying counts and `invalid_bytes` in a single pass.
fn loadPieces(self: *Buffer) error{OutOfMemory}!void {
    const orig = self.original;
    if (orig.len == 0) return;
    var start: usize = 0;
    var i: usize = 0;
    var cr: usize = 0;
    var cn: usize = 0;
    var cc = true;
    while (i < orig.len) {
        const rs = runeStep(orig, i);
        if (i > start and (i - start) + rs.step > max_load_piece) {
            try self.pieces.append(self.allocator, .{ .src = .original, .off = start, .bytes = i - start, .runes = cr, .newlines = cn, .clean = cc });
            start = i;
            cr = 0;
            cn = 0;
            cc = true;
        }
        cr += 1;
        if (!rs.valid) {
            cc = false;
            self.invalid_bytes += 1;
        } else if (orig[i] == '\n') cn += 1;
        i += rs.step;
    }
    try self.pieces.append(self.allocator, .{ .src = .original, .off = start, .bytes = orig.len - start, .runes = cr, .newlines = cn, .clean = cc });
}

fn rebuildIndex(self: *Buffer) error{OutOfMemory}!void {
    const counts = try self.allocator.alloc(RuneIndex.Counts, self.pieces.items.len);
    defer self.allocator.free(counts);
    for (self.pieces.items, counts) |p, *c| {
        c.* = .{ .runes = p.runes, .bytes = p.bytes, .newlines = p.newlines };
    }
    try self.index.rebuild(self.allocator, counts);
}

fn pieceBytes(self: *const Buffer, p: Piece) []const u8 {
    return switch (p.src) {
        .original => self.original[p.off..][0..p.bytes],
        .add => self.add.items[p.off..][0..p.bytes],
    };
}

/// Byte offset of rune `rune_off` within `p` (ASCII/all-single-byte fast path
/// when `runes == bytes`; otherwise walk the span).
fn byteOffsetInPiece(self: *const Buffer, p: Piece, rune_off: usize) usize {
    if (rune_off == 0) return 0;
    if (p.runes == p.bytes) return rune_off;
    const bytes = self.pieceBytes(p);
    var i: usize = 0;
    var r: usize = 0;
    while (r < rune_off) : (r += 1) i += runeStep(bytes, i).step;
    return i;
}

/// A new piece over the first `keep_runes` runes of `p` (same backing/off).
fn leftPart(self: *const Buffer, p: Piece, keep_runes: usize) Piece {
    const boff = self.byteOffsetInPiece(p, keep_runes);
    const sc = scanCounts(self.pieceBytes(p)[0..boff]);
    return .{ .src = p.src, .off = p.off, .bytes = boff, .runes = sc.runes, .newlines = sc.newlines, .clean = sc.clean };
}

/// A new piece over `p` with its first `drop_runes` runes removed.
fn rightPart(self: *const Buffer, p: Piece, drop_runes: usize) Piece {
    const boff = self.byteOffsetInPiece(p, drop_runes);
    const sc = scanCounts(self.pieceBytes(p)[boff..]);
    return .{ .src = p.src, .off = p.off + boff, .bytes = p.bytes - boff, .runes = sc.runes, .newlines = sc.newlines, .clean = sc.clean };
}

/// Length and validity of the rune starting at `bytes[i]`. An invalid lead,
/// truncated sequence, or bad encoding is one rune of one byte (U+FFFD at read).
fn runeStep(bytes: []const u8, i: usize) RuneStep {
    const seqlen = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return .{ .step = 1, .valid = false };
    if (i + seqlen > bytes.len) return .{ .step = 1, .valid = false };
    _ = std.unicode.utf8Decode(bytes[i..][0..seqlen]) catch return .{ .step = 1, .valid = false };
    return .{ .step = seqlen, .valid = true };
}

/// The one shared count walk (Ruling A / split recompute): runes, newlines, and
/// whether every byte decoded cleanly.
fn scanCounts(bytes: []const u8) Scan {
    var runes: usize = 0;
    var newlines: usize = 0;
    var clean = true;
    var i: usize = 0;
    while (i < bytes.len) {
        const rs = runeStep(bytes, i);
        runes += 1;
        if (!rs.valid) clean = false else if (bytes[i] == '\n') newlines += 1;
        i += rs.step;
    }
    return .{ .runes = runes, .newlines = newlines, .clean = clean };
}

// --- tests ---------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

/// Naive []u8 reference model: text kept as valid UTF-8 bytes, rune math via
/// std.unicode. Used to cross-check the piece table.
const TestRef = struct {
    text: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestRef, alloc: std.mem.Allocator) void {
        self.text.deinit(alloc);
    }

    fn byteOff(bytes: []const u8, rune_pos: usize) usize {
        var i: usize = 0;
        var r: usize = 0;
        while (r < rune_pos) : (r += 1) i += std.unicode.utf8ByteSequenceLength(bytes[i]) catch unreachable;
        return i;
    }

    fn insert(self: *TestRef, alloc: std.mem.Allocator, rune_pos: usize, bytes: []const u8) !void {
        const boff = byteOff(self.text.items, rune_pos);
        try self.text.insertSlice(alloc, boff, bytes);
    }

    fn delete(self: *TestRef, alloc: std.mem.Allocator, rune_pos: usize, nrunes: usize) !void {
        const b0 = byteOff(self.text.items, rune_pos);
        const b1 = byteOff(self.text.items, rune_pos + nrunes);
        try self.text.replaceRange(alloc, b0, b1 - b0, &.{});
    }

    fn runeCount(self: *const TestRef) usize {
        return std.unicode.utf8CountCodepoints(self.text.items) catch unreachable;
    }

    fn lineCount(self: *const TestRef) usize {
        return std.mem.count(u8, self.text.items, "\n") + 1;
    }

    fn runeAt(self: *const TestRef, pos: usize) u21 {
        const boff = byteOff(self.text.items, pos);
        const l = std.unicode.utf8ByteSequenceLength(self.text.items[boff]) catch unreachable;
        return std.unicode.utf8Decode(self.text.items[boff..][0..l]) catch unreachable;
    }
};

fn expectMatch(buf: *const Buffer, ref: *const TestRef) !void {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try buf.writeRaw(&aw.writer);
    try std.testing.expectEqualStrings(ref.text.items, aw.writer.buffered());
    try std.testing.expectEqual(ref.runeCount(), buf.len());
    try std.testing.expectEqual(ref.lineCount(), buf.lineCount());
    try std.testing.expectEqual(ref.text.items.len, buf.rawByteLen());
    const n = buf.len();
    if (n > 0) {
        const spots = [_]usize{ 0, n / 3, (2 * n) / 3, n - 1 };
        for (spots) |p| try std.testing.expectEqual(ref.runeAt(p), buf.runeAt(p));
    }
}

fn readAll(buf: *const Buffer, alloc: std.mem.Allocator) ![]u8 {
    const dest = try alloc.alloc(u8, Buffer.max_bytes_per_rune * buf.len() + 4);
    defer alloc.free(dest);
    const got = buf.read(0, buf.len(), dest);
    return alloc.dupe(u8, got);
}

test "buffer: empty init — len 0, lineCount 1, rawByteLen 0" {
    var buf = Buffer.initEmpty(std.testing.allocator);
    defer buf.deinit();
    try std.testing.expectEqual(@as(usize, 0), buf.len());
    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
    try std.testing.expectEqual(@as(usize, 0), buf.rawByteLen());
    var dest: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), buf.read(0, 0, &dest).len);
}

test "buffer: insert at 0, middle, end" {
    const alloc = std.testing.allocator;
    var buf = Buffer.initEmpty(alloc);
    defer buf.deinit();
    try buf.insert(0, "world"); // "world"
    try buf.insert(0, "hello "); // "hello world"
    try buf.insert(buf.len(), "!"); // "hello world!"
    try buf.insert(5, ","); // "hello, world!"
    const got = try readAll(&buf, alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("hello, world!", got);
    try std.testing.expectEqual(@as(usize, 13), buf.len());
}

test "buffer: delete spanning piece boundaries" {
    const alloc = std.testing.allocator;
    var buf = Buffer.initEmpty(alloc);
    defer buf.deinit();
    // Build several pieces via separate inserts, then delete across them.
    try buf.insert(0, "AAA");
    try buf.insert(3, "BBB");
    try buf.insert(6, "CCC");
    try buf.insert(3, "xyz"); // "AAAxyzBBBCCC"
    try std.testing.expectEqual(@as(usize, 12), buf.len());
    // Delete runes [2,9): removes "AxyzBBB", leaving "AA" + "CCC" = "AACCC".
    try buf.delete(2, 7);
    const got = try readAll(&buf, alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("AACCC", got);
}

test "buffer: rune vs byte addressing with multibyte runes" {
    const alloc = std.testing.allocator;
    // "é€𝄞" = 2 + 3 + 4 = 9 bytes, 3 runes.
    var buf = try Buffer.initFromBytes(alloc, "é€𝄞");
    defer buf.deinit();
    try std.testing.expectEqual(@as(usize, 3), buf.len());
    try std.testing.expectEqual(@as(usize, 9), buf.rawByteLen());
    try std.testing.expectEqual(@as(u21, 0x00E9), buf.runeAt(0));
    try std.testing.expectEqual(@as(u21, 0x20AC), buf.runeAt(1));
    try std.testing.expectEqual(@as(u21, 0x1D11E), buf.runeAt(2));
    // Insert an ASCII rune between rune 1 and 2 (mid multibyte-piece split).
    try buf.insert(2, "x");
    try std.testing.expectEqual(@as(u21, 'x'), buf.runeAt(2));
    try std.testing.expectEqual(@as(u21, 0x1D11E), buf.runeAt(3));
    // Read a rune sub-range and confirm exact bytes.
    var dest: [16]u8 = undefined;
    try std.testing.expectEqualStrings("€x", buf.read(1, 2, &dest));
}

test "buffer: invalid UTF-8 decodes as U+FFFD, writeRaw preserves bytes" {
    const alloc = std.testing.allocator;
    // 0xFF and 0xFE are invalid lead bytes; NUL is valid and kept.
    const raw = "a\xFF\x00\xFEb";
    var buf = try Buffer.initFromBytes(alloc, raw);
    defer buf.deinit();
    // 5 runes: 'a', <bad>, NUL, <bad>, 'b'. Two invalid bytes.
    try std.testing.expectEqual(@as(usize, 5), buf.len());
    try std.testing.expectEqual(@as(usize, 5), buf.rawByteLen());
    try std.testing.expectEqual(@as(usize, 2), buf.invalid_bytes);
    try std.testing.expectEqual(@as(u21, 'a'), buf.runeAt(0));
    try std.testing.expectEqual(@as(u21, 0xFFFD), buf.runeAt(1));
    try std.testing.expectEqual(@as(u21, 0x0000), buf.runeAt(2));
    try std.testing.expectEqual(@as(u21, 0xFFFD), buf.runeAt(3));
    try std.testing.expectEqual(@as(u21, 'b'), buf.runeAt(4));
    // read substitutes U+FFFD (3 bytes each) for the bad bytes.
    var dest: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a\u{FFFD}\x00\u{FFFD}b", buf.read(0, 5, &dest));
    // writeRaw reproduces the stored bytes byte-identically.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try buf.writeRaw(&aw.writer);
    try std.testing.expectEqualStrings(raw, aw.writer.buffered());
}

test "buffer: edits beside invalid bytes preserve untouched raw bytes" {
    const alloc = std.testing.allocator;
    const raw = "\xFF\xFEXY"; // bad, bad, 'X', 'Y' — 4 runes
    var buf = try Buffer.initFromBytes(alloc, raw);
    defer buf.deinit();
    // Insert between the two bad bytes and rune 'X' (splits the original piece);
    // the halves keep their backing, so raw bytes survive around the edit.
    try buf.insert(2, "hello"); // <bad><bad>helloXY
    try buf.delete(7, 1); // delete 'X' -> <bad><bad>helloY
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try buf.writeRaw(&aw.writer);
    try std.testing.expectEqualStrings("\xFF\xFEhelloY", aw.writer.buffered());
    try std.testing.expectEqual(@as(u21, 0xFFFD), buf.runeAt(0));
    try std.testing.expectEqual(@as(u21, 0xFFFD), buf.runeAt(1));
    try std.testing.expectEqual(@as(u21, 'h'), buf.runeAt(2));
}

test "buffer: 256 KiB load splits pieces and round-trips" {
    const alloc = std.testing.allocator;
    const total = 256 << 10;
    const src = try alloc.alloc(u8, total);
    defer alloc.free(src);
    // A repeating ASCII pattern with periodic newlines (all valid UTF-8).
    for (src, 0..) |*b, i| b.* = if (i % 64 == 63) '\n' else @as(u8, 'a' + @as(u8, @intCast(i % 26)));
    var buf = try Buffer.initFromBytes(alloc, src);
    defer buf.deinit();
    // 64 KiB piece cap ⇒ at least 4 pieces for 256 KiB.
    try std.testing.expect(buf.index.pieceCount() >= 4);
    try std.testing.expectEqual(@as(usize, total), buf.len());
    try std.testing.expectEqual(@as(usize, total), buf.rawByteLen());
    const got = try readAll(&buf, alloc);
    defer alloc.free(got);
    try std.testing.expectEqualSlices(u8, src, got);
    // An edit near a 64 KiB boundary still round-trips.
    try buf.insert((64 << 10) - 1, "ZZZ");
    try std.testing.expectEqual(@as(usize, total + 3), buf.len());
}

test "buffer: line index correct across edits" {
    const alloc = std.testing.allocator;
    var buf = try Buffer.initFromBytes(alloc, "one\ntwo\nthree");
    defer buf.deinit();
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqual(@as(usize, 0), buf.runeOfLine(0));
    try std.testing.expectEqual(@as(usize, 4), buf.runeOfLine(1)); // after "one\n"
    try std.testing.expectEqual(@as(usize, 8), buf.runeOfLine(2)); // after "two\n"
    // Insert a newline inside line 0.
    try buf.insert(1, "X\nY"); // "oX\nYne\ntwo\nthree"
    try std.testing.expectEqual(@as(usize, 4), buf.lineCount());
    try std.testing.expectEqual(@as(usize, 3), buf.runeOfLine(1)); // after "oX\n"
    // Delete the first newline: joins line 0 and 1.
    try buf.delete(2, 1); // "oXYne\ntwo\nthree"
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqual(@as(usize, 6), buf.runeOfLine(1));
}

test "buffer: lineOfRune/runeOfLine are consistent inverses" {
    const alloc = std.testing.allocator;
    var buf = try Buffer.initFromBytes(alloc, "aa\nbbb\n\ncc\nd");
    defer buf.deinit();
    // runeOfLine then lineOfRune round-trips for every line.
    var l: usize = 0;
    while (l < buf.lineCount()) : (l += 1) {
        const r = buf.runeOfLine(l);
        try std.testing.expectEqual(l, buf.lineOfRune(r));
    }
    // lineOfRune is monotonic and matches a manual newline scan.
    var p: usize = 0;
    while (p <= buf.len()) : (p += 1) {
        var expect_line: usize = 0;
        var q: usize = 0;
        while (q < p) : (q += 1) {
            if (buf.runeAt(q) == '\n') expect_line += 1;
        }
        try std.testing.expectEqual(expect_line, buf.lineOfRune(p));
    }
}

test "buffer: scripted 100-op storm matches []u8 reference" {
    const alloc = std.testing.allocator;
    var buf = Buffer.initEmpty(alloc);
    defer buf.deinit();
    var ref = TestRef{};
    defer ref.deinit(alloc);

    const fragments = [_][]const u8{ "abc", "\n", "é", "€𝄞", "x\ny", "  ", "Z" };
    var op: usize = 0;
    while (op < 100) : (op += 1) {
        const n = buf.len();
        // Deterministic schedule: every 3rd op (once there is text) deletes.
        if (n > 3 and op % 3 == 0) {
            const pos = (op * 7) % (n - 1);
            const cnt = 1 + (op % 3);
            const del = @min(cnt, n - pos);
            try buf.delete(pos, del);
            try ref.delete(alloc, pos, del);
        } else {
            const frag = fragments[op % fragments.len];
            const pos = if (n == 0) 0 else (op * 5) % (n + 1);
            try buf.insert(pos, frag);
            try ref.insert(alloc, pos, frag);
        }
        try expectMatch(&buf, &ref);
    }
}

test "buffer: randomized ops match reference model (seed 0x5eed)" {
    const alloc = std.testing.allocator;
    var buf = Buffer.initEmpty(alloc);
    defer buf.deinit();
    var ref = TestRef{};
    defer ref.deinit(alloc);

    // Palette of 1-, 2-, 3- and 4-byte runes plus a newline for line math.
    const palette = [_]u21{ 'a', 'b', '\n', 0x00E9, 0x20AC, 0x1D11E };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();

    var op: usize = 0;
    while (op < 1200) : (op += 1) {
        const n = buf.len();
        if (n > 0 and rand.boolean() and rand.boolean()) {
            // Delete a random run (~1/4 of ops once non-empty).
            const pos = rand.intRangeLessThan(usize, 0, n);
            const max_del = n - pos;
            const cnt = rand.intRangeAtMost(usize, 1, @min(max_del, 6));
            try buf.delete(pos, cnt);
            try ref.delete(alloc, pos, cnt);
        } else {
            // Insert a random 1..6-rune valid-UTF-8 fragment.
            var frag: [6 * 4]u8 = undefined;
            var flen: usize = 0;
            const runes = rand.intRangeAtMost(usize, 1, 6);
            var k: usize = 0;
            while (k < runes) : (k += 1) {
                const cp = palette[rand.intRangeLessThan(usize, 0, palette.len)];
                flen += std.unicode.utf8Encode(cp, frag[flen..]) catch unreachable;
            }
            const pos = rand.intRangeAtMost(usize, 0, n);
            try buf.insert(pos, frag[0..flen]);
            try ref.insert(alloc, pos, frag[0..flen]);
        }
        try expectMatch(&buf, &ref);
    }
    // Confirm the storm produced a non-trivial buffer.
    try std.testing.expect(buf.len() > 0);
}
