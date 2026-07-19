//! A `Buffer` plus ACME's undo/redo machinery: a faithful port of acme's
//! `file.c` scheme onto tagged-union deltas. file-as-struct (P-1): this file
//! *is* the File.
//!
//! Undo model (acme/file.c:15-38, 74-311): every recording edit pushes a delta
//! onto the `delta` (undo) stack carrying the seq at the time and the previous
//! value of the modify bit. `undo` reverses every record of the top seq as a
//! single transaction, pushing the inverse of each onto `epsilon` (the redo
//! stack) with that same seq; `redo` is the mirror. `seq == 0` is transparent —
//! edits record nothing (file.c:79,105), exactly like editing the Buffer raw.
//! One `mark` per user action stamps the seq and discards the redo stack
//! (file.c:305-311). The stored `mod_before` is what survives a Put: undoing
//! past a save restores the modify bit the buffer had at each edit (file.c:93,
//! 117,233,244). Put-seq bookkeeping itself is deferred (R-P4-7); mod is set/
//! cleared here and restored on undo/redo.
//!
//! Delta variant names describe the ORIGINAL operation recorded (not the
//! reverse action): `.insert` (nrunes, no text) reverses by deleting; `.delete`
//! (owned decoded text) reverses by inserting. This is the same information as
//! file.c's Delete/Insert Undo records, just named by cause rather than effect.
//!
//! Invalid UTF-8 (R-P4-2): the Buffer stores loaded bytes verbatim but decodes
//! invalid bytes to U+FFFD at read time. A delete captures the *decoded* text
//! (via buffer.read), so undoing a region that straddled invalid bytes
//! re-inserts decoded U+FFFD bytes — matching acme's rune-granular deltas
//! (file.c:126-134). Untouched pieces keep their raw bytes by construction.
//!
//! OOM mid-unwind (semantic 7): if an allocation fails partway through
//! `undo`/`redo`, the stacks may be left partially unwound. This is treated as
//! fatal — callers are not expected to recover editor state from it.
const std = @import("std");
const Buffer = @import("Buffer.zig");

const File = @This();

pub const Range = struct { q0: usize, q1: usize };

pub const Delta = union(enum) {
    /// An insert of `nrunes` runes at `p0` was recorded; reverse by deleting.
    insert: struct { seq: u32, mod_before: bool, p0: usize, nrunes: usize },
    /// A delete at `p0` was recorded (owned decoded UTF-8); reverse by inserting.
    delete: struct { seq: u32, mod_before: bool, p0: usize, text: []u8 },

    fn seqOf(self: Delta) u32 {
        return switch (self) {
            inline else => |x| x.seq,
        };
    }
};

allocator: std.mem.Allocator,
/// The text. Read-only access is fine directly (`file.buffer`); all mutation
/// that must be undoable goes through File.insert/File.delete.
buffer: Buffer,
delta: std.ArrayList(Delta) = .empty, // undo stack
epsilon: std.ArrayList(Delta) = .empty, // redo stack
seq: u32 = 0, // 0 ⇒ transparent (records nothing)
mod: bool = false,

pub fn init(allocator: std.mem.Allocator, buffer: Buffer) File {
    return .{ .allocator = allocator, .buffer = buffer };
}

pub fn deinit(self: *File) void {
    self.freeTexts(&self.delta);
    self.delta.deinit(self.allocator);
    self.freeTexts(&self.epsilon);
    self.epsilon.deinit(self.allocator);
    self.buffer.deinit();
    self.* = undefined;
}

/// Free the owned text of every `.delete` record in `stack` (leaves it intact).
fn freeTexts(self: *File, stack: *std.ArrayList(Delta)) void {
    for (stack.items) |d| switch (d) {
        .delete => |x| self.allocator.free(x.text),
        .insert => {},
    };
}

fn discard(self: *File, stack: *std.ArrayList(Delta)) void {
    self.freeTexts(stack);
    stack.clearRetainingCapacity();
}

