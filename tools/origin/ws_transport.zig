//! Server-side WebSocket carrier for 9P frames (S-01 §3.2): one binary
//! WebSocket message == exactly one 9P message, size prefix included and
//! required to match the payload length. Text frames are not 9P and are
//! rejected; pings are answered here so the shim's 30 s keepalive never
//! reaches the protocol layer.
//!
//! Blocking by design: the origin runs one thread per connection, so
//! `readMsg` parks in the socket read and `WouldBlock` is never returned.
//! Guarantee 3 of `transport.zig` (an oversized frame stays queued) cannot
//! hold over a stream — the frame is consumed and `FrameTooBig` reported;
//! the peer honoured msize (S-01 §1) if it got here, so this is a protocol
//! violation, not a retry case.
const std = @import("std");
const ninep = @import("ninep");
const tp = ninep.transport;

const WebSocket = std.http.Server.WebSocket;
const header_size = ninep.msg.header_size;

pub const WsTransport = struct {
    ws: *WebSocket,
    closed: bool = false,

    pub fn transport(self: *WsTransport) tp.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: tp.Transport.VTable = .{
        .writeMsg = writeMsg,
        .readMsg = readMsg,
        .close = close,
    };

    fn writeMsg(ctx: *anyopaque, frame: []const u8) tp.Error!void {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        if (!validFrame(frame)) return error.BadFrame;
        self.ws.writeMessage(frame, .binary) catch {
            self.closed = true;
            return error.Closed;
        };
    }

    fn readMsg(ctx: *anyopaque, buf: []u8) tp.Error![]u8 {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        while (true) {
            const m = self.ws.readSmallMessage() catch {
                self.closed = true;
                return error.Closed;
            };
            switch (m.opcode) {
                .ping => {
                    self.ws.writeMessage(m.data, .pong) catch {
                        self.closed = true;
                        return error.Closed;
                    };
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
        self.closed = true;
        self.ws.writeMessage("", .connection_close) catch {};
    }
};

/// A well-formed 9P frame: at least a header, and `size[4]` == its length.
fn validFrame(frame: []const u8) bool {
    return frame.len >= header_size and
        std.mem.readInt(u32, frame[0..4], .little) == frame.len;
}

test "validFrame checks header and size prefix" {
    try std.testing.expect(validFrame(&.{ 7, 0, 0, 0, 100, 0, 0 }));
    try std.testing.expect(!validFrame(&.{ 8, 0, 0, 0, 100, 0, 0 })); // size != len
    try std.testing.expect(!validFrame(&.{ 3, 0, 0 })); // too short
}
