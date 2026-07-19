//! devdraw — the Plan 9 `/dev/draw` device, served over 9P.
//!
//! This is a faithful restructuring of the kernel driver `9/port/devdraw.c`:
//! the tree root *is* the draw directory (`/new`, `/1/{ctl,data,refresh}`),
//! opening `new` morphs the fid into the connection's ctl file
//! (devdraw.c:1056-1061), reading ctl yields the 144-byte connection line
//! (devdraw.c:1197-1204), and every write to `data` is a batch of concatenated
//! draw messages fed through the `drawmesg` verb loop (devdraw.c:1457-1466).
//! The actual compositing lives behind a `draw_backend.Backend` vtable — this
//! file only parses the little-endian wire (G1/G7) and maps faults.
//!
//! Imports: std, ninep (the 9P framework), and the file-local backend. No shim
//! and no `src/draw` — devdraw is a server, wholly independent of the draw
//! client (S-07 §6, R-P2-6). Rulings applied: R-P2-4 (fault table via one
//! `opError`), R-P2-6 (tree shape, single exclusive connection).
const std = @import("std");
const ninep = @import("ninep");
const draw_backend = @import("draw_backend.zig");

const Server = ninep.server.Server;
const Fid = ninep.server.Fid;
const Qid = ninep.Qid;
const OpError = ninep.errors.OpError;
const Stat = ninep.stat;
const msg = ninep.msg;

/// The fixed size of a draw connection line (G8, devdraw.c:1197-1204).
pub const conn_line_len: usize = 144;

/// Draw connection number. The kernel hands out `++sdraw.clientid` per client
/// (devdraw.c:805, G3); Phase 2 serves exactly one connection, numbered 1.
const conn_number: u64 = 1;

/// Tree nodes, addressed by `qid.path`. Connection nodes carry the connection
/// number in the high bits: `path = (conn_number << 4) | node` (R-P2-6). The
/// `new` clone-point and the root live at connection 0.
const Node = enum(u4) {
    root = 0,
    new = 1,
    conn = 2, // the "1" directory
    ctl = 3,
    data = 4,
    refresh = 5,
};

fn qidFor(node: Node) Qid {
    const conn: u64 = switch (node) {
        .root, .new => 0,
        else => conn_number,
    };
    const is_dir = node == .root or node == .conn;
    return .{ .path = (conn << 4) | @intFromEnum(node), .qtype = .{ .dir = is_dir } };
}

fn nodeOf(path: u64) Node {
    return @enumFromInt(@as(u4, @intCast(path & 0xF)));
}

// ===========================================================================
// DevDraw — one exclusive connection over a Backend.
// ===========================================================================

