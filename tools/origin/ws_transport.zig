//! Server-side WebSocket carrier for 9P frames (S-01 §3.2): one binary
//! WebSocket message == exactly one 9P message, size prefix included and
//! required to match the payload length. Text frames are not 9P and are
//! rejected; pings are answered here so keepalive traffic never reaches the
//! protocol layer.
//!
//! Blocking by design: the origin runs one thread per connection, so
//! `readMsg` parks in the socket read and `WouldBlock` is never returned.
//! Guarantee 3 of `transport.zig` (an oversized frame stays queued) cannot
//! hold over a stream — the frame is consumed and `FrameTooBig` reported;
//! the peer honoured msize (S-01 §1) if it got here, so this is a protocol
//! violation, not a retry case.
//!
//! ## Keepalive (R-P12-8)
//!
//! The browser cannot send WebSocket pings from JS, so the origin pings and the
//! browser auto-pongs. Two pieces live here; `main.zig` owns the 30 s timer.
//!
//! 1. `ping` writes an (unmasked, per RFC 6455 §5.1) ping control frame. It runs
//!    on the KEEPALIVE thread while the connection thread may be replying to a
//!    9P request on the same `Writer`, so every write goes through `write_mu`.
//!    That mutex is the whole of the concurrency design: the connection thread
//!    owns the reader outright, so only the writer is shared (ruling R-P12-B2-2).
//! 2. `readAnyMessage` replaces `WebSocket.readSmallMessage`. std's version
//!    SILENTLY SKIPS pong frames (`std/http/Server.zig`, "// Skip pongs."), which
//!    makes "two missed pongs" unobservable. This is the same frame decode over
//!    the same public `Io.Reader` API, with pongs surfaced instead of swallowed
//!    so `pongs` can count them.
const std = @import("std");
const Io = std.Io;
const ninep = @import("ninep");
const tp = ninep.transport;

const WebSocket = std.http.Server.WebSocket;
const header_size = ninep.msg.header_size;

pub const WsTransport = struct {
    ws: *WebSocket,
    /// Needed for `write_mu`; the reader side never blocks on it.
    io: Io,
    closed: bool = false,
    /// Serializes every write to `ws.output`: 9P replies from the connection
    /// thread, pings and the close frame from the keepalive thread.
    write_mu: Io.Mutex = .init,
    /// Pong frames seen since the connection opened. The keepalive thread reads
    /// this to decide whether the peer is still answering (R-P12-8).
    pongs: std.atomic.Value(u32) = .init(0),

    pub fn transport(self: *WsTransport) tp.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: tp.Transport.VTable = .{
        .writeMsg = writeMsg,
        .readMsg = readMsg,
        .close = close,
    };

    /// Send one control/data frame under the write lock. Marks the connection
    /// closed on any write failure — the peer is gone.
    fn writeLocked(self: *WsTransport, data: []const u8, op: WebSocket.Opcode) bool {
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        self.ws.writeMessage(data, op) catch {
            self.closed = true;
            return false;
        };
        return true;
    }

    /// Send a keepalive ping (R-P12-8). False when the socket refused it, which
    /// is itself a dead connection. Safe to call from a thread other than the
    /// one running `readMsg`.
    pub fn ping(self: *WsTransport) bool {
        if (self.closed) return false;
        return self.writeLocked("", .ping);
    }

    fn writeMsg(ctx: *anyopaque, frame: []const u8) tp.Error!void {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        if (!validFrame(frame)) return error.BadFrame;
        if (!self.writeLocked(frame, .binary)) return error.Closed;
    }

    fn readMsg(ctx: *anyopaque, buf: []u8) tp.Error![]u8 {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        while (true) {
            const m = readAnyMessage(self.ws) catch {
                self.closed = true;
                return error.Closed;
            };
            switch (m.opcode) {
                .ping => {
                    if (!self.writeLocked(m.data, .pong)) return error.Closed;
                    continue;
                },
                // The browser's automatic answer to our keepalive: liveness
                // evidence for the ping thread, nothing for the 9P layer.
                .pong => {
                    _ = self.pongs.fetchAdd(1, .release);
                    continue;
                },
                .binary => {},
                else => return error.BadFrame,
            }
            if (!validFrame(m.data)) return error.BadFrame;
            if (m.data.len > buf.len) return error.FrameTooBig;
            @memcpy(buf[0..m.data.len], m.data);
            return buf[0..m.data.len];
        }
    }

    fn close(ctx: *anyopaque) void {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        _ = self.writeLocked("", .connection_close);
        self.closed = true;
    }
};

