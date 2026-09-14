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
const draw_font = @import("draw_font.zig");
const draw_msgs = @import("draw_msgs.zig");
const draw_ctl = @import("draw_ctl.zig");

const Server = ninep.server.Server;
const Fid = ninep.server.Fid;
const Qid = ninep.Qid;
const OpError = ninep.errors.OpError;
const Stat = ninep.stat;
const msg = ninep.msg;

/// The fixed size of a draw connection line (G8, devdraw.c:1197-1204).
pub const conn_line_len: usize = 144;

/// The size of one `refresh` exposure record: a bare rectangle, four
/// little-endian i32 (S-03 §5; see `readOp`'s `.refresh` arm for why it is not
/// the kernel's 5×4 big-endian `id`+rect record).
pub const refresh_rec_len: usize = 16;

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
// Per-font state — types + the three cache functions live in `draw_font.zig`
// since phase 16a (S-07 size seam); the map itself is a `DevDraw` field.
// ===========================================================================

const FChar = draw_font.FChar;
const FontRec = draw_font.FontRec;

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
    /// Per-image font metrics, keyed by image id. An image gains an entry when
    /// 'i' promotes it to a font (devdraw.c:1679-1684); 'f'/reset/deinit free
    /// the entry and its owned `chars` slice (leak-checked by the tests).
    fonts: std.AutoHashMapUnmanaged(u32, FontRec) = .empty,
    /// The exposure rectangle a `refresh` read will hand back, or null when
    /// nothing is pending (S-03 §5). Set by `noteResize`, cleared by the read
    /// that reports it and by a connection reset.
    pending_refresh: ?draw_backend.Rect = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, backend: draw_backend.Backend) Self {
        return .{ .allocator = allocator, .backend = backend };
    }

    /// The display image now covers `r` — queue it as the exposure rectangle for
    /// the connection's `refresh` file (S-03 §5, the device half of R-GFX-05).
    /// Called right after the BACKEND has been resized (the entry point does
    /// `canvas.resize(w,h)` then `noteResize(new screen rect)`), so a `ctl` read
    /// taken any time after this already reports the new display rect: `connLine`
    /// re-reads `backend.displayInfo()` on every read and caches nothing —
    /// VERIFIED at connLine below, and in `HeadlessBackend.displayInfoImpl`,
    /// which derives its rect from the live `width`/`height`.
    ///
    /// Only the newest rectangle is kept. The kernel queues a `Refresh` list per
    /// client and coalesces nothing (devdraw.c:344-367); a single pending rect is
    /// enough here because the only producer is a whole-screen resize, and the
    /// newest one subsumes every older one.
    pub fn noteResize(self: *Self, r: draw_backend.Rect) void {
        self.pending_refresh = r;
    }

    pub fn deinit(self: *Self) void {
        self.freeAllFonts();
        self.fonts.deinit(self.allocator);
        self.allocated.deinit(self.allocator);
        self.* = undefined;
    }

    /// The font-cache functions live in `draw_font.zig` since phase 16a, and
    /// the draw-message verb loop in `draw_msgs.zig`. Decl aliases, not
    /// forwarders: `self.fontLadder(id)`/`self.dispatch(data)` resolve exactly
    /// as before.
    pub const freeFont = draw_font.freeFont;
    pub const freeAllFonts = draw_font.freeAllFonts;
    pub const isAllocated = draw_font.isAllocated;
    pub const fontLadder = draw_font.fontLadder;
    pub const dispatch = draw_msgs.dispatch;

    fn devOf(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    // -- connection line (G8) ------------------------------------------------
    // Formatted in `draw_ctl.zig` since phase 16a; a decl alias, so
    // `self.connLine(&line)` in `readOp` is unchanged.
    pub const connLine = draw_ctl.connLine;

    // -- verb dispatch (G1/G5/G7, devdraw.c:1457-1466) -----------------------

    /// Drop `id` from the reset list (called after a successful backend free so
    /// a later clunk-reset does not double-free it).
    pub fn forget(self: *Self, id: u32) void {
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
        self.freeAllFonts();
        self.busy = false;
        self.pending_refresh = null; // exposure is per-connection state
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
            // The exposure rectangle, reported exactly ONCE per `noteResize`
            // (S-03 §5). NON-BLOCKING: nothing pending reads 0 bytes instead of
            // parking. The kernel sleeps on `cl->refrend` until a rectangle
            // exists (devdraw.c:1237-1248); a parked 9P read needs the ticket /
            // parked-ops machinery that is phase 13's work (R-9P-13), so until
            // then a poller reads empty and tries again — the editor path does
            // not use this file at all (R-P12c-1).
            //
            // WIRE FORMAT DIVERGENCE, deliberate (contract §3d): 16 bytes,
            // `x0 y0 x1 y1` as little-endian i32, matching the rectangle encoding
            // every verb in this file already uses (G1, `rdRect`). The kernel
            // emits 5×4 BIG-endian longs per record — `id` then the rect
            // (devdraw.c:1250-1259) — but our refresh has exactly one producer
            // and it always describes the display image (id 0), so the id field
            // would be a constant, and BPLONG byte order contradicts G1.
            .refresh => {
                if (offset != 0) return 0; // the pending rect reads at 0 or not at all
                const r = self.pending_refresh orelse return 0;
                if (buf.len < refresh_rec_len) return error.ShortDraw; // devdraw.c:1235 n<5*4 ⇒ Ebadarg
                putRect(buf, 0, r);
                self.pending_refresh = null;
                return refresh_rec_len;
            },
            else => return 0, // directories: empty
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

/// The inverse of `rdRect`: four little-endian i32 at `off` (G1). The only
/// rectangle this device ever writes is the `refresh` exposure record.
fn putRect(a: []u8, off: usize, r: draw_backend.Rect) void {
    std.mem.writeInt(i32, a[off + 0 ..][0..4], r.min.x, .little);
    std.mem.writeInt(i32, a[off + 4 ..][0..4], r.min.y, .little);
    std.mem.writeInt(i32, a[off + 8 ..][0..4], r.max.x, .little);
    std.mem.writeInt(i32, a[off + 12 ..][0..4], r.max.y, .little);
}

// ===========================================================================
// Tests (§D 10-17). Hand-encoded draw frames over a chan.Pipe + Server +
// HeadlessBackend — deliberately NO dependency on src/draw (G7 independence).
// Frozen hash per R-P2-7: spot-checks are authoritative and verified first; the
// Wyhash literal is frozen only after they pass, with a scene comment.
//
// The builders and the `Harness` fixture live in `draw_testsrv.zig` since phase
// 16a; the aliases below keep every test body byte-identical.
// ===========================================================================

const testing = std.testing;
const chan = ninep.chan;
const testsrv = @import("draw_testsrv.zig");
const wU32 = testsrv.wU32;
const wU16 = testsrv.wU16;
const wRect = testsrv.wRect;
const wPoint = testsrv.wPoint;
const buildB = testsrv.buildB;
const buildD = testsrv.buildD;
const buildYHdr = testsrv.buildYHdr;
const buildI = testsrv.buildI;
const buildL = testsrv.buildL;
const buildS = testsrv.buildS;
const R = testsrv.R;
const P = testsrv.P;
const unit = testsrv.unit;
const repl_clipr = testsrv.repl_clipr;
const WHITE = testsrv.WHITE;
const RED = testsrv.RED;
const BLUE = testsrv.BLUE;
const Harness = testsrv.Harness;

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

// ===========================================================================
// Phase 3 — font verbs 'y'/'i'/'l'/'s' (device §3 tests 11-16). Verbs are
// hand-encoded (no src/draw import, G7). FROZEN-D per R-P2-7: spot-checks are
// authoritative and verified first; the Wyhash literal is frozen only after
// they pass, with a scene comment.
// ===========================================================================

test "devdraw: y upload then draw round-trip" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // ONE Twrite: mask(1) + 2×2 RGBA32 image(2) + 'y'(16B payload) + 'd' + 'v'.
    // The 'd' sitting right after the 16-byte payload pins the payload advance.
    var b1: [51]u8 = undefined;
    buildB(&b1, 1, draw_backend.GREY1, true, unit, repl_clipr, WHITE); // opaque mask
    var b2: [51]u8 = undefined;
    buildB(&b2, 2, draw_backend.RGBA32, false, R.init(0, 0, 2, 2), R.init(0, 0, 2, 2), 0);
    var yhdr: [21]u8 = undefined;
    buildYHdr(&yhdr, 2, R.init(0, 0, 2, 2));
    // RGBA32 wire order per pixel is [a,b,g,r] (G13). Row-major, 8 B/row.
    const payload = [16]u8{
        0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0xFF, 0x00, // (0,0)=red   (1,0)=green
        0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, // (0,1)=blue  (1,1)=white
    };
    var d: [45]u8 = undefined;
    buildD(&d, 0, 2, 1, R.init(0, 0, 2, 2));

    var batch: [51 + 51 + 21 + 16 + 45 + 1]u8 = undefined;
    var o: usize = 0;
    inline for (.{ b1[0..], b2[0..], yhdr[0..], payload[0..], d[0..] }) |seg| {
        @memcpy(batch[o..][0..seg.len], seg);
        o += seg.len;
    }
    batch[o] = 'v';

    const rw = try h.write(2, &batch);
    try testing.expect(rw.body == .rwrite);
    try testing.expectEqual(@as(u32, batch.len), rw.body.rwrite.count);

    // Spot-checks: the four loaded pixels landed opaque on the display.
    try testing.expectEqual(@as(u32, 0xFF0000FF), h.hb.pixelAt(0, 0));
    try testing.expectEqual(@as(u32, 0x00FF00FF), h.hb.pixelAt(1, 0));
    try testing.expectEqual(@as(u32, 0x0000FFFF), h.hb.pixelAt(0, 1));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), h.hb.pixelAt(1, 1));
    try testing.expectEqual(@as(u32, 1), h.hb.flush_count);
}

