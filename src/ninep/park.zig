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
const server_mut = @import("server_mut.zig");

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

/// THE PASS WALKS TAGS, NOT INDICES (14a review nit, fixed in 16b). A nested
/// retry — an `Ops.write` that calls `completeReads` while this loop is
/// mid-pass, which R-P6-5 explicitly supports — may remove an entry BELOW the
/// cursor; everything after it shifts left, and an index walk then steps over
/// the entry that moved into the vacated slot. It was never dispatched twice
/// and never lost (the next pass picked it up), but "every parked entry is
/// retried exactly once per pass" was not true.
///
/// So the tags parked when the pass BEGINS are snapshotted, and each is looked
/// up by tag when its turn comes: an entry a nested pass already answered is
/// simply gone (`orelse continue`), and one that merely moved is found where it
/// now is. `max_parked` bounds the snapshot, so it is a fixed 128-byte array
/// and this function still allocates nothing.
///
/// A request that parks DURING the pass is not in the snapshot and waits for
/// the next `retryParked` — which its own completion will trigger. Retrying
/// something that blocked moments ago inside this very pass would be wasted
/// work anyway.
fn retryFiltered(srv: *Server, path: ?u64) server.Error!usize {
    var snapshot: [max_parked]u16 = undefined;
    var n: usize = 0;
    for (srv.parked.items.items) |e| {
        if (n == snapshot.len) break; // cannot happen: the queue IS bounded
        snapshot[n] = e.tag;
        n += 1;
    }

    var replies: usize = 0;
    for (snapshot[0..n]) |tag| {
        const i = srv.parked.indexOfTag(tag) orelse continue; // answered by a nested pass
        const e = srv.parked.items.items[i];
        // Not ours, or already in flight one frame up the stack.
        if (e.busy or !matchesPath(srv, e.frame, path)) continue;
        // Re-decode the OWNED frame: the read `count` clamp, the write payload
        // and every bounds check are recomputed exactly as on first arrival.
        const m = msg.decode(e.frame) catch {
            srv.parked.removeAt(srv.allocator, i);
            try srv.replyError(tag, error.BadMessage); // cannot happen: it decoded once
            replies += 1;
            continue;
        };
        // Completions read into `pbuf`, NEVER `rbuf`: a retry can fire from
        // inside `Ops.write`, where `rbuf` still holds the in-flight Twrite's
        // payload (R-P6-5 / O11 D6).
        srv.parked.items.items[i].busy = true;
        const outcome = srv.dispatchT(m, srv.pbuf) catch |err| {
            if (srv.parked.indexOfTag(tag)) |j| srv.parked.items.items[j].busy = false;
            return err;
        };
        // Look the entry up again by TAG: a nested retry may have shifted it.
        const j = srv.parked.indexOfTag(tag) orelse continue;
        srv.parked.items.items[j].busy = false;
        if (outcome == .blocked) continue; // still blocked — stays parked, unanswered
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
    server_mut.discardParkedWalk(srv, srv.parked.items.items[i].frame);
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
            server_mut.discardParkedWalk(srv, e.frame);
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

// ===========================================================================
// Named battery T5-T9 (phase-14a contract §4, test writer's). One shared
// harness — `AllOpsHarness` around an `AllOps` fake whose seven parkable
// slots each block on their own flag — exercises every op the framework may
// park, FIFO order, the flush arm, the bound, and the clunked/vanished-fid
// arm. `testsrv.TestTransport` supplies the transport (server.zig's own
// `BlockFixture` pattern, adapted).
// ===========================================================================
const testsrv = @import("testsrv.zig");
const Fid = server.Fid;
const Ops = server.Ops;
const Stat = @import("stat.zig");

/// Tree: root(1, dir) → "f"(2, file). Every parkable op blocks while its own
/// flag is set, else succeeds trivially. `stat_budget`, used only by T8, lets
/// exactly N blocked `stat` calls through before reverting to WouldBlock —
/// how the bound test frees exactly one slot without a second flag.
const AllOps = struct {
    block_walk: bool = false,
    block_open: bool = false,
    block_read: bool = false,
    block_write: bool = false,
    block_create: bool = false,
    block_remove: bool = false,
    block_stat: bool = false,
    block_wstat: bool = false,
    /// While `block_stat` is set, this many additional calls succeed anyway
    /// (each one consumes one), before reverting to WouldBlock. T8 only.
    stat_budget: usize = 0,
    /// Every fid number the framework has handed to `Ops.clunk`, in order —
    /// including the tentative-newfid discard (`server_mut.discardNewfid`).
    clunked: [8]u32 = .{0} ** 8,
    n_clunked: usize = 0,
    /// 16b item 9: when set, the next `write` unblocks `stat` and drives ONE
    /// path-filtered retry from INSIDE the outer pass (the R-P6-5 nesting).
    nest_path: ?u64 = null,
    /// How many times `stat` has actually been dispatched (blocked calls
    /// included) — the "exactly once per pass" witness.
    stat_calls: usize = 0,

    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 } };
    }
    fn attach(_: *anyopaque, _: *Server, _: *Fid, _: []const u8) errors.OpError!Qid {
        return qidOf(1);
    }
    fn walk1(ctx: *anyopaque, _: *Server, fid: *Fid, name: []const u8) OpBlockError!Qid {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        if (self.block_walk) return error.WouldBlock;
        if (fid.qid.path == 1 and std.mem.eql(u8, name, "f")) return qidOf(2);
        return error.FileDoesNotExist;
    }
    fn open(ctx: *anyopaque, _: *Server, fid: *Fid, _: u8) OpBlockError!Qid {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        if (self.block_open) return error.WouldBlock;
        return fid.qid;
    }
    fn read(ctx: *anyopaque, _: *Server, _: *Fid, _: u64, _: []u8) ReadError!usize {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        if (self.block_read) return error.WouldBlock;
        return 0;
    }
    fn write(ctx: *anyopaque, srv: *Server, _: *Fid, _: u64, data: []const u8) OpBlockError!usize {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        if (self.block_write) return error.WouldBlock;
        if (self.nest_path) |p| {
            self.nest_path = null;
            self.block_stat = false;
            _ = retryParkedPath(srv, p) catch {};
        }
        return data.len;
    }
    fn stat(ctx: *anyopaque, _: *Server, fid: *Fid) OpBlockError!Stat {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        self.stat_calls += 1;
        if (self.block_stat) {
            if (self.stat_budget > 0) {
                self.stat_budget -= 1;
            } else return error.WouldBlock;
        }
        return .{
            .qid = fid.qid,
            .mode = if (fid.qid.qtype.dir) Stat.DMDIR | 0o555 else 0o644,
            .length = 0,
            .name = "f",
        };
    }
    fn create(ctx: *anyopaque, _: *Server, _: *Fid, name: []const u8, _: u32, _: u8) OpBlockError!server.CreateResult {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        if (self.block_create) return error.WouldBlock;
        _ = name;
        return .{ .qid = qidOf(3) };
    }
    fn remove(ctx: *anyopaque, _: *Server, _: *Fid) OpBlockError!void {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        if (self.block_remove) return error.WouldBlock;
    }
    fn wstat(ctx: *anyopaque, _: *Server, _: *Fid, _: Stat) OpBlockError!void {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        if (self.block_wstat) return error.WouldBlock;
    }

    fn clunk(ctx: *anyopaque, _: *Server, fid: *Fid) void {
        const self: *AllOps = @ptrCast(@alignCast(ctx));
        if (self.n_clunked < self.clunked.len) {
            self.clunked[self.n_clunked] = fid.fid;
            self.n_clunked += 1;
        }
    }

    const ops = Ops{
        .attach = attach,
        .walk1 = walk1,
        .open = open,
        .read = read,
        .write = write,
        .clunk = clunk,
        .stat = stat,
        .create = create,
        .remove = remove,
        .wstat = wstat,
    };
};

