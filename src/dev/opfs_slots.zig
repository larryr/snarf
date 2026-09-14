//! opfs_slots — the in-flight `fsOp` table: the machinery that turns "ask the
//! browser and wait" into 14a's `park.WouldBlock` and back.
//!
//! THE PROBLEM. A parked 9P request is retried by re-dispatching the WHOLE
//! T-frame (R-P14a-2), so every `Ops` callback must be re-runnable and must
//! leave no trace when it blocks. A single 9P operation may need SEVERAL
//! browser round trips — a two-element Twalk is two `stat`s, an open with
//! OTRUNC is a `stat` then a `truncate` — and each retry re-runs the callback
//! from the top. Without memory, retry number two would re-issue round trip
//! number one, forever.
//!
//! THE ANSWER (R-P14b-3). One slot per `(fid, op, key)`, where `key` is the
//! byte offset for read/write and the target path's qid hash for everything
//! else. A slot passes through three states:
//!
//!     pending  — issued to the browser, no answer yet        ⇒ WouldBlock
//!     ready    — the completion arrived and is cached here
//!     taken    — the current `Ops` callback has consumed it
//!
//! and the callback's LAST act is `endOp`: if it blocked, every `taken` slot
//! goes back to `ready` so the retry finds the same answers and issues nothing
//! new; if it finished — successfully or with an Rerror — every `taken` slot is
//! freed. `pending` slots are never touched by `endOp`, so two concurrent reads
//! on one fid do not disturb each other.
//!
//! A completion whose ticket is unknown — the fid was clunked while the request
//! was in flight — is DROPPED silently (R-P14b-3). There is no cancel on the
//! wire: the browser will answer, and the answer is simply nobody's.
//!
//! Imports: std + `shim` (the status/op enums). No `ninep`: this file knows
//! nothing about 9P beyond the fid number it keys on.
const std = @import("std");
const shim = @import("shim");

const FsRecord = shim.abi.FsRecord;

/// A cached completion, handed to the caller while its slot is `taken`. The
/// payload is owned by the slot and stays valid until `endOp` frees it — i.e.
/// for the rest of the callback that took it.
pub const Completion = struct {
    status: FsRecord.Status,
    payload: []const u8,
};

pub const State = enum { pending, ready, taken };

pub const Slot = struct {
    ticket: u32,
    fid: u32,
    op: FsRecord.Op,
    key: u64,
    state: State = .pending,
    status: FsRecord.Status = .ok,
    /// Owned copy of the completion payload (empty while pending).
    payload: []u8 = &.{},
};