test "devdraw: y errors" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    var b1: [51]u8 = undefined;
    buildB(&b1, 1, draw_backend.RGBA32, false, R.init(0, 0, 2, 2), R.init(0, 0, 2, 2), 0);
    _ = try h.write(2, &b1);

    // (a) r not contained in the image ⇒ WriteOutside.
    var y_out: [21]u8 = undefined;
    buildYHdr(&y_out, 1, R.init(0, 0, 4, 4));
    const ro = try h.write(2, &y_out);
    try testing.expect(ro.body == .rerror);
    try testing.expectEqualStrings("writeimage outside image", ro.body.rerror.ename);

    // (b) payload shorter than Dy*bpl ⇒ ShortData ⇒ "bad writeimage call".
    var y_short: [21 + 8]u8 = undefined;
    buildYHdr(y_short[0..21], 1, R.init(0, 0, 2, 2)); // needs 16, gets 8
    @memset(y_short[21..], 0);
    const rs = try h.write(2, &y_short);
    try testing.expect(rs.body == .rerror);
    try testing.expectEqualStrings("bad writeimage call", rs.body.rerror.ename);

    // (c) unknown id ⇒ NoDrawImage.
    var y_unk: [21]u8 = undefined;
    buildYHdr(&y_unk, 999, R.init(0, 0, 2, 2));
    const ru = try h.write(2, &y_unk);
    try testing.expect(ru.body == .rerror);
    try testing.expectEqualStrings("unknown id for draw image", ru.body.rerror.ename);
}

