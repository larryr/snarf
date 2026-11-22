//! `cursor` — acme's `setcursor` / `setcursor(nil)`, re-expressed as a WRITE
//! to `/dev/cursor`. Namespace module (S-07 P-1). Ported from
//! larryr/plan9port@337c6ac `libdraw/mouse.c:132-144` and
//! `larryr/plan9@ed1a9c2` `9/port/devmouse.c:381-393`.
//!
//! Plan 9's `/dev/cursor` is write-only. A 72-byte record is
//! `offset[2*4] clr[2*16] set[2*16]` (`cursor(6)`, `draw.h` `Cursor`). A
//! shorter write, including the empty write `setcursor(nil)` sends, restores
//! the arrow. The offset is little-endian, matching plan9port's `BPLONG` and
//! this tree's native host (`host/devdraw/dev_input.zig`), which turns the
//! record into devdraw's `Tcursor`. Devdraw scales the 16×16 image to the
//! 32×32 cursor itself, so the core does not send `Cursor2`.
//!
//! The core does not know what a host can draw. It issues the same write on
//! every host (R-GFX-08):
//!
//!   * NATIVE host — the pointer image changes.
//!   * BROWSER host — no `/dev/cursor` (the browser build is frozen). The
//!     walk fails and this file swallows it.
//!   * A headless test with `ed.ns` null — nothing happens.
//!
//! Every failure is swallowed. A cursor is a courtesy, like a warp: a browser
//! session must not fill `+Errors` with one line per drag.
//!
//! Imports: std + `draw` + `ninep` + `Editor`. This file names `/dev/cursor`
//! by path through the session mount table (R-OV-03). It sees no host.
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");

const Point = draw.proto.Point;

/// Where `/dev/cursor` lives. The host mounts the device at `/dev`; `core`
/// cannot see that, so the path is repeated here. This file is its only reader.
pub const path = "/dev/cursor";

/// `2*4 + 2*16 + 2*16` (devmouse.c:383, libdraw/mouse.c:134).
pub const rec_len: usize = 72;

/// One Plan 9 cursor image. `clr` is the mask, `set` the ink, each 16 rows of
/// 2 bytes, top row first. `offset` is the hotspot relative to the image's
/// top-left (negative pulls the hotspot down and right).
pub const Image = struct {
    offset: Point,
    clr: [32]u8,
    set: [32]u8,
};

/// Acme's `boxcursor` (`acme.c:956-966`). The drag clue for a column-tag
/// button (`rows.c:151`) and, when it is ported, a window-tag button
/// (`cols.c:485`). Hotspot (−7, −7).
pub const box: Image = .{
    .offset = .{ .x = -7, .y = -7 },
    .clr = .{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, //
        0xFF, 0xFF, 0xF8, 0x1F, 0xF8, 0x1F, 0xF8, 0x1F, //
        0xF8, 0x1F, 0xF8, 0x1F, 0xF8, 0x1F, 0xFF, 0xFF, //
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    },
    .set = .{
        0x00, 0x00, 0x7F, 0xFE, 0x7F, 0xFE, 0x7F, 0xFE, //
        0x70, 0x0E, 0x70, 0x0E, 0x70, 0x0E, 0x70, 0x0E, //
        0x70, 0x0E, 0x70, 0x0E, 0x70, 0x0E, 0x70, 0x0E, //
        0x7F, 0xFE, 0x7F, 0xFE, 0x7F, 0xFE, 0x00, 0x00,
    },
};

/// Install `image`. Best effort; see the header.
pub fn set(ed: *Editor, image: Image) void {
    var rec: [rec_len]u8 = undefined;
    format(image, &rec);
    write(ed, &rec);
}

/// Restore the arrow (`setcursor(nil)`, an empty write).
pub fn arrow(ed: *Editor) void {
    write(ed, &.{});
}

/// Encode `image` as the 72-byte record. Offset is little-endian.
pub fn format(image: Image, out: *[rec_len]u8) void {
    std.mem.writeInt(i32, out[0..4], image.offset.x, .little);
    std.mem.writeInt(i32, out[4..8], image.offset.y, .little);
    @memcpy(out[8..40], &image.clr);
    @memcpy(out[40..72], &image.set);
}

