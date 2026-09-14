//! `/dev/draw` for the NATIVE host: a 9P device that FORWARDS, byte for byte,
//! to a plan9port `devdraw` over its `drawfcall` pipe (ADR-0005 §2, ruling
//! R-P15-1 "transport adapter, not backend adapter").
//!
//! The point of the transport adapter is that nothing is re-encoded. The
//! editor's `src/draw/Display.zig` already emits exactly the byte stream
//! libdraw writes to `/dev/draw/N/data` — the same stream `devdraw`'s
//! `draw_datawrite` consumes (devdraw.c:641). So this device is a pipe with a
//! file-system shape on one end:
//!
//!     write /dev/draw/N/data   →  Twrdraw  (verbatim)
//!     read  /dev/draw/new      →  the 144-byte connection line
//!     read  /dev/draw/N/ctl    →  the same line, re-read (the resize path)
//!     read  /dev/draw/N/refresh→  the pending exposure rectangle
//!
//! THE ONE THING THE KERNEL DOES AND devdraw DOES NOT. In Plan 9, opening
//! `/dev/draw/new` creates the connection AND hands back the connection line
//! (devdraw.c:1197-1204). plan9port's devdraw has no file system at all: the
//! screen image is installed, and the line produced, by two DRAW VERBS —
//! `J` (install the screen as image 0) and `I` (queue that image's info for
//! the next read) — which libdraw's `getimage0` writes before every
//! `_displayrddraw` (init.c:122-152, devdraw.c:917-959). That sequence is the
//! kernel's `new`-open, and issuing it is exactly the adapter work this file
//! exists to do. A RE-read (libdraw's `getwindow` after a resize) must free
//! image 0 first, because `J` refuses to install over an existing id
//! (devdraw.c:920-921 `Eimageexists`) — init.c:129-136 frees it the same way.
//!
//! Ported from `larryr/plan9port@337c6ac`; cite `devdraw.c:NN` (the simulator),
//! `init.c:NN` (libdraw) and `9/port/devdraw.c:NN` (the kernel we mirror).
//!
//! Imports: std, ninep, and the sibling `Conn`. Never `core`, never `draw`
//! (S-07 §6 — a device server may not see the client that talks to it).
const std = @import("std");
const ninep = @import("ninep");
const Conn = @import("Conn.zig");

const Server = ninep.server.Server;
const Fid = ninep.server.Fid;
const Qid = ninep.Qid;
const OpError = ninep.errors.OpError;
const Stat = ninep.stat;
const msg = ninep.msg;

/// The connection line's fixed length: 12 fields of `%11d ` (devdraw.c:945-947,
/// init.c:148 `n != 12*12`). Same constant as `dev/draw.zig conn_line_len` and
/// `draw.Display.info_size`.
pub const conn_line_len: usize = 144;

/// The exposure record `refresh` hands back — a bare little-endian rectangle,
/// the shape `dev/draw.zig` settled on (S-03 §5).
pub const refresh_rec_len: usize = 16;

/// devdraw's `client->clientid` is hard-wired to 1 (devdraw.c:29), so the
/// connection directory is `/dev/draw/1`. Parsed out of the line rather than
/// assumed — `Display` opens `<field0>/data`.
const default_conn: u64 = 1;

const Node = enum(u4) {
    root = 0,
    new = 1,
    conn = 2,
    ctl = 3,
    data = 4,
    refresh = 5,
};

fn qidFor(node: Node) Qid {
    const is_dir = node == .root or node == .conn;
    return .{ .path = @intFromEnum(node), .qtype = .{ .dir = is_dir } };
}

fn nodeOf(path: u64) Node {
    return @enumFromInt(@as(u4, @intCast(path & 0xF)));
}