const Qid = @import("qid.zig");

/// Heap-pinned harness: `feed`/`popMsg` primitives (a parked request yields
/// NO reply), plus `transact` for the non-blocking setup steps.
const AllOpsHarness = struct {
    alloc: std.mem.Allocator,
    tt: testsrv.TestTransport,
    fake: AllOps,
    srv: Server,
    rbuf: [8192]u8 = undefined,

    fn create(alloc: std.mem.Allocator) !*AllOpsHarness {
        const self = try alloc.create(AllOpsHarness);
        self.alloc = alloc;
        self.tt = .{ .alloc = alloc };
        self.fake = .{};
        self.srv = try Server.init(alloc, self.tt.asTransport(), &AllOps.ops, &self.fake, 8192);
        return self;
    }

    fn destroy(self: *AllOpsHarness) void {
        self.srv.deinit();
        self.tt.deinit();
        self.alloc.destroy(self);
    }

    fn feed(self: *AllOpsHarness, m: msg.Message) !void {
        var enc: [8192]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        try self.tt.pushReq(enc[0..n]);
        _ = try self.srv.step();
    }

    fn popMsg(self: *AllOpsHarness) !?msg.Message {
        const reply = self.tt.popReply() orelse return null;
        defer self.alloc.free(reply);
        @memcpy(self.rbuf[0..reply.len], reply);
        return try msg.decode(self.rbuf[0..reply.len]);
    }

    fn transact(self: *AllOpsHarness, m: msg.Message) !msg.Message {
        try self.feed(m);
        return (try self.popMsg()) orelse error.NoReply;
    }

    fn setup(self: *AllOpsHarness) !void {
        const rv = try self.transact(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect(rv.body == .rversion);
        const ra = try self.transact(.{ .tag = 1, .body = .{ .tattach = .{ .fid = 0, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
        try testing.expect(ra.body == .rattach);
    }
};

test "park: Tstat blocks with no reply until the flag flips, then completes exactly once (T5)" {
    const h = try AllOpsHarness.create(testing.allocator);
    defer h.destroy();
    try h.setup();
    h.fake.block_stat = true;

    try h.feed(.{ .tag = 20, .body = .{ .tstat = .{ .fid = 0 } } });
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());

    // Still blocked: retryParked makes no progress and sends nothing.
    try testing.expectEqual(@as(usize, 0), try retryParked(&h.srv));
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());

    h.fake.block_stat = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    const r = (try h.popMsg()).?;
    try testing.expect(r.body == .rstat);
    try testing.expectEqual(@as(u16, 20), r.tag);
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(@as(usize, 0), h.srv.parkedCount());
}

test "park: clunk (and attach) cannot park — a compile-time property; the 7 parkable ops each park and complete (T6)" {
    // Compile-time (the coder's as-built ruling, phase-14a contract T6
    // adjustment): `Ops.clunk` returns plain `void` — no error union at all,
    // so WouldBlock has nowhere to live — and `Ops.attach` returns the
    // narrower `errors.OpError`, a named closed set with no WouldBlock
    // member. Neither slot's signature can be made to park; this is a type
    // fact, not a runtime refusal, so it is checked with `@typeInfo`.
    comptime {
        const ClunkOpt = std.meta.fieldInfo(Ops, .clunk).type; // ?*const fn(...) void
        const ClunkFnPtr = @typeInfo(ClunkOpt).optional.child; // *const fn(...) void
        const ClunkFn = @typeInfo(ClunkFnPtr).pointer.child; // fn(...) void
        const ClunkRet = @typeInfo(ClunkFn).@"fn".return_type.?;
        if (@typeInfo(ClunkRet) != .void) @compileError("Ops.clunk must return plain void — WouldBlock must not be representable");

        const AttachFnPtr = std.meta.fieldInfo(Ops, .attach).type; // *const fn(...) OpError!Qid
        const AttachFn = @typeInfo(AttachFnPtr).pointer.child;
        const AttachRet = @typeInfo(AttachFn).@"fn".return_type.?;
        const AttachErrSet = @typeInfo(AttachRet).error_union.error_set;
        const members = @typeInfo(AttachErrSet).error_set.?;
        for (members) |e| {
            if (std.mem.eql(u8, e.name, "WouldBlock")) @compileError("Ops.attach's error set must not contain WouldBlock");
        }
    }

    // Runtime: each of the seven parkable ops parks (no reply) then
    // completes (exactly one reply) once its own flag flips.
    const h = try AllOpsHarness.create(testing.allocator);
    defer h.destroy();
    try h.setup();

    // walk1
    h.fake.block_walk = true;
    try h.feed(.{ .tag = 10, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"f"}) } });
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());
    h.fake.block_walk = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    const rwalk = (try h.popMsg()).?;
    try testing.expect(rwalk.body == .rwalk);
    try testing.expectEqual(@as(u16, 10), rwalk.tag);

    // open (fid 1, walked above)
    h.fake.block_open = true;
    try h.feed(.{ .tag = 11, .body = .{ .topen = .{ .fid = 1, .mode = msg.OREAD } } });
    try testing.expect((try h.popMsg()) == null);
    h.fake.block_open = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    try testing.expect((try h.popMsg()).?.body == .ropen);

    // read (fid 1, now open)
    h.fake.block_read = true;
    try h.feed(.{ .tag = 12, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 10 } } });
    try testing.expect((try h.popMsg()) == null);
    h.fake.block_read = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    try testing.expect((try h.popMsg()).?.body == .rread);

    // write: walk+open a second fid with a write-capable mode.
    _ = try h.transact(.{ .tag = 13, .body = .{ .twalk = msg.Body.Twalk.init(0, 2, &.{"f"}) } });
    _ = try h.transact(.{ .tag = 14, .body = .{ .topen = .{ .fid = 2, .mode = msg.ORDWR } } });
    h.fake.block_write = true;
    try h.feed(.{ .tag = 15, .body = .{ .twrite = .{ .fid = 2, .offset = 0, .data = "hi" } } });
    try testing.expect((try h.popMsg()) == null);
    h.fake.block_write = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    const rwrite = (try h.popMsg()).?;
    try testing.expect(rwrite.body == .rwrite);
    try testing.expectEqual(@as(u32, 2), rwrite.body.rwrite.count);

    // stat (fid 0, root)
    h.fake.block_stat = true;
    try h.feed(.{ .tag = 16, .body = .{ .tstat = .{ .fid = 0 } } });
    try testing.expect((try h.popMsg()) == null);
    h.fake.block_stat = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    try testing.expect((try h.popMsg()).?.body == .rstat);

    // create (fid 0, root: still unopened and a directory)
    h.fake.block_create = true;
    try h.feed(.{ .tag = 17, .body = .{ .tcreate = .{ .fid = 0, .name = "made", .perm = 0o644, .mode = msg.OWRITE } } });
    try testing.expect((try h.popMsg()) == null);
    h.fake.block_create = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    const rcreate = (try h.popMsg()).?;
    try testing.expect(rcreate.body == .rcreate);
    try testing.expectEqual(@as(u64, 3), rcreate.body.rcreate.qid.path);

    // wstat (fid 1, still valid and open)
    h.fake.block_wstat = true;
    var blob: [64]u8 = undefined;
    const nst = try Stat.dontTouch().encode(&blob);
    try h.feed(.{ .tag = 18, .body = .{ .twstat = .{ .fid = 1, .stat = blob[0..nst] } } });
    try testing.expect((try h.popMsg()) == null);
    h.fake.block_wstat = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    try testing.expect((try h.popMsg()).?.body == .rwstat);

    // remove (fid 2, still valid)
    h.fake.block_remove = true;
    try h.feed(.{ .tag = 19, .body = .{ .tremove = .{ .fid = 2 } } });
    try testing.expect((try h.popMsg()) == null);
    h.fake.block_remove = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    try testing.expect((try h.popMsg()).?.body == .rremove);

    try testing.expectEqual(@as(usize, 0), h.srv.parkedCount());
}