/// Stamp the sequence number for the coming transaction and drop the redo
/// stack (file.c:305-311). One mark per user action per file.
pub fn mark(self: *File, seq: u32) void {
    std.debug.assert(seq > 0);
    std.debug.assert(seq >= self.seq);
    self.discard(&self.epsilon);
    self.seq = seq;
}

/// Insert valid UTF-8 `bytes` at rune offset `p0` (file.c:74). Records the
/// inverse when seq > 0; sets mod when anything was inserted.
pub fn insert(self: *File, p0: usize, bytes: []const u8) error{OutOfMemory}!void {
    if (self.seq > 0) {
        const nrunes = std.unicode.utf8CountCodepoints(bytes) catch unreachable;
        // Reserve first so the record append cannot fail after the buffer edit.
        try self.delta.ensureUnusedCapacity(self.allocator, 1);
        try self.buffer.insert(p0, bytes);
        self.delta.appendAssumeCapacity(.{ .insert = .{
            .seq = self.seq,
            .mod_before = self.mod,
            .p0 = p0,
            .nrunes = nrunes,
        } });
    } else {
        try self.buffer.insert(p0, bytes);
    }
    if (bytes.len != 0) self.mod = true; // file.c:82-83 (ns > 0)
}

/// Delete `nrunes` runes at rune offset `p0` (file.c:100). Captures the doomed
/// (decoded) text BEFORE deleting so undo can restore it.
pub fn delete(self: *File, p0: usize, nrunes: usize) error{OutOfMemory}!void {
    if (self.seq > 0) {
        const text = try self.captureText(p0, nrunes); // read before delete
        errdefer self.allocator.free(text);
        try self.delta.ensureUnusedCapacity(self.allocator, 1);
        try self.buffer.delete(p0, nrunes);
        self.delta.appendAssumeCapacity(.{ .delete = .{
            .seq = self.seq,
            .mod_before = self.mod,
            .p0 = p0,
            .text = text,
        } });
    } else {
        try self.buffer.delete(p0, nrunes);
    }
    if (nrunes != 0) self.mod = true; // file.c:108-109 (p1 > p0)
}

/// Allocate and return the decoded UTF-8 of `[p0, p0+nrunes)`.
fn captureText(self: *File, p0: usize, nrunes: usize) error{OutOfMemory}![]u8 {
    const cap = nrunes * Buffer.max_bytes_per_rune;
    const dest = try self.allocator.alloc(u8, cap);
    errdefer self.allocator.free(dest);
    const filled = self.buffer.read(p0, nrunes, dest);
    if (filled.len == cap) return dest;
    return self.allocator.realloc(dest, filled.len);
}

/// Undo one transaction: reverse every top-seq delta onto epsilon, seq
/// decreasing (file.c:188-276). Returns the Range of the last inversion, or
/// null if the undo stack was empty.
pub fn undo(self: *File) error{OutOfMemory}!?Range {
    return self.unwind(&self.delta, &self.epsilon, true);
}

/// Redo one transaction: the mirror of undo (file.c:202-207,275-276).
pub fn redo(self: *File) error{OutOfMemory}!?Range {
    return self.unwind(&self.epsilon, &self.delta, false);
}

