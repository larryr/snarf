//! Transport — the message-framed byte pipe under a 9P endpoint.
//!
//! A `Transport` moves whole 9P frames (a self-delimiting `size[4] ...` message,
//! S-01 §3.1) between a client and a server. It is deliberately the *keystone*
//! interface: `server.zig`, `client.zig`, and `chan.zig` all speak to each other
//! only through this vtable, so any duplex frame carrier (an in-process SPSC
//! pipe, a SharedArrayBuffer bridge to a worker, a WebSocket) can be dropped in
//! without touching the protocol code (S-01 §3.2).
//!
//! Semantic guarantees every conforming implementation MUST uphold:
//!   1. Frames are delivered intact, in order, exactly once. A `readMsg` returns
//!      exactly one frame as written by one `writeMsg`; frames never coalesce or
//!      split.
//!   2. `writeMsg` validates the frame: `frame.len >= header_size` (7) and the
//!      little-endian `size[4]` prefix equals `frame.len`; otherwise `BadFrame`
//!      and nothing is enqueued.
//!   3. If the caller's `readMsg` buffer is too small for the next frame, it
//!      returns `FrameTooBig` WITHOUT consuming the frame (the frame stays queued
//!      for a retry with a larger buffer).
//!   4. `close` is idempotent. After close, a peer keeps draining already-queued
//!      frames and only then sees `Closed`; further reads past the drain and all
//!      writes on a closed side return `Closed`.
//!   5. Zero-copy frame views are deferred (R7): `readMsg` copies into the
//!      caller-supplied buffer and returns a sub-slice of it.
//!
//! `WouldBlock` is the non-blocking signal: no frame available to read, or no
//! room to write right now. Callers pump their peer and retry (see client Pump).
const std = @import("std");

/// Errors a transport operation can surface. See guarantees above.
pub const Error = error{
    /// No frame available (read) or no room (write) right now; retry later.
    WouldBlock,
    /// This side (or its peer) is closed and fully drained.
    Closed,
    /// The next queued frame does not fit the supplied read buffer; the frame
    /// is left queued (guarantee 3).
    FrameTooBig,
    /// A write frame failed validation (too short, or size prefix != len).
    BadFrame,
};

/// A duplex, message-framed byte pipe. Thin vtable wrapper: holds an erased
/// `ctx` pointer and a static `VTable`. Copyable by value (it is just a pair of
/// pointers); the backing implementation owns all state.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Enqueue one whole frame. Upholds guarantee 2 (validation) and 4
        /// (Closed after close). May return `WouldBlock` if no room.
        writeMsg: *const fn (ctx: *anyopaque, frame: []const u8) Error!void,
        /// Dequeue the next whole frame into `buf`, returning a sub-slice of
        /// `buf`. Upholds guarantees 1, 3, 4. `WouldBlock` if none available.
        readMsg: *const fn (ctx: *anyopaque, buf: []u8) Error![]u8,
        /// Close this side. Idempotent (guarantee 4).
        close: *const fn (ctx: *anyopaque) void,
    };

    /// Write one whole 9P frame. See `VTable.writeMsg`.
    pub fn writeMsg(self: Transport, frame: []const u8) Error!void {
        return self.vtable.writeMsg(self.ctx, frame);
    }

    /// Read the next whole 9P frame into `buf`. See `VTable.readMsg`.
    pub fn readMsg(self: Transport, buf: []u8) Error![]u8 {
        return self.vtable.readMsg(self.ctx, buf);
    }

    /// Close this side of the transport. Idempotent.
    pub fn close(self: Transport) void {
        self.vtable.close(self.ctx);
    }
};

test "transport: vtable dispatch reaches ctx" {
    // A trivial in-test implementation exercises the wrapper's dispatch.
    const Stub = struct {
        wrote: usize = 0,
        closed: bool = false,

        fn writeMsg(ctx: *anyopaque, frame: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.wrote += frame.len;
        }
        fn readMsg(ctx: *anyopaque, buf: []u8) Error![]u8 {
            _ = ctx;
            _ = buf;
            return Error.WouldBlock;
        }
        fn close(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.closed = true;
        }
        const vtable: Transport.VTable = .{
            .writeMsg = writeMsg,
            .readMsg = readMsg,
            .close = close,
        };
    };

    var stub: Stub = .{};
    const t: Transport = .{ .ctx = &stub, .vtable = &Stub.vtable };
    try t.writeMsg(&.{ 1, 2, 3, 4, 5, 6, 7 });
    try std.testing.expectEqual(@as(usize, 7), stub.wrote);
    try std.testing.expectError(Error.WouldBlock, t.readMsg(&.{}));
    t.close();
    try std.testing.expect(stub.closed);
}
