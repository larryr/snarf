//! Elog — the buffered edit transcript (acme's `elog.c`), one per Edit
//! invocation, riding `cmd.Ctx` (R-P10-6: NOT on `File` — v1 is single-file;
//! the multi-file Edit phase moves it). file-as-struct (P-1): this file *is*
//! the Elog.
//!
//! Why buffered (elog.c:19-27): addresses in a compound command refer to the
//! file as it was BEFORE any of this Edit's changes; tracking moving text live
//! (e.g. `,x m$`) is intractable; and adjacent/nearby changes can be merged
//! (hence `Replace` besides `Insert`/`Delete`). Each entry point either extends
//! the open `pending` head or flushes it into `log` and opens a new one
//! (`eloginsert`/`elogdelete`/`elogreplace`). `apply` flushes the tail, then
//! walks `log` in REVERSE — `elogapply` reads its buffer end-backwards
//! (elog.c:257-259) — so a high-address change applies before any lower,
//! still-pending address is touched, keeping the frozen coordinate space valid.
//!
//! Divergences (flagged, contract §2.3/§2.7): the C's hard RBUFSIZE-bounded
//! chunking of an over-long insert (elog.c:176-186) and its "replacement string
//! too large" abort (elog.c:155-156) are dropped — no fixed buffers in this
//! port, so `min_string`/`max_string` are merge HEURISTICS, not hard caps. A
//! `replace` whose new `q0` lands strictly before the pending record's END
//! (overlapping addresses) skips the gap-merge arithmetic rather than
//! replicating the C's unsigned-subtraction wraparound (`uint gap`) — Zig's
//! safety-checked usize subtraction would panic instead of silently producing
//! a huge gap, so this is treated as "don't merge" instead.
//!
//! Ported from larryr/plan9port@337c6ac acme/elog.c; cite as `elog.c:NN`.
const std = @import("std");
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");
const Text = @import("../text/Text.zig");
const Editor = @import("../Editor.zig");
const ast = @import("ast.zig");

const Elog = @This();

/// dat.h:497-502 minus `Filename` (no cross-file rename records in v1). Owned
/// UTF-8 text (`.insert`/`.replace`) is freed by whichever of `term`/`apply`
/// consumes the record.
pub const Record = union(enum) {
    insert: struct { q0: usize, nr: usize, text: []u8 },
    delete: struct { q0: usize, nd: usize },
    replace: struct { q0: usize, nd: usize, nr: usize, text: []u8 },
};

/// The single open head being merged — the C's one `Buflog elog` plus its rune
/// buffer `f->elog.r` (dat.h). `nd` is runes-to-delete (delete/replace); `nr`
/// is the rune count of `text` (insert/replace, unused for delete).
const Pending = struct {
    kind: enum { insert, delete, replace },
    q0: usize,
    nd: usize = 0,
    nr: usize = 0,
    text: std.ArrayList(u8) = .empty,

    fn deinit(p: *Pending, a: std.mem.Allocator) void {
        p.text.deinit(a);
    }
};

/// Merge thresholds (elog.c:40-45): `Minstring` — gaps narrower than this get
/// bridged by re-reading the file; `Maxstring` — a merged record wider than
/// this stops merging (the C sizes it to RBUFSIZE so one `fbufalloc` never
/// needs to grow; here it is just a heuristic, see the header divergence note).
const min_string: usize = 16;
const max_string: usize = 4096;

allocator: std.mem.Allocator,
ed: *Editor,
log: std.ArrayList(Record) = .empty,
pending: ?Pending = null,
/// elog.c:17's file-static `warned`: ONE out-of-sequence warning per Elog
/// lifetime, shared by the three record-builders below AND reused (after
/// `term` resets it) by `apply`'s tail sanity check.
warned: bool = false,

pub fn init(a: std.mem.Allocator, ed: *Editor) Elog {
    return .{ .allocator = a, .ed = ed };
}

pub fn deinit(self: *Elog) void {
    self.term();
    self.log.deinit(self.allocator);
    self.* = undefined;
}