/// Shared engine for undo (isundo=true) and redo (isundo=false). Pops records
/// off `src`, applies each reverse to the buffer, and pushes the inverse onto
/// `dst` with the record's own seq. Inversions run newest-first.
fn unwind(
    self: *File,
    src: *std.ArrayList(Delta),
    dst: *std.ArrayList(Delta),
    isundo: bool,
) error{OutOfMemory}!?Range {
    var result: ?Range = null;
    var stop: u32 = if (isundo) self.seq else 0; // redo: not known until first record
    var have_stop = isundo;

    while (src.items.len > 0) {
        const top = src.items[src.items.len - 1];
        const useq = top.seqOf();
        if (isundo) {
            if (useq < stop) { // older transaction — leave it for the next undo
                self.seq = useq;
                return result;
            }
        } else {
            if (!have_stop) {
                stop = useq;
                have_stop = true;
            }
            if (useq > stop) return result; // newer transaction — stop redo here
        }

        const rec = src.pop().?;
        switch (rec) {
            .insert => |r| {
                // Original was an insert: reverse by deleting r.nrunes at r.p0.
                self.seq = r.seq;
                const text = try self.captureText(r.p0, r.nrunes);
                {
                    errdefer self.allocator.free(text);
                    try dst.append(self.allocator, .{ .delete = .{
                        .seq = r.seq,
                        .mod_before = self.mod,
                        .p0 = r.p0,
                        .text = text,
                    } });
                }
                self.mod = r.mod_before; // file.c:233 / :244
                try self.buffer.delete(r.p0, r.nrunes);
                result = .{ .q0 = r.p0, .q1 = r.p0 };
            },
            .delete => |r| {
                // Original was a delete: reverse by inserting the saved text.
                self.seq = r.seq;
                const nrunes = std.unicode.utf8CountCodepoints(r.text) catch unreachable;
                try dst.append(self.allocator, .{ .insert = .{
                    .seq = r.seq,
                    .mod_before = self.mod,
                    .p0 = r.p0,
                    .nrunes = nrunes,
                } });
                self.mod = r.mod_before;
                try self.buffer.insert(r.p0, r.text);
                self.allocator.free(r.text); // consumed off the src stack
                result = .{ .q0 = r.p0, .q1 = r.p0 + nrunes };
            },
        }
    }
    if (isundo) self.seq = 0; // drained the whole undo stack (file.c:275-276)
    return result;
}

/// Seq of the transaction a call to `undo` would reverse (0 if none).
pub fn undoSeq(self: *const File) u32 {
    if (self.delta.items.len == 0) return 0;
    return self.delta.items[self.delta.items.len - 1].seqOf();
}

/// Seq of the transaction a call to `redo` would reapply (0 if none) — the
/// port of fileredoseq (file.c:176).
pub fn redoSeq(self: *const File) u32 {
    if (self.epsilon.items.len == 0) return 0;
    return self.epsilon.items[self.epsilon.items.len - 1].seqOf();
}

/// Drop both stacks and reset seq to 0, keeping the text and the mod flag
/// (file.c:281-287).
pub fn reset(self: *File) void {
    self.discard(&self.delta);
    self.discard(&self.epsilon);
    self.seq = 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

/// Read the whole buffer as decoded UTF-8 (caller frees).
fn dumpText(f: *const File, a: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const n = f.buffer.len();
    if (n == 0) return a.alloc(u8, 0);
    const dest = try a.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer a.free(dest);
    return a.dupe(u8, f.buffer.read(0, n, dest));
}

fn expectText(f: *const File, expected: []const u8) !void {
    const got = try dumpText(f, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, expected, got);
}

test "file: unmarked edits record nothing (acts like Buffer)" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    // seq stays 0: no marks.
    try f.insert(0, "abc");
    try f.delete(0, 1); // -> "bc"

    try expectText(&f, "bc");
    try testing.expectEqual(@as(usize, 0), f.delta.items.len);
    try testing.expectEqual(@as(usize, 0), f.epsilon.items.len);
    try testing.expectEqual(@as(u32, 0), f.undoSeq());
    try testing.expectEqual(@as(u32, 0), f.redoSeq());
    // Undo is a no-op when nothing was recorded.
    try testing.expectEqual(@as(?Range, null), try f.undo());
    try expectText(&f, "bc");
}

test "file: single-op undo restores text, seq, and mod" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    f.mark(1);
    try f.insert(0, "hi");
    try expectText(&f, "hi");
    try testing.expect(f.mod);
    try testing.expectEqual(@as(u32, 1), f.seq);

    const r = try f.undo();
    try expectText(&f, "");
    try testing.expect(!f.mod); // mod_before was false
    try testing.expectEqual(@as(u32, 0), f.seq);
    try testing.expectEqual(Range{ .q0 = 0, .q1 = 0 }, r.?);
}