test "devdraw: i/l/s two-glyph string — spot checks + frozen hash" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // Scene images: white mask (unused by 's'), RED source, GREY8 strip, GREY8
    // font cache — all 8×4. The strip 'y'-loads four rows; 'l' copies its left
    // 4 cols into glyph 0 and its right 4 cols into glyph 1 of the font image.
    var b1: [51]u8 = undefined;
    buildB(&b1, 1, draw_backend.GREY1, true, unit, repl_clipr, WHITE);
    var b2: [51]u8 = undefined;
    buildB(&b2, 2, draw_backend.RGBA32, true, unit, repl_clipr, RED);
    var b3: [51]u8 = undefined;
    buildB(&b3, 3, draw_backend.GREY8, false, R.init(0, 0, 8, 4), R.init(0, 0, 8, 4), 0);
    var b4: [51]u8 = undefined;
    buildB(&b4, 4, draw_backend.GREY8, false, R.init(0, 0, 8, 4), R.init(0, 0, 8, 4), 0);

    var yhdr: [21]u8 = undefined;
    buildYHdr(&yhdr, 3, R.init(0, 0, 8, 4)); // GREY8 8×4 ⇒ 8 B/row, 32 B total
    const strip = [32]u8{
        0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00,
        0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00,
        0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00,
        0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00,
    };

    var ifont: [10]u8 = undefined;
    buildI(&ifont, 4, 2, 3); // nchars 2, ascent 3
    var l0: [37]u8 = undefined;
    buildL(&l0, 4, 3, 0, R.init(0, 0, 4, 4), .{ .x = 0, .y = 0 }, 0, 5);
    var l1: [37]u8 = undefined;
    buildL(&l1, 4, 3, 1, R.init(4, 0, 8, 4), .{ .x = 4, .y = 0 }, 1, 6);

    var s: [47 + 4]u8 = undefined;
    buildS(&s, 0, 2, 4, .{ .x = 100, .y = 100 }, R.init(0, 0, 640, 480), .{ .x = 0, .y = 0 }, &.{ 0, 1 });

    var batch: [51 * 4 + 21 + 32 + 10 + 37 * 2 + (47 + 4) + 1]u8 = undefined;
    var o: usize = 0;
    inline for (.{ b1[0..], b2[0..], b3[0..], b4[0..], yhdr[0..], strip[0..], ifont[0..], l0[0..], l1[0..], s[0..] }) |seg| {
        @memcpy(batch[o..][0..seg.len], seg);
        o += seg.len;
    }
    batch[o] = 'v';

    const rw = try h.write(2, &batch);
    try testing.expect(rw.body == .rwrite);
    try testing.expectEqual(@as(u32, batch.len), rw.body.rwrite.count);

    // Glyph 0: box (100,97)-(104,101), left=0 width=5. The GREY8 mask is the
    // strip's left 4 columns ⇒ a checkerboard of RED (all opaque, XRGB dst).
    const red = @as(u32, 0xFF0000FF);
    for ([_][2]u32{
        .{ 100, 97 }, .{ 102, 97 }, .{ 101, 98 },  .{ 103, 98 },
        .{ 100, 99 }, .{ 102, 99 }, .{ 101, 100 }, .{ 103, 100 },
    }) |pt| try testing.expectEqual(red, h.hb.pixelAt(pt[0], pt[1]));
    // The complementary mask=0 cells inside glyph 0's box stay untouched.
    for ([_][2]u32{ .{ 101, 97 }, .{ 103, 97 }, .{ 100, 98 }, .{ 102, 98 } }) |pt|
        try testing.expectEqual(@as(u32, 0), h.hb.pixelAt(pt[0], pt[1]));

    // Glyph 1: pen advanced to q.x=105, left=1 ⇒ box (106,97)-(110,101). The
    // mask is the strip's right 4 cols: cols 4,5 solid ⇒ x=106,107 RED for
    // y=97..100; cols 6,7 empty ⇒ x=108,109 clear.
    var yy: u32 = 97;
    while (yy < 101) : (yy += 1) {
        try testing.expectEqual(red, h.hb.pixelAt(106, yy));
        try testing.expectEqual(red, h.hb.pixelAt(107, yy));
        try testing.expectEqual(@as(u32, 0), h.hb.pixelAt(108, yy));
        try testing.expectEqual(@as(u32, 0), h.hb.pixelAt(109, yy));
    }

    // Gaps and box edges stay black.
    try testing.expectEqual(@as(u32, 0), h.hb.pixelAt(105, 97)); // inter-glyph gap
    try testing.expectEqual(@as(u32, 0), h.hb.pixelAt(100, 96)); // above the box
    try testing.expectEqual(@as(u32, 0), h.hb.pixelAt(100, 101)); // below the box
    try testing.expectEqual(@as(u32, 1), h.hb.flush_count);

    // FROZEN-D — scene: 640×480 zeroed fb; RED (0xFF0000FF) SoverD through the
    // GREY8 font image as mask, drawing glyphs {0,1} of the 2-char font (ascent
    // 3, widths 5/6) at baseline (100,100), wire clipr = full display, then 'v'.
    try testing.expectEqual(@as(u64, 0x237ec3dc00be4b1d), h.hb.hash());
}