test "park: FIFO order across two retries; a mid-queue Tflush leaves the other two to complete (T7)" {
    const h = try AllOpsHarness.create(testing.allocator);
    defer h.destroy();
    try h.setup();
    h.fake.block_stat = true;

    try h.feed(.{ .tag = 1, .body = .{ .tstat = .{ .fid = 0 } } });
    try h.feed(.{ .tag = 2, .body = .{ .tstat = .{ .fid = 0 } } });
    try h.feed(.{ .tag = 3, .body = .{ .tstat = .{ .fid = 0 } } });
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(@as(usize, 3), h.srv.parkedCount());

    // First retry: still blocked everywhere, nothing completes.
    try testing.expectEqual(@as(usize, 0), try retryParked(&h.srv));
    try testing.expectEqual(@as(usize, 3), h.srv.parkedCount());

    // Flush the middle tag: Rerror "interrupted" on tag 2 FIRST, then Rflush.
    try h.feed(.{ .tag = 9, .body = .{ .tflush = .{ .oldtag = 2 } } });
    const e = (try h.popMsg()).?;
    try testing.expect(e.body == .rerror);
    try testing.expectEqual(@as(u16, 2), e.tag);
    try testing.expectEqualStrings("interrupted", e.body.rerror.ename);
    const fl = (try h.popMsg()).?;
    try testing.expect(fl.body == .rflush);
    try testing.expectEqual(@as(u16, 9), fl.tag);
    try testing.expectEqual(@as(usize, 2), h.srv.parkedCount());

    // Second retry, unblocked: the remaining two complete in park order.
    h.fake.block_stat = false;
    try testing.expectEqual(@as(usize, 2), try retryParked(&h.srv));
    const r1 = (try h.popMsg()).?;
    try testing.expect(r1.body == .rstat);
    try testing.expectEqual(@as(u16, 1), r1.tag);
    const r3 = (try h.popMsg()).?;
    try testing.expect(r3.body == .rstat);
    try testing.expectEqual(@as(u16, 3), r3.tag);
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(@as(usize, 0), h.srv.parkedCount());
}