test "file: grouped transaction undoes as one unit" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    // One mark, three inserts — all share seq 1, so they form one transaction.
    f.mark(1);
    try f.insert(0, "a");
    try f.insert(1, "b");
    try f.insert(2, "c");
    try expectText(&f, "abc");

    const r = try f.undo();
    try expectText(&f, "");
    // Last inversion processed is the oldest record (insert "a" at 0).
    try testing.expectEqual(Range{ .q0 = 0, .q1 = 0 }, r.?);
    // Nothing left on the undo stack.
    try testing.expectEqual(@as(?Range, null), try f.undo());
}

test "file: undo then redo round-trips text and mod" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    f.mark(1);
    try f.insert(0, "data");
    try testing.expect(f.mod);

    _ = try f.undo();
    try expectText(&f, "");
    try testing.expect(!f.mod);
    try testing.expectEqual(@as(u32, 0), f.seq);

    const r = try f.redo();
    try expectText(&f, "data");
    try testing.expect(f.mod);
    try testing.expectEqual(@as(u32, 1), f.seq);
    try testing.expectEqual(Range{ .q0 = 0, .q1 = 4 }, r.?);
}

test "file: undo across many transactions in order" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    f.mark(1);
    try f.insert(0, "A");
    f.mark(2);
    try f.insert(1, "B");
    f.mark(3);
    try f.insert(2, "C");
    try expectText(&f, "ABC");

    _ = try f.undo();
    try expectText(&f, "AB");
    _ = try f.undo();
    try expectText(&f, "A");
    _ = try f.undo();
    try expectText(&f, "");
    try testing.expectEqual(@as(?Range, null), try f.undo());
}

test "file: new mark invalidates redo" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    f.mark(1);
    try f.insert(0, "x");
    f.mark(2);
    try f.insert(1, "y");
    try expectText(&f, "xy");

    _ = try f.undo();
    try expectText(&f, "x");
    try testing.expectEqual(@as(u32, 2), f.redoSeq()); // redo pending

    // A fresh action marks a new seq and must discard the redo stack.
    f.mark(3);
    try f.insert(1, "z");
    try expectText(&f, "xz");
    try testing.expectEqual(@as(u32, 0), f.redoSeq());
    try testing.expectEqual(@as(?Range, null), try f.redo());
    try expectText(&f, "xz");
}

test "file: mod flag transitions across edit/undo/redo" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    try testing.expect(!f.mod);

    f.mark(1);
    try f.insert(0, "hello");
    try testing.expect(f.mod);

    // Simulate a Put: the buffer is now saved, so it is no longer modified.
    // (Put-seq bookkeeping is deferred, R-P4-7 — we only clear the bit.)
    f.mod = false;

    f.mark(2);
    try f.insert(5, " world");
    try testing.expect(f.mod);

    // Undo back to the saved state: mod_before recorded post-Put was false.
    _ = try f.undo();
    try expectText(&f, "hello");
    try testing.expect(!f.mod); // the saved state reads as unmodified

    // Redo re-dirties: the epsilon record captured mod=true at undo time.
    _ = try f.redo();
    try expectText(&f, "hello world");
    try testing.expect(f.mod);

    // Undo the whole way out: earliest record's mod_before was false.
    _ = try f.undo();
    _ = try f.undo();
    try expectText(&f, "");
    try testing.expect(!f.mod);
}

