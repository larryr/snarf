//! `/dev/draw` client connection — the libdraw `Display` (init.c:200-330
//! `initdisplay`), file-as-struct (S-07 P-1): this file *is* the `Display`.
//!
//! A `Display` owns one draw connection: the morphed `new`→ctl fid and the
//! per-connection `data` fid, plus the write-buffer discipline libdraw uses to
//! batch draw-protocol verbs into a single `data` write (init.c:427-468
//! doflush/bufimage). The editor core draws ONLY by emitting proto ops here
//! (ADR-0003); this module speaks 9P through a borrowed `ninep.Client` and
//! never touches a browser API (S-07 §6).
//!
//! The `Display`↔`Image` import cycle (each file imports the other) is
//! intended and legal in Zig — an `Image` carries a back-pointer to its
//! `Display`, and `Display` embeds three `Image` handles.
const std = @import("std");
const ninep = @import("ninep");
const proto = @import("proto.zig");
const Image = @import("Image.zig");

const Display = @This();

/// The parsed 12-field connection line (init.c:271-287; G8). `conn` is the
/// connection number N (kernel `clientid`, G3) used to open `N/data`.
pub const ConnInfo = struct {
    conn: u32,
    image_id: u32,
    chan: proto.Chan,
    repl: bool,
    r: proto.Rect,
    clipr: proto.Rect,
};

pub const ParseError = error{ ShortInfo, BadInfo };
pub const Error = ninep.Client.Error || ParseError;

/// Length of the connection line: 12 fields × 12 bytes (init.c:198 NINFO; G8).
pub const info_size: usize = 144;

allocator: std.mem.Allocator,
/// Borrowed; the caller owns the client's lifetime.
client: *ninep.Client,
/// The `new` fid, morphed into this connection's ctl file (G8; owned).
ctl_fid: u32,
/// This connection's `N/data` fid (owned).
data_fid: u32,
conn: ConnInfo,
/// The display image itself, id 0 (G6). Constructed from `conn`, never a 'b'.
image: Image,
/// 1×1 repl GREY1 solids allocated at init (init.c:313-317). `white` doubles
/// as the opaque mask libdraw substitutes for a nil mask (G4; draw.c:31).
white: Image,
black: Image,
/// Write buffer; `buf.len == buf_size + 1`, the last byte reserved for the
/// lone 'v' flush verb (init.c:299 "+5 for flush message", G7 v is 1 byte).
buf: []u8,
bufn: usize,
buf_size: usize,
/// Pre-incremented per allocImage (alloc.c:46 `d->imageid++`); white=1,
/// black=2, so the first user image is id 3 and no id is ever 0 (the display).
imageid: u32 = 0,

/// Parse the 144-byte connection line into a `ConnInfo`. PURE and unit-tested.
/// Each field is 11 right-justified columns + one space (G8); field 2 is a
/// channel descriptor (proto.strToChan); rect coordinates may be negative
/// (signed i32, G1). `<144` ⇒ ShortInfo; any malformed field ⇒ BadInfo.
/// (init.c:275-287.)
pub fn parseConnInfo(info: []const u8) ParseError!ConnInfo {
    if (info.len < info_size) return error.ShortInfo;
    const conn = parseU32(fieldOf(info, 0)) orelse return error.BadInfo;
    const image_id = parseU32(fieldOf(info, 1)) orelse return error.BadInfo;
    const chan = proto.strToChan(fieldOf(info, 2)) orelse return error.BadInfo;
    const repl = parseI32(fieldOf(info, 3)) orelse return error.BadInfo;
    const r = try parseRect(info, 4);
    const clipr = try parseRect(info, 8);
    return .{
        .conn = conn,
        .image_id = image_id,
        .chan = chan,
        .repl = repl != 0,
        .r = r,
        .clipr = clipr,
    };
}

