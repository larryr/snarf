//! park.zig — the framework WAIT QUEUE: any 9P operation may answer "not now,
//! ask me again later" and be parked until it can be served (R-9P-13, S-01 §3).
//!
//! Phase 6 introduced this for reads only (R-P6-2): `Ops.read` returned
//! `error.WouldBlockRead`, the framework filed `{tag, fid, offset, count}` on a
//! FIFO and re-ran `ops.read` from `Server.completeReads`. Phase 14a
//! generalises it, because a device backed by the browser (OPFS, phase 14b)
//! cannot answer walk/open/create/remove/stat synchronously either.
//!
//! The generalisation is deliberately blunt (ruling R-P14a-2): a parked entry
//! stores the **whole T-frame**, byte for byte, and a retry simply re-decodes
//! it and re-dispatches it through the ordinary handler. There is no per-op
//! parked struct and no partially-applied operation to resume — a blocked
//! handler must leave no observable trace, exactly as `Ops.read` already had
//! to. This is the same shape as `srv.c`'s deferred request list (:862
//! `or->flush[]`, :751 respond, :245 sflush), which also keeps the request
//! intact and replays the decision.
//!
//! WHAT MAY BLOCK. `walk1`, `open`, `read`, `write`, `create`, `remove`,
//! `stat` and `wstat` may return `error.WouldBlock` (and `read` also the
//! phase-6 spelling `error.WouldBlockRead`; the two are the same signal —
//! R-P14a-1 compatibility). `attach` and `clunk`/`flush` may NOT, and that is
//! enforced by their vtable types rather than by a runtime check: `Ops.attach`
//! returns plain `errors.OpError` (which has no WouldBlock member) and
//! `Ops.clunk`/`Ops.flush` return `void`. Session control (Tversion) obviously
//! cannot block either — it tears the queue down.
//!
//! BOUND. Plan 9 imposes no limit on outstanding requests; a kernel mount
//! point simply blocks the calling process. Snarf's servers run inside one
//! wasm module with one heap and no way to apply back-pressure to a misbehaving
//! client, so the queue is capped at `max_parked` and the overflowing request
//! is refused with `Rerror "too many parked requests"` (S-01 §3).
//!
//! Imports: std + sibling ninep files (S-07 §6). `server.zig` imports this
//! file and this file names `server.Server` — the same mutual pair as
//! `client.zig`/`tickets.zig`; no type here embeds a `Server`.
const std = @import("std");
const msg = @import("msg.zig");
const errors = @import("errors.zig");
const server = @import("server.zig");

const Server = server.Server;

/// THE framework signal, returned by an `Ops` callback that has asked someone
/// else (the browser, a device queue) and has no answer yet.
pub const WouldBlock = error.WouldBlock;

/// Both spellings of the signal. `WouldBlockRead` is the phase-6 name, kept so
/// every pre-14a device server (`dev/input.zig`, `core/served/fsys.zig`,
/// `tools/origin/*`) compiles and behaves byte-for-byte unchanged (R-P14a-1).
pub const BlockError = error{ WouldBlock, WouldBlockRead };

/// The error set a parkable `Ops` callback returns: the ordinary 9P operation
/// errors widened with the park signal. Neither block member is a member of
/// `errors.OpError`, so neither can ever become an Rerror string and
/// `errors.errorString` stays total (the phase-6 argument, generalised).
pub const OpBlockError = errors.OpError || BlockError;

/// Compatibility alias for `Ops.read`'s error set (phase-6 name, R-P14a-1).
pub const ReadError = OpBlockError;

/// What a dispatched T-message did: answered the client, or asked to be parked.
pub const Outcome = enum { replied, blocked };

/// Queue depth ceiling — see the header. 64 is generous for the editor (the
/// boot namespace parks at most a mouse read and a kbd read) and small enough
/// that a runaway client cannot exhaust the wasm heap with frames.
pub const max_parked: usize = 64;

/// The refusal when the queue is full. Not an `errors.OpError`: it is a
/// framework resource limit, not a 9P file error, so it has no typed member and
/// no `errorFromString` round trip (a client sees `error.Other` plus the text).
pub const too_many_parked = "too many parked requests";

/// One parked request: its tag (for Tflush/duplicate-tag lookup) and an OWNED
/// copy of the whole T-frame. The copy is mandatory — the frame arrives in
/// `Server.rbuf`, which the very next `step()` overwrites.
pub const Entry = struct {
    tag: u16,
    frame: []u8,
    /// True while this entry is being re-dispatched. A handler may itself
    /// drive a retry (`Ops.write` calling `completeReads` is a supported and
    /// tested path, R-P6-5); the flag stops such a nested pass from
    /// dispatching — and replying to — the request already in flight.
    busy: bool = false,
};

