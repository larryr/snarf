//! OriginMount — `/mnt/origin`, the browser's WebSocket 9P mount (R-P12-5/6/7).
//!
//! file-as-struct (S-07 P-1): this file *is* the mount. It owns one
//! `shim.WsTransport`, one `ninep.Client` over it, and the `/mnt/origin` entry
//! in the editor's `ninep.mount.Namespace`. It is a BOOT-GLUE type — it sees
//! both `ninep` and `shim`, which `core` may never do (S-07 §6) — so it lives in
//! its own module rather than in `core`, and `src/main_wasm.zig` is its only
//! production caller.
//!
//! ## Why a hand-driven handshake (ruling R-P12-B2-1)
//!
//! `ninep.Client`'s RPCs are SYNCHRONOUS: `version`/`attach`/`walk`/`open` send
//! a T-message and then loop on `readMsg`, resolving `WouldBlock` by running the
//! client's `Pump`. That works for an in-process server (the pump is the peer's
//! `poll`). It cannot work over a browser WebSocket: a reply only materializes
//! when the module RETURNS to the JS event loop and the shim calls `wsPush`, so
//! there is no pump that can produce one, and R-P12-4 forbids spin-waiting.
//!
//! So version+attach are driven HERE, one step per `poll()`, at the frame level
//! (`ninep.msg.encode`/`decode` straight onto the transport). When Rattach lands
//! the negotiated msize is written into the `Client` and `/mnt/origin` is bound;
//! from then on the `Client` owns the transport and callers use its ticket API
//! (`beginRead`/`checkRead`), the only async surface `ninep` offers today.
//!
//! GAP (reported, not patched): `ninep` has no async ticket for walk/open/clunk,
//! so nothing but a read can be driven over this transport yet. Reaching real
//! files from the UI (the next wave) needs either that ticket API or a resumable
//! RPC state machine in `client.zig`.
//!
//! ## Lifecycle
//!
//!   idle ──dial()──▶ dialing ──wsOpen──▶ versioning ──Rversion──▶ attaching
//!                                                     ──Rattach──▶ mounted
//!   any of dialing/versioning/attaching ──close|error|10 s──▶ down (mount absent)
//!   mounted ──close|error──▶ down (fids dead, `/mnt/origin` unbound)
//!
//! There is no automatic retry (R-P12-6): `Reconnect` calls `dial()` again, which
//! tears the old connection down and builds a FRESH transport (new connection id)
//! and a FRESH `Client` (fid numbering restarts at 0, so old fids stay dead).
//!
//! PINNED: `Client` captures `&self.ws`, so an `OriginMount` must not move after
//! `dial()`. `src/main_wasm.zig` keeps it inside the heap-allocated `App`.
const std = @import("std");
const ninep = @import("ninep");
const shim = @import("shim");

const OriginMount = @This();

const WsTransport = shim.WsTransport;
const Namespace = ninep.mount.Namespace;
const Client = ninep.Client;
const msg = ninep.msg;

/// Where the origin tree lands in the namespace (R-P12-5).
pub const mount_point = "/mnt/origin";

/// R-P12-5: a dial that has not produced Rattach within this many milliseconds
/// is abandoned and the mount is simply absent. Measured from the first `poll`
/// after `dial` (see `deadline_armed`) — boot itself never waits.
pub const dial_timeout_ms: u32 = 10_000;

/// Proposed msize, matching the in-process draw/input stacks. The origin server
/// offers 65536 and `version` takes the minimum.
pub const msize: u32 = 8192;

/// The user the browser attaches as. No auth in v1 (R-P12 deferred: `Tauth`
/// before any non-loopback bind).
pub const uname = "larry";

/// R-P12-6's wording for a socket that went away without saying why.
pub const closed_text = "websocket closed";

/// Where the connection is. `down` is terminal until the next `dial()`.
pub const Phase = enum { idle, dialing, versioning, attaching, mounted, down };

/// What `poll` observed this tick. Exactly one of these turns into exactly one
/// `ed.warning` line in the caller (R-P12-5/6/7); `none` is the common case.
pub const Event = union(enum) {
    /// Nothing changed.
    none,
    /// version+attach completed and `/mnt/origin` is bound.
    mounted,
    /// The dial never completed (timeout, refused, protocol violation). The
    /// mount is ABSENT and boot is otherwise identical (R-P12-5).
    failed: []const u8,
    /// A live mount died: `/mnt/origin` is unbound and every origin fid is dead
    /// (R-P12-6). No automatic redial.
    lost: []const u8,
};

