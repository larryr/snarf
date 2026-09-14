//! `/dev/mouse`, `/dev/kbd`, `/dev/cursor`, `/dev/snarf`, `/dev/label` for the
//! NATIVE host — the input half of the `devdraw` adapter (ADR-0005 §2b).
//!
//! `devdraw` is a real window system: it delivers real three-button mouse
//! records (its Cocoa layer already maps Option→B2 and Cmd→B3 the way a Plan 9
//! user expects), real keyboard runes, and it can MOVE THE POINTER. So this
//! device is a passthrough, not a state machine: none of the browser device's
//! profile/chord emulation (`dev/profiles.zig`, ADR-0004, S-04 §2) applies, and
//! there is no `ctl` file to select a profile with.
//!
//! The record format is shared with the browser device on purpose:
//! `dev.input.formatMouseRec` (devmouse.c:306-309, 49 bytes) is called from
//! here, so the two hosts cannot drift in what `/dev/mouse` looks like.
//!
//! THE WARP (R-P15-3, R-EDIT-25 as amended). Plan 9's `/dev/mouse` is
//! READ-WRITE: "writing the mouse file, in the same format, causes the mouse
//! cursor to move to the position specified by the x and y coordinates of the
//! message" (mouse(3):41-48; the kernel parses it in `devmouse.c:458-476`,
//! which skips the leading 'm' and reads two integers). That write is what
//! acme's `moveto` ultimately performs, and it is the ONE thing the browser
//! cannot do. Here it becomes `Tmoveto` (drawclient.c:346-357) and the pointer
//! really moves. The editor core issues the same write on both hosts; the
//! browser's `dev/input.zig` refuses it and nothing happens.
//!
//! Reads PARK when their queue is empty (`error.WouldBlockRead`, R-P6-2); the
//! host loop pushes events and then calls `Server.completeReads`.
//!
//! Imports: std, ninep, `dev` (the record formatter) and the sibling `Conn`.
const std = @import("std");
const ninep = @import("ninep");
const dev = @import("dev");
const Conn = @import("Conn.zig");
const wsys = @import("wsys.zig");

const Server = ninep.server.Server;
const Fid = ninep.server.Fid;
const Qid = ninep.Qid;
const OpError = ninep.errors.OpError;
const ReadError = ninep.server.ReadError;
const Stat = ninep.stat;

pub const mouse_rec_len = dev.input.mouse_rec_len;
pub const MouseRec = dev.input.MouseRec;

/// The Plan 9 `/dev/cursor` blob: `offset[2*4] clr[2*16] set[2*16]`. A shorter
/// write restores the arrow (devmouse.c:381-393, cursor(6)).
pub const cursor_rec_len: usize = 2 * 4 + 2 * 16 + 2 * 16;

const Node = enum(u4) { root = 0, mouse = 1, kbd = 2, cursor = 3, snarf = 4, label = 5 };

fn qidFor(node: Node) Qid {
    return .{ .path = @intFromEnum(node), .qtype = .{ .dir = node == .root } };
}

fn nodeOf(path: u64) Node {
    return @enumFromInt(@as(u4, @intCast(path & 0xF)));
}

