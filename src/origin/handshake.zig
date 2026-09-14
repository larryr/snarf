//! The origin mount's hand-driven 9P handshake — one step per `poll()`
//! (`dialing → versioning → attaching → binding`), plus the frame-level `send`
//! and `recv` those steps run on. Namespace module (S-07 P-1, lowercase);
//! carved out of `OriginMount.zig` in phase 12e, which keeps the lifecycle
//! (`dial`/`push`/`poll`, `fail`/`lose`/`unbind`, the `Phase`/`Event` types and
//! every constant) and dispatches here from `poll`.
//!
//! WHY the handshake is hand-driven at all — `ninep.Client`'s RPCs are
//! synchronous and there is no pump on this side of a WebSocket — is recorded in
//! `OriginMount.zig`'s header (ruling R-P12-B2-1), along with the invariant this
//! file depends on: while these steps run, the mount is the SOLE reader of the
//! transport, so a raw `recv()` cannot steal a frame from the `Client`. After
//! `stepBinding` succeeds the `Client` owns the transport and nothing here may
//! read a frame again.
//!
//! Ported behavior is 9P2000 proper: `9/port/devmnt.c` + `intro(5)`/`version(5)`/
//! `attach(5)`/`walk(5)`.
const std = @import("std");
const ninep = @import("ninep");
const OriginMount = @import("OriginMount.zig");

const msg = ninep.msg;
const Event = OriginMount.Event;
const msize = OriginMount.msize;
const uname = OriginMount.uname;
const bin_name = OriginMount.bin_name;
const mount_point = OriginMount.mount_point;
const bin_point = OriginMount.bin_point;

/// Waiting for the shim's `onopen`. Once it lands, send Tversion.
pub fn stepDialing(self: *OriginMount) Event {
    if (!self.ws.isOpen()) return .none;
    send(self, .{ .tag = msg.NOTAG, .body = .{
        .tversion = .{ .msize = msize, .version = msg.version9p },
    } }) catch |e| return self.fail(@errorName(e));
    self.phase = .versioning;
    return .none;
}

/// Waiting for Rversion. On success send Tattach on tag 0.
pub fn stepVersioning(self: *OriginMount) Event {
    const m = (recv(self) catch |e| return self.fail(@errorName(e))) orelse return .none;
    if (m.tag != msg.NOTAG) return self.fail("bad Rversion tag");
    switch (m.body) {
        .rversion => |v| {
            if (!std.mem.eql(u8, v.version, msg.version9p)) return self.fail("9P version mismatch");
            self.neg_msize = @min(v.msize, msize);
        },
        .rerror => |e| return self.fail(e.ename),
        else => return self.fail("bad Rversion"),
    }
    send(self, .{ .tag = 0, .body = .{
        .tattach = .{ .fid = self.root_fid, .afid = msg.NOFID, .uname = uname, .aname = "" },
    } }) catch |e| return self.fail(@errorName(e));
    self.phase = .attaching;
    return .none;
}

/// Waiting for Rattach. On success adopt the negotiated session into the
/// `Client`, then ask for the origin's `bin` directory (Twalk on tag 0, one
/// component) before binding anything.
pub fn stepAttaching(self: *OriginMount) Event {
    const m = (recv(self) catch |e| return self.fail(@errorName(e))) orelse return .none;
    if (m.tag != 0) return self.fail("bad Rattach tag");
    const root_qid = switch (m.body) {
        .rattach => |a| a.qid,
        .rerror => |e| return self.fail(e.ename),
        else => return self.fail("bad Rattach"),
    };
    // Adopt the hand-driven handshake into the Client (ruling R-P12-B2-1): the
    // only session state `version()` would have set that later ops depend on is
    // `msize` — `next_fid`/`next_tag` already start where a fresh session does,
    // and `fids` is only a qid cache `walk` falls back out of. Seed that cache
    // with the root qid Rattach just gave us, so a later pure clone of the
    // mount's root fid knows it is a directory.
    const c = self.clientPtr().?;
    c.msize = self.neg_msize;
    c.seedQid(self.root_fid, root_qid);

    const bin_fid = c.allocFid();
    send(self, .{ .tag = 0, .body = .{
        .twalk = msg.Body.Twalk.init(self.root_fid, bin_fid, &.{bin_name}),
    } }) catch |e| {
        c.freeFid(bin_fid);
        return self.fail(@errorName(e));
    };
    self.bin_fid = bin_fid;
    self.phase = .binding;
    return .none;
}

/// Waiting for the `bin` Rwalk. Either way the mount comes up: an origin need
/// not export commands, so a walk that fails just leaves `/bin` alone
/// (contract §3c). A failed one-element Twalk leaves newfid untouched
/// server-side (5/walk), so the fid number is safe to recycle.
pub fn stepBinding(self: *OriginMount) Event {
    const m = (recv(self) catch |e| return self.fail(@errorName(e))) orelse return .none;
    if (m.tag != 0) return self.fail("bad Rwalk tag");
    const c = self.clientPtr().?;
    var have_bin = false;
    switch (m.body) {
        .rwalk => |w| have_bin = w.nwqid == 1 and w.wqid[0].qtype.dir,
        .rerror => {}, // no `bin` in this export
        else => return self.fail("bad Rwalk"),
    }
    if (!have_bin) {
        if (self.bin_fid) |f| c.freeFid(f);
        self.bin_fid = null;
    }

    self.ns.bind(mount_point, c, self.root_fid, .replace) catch |e| return self.fail(@errorName(e));
    if (self.bin_fid) |f| {
        // MAFTER: the origin's commands go at the END of the union, so a local
        // `/bin` member (when one exists) still wins (chan.c:744-753).
        self.ns.bind(bin_point, c, f, .after) catch |e| {
            self.ns.unmount(mount_point) catch {}; // all or nothing
            return self.fail(@errorName(e));
        };
    }
    self.phase = .mounted;
    self.reason_len = 0;
    return .mounted;
}