pub const DevDraw = struct {
    allocator: std.mem.Allocator,
    backend: draw_backend.Backend,
    /// The single connection's ctl file has been opened and not yet released.
    /// Guards exclusivity (devdraw.c:1064 `if(cl->busy) error(Einuse)`).
    busy: bool = false,
    /// Number of open ctl fids; when it falls to 0 the connection resets.
    open_count: u32 = 0,
    /// Image ids allocated on this connection since it opened, so a clunk-reset
    /// can free them (devdraw.c drawfreeclient teardown; R-P2-6).
    allocated: std.ArrayListUnmanaged(u32) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, backend: draw_backend.Backend) Self {
        return .{ .allocator = allocator, .backend = backend };
    }

    pub fn deinit(self: *Self) void {
        self.allocated.deinit(self.allocator);
        self.* = undefined;
    }

    fn devOf(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    // -- connection line (G8) ------------------------------------------------

    /// Format the 144-byte connection line: 12 fields, each a value
    /// right-justified in 11 columns followed by one space, no newline
    /// (devdraw.c:1197-1204). Field order: clientid, infoid(0), chan string,
    /// repl(0), r×4, clipr×4. Values come from `backend.displayInfo()`.
    fn connLine(self: *Self, out: *[conn_line_len]u8) void {
        const di = self.backend.displayInfo();
        var pos: usize = 0;
        var tmp: [16]u8 = undefined;
        putIntField(out, &pos, &tmp, 1); // clientid = N = 1 (G3)
        putIntField(out, &pos, &tmp, 0); // infoid
        putStrField(out, &pos, chanToStr(di.chan)); // display chan
        putIntField(out, &pos, &tmp, 0); // repl
        putIntField(out, &pos, &tmp, di.r.min.x);
        putIntField(out, &pos, &tmp, di.r.min.y);
        putIntField(out, &pos, &tmp, di.r.max.x);
        putIntField(out, &pos, &tmp, di.r.max.y);
        putIntField(out, &pos, &tmp, di.clipr.min.x);
        putIntField(out, &pos, &tmp, di.clipr.min.y);
        putIntField(out, &pos, &tmp, di.clipr.max.x);
        putIntField(out, &pos, &tmp, di.clipr.max.y);
        std.debug.assert(pos == conn_line_len);
    }

    // -- verb dispatch (G1/G5/G7, devdraw.c:1457-1466) -----------------------

    /// Walk the batch of concatenated draw messages in one `data` write.
    /// Per verb: check the remaining bytes cover the fixed message size (else
    /// `ShortDraw`, G5), parse little-endian fields (G1/G7), call the backend.
    /// A fault stops the loop; ops already applied stay applied (G6 — no
    /// rollback). Backend faults funnel through the single `opError` table.
    fn dispatch(self: *Self, data: []const u8) OpError!void {
        var i: usize = 0;
        while (i < data.len) {
            const a = data[i..];
            switch (a[0]) {
                // 'b' — alloc: id[4]@1 screenid[4]@5 refresh[1]@9 chan[4]@10
                //   repl[1]@14 r[16]@15 clipr[16]@31 color[4]@47 (devdraw.c:1467).
                'b' => {
                    if (a.len < 51) return error.ShortDraw;
                    const id = rdU32(a, 1);
                    if (rdU32(a, 5) != 0) return error.BadDraw; // no screens in Phase 2
                    const ch = rdU32(a, 10);
                    const repl = a[14] != 0;
                    const r = rdRect(a, 15);
                    const clipr = rdRect(a, 31);
                    const color = rdU32(a, 47);
                    self.backend.allocImage(id, r, ch, repl, clipr, color) catch |e| return opError(e);
                    self.allocated.append(self.allocator, id) catch return error.IoError;
                    i += 51;
                },
                // 'd' — draw: dstid[4]@1 srcid[4]@5 maskid[4]@9 r[16]@13 sp[8]@29
                //   mp[8]@37; always SoverD in Phase 2 (devdraw.c:1578).
                'd' => {
                    if (a.len < 45) return error.ShortDraw;
                    const dstid = rdU32(a, 1);
                    const srcid = rdU32(a, 5);
                    const maskid = rdU32(a, 9);
                    const r = rdRect(a, 13);
                    const sp = rdPoint(a, 29);
                    const mp = rdPoint(a, 37);
                    self.backend.draw(dstid, srcid, maskid, r, sp, mp) catch |e| return opError(e);
                    i += 45;
                },
                // 'f' — free: id[4]@1 (devdraw.c:1640).
                'f' => {
                    if (a.len < 5) return error.ShortDraw;
                    const id = rdU32(a, 1);
                    self.backend.freeImage(id) catch |e| return opError(e);
                    self.forget(id);
                    i += 5;
                },
                // 'v' — visible/flush: bare byte (devdraw.c:2075).
                'v' => {
                    self.backend.flush();
                    i += 1;
                },
                else => return error.BadDraw, // unknown verb (devdraw.c:1462 "bad draw command")
            }
        }
    }

    /// Drop `id` from the reset list (called after a successful backend free so
    /// a later clunk-reset does not double-free it).
    fn forget(self: *Self, id: u32) void {
        for (self.allocated.items, 0..) |v, idx| {
            if (v == id) {
                _ = self.allocated.swapRemove(idx);
                return;
            }
        }
    }

    /// Release everything allocated on this connection and mark it idle. Mirrors
    /// the per-client teardown when the last ctl fid clunks (R-P2-6). Backend
    /// free errors are ignored — teardown is best-effort.
    fn reset(self: *Self) void {
        for (self.allocated.items) |id| self.backend.freeImage(id) catch {};
        self.allocated.clearRetainingCapacity();
        self.busy = false;
    }

    // -- Ops vtable (exact phase-1 signatures, R8) ---------------------------

    pub const ops: ninep.server.Ops = .{
        .attach = attachOp,
        .walk1 = walk1Op,
        .open = openOp,
        .read = readOp,
        .write = writeOp,
        .clunk = clunkOp,
        .stat = statOp,
    };

    fn attachOp(_: *anyopaque, _: *Server, _: *Fid, _: []const u8) OpError!Qid {
        return qidFor(.root);
    }

    fn walk1Op(_: *anyopaque, _: *Server, fid: *Fid, name: []const u8) OpError!Qid {
        const eq = std.mem.eql;
        if (eq(u8, name, "..")) return qidFor(.root); // conn→root, root→root
        return switch (nodeOf(fid.qid.path)) {
            .root => if (eq(u8, name, "new"))
                qidFor(.new)
            else if (eq(u8, name, "1"))
                qidFor(.conn)
            else
                error.FileDoesNotExist,
            .conn => if (eq(u8, name, "ctl"))
                qidFor(.ctl)
            else if (eq(u8, name, "data"))
                qidFor(.data)
            else if (eq(u8, name, "refresh"))
                qidFor(.refresh)
            else
                error.FileDoesNotExist,
            else => error.FileDoesNotExist,
        };
    }

    fn openOp(ctx: *anyopaque, _: *Server, fid: *Fid, mode: u8) OpError!Qid {
        const self = devOf(ctx);
        switch (nodeOf(fid.qid.path)) {
            // Opening `new` allocates a connection and morphs the fid into its
            // ctl file (devdraw.c:1056-1061). We serve one connection, so a busy
            // one refuses; otherwise this open *is* the ctl open.
            .new => {
                if (self.busy) return error.PermissionDenied;
                self.busy = true;
                self.open_count += 1;
                const q = qidFor(.ctl);
                fid.qid = q; // the framework reports the returned qid in Ropen
                return q;
            },
            .ctl => {
                if (self.busy) return error.PermissionDenied; // Einuse
                self.busy = true;
                self.open_count += 1;
                return fid.qid;
            },
            // data/refresh only exist once the connection is live.
            .data => {
                if (!self.busy) return error.PermissionDenied;
                return fid.qid;
            },
            .refresh => {
                if (!self.busy) return error.PermissionDenied;
                if ((mode & 3) == msg.OWRITE or (mode & 3) == msg.ORDWR) return error.PermissionDenied;
                return fid.qid;
            },
            .root, .conn => return fid.qid, // directory read
        }
    }

    fn readOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, buf: []u8) OpError!usize {
        const self = devOf(ctx);
        switch (nodeOf(fid.qid.path)) {
            .ctl => {
                if (offset != 0) return 0; // the line reads idempotently at 0
                if (buf.len < conn_line_len) return error.ShortDraw;
                var line: [conn_line_len]u8 = undefined;
                self.connLine(&line);
                @memcpy(buf[0..conn_line_len], &line);
                return conn_line_len;
            },
            .data => return error.BadDraw, // data is write-only (devdraw.c:1450 Qdata)
            else => return 0, // refresh + directories: empty
        }
    }

    fn writeOp(ctx: *anyopaque, _: *Server, fid: *Fid, _: u64, data: []const u8) OpError!usize {
        const self = devOf(ctx);
        switch (nodeOf(fid.qid.path)) {
            .data => {
                try self.dispatch(data);
                return data.len;
            },
            else => return error.BadDraw, // ctl infoid writes are Phase 3
        }
    }

    fn clunkOp(ctx: *anyopaque, _: *Server, fid: *Fid) void {
        const self = devOf(ctx);
        // Only an *open* ctl fid closing counts toward teardown.
        if (nodeOf(fid.qid.path) == .ctl and fid.omode != null) {
            if (self.open_count > 0) self.open_count -= 1;
            if (self.open_count == 0) self.reset();
        }
    }

    fn statOp(_: *anyopaque, _: *Server, fid: *Fid) OpError!Stat {
        const info: struct { name: []const u8, mode: u32 } = switch (nodeOf(fid.qid.path)) {
            .root => .{ .name = "draw", .mode = Stat.DMDIR | 0o555 },
            .new => .{ .name = "new", .mode = 0o666 },
            .conn => .{ .name = "1", .mode = Stat.DMDIR | 0o555 },
            .ctl => .{ .name = "ctl", .mode = 0o666 },
            .data => .{ .name = "data", .mode = 0o666 },
            .refresh => .{ .name = "refresh", .mode = 0o444 },
        };
        return .{ .qid = fid.qid, .mode = info.mode, .length = 0, .name = info.name };
    }
};