pub const DevInput9 = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    conn: *Conn,
    mouse_q: std.ArrayListUnmanaged(MouseRec) = .empty,
    /// UTF-8 bytes, whole runes only (the browser device's shape).
    kbd_q: std.ArrayListUnmanaged(u8) = .empty,
    /// The last `Trdsnarf` answer, kept alive for the duration of the read.
    snarf_buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, conn: *Conn) Self {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn deinit(self: *Self) void {
        self.mouse_q.deinit(self.allocator);
        self.kbd_q.deinit(self.allocator);
        self.snarf_buf.deinit(self.allocator);
    }

    /// Qid paths for `Server.completeReads` (R-P6-3), mirroring
    /// `dev.input.DevInput.mousePath`/`kbdPath`.
    pub fn mousePath() u64 {
        return qidFor(.mouse).path;
    }
    pub fn kbdPath() u64 {
        return qidFor(.kbd).path;
    }

    /// Enqueue one mouse record straight from an `Rrdmouse`. No coalescing and
    /// no chord emulation: devdraw already delivers exactly what the window
    /// system saw (contrast `dev/input.zig MouseQueue`, S-04 §5).
    pub fn pushMouse(self: *Self, ev: Conn.MouseEvent) !void {
        try self.mouse_q.append(self.allocator, .{
            .x = ev.x,
            .y = ev.y,
            .buttons = ev.buttons,
            .msec = ev.msec,
        });
    }

    /// Enqueue one keyboard rune (`Rrdkbd4`). Runes devdraw cannot express as
    /// UTF-8 (its function-key range is above the Unicode max) are dropped.
    pub fn pushRune(self: *Self, r: u32) !void {
        if (r > 0x10FFFF) return;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(r), &buf) catch return;
        try self.kbd_q.appendSlice(self.allocator, buf[0..n]);
    }

    // -- Ops vtable ---------------------------------------------------------

    pub const ops: ninep.server.Ops = .{
        .attach = attachOp,
        .walk1 = walk1Op,
        .open = openOp,
        .read = readOp,
        .write = writeOp,
        .clunk = clunkOp,
        .stat = statOp,
    };

    fn devOf(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    fn attachOp(_: *anyopaque, _: *Server, _: *Fid, _: []const u8) OpError!Qid {
        return qidFor(.root);
    }

    fn walk1Op(_: *anyopaque, _: *Server, fid: *Fid, name: []const u8) OpError!Qid {
        const eq = std.mem.eql;
        if (eq(u8, name, "..")) return qidFor(.root);
        if (nodeOf(fid.qid.path) != .root) return error.FileDoesNotExist;
        if (eq(u8, name, "mouse")) return qidFor(.mouse);
        if (eq(u8, name, "kbd")) return qidFor(.kbd);
        if (eq(u8, name, "cursor")) return qidFor(.cursor);
        if (eq(u8, name, "snarf")) return qidFor(.snarf);
        if (eq(u8, name, "label")) return qidFor(.label);
        return error.FileDoesNotExist;
    }

    /// NO exclusive-open guard, deliberately — unlike the browser device
    /// (`dev/input.zig openOp`, which returns `Einuse` on a second `mouse`
    /// open). The warp needs a WRITE fid on `/dev/mouse` while the host loop
    /// already holds a standing READ fid on it, and Plan 9's own `/dev/mouse`
    /// is a single read-write file that acme opens once and does both through
    /// (mouse.c:9-12 `moveto` writes the very fd `readmouse` reads).
    fn openOp(_: *anyopaque, _: *Server, fid: *Fid, _: u8) OpError!Qid {
        return fid.qid;
    }

    fn readOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, buf: []u8) ReadError!usize {
        const self = devOf(ctx);
        switch (nodeOf(fid.qid.path)) {
            .mouse => {
                if (self.mouse_q.items.len == 0) return error.WouldBlockRead;
                const rec = self.mouse_q.orderedRemove(0);
                var tmp: [mouse_rec_len]u8 = undefined;
                dev.input.formatMouseRec(rec, &tmp);
                const n = @min(mouse_rec_len, buf.len);
                @memcpy(buf[0..n], tmp[0..n]);
                return n;
            },
            .kbd => {
                if (self.kbd_q.items.len == 0) return error.WouldBlockRead;
                var n: usize = 0;
                while (n < self.kbd_q.items.len) {
                    const seq = std.unicode.utf8ByteSequenceLength(self.kbd_q.items[n]) catch 1;
                    if (n + seq > self.kbd_q.items.len) break;
                    if (n + seq > buf.len) break;
                    n += seq;
                }
                if (n == 0) return 0;
                @memcpy(buf[0..n], self.kbd_q.items[0..n]);
                std.mem.copyForwards(u8, self.kbd_q.items[0 .. self.kbd_q.items.len - n], self.kbd_q.items[n..]);
                self.kbd_q.shrinkRetainingCapacity(self.kbd_q.items.len - n);
                return n;
            },
            // `Trdsnarf` (drawclient.c:402-414): the host clipboard, fetched on
            // the offset-0 read and paged out from there.
            .snarf => {
                if (offset == 0) {
                    const s = self.conn.rdSnarf(self.allocator) catch return error.IoError;
                    defer self.allocator.free(s);
                    self.snarf_buf.clearRetainingCapacity();
                    self.snarf_buf.appendSlice(self.allocator, s) catch return error.IoError;
                }
                if (offset >= self.snarf_buf.items.len) return 0;
                const avail = self.snarf_buf.items[@intCast(offset)..];
                const n = @min(avail.len, buf.len);
                @memcpy(buf[0..n], avail[0..n]);
                return n;
            },
            .cursor, .label, .root => return 0,
        }
    }

    fn writeOp(ctx: *anyopaque, _: *Server, fid: *Fid, _: u64, data: []const u8) OpError!usize {
        const self = devOf(ctx);
        switch (nodeOf(fid.qid.path)) {
            // THE WARP (mouse(3):41-48, devmouse.c:458-476 `case Qmouse`).
            .mouse => {
                const pt = parseWarp(data) orelse return error.BadMessage;
                self.conn.moveTo(pt.x, pt.y) catch return error.IoError;
                return data.len;
            },
            // `Tcursor` — devdraw scales the 1× blob into a 2× cursor itself
            // (srv.c:258-266 `scalecursor`), so the 72-byte Plan 9 record maps
            // straight across. Short write ⇒ the arrow (devmouse.c:383-386).
            .cursor => {
                if (data.len < cursor_rec_len) {
                    self.conn.cursor(null) catch return error.IoError;
                    return data.len;
                }
                var c: wsys.Cursor = .{ .off = .{
                    .x = std.mem.readInt(i32, data[0..4], .little),
                    .y = std.mem.readInt(i32, data[4..8], .little),
                } };
                @memcpy(&c.clr, data[8..40]);
                @memcpy(&c.set, data[40..72]);
                self.conn.cursor(c) catch return error.IoError;
                return cursor_rec_len;
            },
            .snarf => {
                self.conn.wrSnarf(data) catch return error.IoError;
                return data.len;
            },
            .label => {
                self.conn.label(data) catch return error.IoError;
                return data.len;
            },
            .kbd, .root => return error.PermissionDenied,
        }
    }

    fn clunkOp(_: *anyopaque, _: *Server, _: *Fid) void {}

    fn statOp(_: *anyopaque, _: *Server, fid: *Fid) OpError!Stat {
        const info: struct { name: []const u8, mode: u32 } = switch (nodeOf(fid.qid.path)) {
            .root => .{ .name = "input", .mode = Stat.DMDIR | 0o555 },
            // 0666: the warp is a WRITE to this file (mouse(3)), which is why
            // the browser's copy of this device is 0444.
            .mouse => .{ .name = "mouse", .mode = 0o666 },
            .kbd => .{ .name = "kbd", .mode = 0o444 },
            .cursor => .{ .name = "cursor", .mode = 0o666 },
            .snarf => .{ .name = "snarf", .mode = 0o666 },
            .label => .{ .name = "label", .mode = 0o666 },
        };
        return .{ .qid = fid.qid, .mode = info.mode, .length = 0, .name = info.name };
    }
};