pub const Rect = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// The device. Borrows a live `Conn`; owns nothing but its cached line.
pub const DevDraw9 = struct {
    const Self = @This();

    conn: *Conn,
    /// The last connection line read back from the peer.
    line: [conn_line_len]u8 = @splat(' '),
    /// Has image 0 (the screen) been installed with `J` at least once?
    installed: bool = false,
    /// `1` until the first line is parsed, then whatever field 0 says.
    conn_no: u64 = default_conn,
    /// Set by `noteResize` when `Rrdmouse.resized` arrives; a `refresh` read
    /// consumes it (the `dev/draw.zig` contract, S-03 §5).
    pending_refresh: ?Rect = null,

    pub fn init(conn: *Conn) Self {
        return .{ .conn = conn };
    }

    /// Re-issue `J`+`I` and read the connection line back (init.c:129-152).
    /// The `f` that precedes them on every re-read is `_freeimage1(image)`
    /// (init.c:135): `J` cannot install over a live image 0.
    pub fn refreshLine(self: *Self) !void {
        var verbs: [7]u8 = undefined;
        var n: usize = 0;
        if (self.installed) {
            verbs[0] = 'f'; // devdraw.c:863 free image
            std.mem.writeInt(u32, verbs[1..5], 0, .little); // draw.h:528 BGLONG is LE
            n = 5;
        }
        verbs[n] = 'J'; // devdraw.c:918 install screen as image 0
        verbs[n + 1] = 'I'; // devdraw.c:930 queue its info
        n += 2;
        _ = try self.conn.wrDraw(verbs[0..n]);
        self.installed = true;
        const got = try self.conn.rdDraw(&self.line);
        if (got != conn_line_len) return error.ShortInfo;
        self.conn_no = parseField0(&self.line) orelse default_conn;
    }

    /// The device learned the window changed size (`Rrdmouse.resized`): the
    /// next `refresh` read reports `r`, and the next `ctl` read re-reads the
    /// line from the peer. Mirrors `dev/draw.zig noteResize`.
    pub fn noteResize(self: *Self, r: Rect) void {
        self.pending_refresh = r;
    }

    /// The display rectangle currently reported by the peer (fields 4..7).
    pub fn screenRect(self: *const Self) Rect {
        return .{
            .x0 = parseFieldI(&self.line, 4) orelse 0,
            .y0 = parseFieldI(&self.line, 5) orelse 0,
            .x1 = parseFieldI(&self.line, 6) orelse 0,
            .y1 = parseFieldI(&self.line, 7) orelse 0,
        };
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

    fn walk1Op(ctx: *anyopaque, _: *Server, fid: *Fid, name: []const u8) OpError!Qid {
        const self = devOf(ctx);
        const eq = std.mem.eql;
        if (eq(u8, name, "..")) return qidFor(.root);
        return switch (nodeOf(fid.qid.path)) {
            .root => if (eq(u8, name, "new"))
                qidFor(.new)
            else if (self.isConnName(name))
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

    fn isConnName(self: *const Self, name: []const u8) bool {
        const n = std.fmt.parseInt(u64, name, 10) catch return false;
        return n == self.conn_no;
    }

    /// Opening `new` morphs the fid into the connection's ctl file
    /// (devdraw.c:1056-1061). Unlike the kernel, no connection is *created*
    /// here: plan9port's devdraw has exactly one, made by `Tinit`.
    fn openOp(_: *anyopaque, _: *Server, fid: *Fid, mode: u8) OpError!Qid {
        switch (nodeOf(fid.qid.path)) {
            // The fid MORPHS into the connection's ctl file; the line itself
            // is fetched by the first read of that fid (`Display.init` reads it
            // immediately, init.c:234-241), so nothing is sent from here.
            .new => {
                const q = qidFor(.ctl);
                fid.qid = q;
                return q;
            },
            .refresh => {
                if ((mode & 3) == msg.OWRITE or (mode & 3) == msg.ORDWR) return error.PermissionDenied;
                return fid.qid;
            },
            else => return fid.qid,
        }
    }

    fn readOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, buf: []u8) OpError!usize {
        const self = devOf(ctx);
        switch (nodeOf(fid.qid.path)) {
            // The connection line. A read at offset 0 RE-READS it from the peer
            // (libdraw's `getwindow`, init.c:191-228): the window may have been
            // resized since, and the client learns the new rect only here.
            .ctl => {
                if (offset == 0) self.refreshLine() catch return error.IoError;
                return sliceOut(&self.line, offset, buf);
            },
            .refresh => {
                const r = self.pending_refresh orelse return 0;
                if (buf.len < refresh_rec_len) return error.ShortDraw;
                std.mem.writeInt(i32, buf[0..4], r.x0, .little);
                std.mem.writeInt(i32, buf[4..8], r.y0, .little);
                std.mem.writeInt(i32, buf[8..12], r.x1, .little);
                std.mem.writeInt(i32, buf[12..16], r.y1, .little);
                self.pending_refresh = null;
                return refresh_rec_len;
            },
            // `data` reads exist in the kernel (the reply to a read-verb) and
            // map to Trddraw. Snarf's draw client never issues one — the info
            // line is the only thing it reads back, and `ctl` serves that — so
            // this arm is here for protocol completeness only.
            .data => {
                const n = self.conn.rdDraw(buf) catch return error.IoError;
                return n;
            },
            .new => return sliceOut(&self.line, offset, buf),
            .root, .conn => return 0, // directory reads: the tree is fixed
        }
    }

    /// Every `data` write is a batch of draw verbs; hand it to the peer
    /// unchanged (`_displaywrdraw`, drawclient.c:437-448). A short accept is an
    /// I/O error, exactly as `Display.doFlush` expects.
    fn writeOp(ctx: *anyopaque, _: *Server, fid: *Fid, _: u64, data: []const u8) OpError!usize {
        const self = devOf(ctx);
        switch (nodeOf(fid.qid.path)) {
            .data => {
                const n = self.conn.wrDraw(data) catch |e| return connError(e);
                if (n != data.len) return error.IoError;
                return data.len;
            },
            // The kernel's ctl accepts no writes worth porting here.
            else => return error.PermissionDenied,
        }
    }

    fn clunkOp(_: *anyopaque, _: *Server, _: *Fid) void {}

    fn statOp(ctx: *anyopaque, _: *Server, fid: *Fid) OpError!Stat {
        const self = devOf(ctx);
        var namebuf: [24]u8 = undefined;
        const info: struct { name: []const u8, mode: u32 } = switch (nodeOf(fid.qid.path)) {
            .root => .{ .name = "draw", .mode = Stat.DMDIR | 0o555 },
            .new => .{ .name = "new", .mode = 0o666 },
            .conn => .{
                .name = std.fmt.bufPrint(&namebuf, "{d}", .{self.conn_no}) catch "1",
                .mode = Stat.DMDIR | 0o555,
            },
            .ctl => .{ .name = "ctl", .mode = 0o666 },
            .data => .{ .name = "data", .mode = 0o666 },
            .refresh => .{ .name = "refresh", .mode = 0o444 },
        };
        return .{ .qid = fid.qid, .mode = info.mode, .length = 0, .name = info.name };
    }
};

/// A `Conn.Error` seen from inside a 9P op. `DrawError` is the peer's own
/// complaint about our draw bytes, which is exactly a bad draw message.
fn connError(e: anyerror) OpError {
    return switch (e) {
        error.DrawError => error.BadDraw,
        error.Closed => error.ConnectionClosed,
        else => error.IoError,
    };
}

fn sliceOut(src: []const u8, offset: u64, buf: []u8) usize {
    if (offset >= src.len) return 0;
    const avail = src[@intCast(offset)..];
    const n = @min(avail.len, buf.len);
    @memcpy(buf[0..n], avail[0..n]);
    return n;
}

/// Field `i` of the line: 11 right-justified columns plus one space
/// (devdraw.c:945-947), trimmed.
fn field(line: []const u8, i: usize) []const u8 {
    return std.mem.trim(u8, line[i * 12 ..][0..12], " ");
}

fn parseField0(line: []const u8) ?u64 {
    return std.fmt.parseInt(u64, field(line, 0), 10) catch null;
}

fn parseFieldI(line: []const u8, i: usize) ?i32 {
    return std.fmt.parseInt(i32, field(line, i), 10) catch null;
}

// ==========================================================================
// Tests — the device over a scripted peer (no devdraw, no window).
// ==========================================================================
const testing = std.testing;

/// Build a devdraw-shaped connection line (`%11d ` × 12, devdraw.c:945-947).
fn buildLine(out: *[conn_line_len]u8, fields: [12][]const u8) void {
    for (fields, 0..) |f, i| {
        const cell = out[i * 12 ..][0..12];
        @memset(cell, ' ');
        @memcpy(cell[11 - f.len ..][0..f.len], f);
    }
}

const sample = [12][]const u8{ "1", "0", "x8r8g8b8", "0", "0", "0", "800", "600", "0", "0", "800", "600" };

test "dev_draw: the first ctl read installs image 0 with J+I and parses the line" {
    var script: Conn.Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());
    script.conn = &c;

    var line: [conn_line_len]u8 = undefined;
    buildLine(&line, sample);
    try script.expect(.{ .rwrdraw = 2 }); // answers the J+I Twrdraw
    try script.expect(.{ .rrddraw = &line }); // answers the Trddraw

    var d = DevDraw9.init(&c);
    try d.refreshLine();
    try testing.expectEqual(@as(u64, 1), d.conn_no);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 800, .y1 = 600 }, d.screenRect());
    // Exactly "JI" went out, with no leading free: nothing was installed yet.
    try testing.expectEqualStrings("JI", script.frame(0).?.msg.twrdraw);
    try testing.expectEqual(@as(u32, conn_line_len), script.frame(1).?.msg.trddraw);
}

