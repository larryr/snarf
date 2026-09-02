//! Client-side WebSocket transport for 9P frames — the peer of
//! ws_transport.zig, used by the native acceptance tests (and by any future
//! native 9P client of the origin). RFC 6455 client rules: every frame we
//! send is masked; the server's frames are not. Blocking, like the server.
//!
//! The handshake key is a fixed constant: the key exists to defeat caching
//! proxies, not for security, and this client only ever talks to loopback.
const std = @import("std");
const Io = std.Io;
const ninep = @import("ninep");
const tp = ninep.transport;

const header_size = ninep.msg.header_size;

pub const WsClient = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    rbuf: []u8,
    wbuf: []u8,
    closed: bool = false,

    const mask_key = [4]u8{ 0x5a, 0x11, 0xc3, 0x7e };
    const handshake_key = "AQIDBAUGBwgJCgsMDQ4PEA=="; // base64 of 0x01..0x10

    /// Connect to loopback:`port`, upgrade `path`, and return a ready client.
    /// `capacity` bounds one frame in either direction (≥ the 9P msize).
    pub fn connect(gpa: std.mem.Allocator, io: Io, port: u16, path: []const u8, capacity: usize) !*WsClient {
        const self = try gpa.create(WsClient);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .stream = undefined,
            .reader = undefined,
            .writer = undefined,
            .rbuf = try gpa.alloc(u8, capacity),
            .wbuf = try gpa.alloc(u8, capacity),
        };
        errdefer gpa.free(self.rbuf);
        errdefer gpa.free(self.wbuf);

        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        self.stream = try addr.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);
        self.reader = self.stream.reader(io, self.rbuf);
        self.writer = self.stream.writer(io, self.wbuf);

        const w = &self.writer.interface;
        try w.print(
            "GET {s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, handshake_key },
        );
        try w.flush();

        const r = &self.reader.interface;
        const status = try r.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, status, "HTTP/1.1 101")) return error.UpgradeRefused;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (line.len <= 2) break; // the blank line ends the headers
        }
        return self;
    }

    pub fn deinit(self: *WsClient) void {
        self.stream.close(self.io);
        self.gpa.free(self.rbuf);
        self.gpa.free(self.wbuf);
        self.gpa.destroy(self);
    }

    pub fn transport(self: *WsClient) tp.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: tp.Transport.VTable = .{
        .writeMsg = writeMsg,
        .readMsg = readMsg,
        .close = close,
    };

    fn writeMsg(ctx: *anyopaque, frame: []const u8) tp.Error!void {
        const self: *WsClient = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        if (frame.len < header_size or std.mem.readInt(u32, frame[0..4], .little) != frame.len)
            return error.BadFrame;
        self.sendFrame(0x2, frame) catch {
            self.closed = true;
            return error.Closed;
        };
    }

    /// One masked frame: FIN + opcode, MASK + length, key, XOR'd payload.
    fn sendFrame(self: *WsClient, opcode: u8, payload: []const u8) !void {
        const w = &self.writer.interface;
        try w.writeByte(0x80 | opcode);
        if (payload.len < 126) {
            try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len <= 0xffff) {
            try w.writeByte(0x80 | 126);
            try w.writeInt(u16, @intCast(payload.len), .big);
        } else {
            try w.writeByte(0x80 | 127);
            try w.writeInt(u64, payload.len, .big);
        }
        try w.writeAll(&mask_key);
        var chunk: [512]u8 = undefined;
        var i: usize = 0;
        while (i < payload.len) {
            const n = @min(chunk.len, payload.len - i);
            for (chunk[0..n], payload[i..][0..n], 0..) |*dst, src, k| dst.* = src ^ mask_key[(i + k) % 4];
            try w.writeAll(chunk[0..n]);
            i += n;
        }
        try w.flush();
    }

    fn readMsg(ctx: *anyopaque, buf: []u8) tp.Error![]u8 {
        const self: *WsClient = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        return self.recvFrame(buf) catch |e| switch (e) {
            error.BadFrame, error.FrameTooBig => |known| known,
            else => {
                self.closed = true;
                return error.Closed;
            },
        };
    }

    fn recvFrame(self: *WsClient, buf: []u8) ![]u8 {
        const r = &self.reader.interface;
        while (true) {
            const h = try r.takeArray(2);
            const fin = h[0] & 0x80 != 0;
            const opcode = h[0] & 0x0f;
            const masked = h[1] & 0x80 != 0;
            var len: u64 = h[1] & 0x7f;
            if (len == 126) len = try r.takeInt(u16, .big) else if (len == 127) len = try r.takeInt(u64, .big);
            if (masked) return error.BadFrame; // servers never mask (RFC 6455 §5.1)
            switch (opcode) {
                0x8 => return error.Closed,
                0x9 => { // ping → pong with the same payload
                    var ping: [125]u8 = undefined;
                    if (len > ping.len) return error.BadFrame;
                    try r.readSliceAll(ping[0..@intCast(len)]);
                    try self.sendFrame(0xA, ping[0..@intCast(len)]);
                    continue;
                },
                0xA => { // unsolicited pong: skip
                    try r.discardAll64(len);
                    continue;
                },
                0x2 => {
                    if (!fin) return error.BadFrame; // no fragmentation in v1 (S-01 §3.2)
                    if (len > buf.len) {
                        try r.discardAll64(len);
                        return error.FrameTooBig;
                    }
                    const out = buf[0..@intCast(len)];
                    try r.readSliceAll(out);
                    if (out.len < header_size or std.mem.readInt(u32, out[0..4], .little) != out.len)
                        return error.BadFrame;
                    return out;
                },
                else => return error.BadFrame,
            }
        }
    }

    fn close(ctx: *anyopaque) void {
        const self: *WsClient = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        self.closed = true;
        self.sendFrame(0x8, "") catch {};
    }
};