/// The point a warp write names.
pub const Warp = struct { x: i32, y: i32 };

/// Parse a `/dev/mouse` warp write. The kernel takes the record format —
/// `m` then decimal fields — and reads only x and y with `strtoul`
/// (devmouse.c:461-468), so any spacing works and trailing fields are ignored.
pub fn parseWarp(data: []const u8) ?Warp {
    if (data.len < 2 or data[0] != 'm') return null;
    var it = std.mem.tokenizeAny(u8, data[1..], " \t\n");
    const xs = it.next() orelse return null;
    const ys = it.next() orelse return null;
    const x = std.fmt.parseInt(i32, xs, 10) catch return null;
    const y = std.fmt.parseInt(i32, ys, 10) catch return null;
    return .{ .x = x, .y = y };
}

// ==========================================================================
// Tests — the device over a scripted peer.
// ==========================================================================
const testing = std.testing;

fn testFid(node: Node) Fid {
    return .{ .fid = 1, .qid = qidFor(node), .omode = 2, .uname = @constCast("") };
}

test "dev_input: a mouse read yields the 49-byte record, and parks when empty" {
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    var d = DevInput9.init(testing.allocator, &c);
    defer d.deinit();
    var srv: Server = undefined;
    var fid = testFid(.mouse);
    var buf: [mouse_rec_len]u8 = undefined;

    try testing.expectError(error.WouldBlockRead, DevInput9.ops.read(&d, &srv, &fid, 0, &buf));
    try d.pushMouse(.{ .x = 10, .y = 20, .buttons = 4, .msec = 99, .resized = false });
    try testing.expectEqual(mouse_rec_len, try DevInput9.ops.read(&d, &srv, &fid, 0, &buf));
    var want: [mouse_rec_len]u8 = undefined;
    dev.input.formatMouseRec(.{ .x = 10, .y = 20, .buttons = 4, .msec = 99 }, &want);
    try testing.expectEqualSlices(u8, &want, &buf);
    try testing.expectError(error.WouldBlockRead, DevInput9.ops.read(&d, &srv, &fid, 0, &buf));
}