test "park: the queue is bounded at max_parked; freeing one slot admits a new park (T8)" {
    const h = try AllOpsHarness.create(testing.allocator);
    defer h.destroy();
    try h.setup();
    h.fake.block_stat = true;

    var t: u16 = 0;
    while (t < max_parked) : (t += 1) {
        try h.feed(.{ .tag = t, .body = .{ .tstat = .{ .fid = 0 } } });
    }
    try testing.expectEqual(max_parked, h.srv.parkedCount());
    try testing.expect((try h.popMsg()) == null);

    // One more ⇒ refused on the spot, "too many parked requests", queue unchanged.
    try h.feed(.{ .tag = 9999, .body = .{ .tstat = .{ .fid = 0 } } });
    const r = (try h.popMsg()).?;
    try testing.expectEqual(@as(u16, 9999), r.tag);
    try testing.expect(r.body == .rerror);
    try testing.expectEqualStrings(too_many_parked, r.body.rerror.ename);
    try testing.expectEqual(max_parked, h.srv.parkedCount());

    // Complete exactly the FIFO head (tag 0) by budgeting one unblocked call;
    // every other parked stat stays blocked and re-parks.
    h.fake.stat_budget = 1;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    const done = (try h.popMsg()).?;
    try testing.expect(done.body == .rstat);
    try testing.expectEqual(@as(u16, 0), done.tag);
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(max_parked - 1, h.srv.parkedCount());

    // The queue is no longer full: a new park now succeeds.
    try h.feed(.{ .tag = 5000, .body = .{ .tstat = .{ .fid = 0 } } });
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(max_parked, h.srv.parkedCount());
}