/// FIFO of parked requests, in park order. Owned by `Server.parked`.
pub const Queue = struct {
    items: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.items.deinit(allocator);
    }

    /// Drop every entry WITHOUT replying (the Tversion path, R-P6-5).
    pub fn clear(self: *Queue, allocator: std.mem.Allocator) void {
        for (self.items.items) |e| allocator.free(e.frame);
        self.items.clearRetainingCapacity();
    }

    pub fn count(self: *const Queue) usize {
        return self.items.items.len;
    }

    /// Is `tag` currently parked (in-flight)?
    pub fn has(self: *const Queue, tag: u16) bool {
        return self.indexOfTag(tag) != null;
    }

    pub fn indexOfTag(self: *const Queue, tag: u16) ?usize {
        for (self.items.items, 0..) |e, i| if (e.tag == tag) return i;
        return null;
    }

    /// Copy `frame` and file it at the back. `false` (nothing filed) when the
    /// queue is already at `max_parked`.
    pub fn append(self: *Queue, allocator: std.mem.Allocator, tag: u16, frame: []const u8) std.mem.Allocator.Error!bool {
        if (self.count() >= max_parked) return false;
        const copy = try allocator.dupe(u8, frame);
        errdefer allocator.free(copy);
        try self.items.append(allocator, .{ .tag = tag, .frame = copy });
        return true;
    }

    /// Remove entry `i`, freeing its frame. Entries after it shift left, which
    /// is what preserves park order.
    pub fn removeAt(self: *Queue, allocator: std.mem.Allocator, i: usize) void {
        const e = self.items.orderedRemove(i);
        allocator.free(e.frame);
    }
};

/// The fid a parked T-frame names. Every parkable T-message opens its body with
/// `fid[4]` (Twalk's first field is the source fid), so the number is at a
/// fixed offset: `size[4] type[1] tag[2]` then `fid[4]`.
/// [`5/0intro` framing; fcall.h:65-74]
pub fn fidOfFrame(frame: []const u8) ?u32 {
    if (frame.len < msg.header_size + 4) return null;
    return std.mem.readInt(u32, frame[msg.header_size..][0..4], .little);
}

/// File `frame` (an owned copy is made) against `tag`. Returns false when the
/// queue is full; the caller must then refuse the request — see
/// `Server.handleFrame`, which replies `too_many_parked`.
pub fn park(srv: *Server, tag: u16, frame: []const u8) server.Error!bool {
    return srv.parked.append(srv.allocator, tag, frame);
}

/// Re-dispatch EVERY parked request, in park order. A handler that blocks
/// again leaves its entry exactly where it was (no reply, no duplicate); any
/// other outcome — Rread, Rerror, Rcreate, ... — unparks it. Returns the number
/// of requests that completed (i.e. that got a reply).
pub fn retryParked(srv: *Server) server.Error!usize {
    return retryFiltered(srv, null);
}

/// The phase-6 signal, unchanged (R-P6-3 / R-P14a-1): retry only the requests
/// whose fid currently names the file with `qid.path == path`. `Server.
/// completeReads` is this function; device adapters call it after pushing a
/// batch onto a stream file's queue.
pub fn retryParkedPath(srv: *Server, path: u64) server.Error!usize {
    return retryFiltered(srv, path);
}

fn retryFiltered(srv: *Server, path: ?u64) server.Error!usize {
    var replies: usize = 0;
    var i: usize = 0;
    while (i < srv.parked.count()) {
        const e = srv.parked.items.items[i];
        if (e.busy or !matchesPath(srv, e.frame, path)) {
            i += 1; // not ours (or already in flight one frame up the stack)
            continue;
        }
        // Re-decode the OWNED frame: the read `count` clamp, the write payload
        // and every bounds check are recomputed exactly as on first arrival.
        const m = msg.decode(e.frame) catch {
            srv.parked.removeAt(srv.allocator, i);
            try srv.replyError(e.tag, error.BadMessage); // cannot happen: it decoded once
            replies += 1;
            continue;
        };
        // Completions read into `pbuf`, NEVER `rbuf`: a retry can fire from
        // inside `Ops.write`, where `rbuf` still holds the in-flight Twrite's
        // payload (R-P6-5 / O11 D6).
        srv.parked.items.items[i].busy = true;
        const outcome = srv.dispatchT(m, srv.pbuf) catch |err| {
            if (srv.parked.indexOfTag(e.tag)) |j| srv.parked.items.items[j].busy = false;
            return err;
        };
        // Look the entry up again by TAG: a nested retry may have shifted it.
        const j = srv.parked.indexOfTag(e.tag) orelse {
            i += 1;
            continue;
        };
        srv.parked.items.items[j].busy = false;
        if (outcome == .blocked) {
            i += 1; // still blocked — stays parked, in place, unanswered
            continue;
        }
        srv.parked.removeAt(srv.allocator, j);
        replies += 1;
    }
    return replies;
}