pub const Table = struct {
    items: std.ArrayList(Slot) = .empty,
    /// Tickets are never reused within a session; 0 is reserved for "none".
    next_ticket: u32 = 1,

    pub fn deinit(self: *Table, a: std.mem.Allocator) void {
        for (self.items.items) |s| a.free(s.payload);
        self.items.deinit(a);
        self.* = undefined;
    }

    pub fn count(self: *const Table) usize {
        return self.items.items.len;
    }

    /// Index of the slot for `(fid, op, key)`, if one exists.
    pub fn find(self: *const Table, fid: u32, op: FsRecord.Op, key: u64) ?usize {
        for (self.items.items, 0..) |s, i| {
            if (s.fid == fid and s.op == op and s.key == key) return i;
        }
        return null;
    }

    fn findTicket(self: *const Table, ticket: u32) ?usize {
        for (self.items.items, 0..) |s, i| if (s.ticket == ticket) return i;
        return null;
    }

    /// File a fresh `pending` slot and return the ticket the caller must send
    /// to the browser with the record.
    pub fn issue(self: *Table, a: std.mem.Allocator, fid: u32, op: FsRecord.Op, key: u64) std.mem.Allocator.Error!u32 {
        const ticket = self.next_ticket;
        self.next_ticket +%= 1;
        if (self.next_ticket == 0) self.next_ticket = 1;
        try self.items.append(a, .{ .ticket = ticket, .fid = fid, .op = op, .key = key });
        return ticket;
    }

    /// Land a completion on its ticket. `false` — nobody is waiting, drop it —
    /// when the ticket is unknown (its fid was clunked) or already answered.
    pub fn complete(
        self: *Table,
        a: std.mem.Allocator,
        ticket: u32,
        status: FsRecord.Status,
        payload: []const u8,
    ) bool {
        const i = self.findTicket(ticket) orelse return false;
        const s = &self.items.items[i];
        if (s.state != .pending) return false; // a second completion for one ticket
        // OOM degrades to an empty payload: the op sees a short answer rather
        // than wedging on a completion that can never be delivered.
        const copy: []u8 = a.dupe(u8, payload) catch &[_]u8{};
        a.free(s.payload);
        s.payload = copy;
        s.status = status;
        s.state = .ready;
        return true;
    }

    /// Consume the answer for `(fid, op, key)`: null means "still waiting" (or
    /// "not asked yet" — the caller distinguishes with `find`). Marks the slot
    /// `taken`, which is what `endOp` acts on.
    pub fn take(self: *Table, fid: u32, op: FsRecord.Op, key: u64) ?Completion {
        const i = self.find(fid, op, key) orelse return null;
        const s = &self.items.items[i];
        switch (s.state) {
            .pending => return null,
            .ready, .taken => {
                s.state = .taken;
                return .{ .status = s.status, .payload = s.payload };
            },
        }
    }

    /// End the current `Ops` callback. `blocked` ⇒ hand every consumed answer
    /// back to the next retry; otherwise the operation is over and its answers
    /// are freed.
    pub fn endOp(self: *Table, a: std.mem.Allocator, blocked: bool) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].state != .taken) {
                i += 1;
                continue;
            }
            if (blocked) {
                self.items.items[i].state = .ready;
                i += 1;
            } else {
                a.free(self.items.items[i].payload);
                _ = self.items.orderedRemove(i);
            }
        }
    }

    /// Forget everything belonging to `fid` (its clunk). Late completions for
    /// the dropped tickets find no slot and are discarded.
    pub fn dropFid(self: *Table, a: std.mem.Allocator, fid: u32) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].fid != fid) {
                i += 1;
                continue;
            }
            a.free(self.items.items[i].payload);
            _ = self.items.orderedRemove(i);
        }
    }
};

// ===========================================================================
// Tests — SMOKE ONLY (the named battery is the test author's, contract §4).
// ===========================================================================
const testing = std.testing;

test "opfs_slots: issue / complete / take / endOp round trip" {
    const a = testing.allocator;
    var t: Table = .{};
    defer t.deinit(a);

    const tk = try t.issue(a, 7, .stat, 99);
    try testing.expectEqual(@as(?Completion, null), t.take(7, .stat, 99)); // still pending
    try testing.expect(t.complete(a, tk, .ok, "xyz"));
    try testing.expect(!t.complete(a, tk, .ok, "xyz")); // only once
    try testing.expect(!t.complete(a, tk + 500, .ok, "")); // unknown ticket dropped

    const c = t.take(7, .stat, 99).?;
    try testing.expectEqual(FsRecord.Status.ok, c.status);
    try testing.expectEqualStrings("xyz", c.payload);

    // Blocked: the answer survives for the retry, and taking it again is free.
    t.endOp(a, true);
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectEqualStrings("xyz", t.take(7, .stat, 99).?.payload);

    // Finished: the slot is gone.
    t.endOp(a, false);
    try testing.expectEqual(@as(usize, 0), t.count());
}

test "opfs_slots: slots are per (fid, op, key); dropFid sweeps one fid" {
    const a = testing.allocator;
    var t: Table = .{};
    defer t.deinit(a);

    _ = try t.issue(a, 1, .read, 0);
    _ = try t.issue(a, 1, .read, 4096); // same fid+op, different offset
    const other = try t.issue(a, 2, .read, 0); // different fid
    try testing.expectEqual(@as(usize, 3), t.count());
    try testing.expect(t.find(1, .read, 4096) != null);
    try testing.expect(t.find(1, .write, 0) == null);

    t.dropFid(a, 1);
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expect(!t.complete(a, 1, .ok, "late")); // fid 1's ticket is nobody's now
    try testing.expect(t.complete(a, other, .ok, "kept"));

    // A pending slot is untouched by endOp in either direction.
    t.endOp(a, true);
    t.endOp(a, false);
    try testing.expectEqual(@as(usize, 1), t.count());
}