allocator: std.mem.Allocator,
/// The editor's mount table; `/mnt/origin` is bound into and removed from it.
ns: *Namespace,
/// The current connection. Replaced wholesale by each `dial()`.
ws: WsTransport,
/// The 9P client over `ws`, created by `dial` and kept alive after a
/// disconnect so stale fids and outstanding tickets fail rather than dangle
/// (R-P12-6). Torn down only by the next `dial`/`deinit`.
client: ?Client = null,
/// The attach fid the mount resolves through; meaningless unless `mounted`.
root_fid: u32 = 0,
phase: Phase = .idle,
/// Next connection id. B1 ruling 6: a FRESH id per dial, so a late record from
/// a previous socket is rejected by `push` instead of relying on JS guards.
next_id: u32 = 1,
/// Dial deadline base, in `tick()` milliseconds.
started_ms: u32 = 0,
/// False until the first `poll` of a dial has stamped `started_ms`. The wasm
/// module has no clock of its own (freestanding: no `std.Io`, no OS): time
/// arrives only as `tick(now_ms)`, so the 10 s budget is measured from the
/// first animation frame after the dial, not from `dial()` itself.
deadline_armed: bool = false,
/// Negotiated msize from Rversion, written into the `Client` on Rattach.
neg_msize: u32 = 0,
/// Handshake scratch. Tversion/Rversion/Tattach/Rattach are all tiny; a real
/// 9P payload never travels through here (the `Client` owns the transport once
/// the mount is up).
hs: [256]u8 = undefined,
/// Why the connection ended, for the caller's warning line.
reason_buf: [128]u8 = undefined,
reason_len: usize = 0,

/// A mount bound to `ns`, not yet dialed. `ns` must outlive this value.
pub fn init(allocator: std.mem.Allocator, ns: *Namespace) OriginMount {
    return .{
        .allocator = allocator,
        .ns = ns,
        .ws = WsTransport.init(allocator, 0),
    };
}

/// Release the transport and the client. Leaves `ns` alone beyond removing our
/// own entry (the namespace clunks nothing — `mount.zig`'s contract R7).
pub fn deinit(self: *OriginMount) void {
    self.unbind();
    self.ws.close();
    self.ws.deinit();
    if (self.client) |*c| c.deinit();
    self.client = null;
}

/// Start (or restart) a connection: tear down whatever is live, mint a fresh
/// transport + client, and ask the shim to open the socket. Returns IMMEDIATELY
/// — boot never waits on the socket (R-P12-5) — so success or failure surfaces
/// later, from `poll`. This is also the `Reconnect` entry point (R-P12-7).
pub fn dial(self: *OriginMount) void {
    self.unbind();
    self.ws.close();
    self.ws.deinit();
    if (self.client) |*c| c.deinit();
    self.client = null;

    self.ws = WsTransport.init(self.allocator, self.next_id);
    self.next_id +%= 1;
    self.client = Client.init(
        self.allocator,
        self.ws.transport(ninep.transport.Transport),
        msize,
    ) catch {
        self.setReason("out of memory");
        self.phase = .down;
        return;
    };
    // The client must never pump: there is no peer to drive on this side of a
    // WebSocket, and a pump loop would spin forever (R-P12-4).
    self.client.?.pump = null;
    self.root_fid = self.client.?.allocFid();
    self.ws.dial();
    self.phase = .dialing;
    self.deadline_armed = false;
    self.reason_len = 0;
}

/// The inbound ABI entry (R-P12-2), forwarded from the `wsPush` export. Records
/// carrying a connection id that is not the live one are STALE — a socket this
/// mount has already walked away from — and are dropped.
pub fn push(self: *OriginMount, id: u32, kind: shim.abi.WsKind, bytes: []const u8) void {
    if (id != self.ws.id) return;
    // The only failure is OOM, which has already poisoned the connection; the
    // next `poll` reports it as a dead socket.
    self.ws.pushRecord(kind, bytes) catch {};
}