// ===========================================================================
// Fault mapping (R-P2-4). ONE table from a backend fault to a 9P Rerror.
// ===========================================================================

fn opError(e: draw_backend.Error) OpError {
    return switch (e) {
        error.UnknownImage => error.NoDrawImage, // "unknown id for draw image"
        error.ImageExists, error.BadChan, error.BadRect, error.Unsupported => error.BadDraw,
        error.OutOfMemory => error.IoError,
    };
}

// ===========================================================================
// Wire helpers (little-endian, G1). Coordinates are signed i32; ids/chan/color
// are u32 (devdraw.c:871-877, draw.h:508-511).
// ===========================================================================

fn rdU32(a: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, a[off..][0..4], .little);
}

fn rdI32(a: []const u8, off: usize) i32 {
    return std.mem.readInt(i32, a[off..][0..4], .little);
}

fn rdRect(a: []const u8, off: usize) draw_backend.Rect {
    return .{
        .min = .{ .x = rdI32(a, off + 0), .y = rdI32(a, off + 4) },
        .max = .{ .x = rdI32(a, off + 8), .y = rdI32(a, off + 12) },
    };
}

fn rdPoint(a: []const u8, off: usize) draw_backend.Point {
    return .{ .x = rdI32(a, off + 0), .y = rdI32(a, off + 4) };
}

