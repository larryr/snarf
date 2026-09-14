//! TEST-ONLY harness for devdraw (the `ninep/testsrv.zig` / `dev/opfs_testsrv.zig`
//! pattern): the hand-encoded verb-byte builders and the `chan.Pipe` + `Server`
//! + `HeadlessBackend` fixture the §D 10-17 battery drives. Split out of
//! `draw.zig` in phase 16a (pure move) so the device file stays inside the
//! ~400-line cap; every test stayed where it was, in `draw.zig`.
//!
//! Deliberately NO dependency on `src/draw` (G7 independence).
const std = @import("std");
const ninep = @import("ninep");
const draw_backend = @import("draw_backend.zig");
const DevDraw = @import("draw.zig").DevDraw;

const Server = ninep.server.Server;
const msg = ninep.msg;
const Stat = ninep.stat;

// ===========================================================================
// Tests (§D 10-17). Hand-encoded draw frames over a chan.Pipe + Server +
// HeadlessBackend — deliberately NO dependency on src/draw (G7 independence).
// Frozen hash per R-P2-7: spot-checks are authoritative and verified first; the
// Wyhash literal is frozen only after they pass, with a scene comment.
// ===========================================================================

const testing = std.testing;
const chan = ninep.chan;

// -- local verb-byte builders (independent of src/draw/proto.zig, G7) --------

pub fn wU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
pub fn wRect(buf: []u8, off: usize, r: draw_backend.Rect) void {
    std.mem.writeInt(i32, buf[off + 0 ..][0..4], r.min.x, .little);
    std.mem.writeInt(i32, buf[off + 4 ..][0..4], r.min.y, .little);
    std.mem.writeInt(i32, buf[off + 8 ..][0..4], r.max.x, .little);
    std.mem.writeInt(i32, buf[off + 12 ..][0..4], r.max.y, .little);
}

/// Build a 51-byte 'b' (alloc) frame (G7).
pub fn buildB(buf: *[51]u8, id: u32, ch: u32, repl: bool, r: draw_backend.Rect, clipr: draw_backend.Rect, color: u32) void {
    buf[0] = 'b';
    wU32(buf, 1, id);
    wU32(buf, 5, 0); // screenid
    buf[9] = 0; // refresh = backup
    wU32(buf, 10, ch);
    buf[14] = @intFromBool(repl);
    wRect(buf, 15, r);
    wRect(buf, 31, clipr);
    wU32(buf, 47, color);
}

/// Build a 45-byte 'd' (draw) frame with sp = mp = origin (G7).
pub fn buildD(buf: *[45]u8, dstid: u32, srcid: u32, maskid: u32, r: draw_backend.Rect) void {
    buf[0] = 'd';
    wU32(buf, 1, dstid);
    wU32(buf, 5, srcid);
    wU32(buf, 9, maskid);
    wRect(buf, 13, r);
    @memset(buf[29..45], 0); // sp[8] + mp[8]
}

pub fn wU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}
pub fn wPoint(buf: []u8, off: usize, p: draw_backend.Point) void {
    std.mem.writeInt(i32, buf[off + 0 ..][0..4], p.x, .little);
    std.mem.writeInt(i32, buf[off + 4 ..][0..4], p.y, .little);
}

/// Build a 21-byte 'y' (load pixels) header; the caller appends the payload.
pub fn buildYHdr(buf: []u8, id: u32, r: draw_backend.Rect) void {
    buf[0] = 'y';
    wU32(buf, 1, id);
    wRect(buf, 5, r);
}

/// Build a 10-byte 'i' (init font) frame.
pub fn buildI(buf: *[10]u8, fontid: u32, nchars: u32, ascent: u8) void {
    buf[0] = 'i';
    wU32(buf, 1, fontid);
    wU32(buf, 5, nchars);
    buf[9] = ascent;
}

/// Build a 37-byte 'l' (load char) frame (left is a signed i8 @35).
pub fn buildL(buf: *[37]u8, fontid: u32, srcid: u32, index: u16, r: draw_backend.Rect, sp: draw_backend.Point, left: i8, width: u8) void {
    buf[0] = 'l';
    wU32(buf, 1, fontid);
    wU32(buf, 5, srcid);
    wU16(buf, 9, index);
    wRect(buf, 11, r);
    wPoint(buf, 27, sp);
    buf[35] = @bitCast(left);
    buf[36] = width;
}

