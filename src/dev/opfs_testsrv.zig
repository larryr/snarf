//! TEST-ONLY harness for the OPFS device (the `ninep/testsrv.zig` pattern from
//! phase 14a): the scripted browser backend (`Script`), the raw-pipe server
//! fixture (`Wire`) and the `drive` helper that answers outstanding `fsOp`
//! tickets until a reply appears. Split out of `opfs.zig` in phase 16a (pure
//! move) so the device file stays inside the ~400-line cap; every test that
//! uses these stayed where it was, in `opfs.zig`.
const std = @import("std");
const ninep = @import("ninep");
const shim = @import("shim");
const opfs = @import("opfs.zig");

const DevOpfs = opfs.DevOpfs;
const Requester = opfs.Requester;
const Server = ninep.server.Server;
const msg = ninep.msg;
const FsRecord = shim.abi.FsRecord;
const testing = std.testing;

/// The scripted backend the tests plug in for the browser: it RECORDS every
/// record it is handed and answers nothing until a test says so, which is what
/// makes park/complete ordering observable.
pub const Script = struct {
    alloc: std.mem.Allocator,
    dev: *DevOpfs = undefined,
    log: std.ArrayList([]u8) = .empty,
    tickets: std.ArrayList(u32) = .empty,

    pub fn requester(self: *Script) Requester {
        return .{ .ctx = self, .issue = issue };
    }

    pub fn issue(ctx: ?*anyopaque, ticket: u32, record: []const u8) void {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        self.log.append(self.alloc, self.alloc.dupe(u8, record) catch return) catch return;
        self.tickets.append(self.alloc, ticket) catch return;
    }

    pub fn deinit(self: *Script) void {
        for (self.log.items) |r| self.alloc.free(r);
        self.log.deinit(self.alloc);
        self.tickets.deinit(self.alloc);
    }

    pub fn last(self: *Script) FsRecord {
        return FsRecord.decode(self.log.items[self.log.items.len - 1]) catch unreachable;
    }

    pub fn answer(self: *Script, i: usize, status: FsRecord.Status, payload: []const u8) void {
        self.dev.complete(self.tickets.items[i], status, payload);
    }
};

// ===========================================================================
// Named battery T2-T11 (phase-14b contract §4), the test-writer's own — over
// a REAL chan.Pipe + Server, driven by hand (no `ninep.Client`/`tickets`: a
// blocking `Client.rpc` against this tree pumps forever the moment an op
// parks, since nothing but an explicit `retryParked` ever answers it). The
// harness below is `dev/input.zig`'s Harness pattern (send once, `recv`
// reports `null` on a parked op instead of blocking), generalised with a
// `drive` helper that answers outstanding `fsOp` tickets — via the `Script`
// requester above — until a reply appears or the test's answer list runs out.
// ===========================================================================

/// One scripted answer for the NEXT outstanding `fsOp` ticket that `drive`
/// hands to `Script.answer`, in the order a chain of round trips needs them
/// (e.g. OTRUNC's `stat` then `truncate`).
pub const Answer = struct { status: FsRecord.Status, payload: []const u8 = &.{} };

const chan = ninep.chan;

/// Heap-pinned raw-pipe harness (no `Client`): `send` writes one T-frame and
/// runs exactly one `Server.step`; `recv` reports `null` on a parked op
/// (`WouldBlock`) rather than spinning. Plugs in whatever `Requester` the test
/// wants — the scripted `Script` for most tests, an auto-answering one for T10.
pub const Wire = struct {
    alloc: std.mem.Allocator,
    pipe: *chan.Pipe,
    dev: DevOpfs,
    srv: Server,
    rbuf: [16384]u8 = undefined,
    tag: u16 = 0,

    pub fn create(alloc: std.mem.Allocator, req: Requester) !*Wire {
        const self = try alloc.create(Wire);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .pipe = try chan.Pipe.init(alloc, 65536),
            .dev = DevOpfs.init(alloc, req),
            .srv = undefined,
        };
        self.srv = try Server.init(alloc, self.pipe.serverEnd(), &DevOpfs.ops, &self.dev, 8192);
        return self;
    }

    pub fn destroy(self: *Wire) void {
        self.srv.deinit();
        self.dev.deinit();
        self.pipe.deinit();
        self.alloc.destroy(self);
    }

    pub fn nextTag(self: *Wire) u16 {
        self.tag += 1;
        return self.tag;
    }

    pub fn send(self: *Wire, m: msg.Message) !void {
        var enc: [8192]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        try self.pipe.clientEnd().writeMsg(enc[0..n]);
        _ = try self.srv.step();
    }

    /// One decoded reply, or `null` when the op parked and nothing came back.
    pub fn recv(self: *Wire) !?msg.Message {
        const frame = self.pipe.clientEnd().readMsg(&self.rbuf) catch |e| switch (e) {
            error.WouldBlock => return null,
            else => return e,
        };
        return try msg.decode(frame);
    }

    /// Tversion + Tattach; asserts the mount's one unparking op (R-P14b-2).
    pub fn connect(self: *Wire) !void {
        try self.send(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect((try self.recv()).?.body == .rversion);
        try self.send(.{ .tag = self.nextTag(), .body = .{ .tattach = .{ .fid = 0, .afid = msg.NOFID, .uname = "larry", .aname = "" } } });
        try testing.expect((try self.recv()).?.body == .rattach);
    }
};

/// Send `m` on `h`; while no reply is ready, hand the newest outstanding
/// `fsOp` ticket the next entry of `answers` and re-dispatch. `error.NoReply`
/// if `answers` runs out first — the op needed more round trips than expected.
pub fn drive(h: *Wire, sc: *Script, m: msg.Message, answers: []const Answer) !msg.Message {
    try h.send(m);
    var i: usize = 0;
    while (true) {
        if (try h.recv()) |r| return r;
        if (i >= answers.len) return error.NoReply;
        const t = sc.tickets.items.len - 1;
        sc.answer(t, answers[i].status, answers[i].payload);
        i += 1;
        _ = try h.srv.retryParked();
    }
}