pub fn empty(e: *const Elog) bool {
    return e.pending == null and e.log.items.len == 0;
}

/// `elogterm` (elog.c:84-94): discard every buffered record (owned text freed)
/// and reset `warned`. Called on a failed Edit — edit.c:145-146: a failed Edit
/// applies NOTHING — and at the tail of `apply` itself (elog.c's own
/// `elogapply` calls `elogterm(f)` once the log is drained).
pub fn term(e: *Elog) void {
    if (e.pending) |*p| p.deinit(e.allocator);
    e.pending = null;
    for (e.log.items) |rec| switch (rec) {
        .insert => |r| e.allocator.free(r.text),
        .delete => {},
        .replace => |r| e.allocator.free(r.text),
    };
    e.log.clearRetainingCapacity();
    e.warned = false; // elog.c:93
}

fn warnOnce(e: *Elog) void {
    if (e.warned) return;
    e.warned = true;
    e.ed.warning("warning: changes out of sequence\n", .{});
}

/// `elogflush` (elog.c:96-116): move the open `pending` head into `log`,
/// handing its accumulated text over as an owned slice. A no-op when nothing
/// is pending (mirrors the C's `Null`-type no-op case).
fn flush(e: *Elog) error{OutOfMemory}!void {
    var p = e.pending orelse return;
    e.pending = null;
    switch (p.kind) {
        .insert => try e.log.append(e.allocator, .{ .insert = .{
            .q0 = p.q0,
            .nr = p.nr,
            .text = try p.text.toOwnedSlice(e.allocator),
        } }),
        .delete => try e.log.append(e.allocator, .{ .delete = .{ .q0 = p.q0, .nd = p.nd } }),
        .replace => try e.log.append(e.allocator, .{ .replace = .{
            .q0 = p.q0,
            .nd = p.nd,
            .nr = p.nr,
            .text = try p.text.toOwnedSlice(e.allocator),
        } }),
    }
}

/// `eloginsert` (elog.c:160-191). `f` is accepted to match the C's call shape
/// (and the frozen signature) but unused: v1 keeps one Elog per Ctx rather
/// than per-File lazy state, so there is no `eloginit` to run.
pub fn insert(e: *Elog, f: *File, q0: usize, text: []const u8, nr: usize) error{OutOfMemory}!void {
    _ = f;
    if (nr == 0) return; // elog.c:162-163
    if (e.pending) |p| {
        if (q0 < p.q0) { // elog.c:167-172
            e.warnOnce();
            try e.flush();
        }
    }
    if (e.pending) |*p| {
        if (p.kind == .insert and p.q0 == q0 and p.nr + nr < max_string) { // elog.c:174-177
            try p.text.appendSlice(e.allocator, text);
            p.nr += nr;
            return;
        }
    }
    try e.flush(); // elog.c:178 (the C's over-Maxstring chunk loop is dropped, see header)
    var np = Pending{ .kind = .insert, .q0 = q0, .nr = nr };
    try np.text.appendSlice(e.allocator, text);
    e.pending = np;
}

/// `elogdelete` (elog.c:193-213). The out-of-sequence check compares the new
/// `q0` against the pending record's END (`q0+nd`), unlike insert/replace which
/// compare against its START — this is the C's own asymmetry, kept faithfully.
pub fn delete(e: *Elog, f: *File, q0: usize, q1: usize) error{OutOfMemory}!void {
    _ = f;
    if (q0 == q1) return; // elog.c:194-195
    if (e.pending) |p| {
        if (q0 < p.q0 + p.nd) { // elog.c:199-203
            e.warnOnce();
            try e.flush();
        }
    }
    if (e.pending) |*p| {
        if (p.kind == .delete and p.q0 + p.nd == q0) { // elog.c:205-207
            p.nd += q1 - q0;
            return;
        }
    }
    try e.flush(); // elog.c:208
    e.pending = Pending{ .kind = .delete, .q0 = q0, .nd = q1 - q0 };
}