/// Chan-code → its canonical string (chantostr, chan.c). Phase 2 only ever
/// emits the display chan (XRGB32); the rest round out the known set (G9).
fn chanToStr(ch: u32) []const u8 {
    return switch (ch) {
        draw_backend.XRGB32 => "x8r8g8b8",
        draw_backend.RGBA32 => "r8g8b8a8",
        draw_backend.RGB24 => "r8g8b8",
        draw_backend.GREY8 => "k8",
        draw_backend.GREY1 => "k1",
        else => "x8r8g8b8",
    };
}

/// Right-justify `s` in an 11-column field followed by one space (`%11s `).
fn putStrField(out: *[conn_line_len]u8, pos: *usize, s: []const u8) void {
    std.debug.assert(s.len <= 11);
    var pad: usize = 11 - s.len;
    while (pad > 0) : (pad -= 1) {
        out[pos.*] = ' ';
        pos.* += 1;
    }
    @memcpy(out[pos.*..][0..s.len], s);
    pos.* += s.len;
    out[pos.*] = ' ';
    pos.* += 1;
}

/// Right-justify a decimal integer in an 11-column field + space (`%11d `).
/// Formatted via plain `{d}` (no sign padding) into `tmp`, then justified —
/// Zig 0.16's `{d:>11}` prints a `+` for positive signed ints, which the
/// kernel's `snprint("%11d")` never does.
fn putIntField(out: *[conn_line_len]u8, pos: *usize, tmp: *[16]u8, v: i64) void {
    const s = std.fmt.bufPrint(tmp, "{d}", .{v}) catch unreachable;
    putStrField(out, pos, s);
}