/// `WebSocket.readSmallMessage` with pongs SURFACED rather than skipped — the
/// one change that makes R-P12-8's missed-pong rule observable. Otherwise a
/// faithful copy of the std decode (RFC 6455 §5.2): a single unfragmented frame,
/// client→server so the mask bit is mandatory, payload length 7/16/64-bit,
/// unmasked in place.
fn readAnyMessage(ws: *WebSocket) WebSocket.ReadSmallTextMessageError!WebSocket.SmallMessage {
    const in = ws.input;
    const header = try in.takeArray(2);
    const h0: WebSocket.Header0 = @bitCast(header[0]);
    const h1: WebSocket.Header1 = @bitCast(header[1]);

    switch (h0.opcode) {
        .text, .binary, .pong, .ping => {},
        .connection_close => return error.ConnectionClose,
        .continuation => return error.UnexpectedOpCode,
        _ => return error.UnexpectedOpCode,
    }
    if (!h0.fin) return error.MessageOversize;
    if (!h1.mask) return error.MissingMaskBit;

    const len: usize = switch (h1.payload_len) {
        .len16 => try in.takeInt(u16, .big),
        .len64 => std.math.cast(usize, try in.takeInt(u64, .big)) orelse return error.MessageOversize,
        else => @intFromEnum(h1.payload_len),
    };
    if (len > in.buffer.len) return error.MessageOversize;
    const mask: u32 = @bitCast((try in.takeArray(4)).*);
    const payload = try in.take(len);

    // Unmask a word at a time; the tail may be a partial word.
    const floored_len = (payload.len / 4) * 4;
    const u32_payload: []align(1) u32 = @ptrCast(payload[0..floored_len]);
    for (u32_payload) |*elem| elem.* ^= mask;
    const mask_bytes: []const u8 = @ptrCast(&mask);
    for (payload[floored_len..], mask_bytes[0 .. payload.len - floored_len]) |*leftover, m|
        leftover.* ^= m;

    return .{ .opcode = h0.opcode, .data = payload };
}

/// A well-formed 9P frame: at least a header, and `size[4]` == its length.
fn validFrame(frame: []const u8) bool {
    return frame.len >= header_size and
        std.mem.readInt(u32, frame[0..4], .little) == frame.len;
}

// ==========================================================================
// Tests
// ==========================================================================
const testing = std.testing;

test "validFrame checks header and size prefix" {
    try testing.expect(validFrame(&.{ 7, 0, 0, 0, 100, 0, 0 }));
    try testing.expect(!validFrame(&.{ 8, 0, 0, 0, 100, 0, 0 })); // size != len
    try testing.expect(!validFrame(&.{ 3, 0, 0 })); // too short
}

/// Frame `payload` the way a BROWSER would: client→server frames are masked
/// (RFC 6455 §5.3), which is exactly what `readAnyMessage` must undo.
fn maskedFrame(out: []u8, op: WebSocket.Opcode, payload: []const u8, mask: [4]u8) []u8 {
    std.debug.assert(payload.len < 126);
    out[0] = @bitCast(@as(WebSocket.Header0, .{ .opcode = op, .fin = true }));
    out[1] = @bitCast(@as(WebSocket.Header1, .{
        .payload_len = @enumFromInt(payload.len),
        .mask = true,
    }));
    @memcpy(out[2..6], &mask);
    for (payload, 0..) |b, i| out[6 + i] = b ^ mask[i % 4];
    return out[0 .. 6 + payload.len];
}