// --- frame I/O ---------------------------------------------------------------

/// Encode one T-message straight onto the transport. `WouldBlock` cannot happen
/// here: every caller has already seen `isOpen()`.
pub fn send(self: *OriginMount, m: msg.Message) !void {
    var buf: [256]u8 = undefined;
    const n = try msg.encode(&m, &buf);
    try self.ws.writeMsg(buf[0..n]);
}

/// The next queued frame, decoded; null when nothing is ready (never parks,
/// R-P12-4).
pub fn recv(self: *OriginMount) !?msg.Message {
    const frame = self.ws.readMsg(&self.hs) catch |e| switch (e) {
        error.WouldBlock => return null,
        else => return e,
    };
    return msg.decode(frame) catch error.BadFrame;
}

// ===========================================================================
// Tests. The handshake half of `OriginMount.zig`'s suite (names unchanged,
// phase 12e) plus the scripted-server helpers both halves share: `abi.is_wasm`
// is false natively, so `WsTransport`'s outbound half lands in the
// `abi.test_ws_*` seams and the inbound half is whatever `push` is handed.
// No socket, no shim, no origin.
// ===========================================================================
const testing = std.testing;
const Namespace = ninep.mount.Namespace;
const Phase = OriginMount.Phase;

/// Encode one R-message the way the origin server would have framed it, and
/// hand it to the mount as a `.data` record.
pub fn feed(om: *OriginMount, m: msg.Message) !void {
    var buf: [256]u8 = undefined;
    const n = try msg.encode(&m, &buf);
    om.push(om.ws.id, .data, buf[0..n]);
}

/// Rwalk for the `bin` lookup: `found` decides whether the export has one.
pub fn feedBinWalk(om: *OriginMount, found: bool) !void {
    if (found) {
        try feed(om, .{ .tag = 0, .body = .{
            .rwalk = msg.Body.Rwalk.init(&.{.{ .path = 2, .qtype = .{ .dir = true } }}),
        } });
    } else {
        try feed(om, .{ .tag = 0, .body = .{ .rerror = .{ .ename = "does not exist" } } });
    }
}

/// Drive `dial → open → Rversion → Rattach → Rwalk(bin)`, asserting the mount
/// comes up with the origin's `bin` in the `/bin` union.
pub fn bringUp(om: *OriginMount, now: u32) !void {
    try bringUpBin(om, now, true);
}

/// `bringUp` with control over whether the export has a `bin` directory.
pub fn bringUpBin(om: *OriginMount, now: u32, has_bin: bool) !void {
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
    try testing.expectEqual(Event.none, om.poll(now)); // sends Twalk bin
    try feedBinWalk(om, has_bin);
    try testing.expect(om.poll(now) == .mounted);
}

test "origin: version+attach binds /n/origin and unions the origin bin into /bin (T14)" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    try bringUp(&om, 100);
    try testing.expect(om.isMounted());

    const r = try ns.resolve("/n/origin/version");
    try testing.expectEqualStrings("/n/origin", r.entry.prefix);
    try testing.expectEqualStrings("version", r.remainder);
    try testing.expectEqual(om.clientPtr().?, r.entry.first().client);
    try testing.expectEqual(om.root_fid, r.entry.first().root_fid);
    // The negotiated msize was adopted into the Client (ruling R-P12-B2-1).
    try testing.expectEqual(@as(u32, 8192), om.clientPtr().?.msize);

    // ...and the origin's `bin` is the one (MAFTER) member of `/bin`.
    const b = try ns.resolve("/bin");
    try testing.expectEqual(@as(usize, 1), b.entry.targets.items.len);
    try testing.expectEqual(om.bin_fid.?, b.entry.first().root_fid);
    try testing.expectEqual(ninep.mount.BindFlag.after, b.entry.first().flag);
}

test "origin: an export without bin mounts anyway and leaves /bin untouched (T14)" {
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();
    var om = OriginMount.init(testing.allocator, &ns);
    defer om.deinit();

    try bringUpBin(&om, 100, false);
    try testing.expect(om.isMounted());
    try testing.expectEqual(@as(?u32, null), om.bin_fid);
    try testing.expectEqualStrings("/n/origin", (try ns.resolve("/n/origin")).entry.prefix);
    try testing.expectError(error.NotMounted, ns.resolve("/bin"));
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
    try testing.expectError(error.NotMounted, ns.resolve("/n/origin"));
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
    try testing.expectError(error.NotMounted, ns.resolve("/n/origin"));
}