/// `elogreplace` (elog.c:123-158). The gap-merge reads the untouched file text
/// between the pending record's end and the new `q0` (elog.c:143 `bufread`) so
/// the merged record's text stays contiguous with what will actually survive
/// between the two edits.
pub fn replace(e: *Elog, f: *File, q0: usize, q1: usize, text: []const u8, nr: usize) error{OutOfMemory}!void {
    if (q0 == q1 and nr == 0) return; // elog.c:125-126
    if (e.pending) |p| {
        if (q0 < p.q0) { // elog.c:131-135
            e.warnOnce();
            try e.flush();
        }
    }
    if (e.pending) |*p| merge: {
        if (p.kind != .replace or q0 < p.q0 + p.nd) break :merge; // see header divergence note
        const gap = q0 - (p.q0 + p.nd);
        if (p.nr + gap + nr < max_string and gap < min_string) { // elog.c:137-141
            if (gap > 0) {
                const scratch = try e.allocator.alloc(u8, gap * Buffer.max_bytes_per_rune);
                defer e.allocator.free(scratch);
                const bytes = f.buffer.read(p.q0 + p.nd, gap, scratch); // elog.c:143
                try p.text.appendSlice(e.allocator, bytes);
                p.nr += gap;
            }
            p.nd += gap + (q1 - q0); // elog.c:146
            try p.text.appendSlice(e.allocator, text);
            p.nr += nr; // elog.c:147-148
            return;
        }
    }
    try e.flush(); // elog.c:150
    var np = Pending{ .kind = .replace, .q0 = q0, .nd = q1 - q0, .nr = nr };
    try np.text.appendSlice(e.allocator, text);
    e.pending = np;
}

/// `textconstrain` (text.c:517-521): min-clamp both ends of a record's ORIGINAL
/// address to the file's CURRENT length — records applied earlier in this same
/// reverse walk may already have changed the file size.
fn constrain(t: *Text, q0: usize, q1: usize) File.Range {
    const len = t.file.buffer.len();
    return .{ .q0 = @min(q0, len), .q1 = @min(q1, len) };
}

/// `elogapply` (elog.c:216-354): flush the tail, then apply every record in
/// REVERSE (append order, not necessarily address order — an out-of-sequence
/// warning can leave `log` non-monotonic, and reverse-of-append is still what
/// the C's end-of-buffer walk does). The first actual mutation stamps
/// `t.file.mark(e.ed.seq)` once (the caller has already bumped `ed.seq`,
/// elog.c:271-273/293-295/304-306 + exec.c:1141). Mutation goes only through
/// `Text.insertAt`/`deleteRange` with `tofile=true`. The collapsed-caret rule
/// (elog.c:284-285/317-318): `Text.insertAt`'s own q0/q1 adjustment only shifts
/// a coordinate that is STRICTLY LESS than the insertion point (text.c:395-398),
/// so a caret sitting EXACTLY at the insertion point (q0==q1==the insert
/// address) is left untouched by `insertAt` itself — the extra check here is
/// exactly the delta the C's rule adds on top: extend `t.q1` over the inserted
/// text.
pub fn apply(e: *Elog, t: *Text) ast.Error!void {
    try e.flush();
    var mod = false;

    while (e.log.pop()) |rec| { // elog.c:257-259 end-of-buffer-backwards
        switch (rec) {
            .insert => |r| {
                if (!mod) {
                    mod = true;
                    t.file.mark(e.ed.seq); // elog.c:304-306
                }
                const c = constrain(t, r.q0, r.q0);
                try t.insertAt(c.q0, r.text, true);
                if (t.q0 == c.q0 and t.q1 == c.q0) t.q1 += r.nr; // elog.c:317-318
                e.allocator.free(r.text);
            },
            .delete => |r| {
                if (!mod) {
                    mod = true;
                    t.file.mark(e.ed.seq); // elog.c:293-295
                }
                const c = constrain(t, r.q0, r.q0 + r.nd);
                try t.deleteRange(c.q0, c.q1, true);
            },
            .replace => |r| {
                if (!mod) {
                    mod = true;
                    t.file.mark(e.ed.seq); // elog.c:271-273
                }
                const c = constrain(t, r.q0, r.q0 + r.nd);
                try t.deleteRange(c.q0, c.q1, true);
                try t.insertAt(c.q0, r.text, true);
                if (t.q0 == c.q0 and t.q1 == c.q0) t.q1 += r.nr; // elog.c:284-285
                e.allocator.free(r.text);
            },
        }
    }

    // elog.c's tail `elogterm(f)`: resets `warned` to false BEFORE the sanity
    // check just below — so (faithfully) that check's `!warned` guard is
    // unconditionally true. Kept bug-for-bug per the citation policy.
    e.term();

    const len = t.file.buffer.len();
    if (t.q0 > len or t.q1 > len or t.q0 > t.q1) { // elog.c:345-350
        if (!e.warned) e.ed.warning("elogapply: can't happen {d} {d} {d}\n", .{ t.q0, t.q1, len });
        t.q1 = @min(t.q1, len);
        t.q0 = @min(t.q0, t.q1);
    }
}