test "dev_draw: a re-read frees image 0 first (getwindow, init.c:129-136)" {
    var script: Conn.Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());
    script.conn = &c;

    var line: [conn_line_len]u8 = undefined;
    buildLine(&line, sample);
    for (0..2) |i| {
        try script.expect(.{ .rwrdraw = if (i == 0) 2 else 7 });
        try script.expect(.{ .rrddraw = &line });
    }
    var d = DevDraw9.init(&c);
    try d.refreshLine();
    try d.refreshLine();
    const second = script.frame(2).?.msg.twrdraw;
    try testing.expectEqual(@as(usize, 7), second.len);
    try testing.expectEqual(@as(u8, 'f'), second[0]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, second[1..5], .little));
    try testing.expectEqual(@as(u8, 'J'), second[5]);
    try testing.expectEqual(@as(u8, 'I'), second[6]);
}

test "dev_draw: a data write forwards verbatim as Twrdraw" {
    var script: Conn.Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());
    script.conn = &c;

    var d = DevDraw9.init(&c);
    var fid: Fid = .{ .fid = 1, .qid = qidFor(.data), .omode = msg.ORDWR, .uname = @constCast("") };
    const bytes = [_]u8{ 'v', 'f', 1, 2, 3, 4 };
    try script.expect(.{ .rwrdraw = bytes.len });
    var srv: Server = undefined;
    const n = try DevDraw9.ops.write(&d, &srv, &fid, 0, &bytes);
    try testing.expectEqual(bytes.len, n);
    try testing.expectEqualSlices(u8, &bytes, script.frame(0).?.msg.twrdraw);
}