test "dev_input: a kbd read yields whole runes from Rrdkbd4" {
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    var d = DevInput9.init(testing.allocator, &c);
    defer d.deinit();
    var srv: Server = undefined;
    var fid = testFid(.kbd);
    var buf: [16]u8 = undefined;
    try testing.expectError(error.WouldBlockRead, DevInput9.ops.read(&d, &srv, &fid, 0, &buf));
    try d.pushRune('a');
    try d.pushRune(0x00E9); // é
    const n = try DevInput9.ops.read(&d, &srv, &fid, 0, &buf);
    try testing.expectEqualStrings("a\u{00E9}", buf[0..n]);
}

test "dev_input: a /dev/mouse write emits Tmoveto — the warp" {
    var script: Conn.Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());
    script.conn = &c;
    var d = DevInput9.init(testing.allocator, &c);
    defer d.deinit();
    var srv: Server = undefined;
    var fid = testFid(.mouse);

    try script.expect(.rmoveto);
    const rec = "m        100         200           0           0 ";
    try testing.expectEqual(rec.len, try DevInput9.ops.write(&d, &srv, &fid, 0, rec));
    const sent = script.frame(0).?.msg;
    try testing.expectEqual(@as(i32, 100), sent.tmoveto.x);
    try testing.expectEqual(@as(i32, 200), sent.tmoveto.y);
}

test "dev_input: a malformed warp write is a bad message" {
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    var d = DevInput9.init(testing.allocator, &c);
    defer d.deinit();
    var srv: Server = undefined;
    var fid = testFid(.mouse);
    try testing.expectError(error.BadMessage, DevInput9.ops.write(&d, &srv, &fid, 0, "hello"));
    try testing.expectEqual(@as(?Warp, null), parseWarp("m 1"));
    try testing.expectEqual(@as(i32, -4), parseWarp("m -4 -5").?.x);
}

test "dev_input: kbd is not writable, mouse is" {
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    var d = DevInput9.init(testing.allocator, &c);
    defer d.deinit();
    var srv: Server = undefined;
    var kfid = testFid(.kbd);
    try testing.expectError(error.PermissionDenied, DevInput9.ops.write(&d, &srv, &kfid, 0, "x"));
    var mfid = testFid(.mouse);
    const st = try DevInput9.ops.stat(&d, &srv, &mfid);
    try testing.expectEqual(@as(u32, 0o666), st.mode);
}