// ===========================================================================
// Tests (§D 10-17). Hand-encoded draw frames over a chan.Pipe + Server +
// HeadlessBackend — deliberately NO dependency on src/draw (G7 independence).
// Frozen hash per R-P2-7: spot-checks are authoritative and verified first; the
// Wyhash literal is frozen only after they pass, with a scene comment.
// ===========================================================================

const testing = std.testing;
const chan = ninep.chan;

// -- local verb-byte builders (independent of src/draw/proto.zig, G7) --------

fn wU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
fn wRect(buf: []u8, off: usize, r: draw_backend.Rect) void {
    std.mem.writeInt(i32, buf[off + 0 ..][0..4], r.min.x, .little);
    std.mem.writeInt(i32, buf[off + 4 ..][0..4], r.min.y, .little);
    std.mem.writeInt(i32, buf[off + 8 ..][0..4], r.max.x, .little);
    std.mem.writeInt(i32, buf[off + 12 ..][0..4], r.max.y, .little);
}

/// Build a 51-byte 'b' (alloc) frame (G7).
fn buildB(buf: *[51]u8, id: u32, ch: u32, repl: bool, r: draw_backend.Rect, clipr: draw_backend.Rect, color: u32) void {
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
fn buildD(buf: *[45]u8, dstid: u32, srcid: u32, maskid: u32, r: draw_backend.Rect) void {
    buf[0] = 'd';
    wU32(buf, 1, dstid);
    wU32(buf, 5, srcid);
    wU32(buf, 9, maskid);
    wRect(buf, 13, r);
    @memset(buf[29..45], 0); // sp[8] + mp[8]
}

const R = draw_backend.Rect;
const unit = R.init(0, 0, 1, 1);
const repl_clipr = R.init(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF); // G10
const WHITE: u32 = 0xFFFFFFFF;
const RED: u32 = 0xFF0000FF;
const BLUE: u32 = 0x0000FFFF;

/// Heap-pinned harness: a Pipe + Server(DevDraw.ops) over a HeadlessBackend.
/// The backend and DevDraw must not move (the Server holds pointers to them).
const Harness = struct {
    alloc: std.mem.Allocator,
    pipe: *chan.Pipe,
    hb: draw_backend.HeadlessBackend,
    dd: DevDraw,
    srv: Server,
    rbuf: [1024]u8 = undefined,
    tag: u16 = 0,

    fn create(alloc: std.mem.Allocator, w: u32, h: u32) !*Harness {
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

    fn destroy(self: *Harness) void {
        self.srv.deinit();
        self.dd.deinit();
        self.hb.deinit();
        self.pipe.deinit();
        self.alloc.destroy(self);
    }

    fn nextTag(self: *Harness) u16 {
        self.tag += 1;
        return self.tag;
    }

    /// Encode `m`, push it into the server, step once, decode the one reply.
    fn transact(self: *Harness, m: msg.Message) !msg.Message {
        var enc: [2048]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        try self.pipe.clientEnd().writeMsg(enc[0..n]);
        _ = try self.srv.step();
        const reply = try self.pipe.clientEnd().readMsg(&self.rbuf);
        return try msg.decode(reply);
    }

    fn version(self: *Harness) !void {
        const r = try self.transact(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect(r.body == .rversion);
    }

    fn attach(self: *Harness, fid: u32) !void {
        const r = try self.transact(.{ .tag = self.nextTag(), .body = .{ .tattach = .{ .fid = fid, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
        try testing.expect(r.body == .rattach);
    }

    fn walk(self: *Harness, fid: u32, newfid: u32, names: []const []const u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(fid, newfid, names) } });
    }

    fn open(self: *Harness, fid: u32, mode: u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .topen = .{ .fid = fid, .mode = mode } } });
    }

    fn write(self: *Harness, fid: u32, data: []const u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .twrite = .{ .fid = fid, .offset = 0, .data = data } } });
    }

    fn read(self: *Harness, fid: u32, offset: u64, count: u32) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .tread = .{ .fid = fid, .offset = offset, .count = count } } });
    }

    fn clunk(self: *Harness, fid: u32) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .tclunk = .{ .fid = fid } } });
    }

    fn stat(self: *Harness, fid: u32) !Stat {
        const r = try self.transact(.{ .tag = self.nextTag(), .body = .{ .tstat = .{ .fid = fid } } });
        try testing.expect(r.body == .rstat);
        return try Stat.decode(r.body.rstat.stat);
    }

    /// Bring up a live connection: version, attach root (fid 0), walk `new`
    /// (fid 1), open it (morphs to ctl). Returns with ctl on fid 1.
    fn connect(self: *Harness) !void {
        try self.version();
        try self.attach(0);
        const w = try self.walk(0, 1, &.{"new"});
        try testing.expect(w.body == .rwalk);
        const o = try self.open(1, msg.ORDWR);
        try testing.expect(o.body == .ropen);
    }

    /// Walk `1/data` (fid 2) and open it ORDWR, ready for draw batches.
    fn openData(self: *Harness) !void {
        const w = try self.walk(0, 2, &.{ "1", "data" });
        try testing.expect(w.body == .rwalk);
        const o = try self.open(2, msg.ORDWR);
        try testing.expect(o.body == .ropen);
    }
};