// ===========================================================================
// Tests (side contract §3, direct-call halves of tests 30/34). A minimal
// Frame.TestFixture + File + Text harness, matching look.zig/Text.zig's style.
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;

const rect = proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

const H = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,
    ed: Editor,
    elog: Elog,

    fn init(seed: []const u8) !*H {
        const a = testing.allocator;
        const h = try a.create(H);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.text = try Text.init(&h.file, a, rect, h.fx.font, &h.fx.disp.image, h.fx.cols());
        h.ed = Editor.init(a);
        h.elog = Elog.init(a, &h.ed);
        return h;
    }
    fn deinit(h: *H) void {
        h.elog.deinit();
        h.ed.deinit();
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn bufText(h: *H) ![]u8 {
        const n = h.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, h.file.buffer.read(0, n, dest));
    }
    fn expectText(h: *H, want: []const u8) !void {
        const got = try h.bufText();
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
};

test "elog: insert merges at same q0" {
    const h = try H.init("abcdef");
    defer h.deinit();

    try h.elog.insert(&h.file, 3, "X", 1);
    try h.elog.insert(&h.file, 3, "Y", 1);

    try testing.expectEqual(@as(usize, 0), h.elog.log.items.len);
    const p = h.elog.pending.?;
    try testing.expect(p.kind == .insert);
    try testing.expectEqual(@as(usize, 3), p.q0);
    try testing.expectEqual(@as(usize, 2), p.nr);
    try testing.expectEqualStrings("XY", p.text.items);
}

test "elog: delete merges contiguous" {
    const h = try H.init("abcdef");
    defer h.deinit();

    try h.elog.delete(&h.file, 2, 4);
    try h.elog.delete(&h.file, 4, 6);

    try testing.expectEqual(@as(usize, 0), h.elog.log.items.len);
    const p = h.elog.pending.?;
    try testing.expect(p.kind == .delete);
    try testing.expectEqual(@as(usize, 2), p.q0);
    try testing.expectEqual(@as(usize, 4), p.nd);
}

test "elog: replace gap merge" {
    // 30 digits/letters: enough room for a gap-read well past both edits.
    const h = try H.init("0123456789ABCDEFGHIJKLMNOPQRST");
    defer h.deinit();

    // Gap 5 apart (< Minstring=16): merges, gap text "23456" read from the file.
    try h.elog.replace(&h.file, 0, 2, "AA", 2);
    try h.elog.replace(&h.file, 7, 9, "BB", 2);
    try testing.expectEqual(@as(usize, 0), h.elog.log.items.len);
    const p = h.elog.pending.?;
    try testing.expect(p.kind == .replace);
    try testing.expectEqual(@as(usize, 0), p.q0);
    try testing.expectEqual(@as(usize, 9), p.nd); // 2 deleted + 5 gap + 2 deleted
    try testing.expectEqual(@as(usize, 9), p.nr); // "AA" + "23456" + "BB"
    try testing.expectEqualStrings("AA23456BB", p.text.items);

    // A second pair 20 apart (>= Minstring): does NOT merge -> two records.
    const h2 = try H.init("0123456789ABCDEFGHIJKLMNOPQRST");
    defer h2.deinit();
    try h2.elog.replace(&h2.file, 0, 2, "AA", 2);
    try h2.elog.replace(&h2.file, 22, 24, "BB", 2);
    try testing.expectEqual(@as(usize, 1), h2.elog.log.items.len); // first flushed
    const q = h2.elog.pending.?;
    try testing.expectEqual(@as(usize, 22), q.q0);
}