fn write(ed: *Editor, data: []const u8) void {
    const ns = ed.ns orelse return;
    const h = ninep.nsdir.walk(ns, path) catch return;
    defer ninep.nsdir.close(ns, h);
    const f = switch (h) {
        .fid => |x| x,
        .dir => return,
    };
    _ = f.client.open(f.fid, ninep.msg.OWRITE) catch return;
    _ = f.client.write(f.fid, 0, data) catch return;
}

const testing = std.testing;

test "cursor: the box record is acme's boxcursor" {
    var rec: [rec_len]u8 = undefined;
    format(box, &rec);
    // Hotspot (−7, −7), little-endian.
    try testing.expectEqualSlices(u8, &.{ 0xF9, 0xFF, 0xFF, 0xFF, 0xF9, 0xFF, 0xFF, 0xFF }, rec[0..8]);
    try testing.expectEqualSlices(u8, &box.clr, rec[8..40]);
    try testing.expectEqualSlices(u8, &box.set, rec[40..72]);
}

test "cursor: no namespace means no write and no failure" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    set(&ed, box);
    arrow(&ed);
}

/// A stand-in `/dev` whose `cursor` file records each write. `last_len` is 0
/// for the arrow and `rec_len` for an image.
pub const Sink = struct {
    last: [rec_len]u8 = @splat(0),
    last_len: usize = 0,
    writes: usize = 0,

    pub const ops: ninep.server.Ops = .{
        .attach = attach,
        .walk1 = walk1,
        .open = open,
        .read = read,
        .write = writeOp,
        .stat = stat,
    };

    fn self_(ctx: *anyopaque) *Sink {
        return @ptrCast(@alignCast(ctx));
    }
    fn attach(_: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, _: []const u8) ninep.errors.OpError!ninep.Qid {
        return .{ .path = 0, .qtype = .{ .dir = true } };
    }
    fn walk1(_: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, name: []const u8) ninep.errors.OpError!ninep.Qid {
        if (!std.mem.eql(u8, name, "cursor")) return error.FileDoesNotExist;
        return .{ .path = 1, .qtype = .{} };
    }
    fn open(_: *anyopaque, _: *ninep.server.Server, fid: *ninep.server.Fid, _: u8) ninep.errors.OpError!ninep.Qid {
        return fid.qid;
    }
    fn read(_: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, _: u64, _: []u8) ninep.errors.OpError!usize {
        return 0;
    }
    fn writeOp(ctx: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, _: u64, data: []const u8) ninep.errors.OpError!usize {
        const s = self_(ctx);
        const n = @min(data.len, rec_len);
        @memset(&s.last, 0);
        @memcpy(s.last[0..n], data[0..n]);
        s.last_len = data.len;
        s.writes += 1;
        return data.len;
    }
    fn stat(_: *anyopaque, _: *ninep.server.Server, fid: *ninep.server.Fid) ninep.errors.OpError!ninep.stat {
        return .{ .qid = fid.qid, .mode = 0o666, .length = 0, .name = "cursor" };
    }
};

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "cursor: set and arrow reach /dev/cursor" {
    const a = testing.allocator;
    var sink: Sink = .{};
    const pipe = try ninep.chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try ninep.server.Server.init(a, pipe.serverEnd(), &Sink.ops, &sink, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pump };
    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");

    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/dev", &cl, root.fid);

    var ed = Editor.init(a);
    defer ed.deinit();
    ed.ns = &ns;

    const mark: Image = .{
        .offset = .{ .x = 3, .y = -1 },
        .clr = @splat(0x11),
        .set = @splat(0x22),
    };
    set(&ed, mark);
    try testing.expectEqual(@as(usize, 1), sink.writes);
    try testing.expectEqual(rec_len, sink.last_len);
    var want: [rec_len]u8 = undefined;
    format(mark, &want);
    try testing.expectEqualSlices(u8, &want, sink.last[0..rec_len]);

    arrow(&ed);
    try testing.expectEqual(@as(usize, 2), sink.writes);
    try testing.expectEqual(@as(usize, 0), sink.last_len);
}