test "devdraw: walk, open new, read connection line" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.version();
    try h.attach(0);

    // walk root → new, open new (morphs the fid into ctl).
    const w = try h.walk(0, 1, &.{"new"});
    try testing.expect(w.body == .rwalk);
    try testing.expectEqual(@as(u64, 0x01), w.body.rwalk.qids()[0].path);
    const o = try h.open(1, msg.ORDWR);
    try testing.expect(o.body == .ropen);
    try testing.expectEqual(@as(u64, 0x13), o.body.ropen.qid.path); // ctl qid (G8 morph)

    const want = "          1           0    x8r8g8b8           0           0           0         640         480           0           0         640         480 ";

    // First read of the connection line.
    const r1 = try h.read(1, 0, 256);
    try testing.expect(r1.body == .rread);
    try testing.expectEqualStrings(want, r1.body.rread.data);

    // Idempotent: a second read at offset 0 yields the same line.
    const r2 = try h.read(1, 0, 256);
    try testing.expectEqualStrings(want, r2.body.rread.data);

    // A read that cannot hold 144 bytes ⇒ short draw message.
    const rshort = try h.read(1, 0, 143);
    try testing.expect(rshort.body == .rerror);
    try testing.expectEqualStrings("short draw message", rshort.body.rerror.ename);

    // Past the line ⇒ EOF (0 bytes).
    const reof = try h.read(1, 144, 256);
    try testing.expect(reof.body == .rread);
    try testing.expectEqual(@as(usize, 0), reof.body.rread.data.len);
}