test "dev_draw: refresh yields the exposure rectangle exactly once" {
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    var d = DevDraw9.init(&c);
    d.noteResize(.{ .x0 = 0, .y0 = 0, .x1 = 640, .y1 = 480 });
    var fid: Fid = .{ .fid = 1, .qid = qidFor(.refresh), .omode = msg.OREAD, .uname = @constCast("") };
    var srv: Server = undefined;
    var buf: [refresh_rec_len]u8 = undefined;
    try testing.expectEqual(refresh_rec_len, try DevDraw9.ops.read(&d, &srv, &fid, 0, &buf));
    try testing.expectEqual(@as(i32, 640), std.mem.readInt(i32, buf[8..12], .little));
    try testing.expectEqual(@as(usize, 0), try DevDraw9.ops.read(&d, &srv, &fid, 0, &buf));
}

test "dev_draw: the connection directory is named from field 0" {
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    var d = DevDraw9.init(&c);
    buildLine(&d.line, .{ "7", "0", "x8r8g8b8", "0", "0", "0", "8", "8", "0", "0", "8", "8" });
    d.conn_no = parseField0(&d.line).?;
    try testing.expectEqual(@as(u64, 7), d.conn_no);
    var fid: Fid = .{ .fid = 1, .qid = qidFor(.root), .omode = null, .uname = @constCast("") };
    var srv: Server = undefined;
    try testing.expectEqual(qidFor(.conn), try DevDraw9.ops.walk1(&d, &srv, &fid, "7"));
    try testing.expectError(error.FileDoesNotExist, DevDraw9.ops.walk1(&d, &srv, &fid, "1"));
}