test "file: undoSeq/redoSeq report pending transactions" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    try testing.expectEqual(@as(u32, 0), f.undoSeq());
    try testing.expectEqual(@as(u32, 0), f.redoSeq());

    f.mark(5);
    try f.insert(0, "aa");
    try testing.expectEqual(@as(u32, 5), f.undoSeq());
    try testing.expectEqual(@as(u32, 0), f.redoSeq());

    f.mark(9);
    try f.insert(2, "bb");
    try testing.expectEqual(@as(u32, 9), f.undoSeq());

    _ = try f.undo();
    try testing.expectEqual(@as(u32, 5), f.undoSeq());
    try testing.expectEqual(@as(u32, 9), f.redoSeq());

    _ = try f.undo();
    try testing.expectEqual(@as(u32, 0), f.undoSeq());
    try testing.expectEqual(@as(u32, 5), f.redoSeq());
}

test "file: reset clears stacks and seq, keeps text and mod" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    f.mark(1);
    try f.insert(0, "hello");
    f.mark(2);
    try f.insert(5, " x");
    _ = try f.undo(); // populate epsilon too

    const text_before = try dumpText(&f, a);
    defer a.free(text_before);
    const mod_before = f.mod;

    f.reset();

    try testing.expectEqual(@as(usize, 0), f.delta.items.len);
    try testing.expectEqual(@as(usize, 0), f.epsilon.items.len);
    try testing.expectEqual(@as(u32, 0), f.seq);
    try expectText(&f, text_before); // text preserved
    try testing.expectEqual(mod_before, f.mod); // mod preserved
    try testing.expectEqual(@as(?Range, null), try f.undo());
}

test "file: randomized edit/undo/redo storm matches snapshots (seed 0xf11e)" {
    const a = testing.allocator;
    var f = File.init(a, Buffer.initEmpty(a));
    defer f.deinit();

    // snaps[k] = the exact buffer text after k committed transactions along the
    // current branch; `cur` indexes the live one. A new transaction truncates
    // any forward snapshots (mark invalidates redo).
    var snaps: std.ArrayList([]u8) = .empty;
    defer {
        for (snaps.items) |s| a.free(s);
        snaps.deinit(a);
    }
    try snaps.append(a, try dumpText(&f, a));
    var cur: usize = 0;
    var next_seq: u32 = 1;

    var prng = std.Random.DefaultPrng.init(0xf11e);
    const rand = prng.random();

    // Mixed 1..4-byte runes plus a newline.
    const runes = [_][]const u8{ "a", "b", "\n", "\u{00e9}", "\u{20ac}", "\u{1d11e}" };

    var iter: usize = 0;
    while (iter < 500) : (iter += 1) {
        const choice = rand.intRangeLessThan(u8, 0, 3); // 0=new txn, 1=undo, 2=redo
        if (choice == 1 and cur > 0) {
            _ = try f.undo();
            cur -= 1;
            try expectText(&f, snaps.items[cur]);
        } else if (choice == 2 and cur + 1 < snaps.items.len) {
            _ = try f.redo();
            cur += 1;
            try expectText(&f, snaps.items[cur]);
        } else {
            f.mark(next_seq);
            next_seq += 1;
            const nedits = rand.intRangeAtMost(usize, 1, 3);
            var e: usize = 0;
            while (e < nedits) : (e += 1) {
                const cur_len = f.buffer.len();
                if (cur_len > 0 and rand.boolean()) {
                    const p0 = rand.intRangeLessThan(usize, 0, cur_len);
                    const nr = rand.intRangeAtMost(usize, 1, cur_len - p0);
                    try f.delete(p0, nr);
                } else {
                    var text: std.ArrayList(u8) = .empty;
                    defer text.deinit(a);
                    const nins = rand.intRangeAtMost(usize, 1, 4);
                    var k: usize = 0;
                    while (k < nins) : (k += 1) {
                        try text.appendSlice(a, runes[rand.intRangeLessThan(usize, 0, runes.len)]);
                    }
                    try f.insert(rand.intRangeAtMost(usize, 0, f.buffer.len()), text.items);
                }
            }
            // Discard forward (now-invalid) snapshots, then record this state.
            while (snaps.items.len > cur + 1) a.free(snaps.pop().?);
            try snaps.append(a, try dumpText(&f, a));
            cur = snaps.items.len - 1;
        }
    }
}