/// The 12-byte cell of field `i`, with its space padding trimmed.
fn fieldOf(info: []const u8, i: usize) []const u8 {
    return std.mem.trim(u8, info[i * 12 ..][0..12], " ");
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseI32(s: []const u8) ?i32 {
    return std.fmt.parseInt(i32, s, 10) catch null;
}

/// Parse four consecutive decimal fields starting at `base` as a rectangle.
fn parseRect(info: []const u8, base: usize) ParseError!proto.Rect {
    const x0 = parseI32(fieldOf(info, base + 0)) orelse return error.BadInfo;
    const y0 = parseI32(fieldOf(info, base + 1)) orelse return error.BadInfo;
    const x1 = parseI32(fieldOf(info, base + 2)) orelse return error.BadInfo;
    const y1 = parseI32(fieldOf(info, base + 3)) orelse return error.BadInfo;
    return proto.Rect.make(x0, y0, x1, y1);
}

/// Open a draw connection under `draw_dir_fid` (R-P2-1: the fid of the draw
/// directory itself, e.g. what resolving `/dev/draw` yields). Mirrors
/// `initdisplay` (init.c:222-317): walk `new`, open ORDWR, read+parse the
/// connection line, open `N/data`, then allocate the white/black solids.
/// `draw_dir_fid` is borrowed. Returns a heap `*Display` so `Image`
/// back-pointers stay stable.
pub fn init(allocator: std.mem.Allocator, client: *ninep.Client, draw_dir_fid: u32) Error!*Display {
    // init.c:224-232: open .../draw/new (ORDWR); the fid morphs into ctl (G8).
    const new_info = try client.walk(draw_dir_fid, &.{"new"});
    errdefer client.clunk(new_info.fid) catch {};
    _ = try client.open(new_info.fid, ninep.msg.ORDWR);

    // init.c:234-241: read the connection line (n<NINFO here is ShortInfo).
    var info_buf: [info_size + 1]u8 = undefined;
    const n = try client.read(new_info.fid, 0, &info_buf);
    if (n < info_size) return error.ShortInfo;
    const conn = try parseConnInfo(info_buf[0..n]);

    // init.c:245-248: open .../draw/<N>/data (ORDWR). N is parsed, never fixed.
    var nbuf: [16]u8 = undefined;
    const n_str = std.fmt.bufPrint(&nbuf, "{d}", .{conn.conn}) catch unreachable;
    const data_info = try client.walk(draw_dir_fid, &.{ n_str, "data" });
    errdefer client.clunk(data_info.fid) catch {};
    _ = try client.open(data_info.fid, ninep.msg.ORDWR);

    // init.c:296-301: bufsize is the data iounit capped at 8000, +1 (we need
    // only one reserved byte for the bare 'v', not the plan9port 5).
    const buf_size: usize = @min(@as(usize, client.msize) - ninep.msg.IOHDRSZ, 8000);
    const buf = try allocator.alloc(u8, buf_size + 1);
    errdefer allocator.free(buf);

    const self = try allocator.create(Display);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .client = client,
        .ctl_fid = new_info.fid,
        .data_fid = data_info.fid,
        .conn = conn,
        .image = .{
            .display = self,
            .id = 0, // G6: the display is image id 0.
            .r = conn.r,
            .clipr = conn.clipr,
            .chan = conn.chan,
            .repl = conn.repl,
        },
        .white = undefined,
        .black = undefined,
        .buf = buf,
        .bufn = 0,
        .buf_size = buf_size,
        .imageid = 0,
    };
    // init.c:313-317: white (id 1) then black (id 2), each a 1×1 repl GREY1
    // solid; each is eager-flushed by allocImage.
    self.white = try self.allocImage(proto.Rect.make(0, 0, 1, 1), proto.GREY1, true, proto.DWhite);
    self.black = try self.allocImage(proto.Rect.make(0, 0, 1, 1), proto.GREY1, true, proto.DBlack);
    return self;
}

/// Best-effort teardown: free the two solids, flush, clunk the owned fids,
/// release the buffer, destroy self. Errors are ignored — nothing is
/// recoverable at teardown. (`draw_dir_fid` was borrowed and is left alone.)
pub fn deinit(self: *Display) void {
    const allocator = self.allocator;
    self.white.free() catch {};
    self.black.free() catch {};
    self.flush() catch {};
    self.client.clunk(self.ctl_fid) catch {};
    self.client.clunk(self.data_fid) catch {};
    allocator.free(self.buf);
    allocator.destroy(self);
}

/// Allocate an image and return its handle. `clipr` is `r` for a plain image
/// or the huge repl clip rect for a tiled one (alloc.c:57-62, G10). Emits 'b'
/// and **eager-flushes** so an allocation error is attributed to this call and
/// not to some later batch (alloc.c:42,68).
pub fn allocImage(self: *Display, r: proto.Rect, chan: proto.Chan, repl: bool, color: proto.Color) Error!Image {
    self.imageid += 1; // alloc.c:46-47
    const id = self.imageid;
    const clipr = if (repl) proto.repl_clipr else r;
    try self.emit(.{ .alloc = .{
        .id = id,
        .chan = chan,
        .repl = repl,
        .r = r,
        .clipr = clipr,
        .color = color,
    } });
    try self.doFlush();
    return .{
        .display = self,
        .id = id,
        .r = r,
        .clipr = clipr,
        .chan = chan,
        .repl = repl,
    };
}