test "elog: out of sequence warns once and proceeds" {
    const h = try H.init("abcdefghijklmnop");
    defer h.deinit();

    try h.elog.insert(&h.file, 10, "A", 1); // opens pending at 10
    try h.elog.insert(&h.file, 2, "B", 1); // 2 < 10 -> ONE warning, flush(10,"A")
    try h.elog.insert(&h.file, 1, "C", 1); // 1 < 2 -> a second violation, no re-warn
    try h.elog.insert(&h.file, 100, "Z", 1); // unrelated q0 -> flush(1,"C"), open new

    // Each of the two violations flushes the then-current pending head, so all
    // three records (10, 2, 1) end up in `log` (append order), with only the
    // unrelated final insert (100) left pending — but exactly ONE warning.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.ed.warnings.items, "changes out of sequence"));
    try testing.expectEqual(@as(usize, 3), h.elog.log.items.len);
    try testing.expectEqual(@as(usize, 10), h.elog.log.items[0].insert.q0);
    try testing.expectEqual(@as(usize, 2), h.elog.log.items[1].insert.q0);
    try testing.expectEqual(@as(usize, 1), h.elog.log.items[2].insert.q0);
    try testing.expectEqual(@as(usize, 100), h.elog.pending.?.q0);
}

test "elog: apply reverse order" {
    const h = try H.init("abcdef");
    defer h.deinit();
    h.ed.seq = 1;

    // Recorded in ascending order: delete [1,2) first, insert "XY" at 4 second.
    try h.elog.delete(&h.file, 1, 2);
    try h.elog.insert(&h.file, 4, "XY", 2);

    // Applied in REVERSE: insert first ("abcdef" -> "abcdXYef"), then the
    // delete at [1,2) ("abcdXYef" -> "acdXYef").
    try h.elog.apply(&h.text);
    try h.expectText("acdXYef");
    try testing.expect(h.file.mod);
    try testing.expectEqual(@as(u32, 1), h.file.undoSeq());
}

test "elog: apply marks once and undo restores" {
    const h = try H.init("abc");
    defer h.deinit();
    h.ed.seq = 1;

    try h.elog.insert(&h.file, 1, "X", 1);
    try h.elog.apply(&h.text);
    try h.expectText("aXbc");
    try testing.expect(h.file.mod);
    try testing.expectEqual(@as(u32, 1), h.file.undoSeq());

    // One undo restores everything: exactly one transaction was marked.
    _ = try h.file.undo();
    try h.expectText("abc");
    try testing.expect(!h.file.mod);
}

test "elog: term discards" {
    const h = try H.init("abcdef");
    defer h.deinit();

    try h.elog.insert(&h.file, 1, "X", 1);
    try h.elog.delete(&h.file, 3, 4);
    try testing.expect(!h.elog.empty());

    h.elog.term();
    try testing.expect(h.elog.empty());
    try h.expectText("abcdef"); // buffer never touched
}

test "elog: caret insert extends selection" {
    const h = try H.init("abc");
    defer h.deinit();
    h.ed.seq = 1;

    try h.elog.insert(&h.file, 1, "XY", 2);
    h.text.q0 = 1;
    h.text.q1 = 1; // collapsed caret exactly at the insertion point

    try h.elog.apply(&h.text);
    try h.expectText("aXYbc");
    try testing.expectEqual(@as(usize, 1), h.text.q0);
    try testing.expectEqual(@as(usize, 3), h.text.q1); // extended over "XY"
}