/// Build a 's' (string) frame of 47 + 2·ni bytes into `buf`.
pub fn buildS(buf: []u8, dstid: u32, srcid: u32, fontid: u32, p: draw_backend.Point, clipr: draw_backend.Rect, sp: draw_backend.Point, indices: []const u16) void {
    buf[0] = 's';
    wU32(buf, 1, dstid);
    wU32(buf, 5, srcid);
    wU32(buf, 9, fontid);
    wPoint(buf, 13, p);
    wRect(buf, 21, clipr);
    wPoint(buf, 37, sp);
    wU16(buf, 45, @intCast(indices.len));
    for (indices, 0..) |ci, k| wU16(buf, 47 + 2 * k, ci);
}

pub const R = draw_backend.Rect;
pub const P = draw_backend.Point;
pub const unit = R.init(0, 0, 1, 1);
pub const repl_clipr = R.init(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF); // G10
pub const WHITE: u32 = 0xFFFFFFFF;
pub const RED: u32 = 0xFF0000FF;
pub const BLUE: u32 = 0x0000FFFF;

/// Heap-pinned harness: a Pipe + Server(DevDraw.ops) over a HeadlessBackend.
/// The backend and DevDraw must not move (the Server holds pointers to them).
pub const Harness = struct {
    alloc: std.mem.Allocator,
    pipe: *chan.Pipe,
    hb: draw_backend.HeadlessBackend,
    dd: DevDraw,
    srv: Server,
    rbuf: [1024]u8 = undefined,
    tag: u16 = 0,

    pub fn create(alloc: std.mem.Allocator, w: u32, h: u32) !*Harness {
        const self = try alloc.create(Harness);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.tag = 0;
        self.pipe = try chan.Pipe.init(alloc, 16384);
        self.hb = try draw_backend.HeadlessBackend.init(alloc, w, h);
        self.dd = DevDraw.init(alloc, self.hb.backend());
        self.srv = try Server.init(alloc, self.pipe.serverEnd(), &DevDraw.ops, &self.dd, 8192);
        return self;
    }

    pub fn destroy(self: *Harness) void {
        self.srv.deinit();
        self.dd.deinit();
        self.hb.deinit();
        self.pipe.deinit();
        self.alloc.destroy(self);
    }

    pub fn nextTag(self: *Harness) u16 {
        self.tag += 1;
        return self.tag;
    }

    /// Encode `m`, push it into the server, step once, decode the one reply.
    pub fn transact(self: *Harness, m: msg.Message) !msg.Message {
        var enc: [2048]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        try self.pipe.clientEnd().writeMsg(enc[0..n]);
        _ = try self.srv.step();
        const reply = try self.pipe.clientEnd().readMsg(&self.rbuf);
        return try msg.decode(reply);
    }

    pub fn version(self: *Harness) !void {
        const r = try self.transact(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect(r.body == .rversion);
    }

    pub fn attach(self: *Harness, fid: u32) !void {
        const r = try self.transact(.{ .tag = self.nextTag(), .body = .{ .tattach = .{ .fid = fid, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
        try testing.expect(r.body == .rattach);
    }

    pub fn walk(self: *Harness, fid: u32, newfid: u32, names: []const []const u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(fid, newfid, names) } });
    }

    pub fn open(self: *Harness, fid: u32, mode: u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .topen = .{ .fid = fid, .mode = mode } } });
    }

    pub fn write(self: *Harness, fid: u32, data: []const u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .twrite = .{ .fid = fid, .offset = 0, .data = data } } });
    }

    pub fn read(self: *Harness, fid: u32, offset: u64, count: u32) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .tread = .{ .fid = fid, .offset = offset, .count = count } } });
    }

    pub fn clunk(self: *Harness, fid: u32) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .tclunk = .{ .fid = fid } } });
    }

    pub fn stat(self: *Harness, fid: u32) !Stat {
        const r = try self.transact(.{ .tag = self.nextTag(), .body = .{ .tstat = .{ .fid = fid } } });
        try testing.expect(r.body == .rstat);
        return try Stat.decode(r.body.rstat.stat);
    }

    /// Bring up a live connection: version, attach root (fid 0), walk `new`
    /// (fid 1), open it (morphs to ctl). Returns with ctl on fid 1.
    pub fn connect(self: *Harness) !void {
        try self.version();
        try self.attach(0);
        const w = try self.walk(0, 1, &.{"new"});
        try testing.expect(w.body == .rwalk);
        const o = try self.open(1, msg.ORDWR);
        try testing.expect(o.body == .ropen);
    }

    /// Walk `1/data` (fid 2) and open it ORDWR, ready for draw batches.
    pub fn openData(self: *Harness) !void {
        const w = try self.walk(0, 2, &.{ "1", "data" });
        try testing.expect(w.body == .rwalk);
        const o = try self.open(2, msg.ORDWR);
        try testing.expect(o.body == .ropen);
    }
};