test "devdraw: b+b+d+v batch in one Twrite" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // 148-byte batch: mask(1) + red source(2) + draw(0←2 via 1) + flush.
    var batch: [148]u8 = undefined;
    var b1: [51]u8 = undefined;
    buildB(&b1, 1, draw_backend.GREY1, true, unit, repl_clipr, WHITE); // opaque mask
    var b2: [51]u8 = undefined;
    buildB(&b2, 2, draw_backend.RGBA32, true, unit, repl_clipr, RED); // solid red src
    var d: [45]u8 = undefined;
    buildD(&d, 0, 2, 1, R.init(100, 100, 300, 200));
    @memcpy(batch[0..51], &b1);
    @memcpy(batch[51..102], &b2);
    @memcpy(batch[102..147], &d);
    batch[147] = 'v';

    const rw = try h.write(2, &batch);
    try testing.expect(rw.body == .rwrite);
    try testing.expectEqual(@as(u32, 148), rw.body.rwrite.count);

    // Spot-checks (authoritative): red rect (100,100)-(300,200), rest untouched.
    try testing.expectEqual(@as(u32, 0xFF0000FF), h.hb.pixelAt(100, 100));
    try testing.expectEqual(@as(u32, 0xFF0000FF), h.hb.pixelAt(299, 199));
    try testing.expectEqual(@as(u32, 0x00000000), h.hb.pixelAt(99, 99));
    try testing.expectEqual(@as(u32, 0x00000000), h.hb.pixelAt(300, 200));
    try testing.expectEqual(@as(u32, 1), h.hb.flush_count);

    // FROZEN-C — scene: 640×480 zeroed fb, opaque red 0xFF0000FF SoverD into
    // (100,100)-(300,200) through a 1×1-repl white mask, then flush.
    try testing.expectEqual(@as(u64, 0x49b12df243bfe36f), h.hb.hash());
}

test "devdraw: bad verb ⇒ Rerror, prior ops applied" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // A valid 'b' followed by an unknown verb byte.
    var batch: [52]u8 = undefined;
    var b1: [51]u8 = undefined;
    buildB(&b1, 1, draw_backend.GREY1, true, unit, repl_clipr, WHITE);
    @memcpy(batch[0..51], &b1);
    batch[51] = 'Z'; // not a verb

    const rw = try h.write(2, &batch);
    try testing.expect(rw.body == .rerror);
    try testing.expectEqualStrings("bad draw message", rw.body.rerror.ename);

    // The 'b' before the bad verb stayed applied (G6 — no rollback).
    try testing.expect(h.hb.images.contains(1));
}

test "devdraw: two whole messages in two Twrites" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // Twrite #1: allocate mask + red source (102 bytes).
    var w1: [102]u8 = undefined;
    var b1: [51]u8 = undefined;
    buildB(&b1, 1, draw_backend.GREY1, true, unit, repl_clipr, WHITE);
    var b2: [51]u8 = undefined;
    buildB(&b2, 2, draw_backend.RGBA32, true, unit, repl_clipr, RED);
    @memcpy(w1[0..51], &b1);
    @memcpy(w1[51..102], &b2);
    const r1 = try h.write(2, &w1);
    try testing.expect(r1.body == .rwrite);
    try testing.expectEqual(@as(u32, 102), r1.body.rwrite.count);

    // Twrite #2: draw + flush (46 bytes).
    var w2: [46]u8 = undefined;
    var d: [45]u8 = undefined;
    buildD(&d, 0, 2, 1, R.init(0, 0, 50, 50));
    @memcpy(w2[0..45], &d);
    w2[45] = 'v';
    const r2 = try h.write(2, &w2);
    try testing.expect(r2.body == .rwrite);
    try testing.expectEqual(@as(u32, 46), r2.body.rwrite.count);

    try testing.expectEqual(@as(u32, 0xFF0000FF), h.hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0xFF0000FF), h.hb.pixelAt(49, 49));
    try testing.expectEqual(@as(u32, 1), h.hb.flush_count);
}