/// Advance the connection one step. Called once per `tick(now_ms)`; never
/// blocks, never spins, and does at most one frame of work.
pub fn poll(self: *OriginMount, now_ms: u32) Event {
    switch (self.phase) {
        .idle, .down => return .none,
        // A live mount: the `Client` drains its own transport, so all we watch
        // for is the socket dying under it (R-P12-6).
        .mounted => {
            if (self.ws.state() == .closed) return self.lose();
            return .none;
        },
        .dialing, .versioning, .attaching => {},
    }

    // The socket died mid-handshake: the mount is simply absent (R-P12-5).
    if (self.ws.state() == .closed) return self.fail(self.wsReason());

    if (!self.deadline_armed) {
        self.started_ms = now_ms;
        self.deadline_armed = true;
    } else if (now_ms -% self.started_ms >= dial_timeout_ms) {
        self.ws.close();
        return self.fail("timeout");
    }

    return switch (self.phase) {
        .dialing => self.stepDialing(),
        .versioning => self.stepVersioning(),
        .attaching => self.stepAttaching(),
        else => unreachable,
    };
}

/// Waiting for the shim's `onopen`. Once it lands, send Tversion.
fn stepDialing(self: *OriginMount) Event {
    if (!self.ws.isOpen()) return .none;
    self.send(.{ .tag = msg.NOTAG, .body = .{
        .tversion = .{ .msize = msize, .version = msg.version9p },
    } }) catch |e| return self.fail(@errorName(e));
    self.phase = .versioning;
    return .none;
}

/// Waiting for Rversion. On success send Tattach on tag 0.
fn stepVersioning(self: *OriginMount) Event {
    const m = (self.recv() catch |e| return self.fail(@errorName(e))) orelse return .none;
    if (m.tag != msg.NOTAG) return self.fail("bad Rversion tag");
    switch (m.body) {
        .rversion => |v| {
            if (!std.mem.eql(u8, v.version, msg.version9p)) return self.fail("9P version mismatch");
            self.neg_msize = @min(v.msize, msize);
        },
        .rerror => |e| return self.fail(e.ename),
        else => return self.fail("bad Rversion"),
    }
    self.send(.{ .tag = 0, .body = .{
        .tattach = .{ .fid = self.root_fid, .afid = msg.NOFID, .uname = uname, .aname = "" },
    } }) catch |e| return self.fail(@errorName(e));
    self.phase = .attaching;
    return .none;
}

/// Waiting for Rattach. On success adopt the negotiated session into the
/// `Client` and bind `/mnt/origin`.
fn stepAttaching(self: *OriginMount) Event {
    const m = (self.recv() catch |e| return self.fail(@errorName(e))) orelse return .none;
    if (m.tag != 0) return self.fail("bad Rattach tag");
    switch (m.body) {
        .rattach => {},
        .rerror => |e| return self.fail(e.ename),
        else => return self.fail("bad Rattach"),
    }
    // Adopt the hand-driven handshake into the Client (ruling R-P12-B2-1): the
    // only session state `version()` would have set that later ops depend on is
    // `msize` — `next_fid`/`next_tag` already start where a fresh session does,
    // and `fids` is only a qid cache `walk` falls back out of.
    const c = self.clientPtr().?;
    c.msize = self.neg_msize;
    self.ns.bind(mount_point, c, self.root_fid) catch |e| return self.fail(@errorName(e));
    self.phase = .mounted;
    self.reason_len = 0;
    return .mounted;
}

/// The live client, or null when nothing has been dialed. After a `lost` event
/// this still returns the DEAD client: every op on it fails `error.Closed`,
/// which is what R-P12-6 means by "every origin fid is dead".
pub fn clientPtr(self: *OriginMount) ?*Client {
    if (self.client) |*c| return c;
    return null;
}

/// True while `/mnt/origin` resolves.
pub fn isMounted(self: *const OriginMount) bool {
    return self.phase == .mounted;
}

/// Why the connection is down (empty when it never was).
pub fn reasonText(self: *const OriginMount) []const u8 {
    return self.reason_buf[0..self.reason_len];
}

// --- internals -------------------------------------------------------------

/// Encode one T-message straight onto the transport. `WouldBlock` cannot happen
/// here: every caller has already seen `isOpen()`.
fn send(self: *OriginMount, m: msg.Message) !void {
    var buf: [256]u8 = undefined;
    const n = try msg.encode(&m, &buf);
    try self.ws.writeMsg(buf[0..n]);
}