/// Does this parked frame belong to `path`? A null filter matches everything
/// (`retryParked`). A frame whose fid has since vanished matches nothing, so a
/// path-filtered pass leaves it alone — `retryParked` still picks it up and the
/// ordinary handler answers "unknown fid".
fn matchesPath(srv: *Server, frame: []const u8, path: ?u64) bool {
    const want = path orelse return true;
    const fid = fidOfFrame(frame) orelse return false;
    const fp = srv.lookupFid(fid) orelse return false;
    return fp.qid.path == want;
}

/// Tflush: if `oldtag` is parked, drop it and answer the OLD tag with
/// `Rerror "interrupted"`. Returns whether anything was flushed. The caller
/// sends the Rflush AFTER this, which is the ordering flush(5) mandates and
/// `srv.c` implements with its deferred `or->flush[]` list (:862, :751).
pub fn flushTag(srv: *Server, oldtag: u16) server.Error!bool {
    const i = srv.parked.indexOfTag(oldtag) orelse return false;
    srv.parked.removeAt(srv.allocator, i);
    try srv.replyError(oldtag, error.Interrupted);
    return true;
}

/// Tclunk: interrupt (`Rerror "interrupted"`) and drop every request parked on
/// `fid`, in park order, before the fid itself goes away (R-P6-5).
pub fn sweepFid(srv: *Server, fid: u32) server.Error!void {
    var i: usize = 0;
    while (i < srv.parked.count()) {
        const e = srv.parked.items.items[i];
        if (fidOfFrame(e.frame) == fid) {
            srv.parked.removeAt(srv.allocator, i); // shift left; do not advance i
            try srv.replyError(e.tag, error.Interrupted);
        } else i += 1;
    }
}

// ===========================================================================
// Tests — SMOKE ONLY. The named battery (T5-T9: park/retry of every op, FIFO
// order, the flush arm, the bound, the clunked-fid arm) is the test author's,
// per the phase-14a contract §4.
// ===========================================================================
const testing = std.testing;

test "park: queue is FIFO, bounded, and frees its frames" {
    const alloc = testing.allocator;
    var q = Queue{};
    defer q.deinit(alloc);

    var frame = [_]u8{0} ** 11;
    std.mem.writeInt(u32, frame[0..4], 11, .little);
    frame[4] = @intFromEnum(msg.Kind.tread);
    var t: u16 = 0;
    while (t < max_parked) : (t += 1) {
        std.mem.writeInt(u16, frame[5..7], t, .little);
        std.mem.writeInt(u32, frame[7..11], @as(u32, t) + 100, .little); // fid
        try testing.expect(try q.append(alloc, t, &frame));
    }
    try testing.expectEqual(max_parked, q.count());
    try testing.expect(!try q.append(alloc, 999, &frame)); // bound refuses

    try testing.expectEqual(@as(?usize, 0), q.indexOfTag(0));
    try testing.expectEqual(@as(?usize, max_parked - 1), q.indexOfTag(@intCast(max_parked - 1)));
    try testing.expect(q.has(3));
    try testing.expect(!q.has(999));
    try testing.expectEqual(@as(?u32, 103), fidOfFrame(q.items.items[3].frame));

    q.removeAt(alloc, 0); // FIFO head leaves, the rest shift left
    try testing.expectEqual(@as(?usize, 0), q.indexOfTag(1));
    try testing.expect(try q.append(alloc, 999, &frame)); // room again
    q.clear(alloc);
    try testing.expectEqual(@as(usize, 0), q.count());
}

test "park: fidOfFrame rejects a runt frame" {
    try testing.expectEqual(@as(?u32, null), fidOfFrame(&[_]u8{ 1, 2, 3 }));
    try testing.expectEqual(@as(?u32, null), fidOfFrame(&([_]u8{0} ** 10)));
}