test "park: a parked request whose fid vanishes without a Tclunk sweep gets the same error a fresh op on that fid would (T9)" {
    // An ordinary Tclunk sweeps everything parked on the fid it drops
    // (`sweepFid`, exercised in server.zig's "clunk with parked reads
    // interrupts then Rclunk") — so "unknown fid on retry" is unreachable
    // via Tclunk (phase-14a contract T9 adjustment). This pins the OTHER
    // path `retryFiltered`/`matchesPath` must also handle: a parked frame
    // whose fid the table no longer has AT ALL, via a test-only bypass that
    // removes the fid directly (no sweep, no Tclunk).
    const h = try AllOpsHarness.create(testing.allocator);
    defer h.destroy();
    try h.setup();
    h.fake.block_stat = true;

    try h.feed(.{ .tag = 41, .body = .{ .tstat = .{ .fid = 0 } } });
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());

    // Remove fid 0 directly (bypassing Tclunk/sweepFid entirely); free the
    // uname the framework owns so the harness stays leak-free.
    if (h.srv.fids.fetchRemove(0)) |kv| h.srv.allocator.free(kv.value.uname);

    h.fake.block_stat = false;
    try testing.expectEqual(@as(usize, 1), try retryParked(&h.srv));
    const r = (try h.popMsg()).?;
    try testing.expect(r.body == .rerror);
    try testing.expectEqual(@as(u16, 41), r.tag);
    try testing.expectEqualStrings("unknown fid", r.body.rerror.ename);
    try testing.expectEqual(@as(usize, 0), h.srv.parkedCount());

    // Confirm it is the SAME error a fresh op on that fid gets.
    const fresh = try h.transact(.{ .tag = 42, .body = .{ .tstat = .{ .fid = 0 } } });
    try testing.expect(fresh.body == .rerror);
    try testing.expectEqualStrings("unknown fid", fresh.body.rerror.ename);
}