/// The next queued frame, decoded; null when nothing is ready (never parks,
/// R-P12-4).
fn recv(self: *OriginMount) !?msg.Message {
    const frame = self.ws.readMsg(&self.hs) catch |e| switch (e) {
        error.WouldBlock => return null,
        else => return e,
    };
    return msg.decode(frame) catch error.BadFrame;
}

/// A dial that never became a mount: nothing to unbind, nothing to keep.
fn fail(self: *OriginMount, why: []const u8) Event {
    self.setReason(why);
    self.phase = .down;
    self.ws.close();
    return .{ .failed = self.reasonText() };
}

/// A live mount whose socket died (R-P12-6): unbind, keep the dead client so
/// stale fids and outstanding tickets fail with `error.Closed`, never redial.
fn lose(self: *OriginMount) Event {
    self.setReason(self.wsReason());
    self.phase = .down;
    self.unbind();
    return .{ .lost = self.reasonText() };
}

/// The transport's own explanation, or R-P12-6's generic wording.
fn wsReason(self: *const OriginMount) []const u8 {
    const t = self.ws.reasonText();
    return if (t.len == 0) closed_text else t;
}

fn setReason(self: *OriginMount, why: []const u8) void {
    // `why` may alias `ws.reason_buf`, which nothing here rewrites before the
    // copy completes; a self-copy (reasonText passed back in) is a no-op memcpy
    // of the same bytes.
    const n = @min(why.len, self.reason_buf.len);
    std.mem.copyForwards(u8, self.reason_buf[0..n], why[0..n]);
    self.reason_len = n;
}

/// Remove `/mnt/origin` from the mount table.
///
/// GAP (reported, not patched): `ninep.mount.Namespace` has `mount`/`bind` but
/// no `unmount`, and R-P12-6 requires an unbind. Rather than widen a fenced
/// framework file mid-phase, this drops the entry through the table's own
/// public fields — exactly what a `Namespace.unmount(prefix)` would do (free the
/// owned prefix, remove the row). The framework should grow that method before a
/// SECOND runtime-managed mount exists.
fn unbind(self: *OriginMount) void {
    const ns = self.ns;
    for (ns.entries.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.prefix, mount_point)) {
            ns.allocator.free(e.prefix);
            _ = ns.entries.orderedRemove(i);
            return;
        }
    }
}

// ===========================================================================
// Tests (R-P12-9a) — a scripted browser: `abi.is_wasm` is false natively, so
// `WsTransport`'s outbound half lands in the `abi.test_ws_*` seams and the
// inbound half is whatever `push` is handed. No socket, no shim, no origin.
// ===========================================================================
const testing = std.testing;

/// Encode one R-message the way the origin server would have framed it, and
/// hand it to the mount as a `.data` record.
fn feed(om: *OriginMount, m: msg.Message) !void {
    var buf: [256]u8 = undefined;
    const n = try msg.encode(&m, &buf);
    om.push(om.ws.id, .data, buf[0..n]);
}

/// Drive `dial → open → Rversion → Rattach`, asserting the mount comes up.
fn bringUp(om: *OriginMount, now: u32) !void {
    om.dial();
    om.push(om.ws.id, .open, "");
    try testing.expectEqual(Event.none, om.poll(now)); // sends Tversion
    try feed(om, .{ .tag = msg.NOTAG, .body = .{
        .rversion = .{ .msize = 8192, .version = msg.version9p },
    } });
    try testing.expectEqual(Event.none, om.poll(now)); // sends Tattach
    try feed(om, .{ .tag = 0, .body = .{
        .rattach = .{ .qid = .{ .path = 1, .qtype = .{ .dir = true } } },
    } });
    try testing.expect(om.poll(now) == .mounted);
}