test "ping writes an unmasked control frame (RFC 6455 server→client)" {
    var out_buf: [64]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var in = Io.Reader.fixed(&.{});
    var ws: WebSocket = .{ .key = "", .input = &in, .output = &out };
    var t: WsTransport = .{ .ws = &ws, .io = testing.io };

    try testing.expect(t.ping());
    const bytes = out.buffered();
    // FIN=1, rsv=0, opcode=9 (ping); length 0 with the mask bit CLEAR — a
    // server must never mask (§5.1), and the payload is empty.
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x00 }, bytes);
}

test "a pong is counted, not mistaken for a 9P frame" {
    // The browser's automatic answer to our ping, followed by a real 9P frame.
    var wire: [128]u8 = undefined;
    const pong = maskedFrame(wire[0..], .pong, "", .{ 1, 2, 3, 4 });
    const nine = maskedFrame(wire[pong.len..], .binary, &.{ 7, 0, 0, 0, 100, 0, 0 }, .{ 9, 8, 7, 6 });

    var in = Io.Reader.fixed(wire[0 .. pong.len + nine.len]);
    var out_buf: [64]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var ws: WebSocket = .{ .key = "", .input = &in, .output = &out };
    var t: WsTransport = .{ .ws = &ws, .io = testing.io };

    // The pong is consumed silently and the 9P frame behind it still arrives.
    var buf: [64]u8 = undefined;
    const got = try WsTransport.readMsg(&t, &buf);
    try testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 100, 0, 0 }, got);
    try testing.expectEqual(@as(u32, 1), t.pongs.load(.acquire));
    // Nothing was written back: a pong needs no answer (§5.5.3).
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
}

test "an inbound ping is answered with its own payload" {
    var wire: [64]u8 = undefined;
    const frame = maskedFrame(&wire, .ping, "hi", .{ 5, 5, 5, 5 });
    var in = Io.Reader.fixed(frame);
    var out_buf: [64]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var ws: WebSocket = .{ .key = "", .input = &in, .output = &out };
    var t: WsTransport = .{ .ws = &ws, .io = testing.io };

    // Only the ping is on the wire, so the read ends at EOF — after replying.
    var buf: [64]u8 = undefined;
    try testing.expectError(error.Closed, WsTransport.readMsg(&t, &buf));
    // 0x8A = FIN|pong, len 2, unmasked, echoing the ping's unmasked payload.
    try testing.expectEqualSlices(u8, &.{ 0x8A, 0x02, 'h', 'i' }, out.buffered());
    try testing.expectEqual(@as(u32, 0), t.pongs.load(.acquire));
}

test "readAnyMessage unmasks a payload longer than one word" {
    var wire: [64]u8 = undefined;
    const payload = "abcdefghij"; // 10 bytes: two whole words plus a 2-byte tail
    const frame = maskedFrame(&wire, .binary, payload, .{ 0x11, 0x22, 0x33, 0x44 });
    var in = Io.Reader.fixed(frame);
    var out_buf: [8]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var ws: WebSocket = .{ .key = "", .input = &in, .output = &out };

    const m = try readAnyMessage(&ws);
    try testing.expectEqual(WebSocket.Opcode.binary, m.opcode);
    try testing.expectEqualStrings(payload, m.data);
}

test "an unmasked client frame is rejected" {
    // §5.1: a client MUST mask. std's decoder and ours both refuse otherwise.
    var wire: [8]u8 = undefined;
    wire[0] = @bitCast(@as(WebSocket.Header0, .{ .opcode = .binary, .fin = true }));
    wire[1] = @bitCast(@as(WebSocket.Header1, .{ .payload_len = @enumFromInt(0), .mask = false }));
    var in = Io.Reader.fixed(wire[0..2]);
    var out_buf: [8]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var ws: WebSocket = .{ .key = "", .input = &in, .output = &out };

    try testing.expectError(error.MissingMaskBit, readAnyMessage(&ws));
}