test "park: a discarded tentative newfid is announced to the server (16b item 1)" {
    // A never-installed newfid is invisible on the WIRE ("the newfid is not
    // created", `5/walk`) but the server may already hold per-fid state for
    // that number. lib9p closes it — `rwalk` does
    // `closefid(removefid(pool, newfid))`, which runs the pool's `destroy`
    // hook — and so do we, on the failure path and on the flush of a parked
    // walk alike. [lib9p/srv.c:334-343 rwalk; lib9p/fid.c:64 closefid]
    const h = try AllOpsHarness.create(testing.allocator);
    defer h.destroy();
    try h.setup();

    // (a) Failed walk on a fresh newfid: clunked, exactly once.
    const bad = try h.transact(.{ .tag = 50, .body = .{ .twalk = msg.Body.Twalk.init(0, 5, &.{"nope"}) } });
    try testing.expect(bad.body == .rerror);
    try testing.expectEqual(@as(usize, 1), h.fake.n_clunked);
    try testing.expectEqual(@as(u32, 5), h.fake.clunked[0]);

    // (b) Clone in place (fid == newfid) must NOT be clunked: the live fid
    //     keeps that number (srv.c:320-323 increfs instead).
    h.fake.n_clunked = 0;
    const same = try h.transact(.{ .tag = 51, .body = .{ .twalk = msg.Body.Twalk.init(0, 0, &.{"nope"}) } });
    try testing.expect(same.body == .rerror);
    try testing.expectEqual(@as(usize, 0), h.fake.n_clunked);

    // (c) A PARKED walk that is flushed: the framework never re-enters
    //     `handleWalk`, so the discard happens in `flushTag`.
    h.fake.block_walk = true;
    try h.feed(.{ .tag = 52, .body = .{ .twalk = msg.Body.Twalk.init(0, 6, &.{"f"}) } });
    try testing.expect((try h.popMsg()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());
    try testing.expectEqual(@as(usize, 0), h.fake.n_clunked); // not yet: it may still come back

    try h.feed(.{ .tag = 53, .body = .{ .tflush = .{ .oldtag = 52 } } });
    const interrupted = (try h.popMsg()).?;
    try testing.expect(interrupted.body == .rerror);
    try testing.expectEqualStrings("interrupted", interrupted.body.rerror.ename);
    try testing.expect((try h.popMsg()).?.body == .rflush);
    try testing.expectEqual(@as(usize, 1), h.fake.n_clunked);
    try testing.expectEqual(@as(u32, 6), h.fake.clunked[0]);
}

test "park: a nested retry cannot make the outer pass skip an entry (16b item 9)" {
    // R-P6-5 supports a handler driving its own retry. When that nested pass
    // removes an entry BELOW the outer cursor, everything after it shifts left
    // — and the old index walk stepped over whatever moved into the vacated
    // slot. Walking a snapshot of TAGS instead visits every entry that was
    // parked when the pass began, exactly once.
    const h = try AllOpsHarness.create(testing.allocator);
    defer h.destroy();
    try h.setup();

    const rw = try h.transact(.{ .tag = 10, .body = .{ .twalk = msg.Body.Twalk.init(0, 1, &.{"f"}) } });
    try testing.expect(rw.body == .rwalk);
    const ro = try h.transact(.{ .tag = 11, .body = .{ .topen = .{ .fid = 1, .mode = msg.ORDWR } } });
    try testing.expect(ro.body == .ropen);

    h.fake.block_stat = true;
    h.fake.block_write = true;
    // Park order: [A Tstat fid1 (qid path 2)] [B Twrite fid1] [C Tstat fid0
    // (qid path 1)]. The nested pass is filtered on path 2, so it can reach A
    // and NOT C — which is exactly the shape that used to lose C.
    try h.feed(.{ .tag = 70, .body = .{ .tstat = .{ .fid = 1 } } });
    try h.feed(.{ .tag = 71, .body = .{ .twrite = .{ .fid = 1, .offset = 0, .data = "x" } } });
    try h.feed(.{ .tag = 72, .body = .{ .tstat = .{ .fid = 0 } } });
    try testing.expectEqual(@as(usize, 3), h.srv.parkedCount());
    try testing.expect((try h.popMsg()) == null);

    // One UNFILTERED pass. A is still blocked when its turn comes; B's handler
    // then unblocks `stat` and drives the nested path-2 retry, which answers A
    // and removes it from index 0.
    h.fake.block_write = false;
    h.fake.nest_path = 2;
    h.fake.stat_calls = 0;
    try testing.expectEqual(@as(usize, 2), try retryParked(&h.srv)); // B and C; A's reply is the nested pass's
    try testing.expectEqual(@as(usize, 0), h.srv.parkedCount()); // C is NOT skipped

    // All three answered, and each Tstat ran once per pass that reached it:
    // A blocked on its outer turn and succeeded in the nested pass, C once.
    var seen = [_]bool{ false, false, false };
    for (0..3) |_| {
        const r = (try h.popMsg()).?;
        try testing.expect(r.body != .rerror);
        seen[r.tag - 70] = true;
    }
    try testing.expect(seen[0] and seen[1] and seen[2]);
    try testing.expectEqual(@as(usize, 3), h.fake.stat_calls);
}