test "origin: a dial that never completes leaves the namespace working" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    // Something else is mounted; the origin's absence must not disturb it.
    var other: Client = undefined;
    try ns.mount("/dev", &other, 3);

    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();
    om.dial();

    // The socket never opens. Ticks pass, nothing happens, boot is unaffected.
    var t: u32 = 1000;
    while (t < 1000 + dial_timeout_ms) : (t += 16) {
        try testing.expectEqual(Event.none, om.poll(t));
    }
    try testing.expectEqual(Phase.dialing, om.phase);

    // At the deadline the mount is abandoned with ONE reason, and stays down.
    const ev = om.poll(1000 + dial_timeout_ms);
    try testing.expect(ev == .failed);
    try testing.expectEqualStrings("timeout", ev.failed);
    try testing.expectEqual(Phase.down, om.phase);
    try testing.expectEqual(Event.none, om.poll(1_000_000));

    // `/mnt/origin` is absent; the rest of the namespace still resolves.
    try testing.expectError(error.NotMounted, ns.resolve("/mnt/origin/version"));
    try testing.expectEqualStrings("/dev", (try ns.resolve("/dev/mouse")).entry.prefix);
}

test "origin: the deadline is measured from the first tick, not from dial" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    // The page has been open a while: the first tick already reads 90 s.
    om.dial();
    try testing.expectEqual(Event.none, om.poll(90_000));
    try testing.expectEqual(Event.none, om.poll(90_000 + dial_timeout_ms - 1));
    try testing.expect(om.poll(90_000 + dial_timeout_ms) == .failed);
}

test "origin: a refused dial is one warning and an absent mount" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    om.dial();
    om.push(om.ws.id, .err, "connection refused");
    const ev = om.poll(10);
    try testing.expect(ev == .failed);
    try testing.expectEqualStrings("connection refused", ev.failed);
    try testing.expectError(error.NotMounted, ns.resolve("/mnt/origin"));
}

test "origin: version+attach binds /mnt/origin" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    try bringUp(&om, 100);
    try testing.expect(om.isMounted());

    const r = try ns.resolve("/mnt/origin/version");
    try testing.expectEqualStrings("/mnt/origin", r.entry.prefix);
    try testing.expectEqualStrings("version", r.remainder);
    try testing.expectEqual(om.clientPtr().?, r.entry.target.client);
    try testing.expectEqual(om.root_fid, r.entry.target.root_fid);
    // The negotiated msize was adopted into the Client (ruling R-P12-B2-1).
    try testing.expectEqual(@as(u32, 8192), om.clientPtr().?.msize);
}

test "origin: the handshake sends Tversion then Tattach, and never parks" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    om.dial();
    // Nothing is sent before the socket opens, and polling is a cheap no-op.
    try testing.expectEqual(Event.none, om.poll(1));
    try testing.expectEqual(Phase.dialing, om.phase);

    om.push(om.ws.id, .open, "");
    try testing.expectEqual(Event.none, om.poll(2));
    try testing.expectEqual(Phase.versioning, om.phase);
    // A poll with no reply queued stays put — no spin, no park (R-P12-4).
    try testing.expectEqual(Event.none, om.poll(3));
    try testing.expectEqual(Phase.versioning, om.phase);

    try feed(&om, .{ .tag = msg.NOTAG, .body = .{
        .rversion = .{ .msize = 65536, .version = msg.version9p },
    } });
    try testing.expectEqual(Event.none, om.poll(4));
    try testing.expectEqual(Phase.attaching, om.phase);
    // The server offered more than we proposed: the minimum wins.
    try testing.expectEqual(@as(u32, msize), om.neg_msize);
}

test "origin: a server that cannot speak 9P2000 fails the mount" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    om.dial();
    om.push(om.ws.id, .open, "");
    _ = om.poll(1);
    try feed(&om, .{ .tag = msg.NOTAG, .body = .{
        .rversion = .{ .msize = 8192, .version = "unknown" },
    } });
    const ev = om.poll(2);
    try testing.expect(ev == .failed);
    try testing.expectEqualStrings("9P version mismatch", ev.failed);
}

test "origin: an Rerror to Tattach fails the mount with the server's text" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    om.dial();
    om.push(om.ws.id, .open, "");
    _ = om.poll(1);
    try feed(&om, .{ .tag = msg.NOTAG, .body = .{
        .rversion = .{ .msize = 8192, .version = msg.version9p },
    } });
    _ = om.poll(2);
    try feed(&om, .{ .tag = 0, .body = .{ .rerror = .{ .ename = "permission denied" } } });
    const ev = om.poll(3);
    try testing.expect(ev == .failed);
    try testing.expectEqualStrings("permission denied", ev.failed);
    try testing.expectError(error.NotMounted, ns.resolve("/mnt/origin"));
}