test "devdraw: font errors" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // Fixtures: white mask(1), RED src(2), GREY8 strip(3), GREY8 font(4),
    // and a plain non-font image(5).
    {
        var b1: [51]u8 = undefined;
        buildB(&b1, 1, draw_backend.GREY1, true, unit, repl_clipr, WHITE);
        var b2: [51]u8 = undefined;
        buildB(&b2, 2, draw_backend.RGBA32, true, unit, repl_clipr, RED);
        var b3: [51]u8 = undefined;
        buildB(&b3, 3, draw_backend.GREY8, false, R.init(0, 0, 8, 4), R.init(0, 0, 8, 4), 0);
        var b4: [51]u8 = undefined;
        buildB(&b4, 4, draw_backend.GREY8, false, R.init(0, 0, 8, 4), R.init(0, 0, 8, 4), 0);
        var b5: [51]u8 = undefined;
        buildB(&b5, 5, draw_backend.RGBA32, false, R.init(0, 0, 4, 4), R.init(0, 0, 4, 4), 0);
        var pre: [51 * 5]u8 = undefined;
        inline for (.{ b1[0..], b2[0..], b3[0..], b4[0..], b5[0..] }, 0..) |seg, idx|
            @memcpy(pre[idx * 51 ..][0..51], seg);
        _ = try h.write(2, &pre);
    }

    const expectErr = struct {
        fn f(hh: *Harness, data: []const u8, want: []const u8) !void {
            const r = try hh.write(2, data);
            try testing.expect(r.body == .rerror);
            try testing.expectEqualStrings(want, r.body.rerror.ename);
        }
    }.f;

    // 'i' fontid 0 ⇒ BadDraw; unknown id ⇒ NoDrawImage; nchars 0 / 4097 ⇒ BadDraw.
    var ib: [10]u8 = undefined;
    buildI(&ib, 0, 2, 3);
    try expectErr(h, &ib, "bad draw message");
    buildI(&ib, 999, 2, 3);
    try expectErr(h, &ib, "unknown id for draw image");
    buildI(&ib, 4, 0, 3);
    try expectErr(h, &ib, "bad draw message");
    buildI(&ib, 4, 4097, 3);
    try expectErr(h, &ib, "bad draw message");

    // 'l' on an allocated non-font image ⇒ NotFont.
    var lb: [37]u8 = undefined;
    buildL(&lb, 5, 3, 0, R.init(0, 0, 4, 4), .{ .x = 0, .y = 0 }, 0, 5);
    try expectErr(h, &lb, "image not a font");

    // Promote id 4 to a real 2-char font; 'l' index ≥ nchars ⇒ BadIndex.
    buildI(&ib, 4, 2, 3);
    _ = try h.write(2, &ib);
    buildL(&lb, 4, 3, 5, R.init(0, 0, 4, 4), .{ .x = 0, .y = 0 }, 0, 5);
    try expectErr(h, &lb, "character index out of range");

    // 's' unknown fontid ⇒ NoDrawImage; 's' on a non-font ⇒ NotFont.
    var sb: [47 + 2]u8 = undefined;
    buildS(&sb, 0, 2, 999, .{ .x = 100, .y = 100 }, R.init(0, 0, 640, 480), .{ .x = 0, .y = 0 }, &.{0});
    try expectErr(h, &sb, "unknown id for draw image");
    buildS(&sb, 0, 2, 5, .{ .x = 100, .y = 100 }, R.init(0, 0, 640, 480), .{ .x = 0, .y = 0 }, &.{0});
    try expectErr(h, &sb, "image not a font");

    // 's' indices {0,99}: glyph 0 must be loaded so it paints before the fault.
    var yhdr: [21]u8 = undefined;
    buildYHdr(&yhdr, 3, R.init(0, 0, 8, 4));
    const strip = [32]u8{
        0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00,
        0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00,
        0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00,
        0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00,
    };
    var yl: [21 + 32]u8 = undefined;
    @memcpy(yl[0..21], &yhdr);
    @memcpy(yl[21..], &strip);
    _ = try h.write(2, &yl);
    var l0: [37]u8 = undefined;
    buildL(&l0, 4, 3, 0, R.init(0, 0, 4, 4), .{ .x = 0, .y = 0 }, 0, 5);
    _ = try h.write(2, &l0);

    // Wire clipr is a small window that excludes (0,0). glyph 0 paints; index 99
    // ⇒ BadIndex; clipr must be restored to the display default afterward.
    var sbad: [47 + 4]u8 = undefined;
    buildS(&sbad, 0, 2, 4, .{ .x = 100, .y = 100 }, R.init(100, 90, 120, 110), .{ .x = 0, .y = 0 }, &.{ 0, 99 });
    try expectErr(h, &sbad, "character index out of range");
    try testing.expectEqual(@as(u32, 0xFF0000FF), h.hb.pixelAt(100, 97)); // glyph 0 stayed

    // clipr restored ⇒ a 'd' fully outside the wire clipr (100,90,120,110) still paints.
    var d: [45]u8 = undefined;
    buildD(&d, 0, 2, 1, R.init(0, 0, 10, 10));
    var dv: [46]u8 = undefined;
    @memcpy(dv[0..45], &d);
    dv[45] = 'v';
    const rd = try h.write(2, &dv);
    try testing.expect(rd.body == .rwrite);
    try testing.expectEqual(@as(u32, 0xFF0000FF), h.hb.pixelAt(0, 0)); // painted ⇒ clipr was restored
}