test "devdraw: op split across two Twrites ⇒ both fail" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();
    const before = h.hb.hash();

    var b1: [51]u8 = undefined;
    buildB(&b1, 1, draw_backend.RGBA32, true, unit, repl_clipr, RED);

    // First half: verb 'b' but the message is truncated ⇒ short draw message.
    const r1 = try h.write(2, b1[0..30]);
    try testing.expect(r1.body == .rerror);
    try testing.expectEqualStrings("short draw message", r1.body.rerror.ename);

    // Second half: the trailing bytes begin mid-field, not on a verb ⇒ error.
    const r2 = try h.write(2, b1[30..51]);
    try testing.expect(r2.body == .rerror);

    // Nothing reached the backend: no images, framebuffer unchanged.
    try testing.expectEqual(@as(usize, 0), h.hb.images.count());
    try testing.expectEqual(before, h.hb.hash());
}

test "devdraw: single connection is exclusive" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.version();
    try h.attach(0);

    // First open of `new` succeeds and marks the connection busy.
    _ = try h.walk(0, 1, &.{"new"});
    const o1 = try h.open(1, msg.ORDWR);
    try testing.expect(o1.body == .ropen);

    // A second independent `new` fid cannot open while busy.
    _ = try h.walk(0, 2, &.{"new"});
    const o2 = try h.open(2, msg.ORDWR);
    try testing.expect(o2.body == .rerror);
    try testing.expectEqualStrings("permission denied", o2.body.rerror.ename);
}

test "devdraw: clunk resets images" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // Allocate two images on the connection.
    var w1: [102]u8 = undefined;
    var b1: [51]u8 = undefined;
    buildB(&b1, 1, draw_backend.GREY1, true, unit, repl_clipr, WHITE);
    var b2: [51]u8 = undefined;
    buildB(&b2, 2, draw_backend.RGBA32, true, unit, repl_clipr, RED);
    @memcpy(w1[0..51], &b1);
    @memcpy(w1[51..102], &b2);
    _ = try h.write(2, &w1);
    try testing.expectEqual(@as(usize, 2), h.hb.images.count());

    // Clunking the ctl fid (fid 1) releases the connection and its images.
    const rc = try h.clunk(1);
    try testing.expect(rc.body == .rclunk);
    try testing.expectEqual(@as(usize, 0), h.hb.images.count());
    try testing.expect(!h.dd.busy);

    // The connection is free again: a fresh `new` open succeeds.
    _ = try h.walk(0, 3, &.{"new"});
    const o = try h.open(3, msg.ORDWR);
    try testing.expect(o.body == .ropen);
}

test "devdraw: stat and walk table" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.version();
    try h.attach(0);

    // Root directory.
    const root = try h.stat(0);
    try testing.expectEqualStrings("draw", root.name);
    try testing.expectEqual(Stat.DMDIR | @as(u32, 0o555), root.mode);
    try testing.expect(root.qid.qtype.dir);

    // new (clone point).
    _ = try h.walk(0, 1, &.{"new"});
    const new = try h.stat(1);
    try testing.expectEqualStrings("new", new.name);
    try testing.expectEqual(@as(u32, 0o666), new.mode);

    // The connection directory "1".
    _ = try h.walk(0, 2, &.{"1"});
    const conn = try h.stat(2);
    try testing.expectEqualStrings("1", conn.name);
    try testing.expectEqual(Stat.DMDIR | @as(u32, 0o555), conn.mode);
    try testing.expect(conn.qid.qtype.dir);

    // ctl / data / refresh (walked from the unopened "1" fid).
    _ = try h.walk(2, 3, &.{"ctl"});
    const ctl = try h.stat(3);
    try testing.expectEqualStrings("ctl", ctl.name);
    try testing.expectEqual(@as(u32, 0o666), ctl.mode);

    _ = try h.walk(2, 4, &.{"data"});
    const data = try h.stat(4);
    try testing.expectEqualStrings("data", data.name);
    try testing.expectEqual(@as(u32, 0o666), data.mode);

    _ = try h.walk(2, 5, &.{"refresh"});
    const refresh = try h.stat(5);
    try testing.expectEqualStrings("refresh", refresh.name);
    try testing.expectEqual(@as(u32, 0o444), refresh.mode);
}