test "origin: a disconnect fails outstanding tickets, kills fids, unbinds" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    try bringUp(&om, 100);
    const c = om.clientPtr().?;

    // An outstanding read on the mount, still waiting for its Rread.
    var buf: [64]u8 = undefined;
    const ticket = try c.beginRead(om.root_fid, 0, &buf);
    try testing.expectEqual(@as(?usize, null), try c.checkRead(ticket));

    // The socket goes away.
    om.push(om.ws.id, .close, "1006 abnormal closure");
    const ev = om.poll(200);
    try testing.expect(ev == .lost);
    try testing.expectEqualStrings("1006 abnormal closure", ev.lost);

    // R-P12-6: the mount is gone...
    try testing.expectError(error.NotMounted, ns.resolve("/mnt/origin/version"));
    // ...the outstanding ticket fails...
    try testing.expectError(error.Closed, c.checkRead(ticket));
    // ...and every origin fid is dead, however it is touched.
    try testing.expectError(error.Closed, c.walk(om.root_fid, &.{"version"}));
    try testing.expectError(error.Closed, c.open(om.root_fid, ninep.msg.OREAD));
    try testing.expectError(error.Closed, c.clunk(om.root_fid));
    // No automatic redial: it stays down until Reconnect.
    try testing.expectEqual(Event.none, om.poll(300));
    try testing.expectEqual(Phase.down, om.phase);
}

test "origin: a close with no reason still explains itself" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    try bringUp(&om, 1);
    om.push(om.ws.id, .close, "");
    const ev = om.poll(2);
    try testing.expect(ev == .lost);
    try testing.expectEqualStrings(closed_text, ev.lost);
}

test "origin: Reconnect re-dials on a fresh connection and re-binds" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    try bringUp(&om, 10);
    const first_id = om.ws.id;
    om.push(om.ws.id, .close, "1001 going away");
    try testing.expect(om.poll(20) == .lost);

    // Reconnect: a fresh id, fresh fids, and the mount comes back.
    try bringUp(&om, 30);
    try testing.expect(om.ws.id != first_id);
    try testing.expect(om.isMounted());
    const r = try ns.resolve("/mnt/origin/version");
    try testing.expectEqualStrings("version", r.remainder);
    try testing.expectEqual(om.clientPtr().?, r.entry.target.client);

    // Exactly one `/mnt/origin` row: the re-bind replaced, it did not stack.
    var seen: usize = 0;
    for (ns.entries.items) |e| {
        if (std.mem.eql(u8, e.prefix, mount_point)) seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
}

test "origin: Reconnect on a live mount replaces it" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    try bringUp(&om, 10);
    // No disconnect first: Reconnect closes the live socket itself (R-P12-7).
    om.dial();
    try testing.expectError(error.NotMounted, ns.resolve("/mnt/origin"));
    try testing.expectEqual(Phase.dialing, om.phase);
    om.push(om.ws.id, .open, "");
    _ = om.poll(11);
    try feed(&om, .{ .tag = msg.NOTAG, .body = .{
        .rversion = .{ .msize = 8192, .version = msg.version9p },
    } });
    _ = om.poll(12);
    try feed(&om, .{ .tag = 0, .body = .{ .rattach = .{ .qid = .{ .path = 1, .qtype = .{ .dir = true } } } } });
    try testing.expect(om.poll(13) == .mounted);
}

test "origin: a record from a stale connection id is dropped" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    om.dial();
    const stale = om.ws.id -% 1;
    om.push(stale, .open, ""); // a leftover handler from a previous socket
    try testing.expectEqual(Event.none, om.poll(1));
    try testing.expectEqual(Phase.dialing, om.phase); // still waiting for OUR open
    om.push(om.ws.id, .open, "");
    try testing.expectEqual(Event.none, om.poll(2));
    try testing.expectEqual(Phase.versioning, om.phase);
}

test "origin: a malformed frame poisons the connection instead of desyncing" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    om.dial();
    om.push(om.ws.id, .open, "");
    _ = om.poll(1);
    om.push(om.ws.id, .data, &.{ 99, 0, 0, 0, 101, 0, 0 }); // size[4] != len
    const ev = om.poll(2);
    try testing.expect(ev == .failed);
    try testing.expectEqual(Phase.down, om.phase);
    try testing.expectError(error.NotMounted, ns.resolve("/mnt/origin"));
}