test "devdraw: s short checks two-stage" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // Stage 1: fewer than the 47-byte header ⇒ ShortDraw.
    var short_hdr: [46]u8 = undefined;
    short_hdr[0] = 's';
    @memset(short_hdr[1..], 0);
    const r1 = try h.write(2, &short_hdr);
    try testing.expect(r1.body == .rerror);
    try testing.expectEqualStrings("short draw message", r1.body.rerror.ename);

    // Stage 2: header present, ni=3, but only 2 indices follow ⇒ ShortDraw.
    var s2: [47 + 4]u8 = undefined;
    buildS(&s2, 0, 2, 4, .{ .x = 0, .y = 0 }, R.init(0, 0, 640, 480), .{ .x = 0, .y = 0 }, &.{ 0, 0 });
    wU16(&s2, 45, 3); // claim 3 indices while only 2 are present
    const r2 = try h.write(2, &s2);
    try testing.expect(r2.body == .rerror);
    try testing.expectEqualStrings("short draw message", r2.body.rerror.ename);
}

test "devdraw: clunk resets fonts" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();
    try h.openData();

    // Allocate an image and promote it to a font.
    var b2: [51]u8 = undefined;
    buildB(&b2, 2, draw_backend.GREY8, false, R.init(0, 0, 8, 4), R.init(0, 0, 8, 4), 0);
    var ib: [10]u8 = undefined;
    buildI(&ib, 2, 2, 3);
    var w1: [61]u8 = undefined;
    @memcpy(w1[0..51], &b2);
    @memcpy(w1[51..], &ib);
    _ = try h.write(2, &w1);
    try testing.expectEqual(@as(usize, 1), h.dd.fonts.count());

    // Clunk the data fid then the ctl fid: the ctl close resets the connection,
    // freeing images AND font metrics.
    _ = try h.clunk(2);
    const rc = try h.clunk(1);
    try testing.expect(rc.body == .rclunk);
    try testing.expectEqual(@as(usize, 0), h.dd.fonts.count());
    try testing.expectEqual(@as(usize, 0), h.hb.images.count());

    // Reconnect and re-'i' works on a fresh connection.
    _ = try h.walk(0, 3, &.{"new"});
    const o = try h.open(3, msg.ORDWR);
    try testing.expect(o.body == .ropen);
    const wd = try h.walk(0, 4, &.{ "1", "data" });
    try testing.expect(wd.body == .rwalk);
    const od = try h.open(4, msg.ORDWR);
    try testing.expect(od.body == .ropen);
    const r2 = try h.write(4, &w1);
    try testing.expect(r2.body == .rwrite);
    try testing.expectEqual(@as(usize, 1), h.dd.fonts.count());
}