/// Append one verb to the write buffer, flushing first if it would not fit
/// (bufimage, init.c:463-467). The verb reaches the wire only on a subsequent
/// overflow, `flush`, `allocImage`'s eager flush, or `deinit`.
pub fn emit(self: *Display, op: proto.Op) Error!void {
    const size = proto.encodedSize(op);
    if (self.bufn + size > self.buf_size) try self.doFlush();
    const written = proto.encode(op, self.buf[self.bufn..self.buf_size]) catch unreachable;
    self.bufn += written.len;
}

/// Flush the buffer with the visible ('v') verb appended into the reserved
/// byte (flushimage(d, 1), init.c:437-449). An empty buffer still sends the
/// lone 'v'.
pub fn flush(self: *Display) Error!void {
    self.buf[self.bufn] = 'v';
    self.bufn += 1;
    try self.doFlush();
}

/// Send the buffered bytes in ONE `data` write (doflush, init.c:427-435). A
/// short ack is an I/O error; on success the buffer is reset. A zero-length
/// buffer is a no-op (init.c:431-432).
fn doFlush(self: *Display) Error!void {
    if (self.bufn == 0) return;
    const n = try self.client.write(self.data_fid, 0, self.buf[0..self.bufn]);
    if (n != self.bufn) return error.IoError;
    self.bufn = 0;
}

// ==========================================================================
// Tests (§C) — pure parse cases. The client-driven integration test lives in
// draw.zig (it needs ninep.server, allowed there in test blocks per R-P2-3).
// ==========================================================================
const testing = std.testing;

/// Build a 144-byte connection line from 12 string field values, each right-
/// justified in 11 columns with a trailing space (the kernel's `%11s ` format,
/// G8; devdraw.c:1197-1204).
fn buildConnLine(buf: *[info_size]u8, fields: [12][]const u8) void {
    for (fields, 0..) |f, i| {
        const cell = buf[i * 12 ..][0..12];
        @memset(cell, ' ');
        @memcpy(cell[11 - f.len ..][0..f.len], f);
    }
}

test "display: parse connection line" {
    var line: [info_size]u8 = undefined;
    buildConnLine(&line, .{ "1", "0", "x8r8g8b8", "0", "0", "0", "800", "600", "0", "0", "800", "600" });
    const ci = try parseConnInfo(&line);
    try testing.expectEqual(@as(u32, 1), ci.conn);
    try testing.expectEqual(@as(u32, 0), ci.image_id);
    try testing.expectEqual(proto.XRGB32, ci.chan);
    try testing.expectEqual(false, ci.repl);
    try testing.expectEqual(proto.Rect.make(0, 0, 800, 600), ci.r);
    try testing.expectEqual(proto.Rect.make(0, 0, 800, 600), ci.clipr);
}

test "display: parse short info" {
    const short = [_]u8{' '} ** (info_size - 1);
    try testing.expectError(error.ShortInfo, parseConnInfo(&short));
}

test "display: parse bad decimal field" {
    var line: [info_size]u8 = undefined;
    // Field 0 (conn) is not a decimal ⇒ BadInfo.
    buildConnLine(&line, .{ "xyz", "0", "x8r8g8b8", "0", "0", "0", "800", "600", "0", "0", "800", "600" });
    try testing.expectError(error.BadInfo, parseConnInfo(&line));
}

test "display: parse bad chan" {
    var line: [info_size]u8 = undefined;
    // Field 2 is not a valid channel descriptor ⇒ BadInfo.
    buildConnLine(&line, .{ "1", "0", "q8", "0", "0", "0", "800", "600", "0", "0", "800", "600" });
    try testing.expectError(error.BadInfo, parseConnInfo(&line));
}

test "display: negative rect coords parse" {
    var line: [info_size]u8 = undefined;
    buildConnLine(&line, .{ "1", "0", "x8r8g8b8", "1", "-5", "-10", "800", "600", "-100", "-100", "900", "700" });
    const ci = try parseConnInfo(&line);
    try testing.expectEqual(true, ci.repl);
    try testing.expectEqual(proto.Rect.make(-5, -10, 800, 600), ci.r);
    try testing.expectEqual(proto.Rect.make(-100, -100, 900, 700), ci.clipr);
}