// ===========================================================================
// Phase 12c — resize (R-GFX-05, contract §3d). Deliberately still NO
// dependency on src/draw (G7): the ctl line is checked field-by-field here,
// the way a real client (`Display.parseConnInfo`) would decode it, without
// importing that module.
// ===========================================================================

/// Extract field `idx` (0-based) of a 144-byte connection line: 11 columns +
/// one trailing space, so field `idx` starts at `idx*12` (devdraw.c:1197-1204).
fn fieldAt(line: []const u8, idx: usize) []const u8 {
    const start = idx * 12;
    return std.mem.trim(u8, line[start..][0..11], " ");
}

fn parseFieldInt(line: []const u8, idx: usize) !i64 {
    return std.fmt.parseInt(i64, fieldAt(line, idx), 10);
}

test "devdraw: ctl reflects a backend resize after noteResize (T3)" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect();

    try h.hb.resize(800, 600);
    h.dd.noteResize(draw_backend.Rect.init(0, 0, 800, 600));

    const r1 = try h.read(1, 0, 256);
    try testing.expect(r1.body == .rread);
    const line = r1.body.rread.data;

    // Fields 4-7: display image rect. Fields 8-11: clipr. (ground-truth table)
    try testing.expectEqual(@as(i64, 0), try parseFieldInt(line, 4));
    try testing.expectEqual(@as(i64, 0), try parseFieldInt(line, 5));
    try testing.expectEqual(@as(i64, 800), try parseFieldInt(line, 6));
    try testing.expectEqual(@as(i64, 600), try parseFieldInt(line, 7));
    try testing.expectEqual(@as(i64, 0), try parseFieldInt(line, 8));
    try testing.expectEqual(@as(i64, 0), try parseFieldInt(line, 9));
    try testing.expectEqual(@as(i64, 800), try parseFieldInt(line, 10));
    try testing.expectEqual(@as(i64, 600), try parseFieldInt(line, 11));

    // Idempotent, like the un-resized case: a second read is unchanged.
    const r2 = try h.read(1, 0, 256);
    try testing.expectEqualStrings(line, r2.body.rread.data);
}

test "devdraw: refresh reports the pending rect exactly once (T4)" {
    const h = try Harness.create(testing.allocator, 640, 480);
    defer h.destroy();
    try h.connect(); // ctl on fid 1, connection busy

    // Walk root → "1" → "refresh" (fid 2), open OREAD.
    const w = try h.walk(0, 2, &.{ "1", "refresh" });
    try testing.expect(w.body == .rwalk);
    const o = try h.open(2, msg.OREAD);
    try testing.expect(o.body == .ropen);

    // Nothing pending: 0 bytes, with or without a resize having happened.
    const r0 = try h.read(2, 0, 256);
    try testing.expect(r0.body == .rread);
    try testing.expectEqual(@as(usize, 0), r0.body.rread.data.len);

    try h.hb.resize(800, 600);
    h.dd.noteResize(draw_backend.Rect.init(0, 0, 800, 600));

    // First read after noteResize: exactly refresh_rec_len bytes, the rect.
    const r1 = try h.read(2, 0, 256);
    try testing.expect(r1.body == .rread);
    try testing.expectEqual(@as(usize, refresh_rec_len), r1.body.rread.data.len);
    const data = r1.body.rread.data;
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, data[0..4], .little));
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, data[4..8], .little));
    try testing.expectEqual(@as(i32, 800), std.mem.readInt(i32, data[8..12], .little));
    try testing.expectEqual(@as(i32, 600), std.mem.readInt(i32, data[12..16], .little));

    // Reported exactly once: reading again with nothing new pending ⇒ 0 bytes.
    const r2 = try h.read(2, 0, 256);
    try testing.expect(r2.body == .rread);
    try testing.expectEqual(@as(usize, 0), r2.body.rread.data.len);

    // A read at a non-zero offset never returns the rect, pending or not.
    h.dd.noteResize(draw_backend.Rect.init(0, 0, 1024, 768));
    const r3 = try h.read(2, 8, 256);
    try testing.expect(r3.body == .rread);
    try testing.expectEqual(@as(usize, 0), r3.body.rread.data.len);
}
