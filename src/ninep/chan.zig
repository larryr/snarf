//! chan.zig — SPSC byte ring + in-process Pipe loopback transport.
//!
//! `Ring` is a single-producer/single-consumer byte ring over a caller-supplied
//! buffer — no allocation happens here, so a SharedArrayBuffer-backed slice can
//! be dropped in later without changing this file. `Pipe` composes two `Ring`s
//! into a duplex `transport.Transport` pair for in-process client/server
//! loopback (used by tests today; a worker bridge later). A 9P frame is
//! `size[4] type[1] tag[2] ...`, little-endian, minimum legal length 7 bytes
//! (S-01 §3.1). See `agents/contracts/phase1-ninep.md` §6.
//!
//! Imports: std + transport.zig only (S-07 §6). Framing-agnostic beyond the
//! 4-byte size prefix — does not import msg.zig.
const std = @import("std");
const transport = @import("transport.zig");

/// Minimum legal 9P frame length: size[4] type[1] tag[2] (S-01 §3.1).
const min_frame_len: usize = 7;
/// Length of the little-endian frame-size prefix every frame starts with.
const size_prefix_len: usize = 4;

/// Single-producer/single-consumer byte ring over `buf`. `head` (consumer
/// position) and `tail` (producer position) are monotonically increasing
/// `usize` counters; the byte position in `buf` is `idx % buf.len` (capacity
/// need not be a power of two). Field order keeps `head`/`tail` adjacent so
/// they can become atomics later without a layout change.
pub const Ring = struct {
    buf: []u8,
    head: usize = 0,
    tail: usize = 0,
    closed: bool = false,

    /// Wrap `buf` as a ring. Asserts `buf.len > 0` and `buf.len < 1 << 31`
    /// (capacity stays well below the point where `tail -% head` wraparound
    /// arithmetic could misread full-vs-empty).
    pub fn init(buf: []u8) Ring {
        std.debug.assert(buf.len > 0);
        std.debug.assert(buf.len < (1 << 31));
        return .{ .buf = buf };
    }

    /// Bytes currently available to `pop`/`peek`.
    pub fn readable(self: *const Ring) usize {
        return self.tail -% self.head;
    }

    /// Bytes of room currently available to `push`.
    pub fn writable(self: *const Ring) usize {
        return self.buf.len - self.readable();
    }

    /// Copy up to `src.len` bytes in, wrapping at `buf.len`. Returns the
    /// number of bytes actually copied — may be less than `src.len` (or 0) if
    /// the ring does not have enough room.
    pub fn push(self: *Ring, src: []const u8) usize {
        const n = @min(src.len, self.writable());
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.buf[(self.tail +% i) % self.buf.len] = src[i];
        }
        self.tail +%= n;
        return n;
    }

    /// Copy up to `dst.len` bytes out, wrapping at `buf.len`, consuming them.
    /// Returns the number of bytes actually copied.
    pub fn pop(self: *Ring, dst: []u8) usize {
        const n = self.peek(dst);
        self.head +%= n;
        return n;
    }

    /// Like `pop` but does not consume: `head` is left unchanged.
    pub fn peek(self: *const Ring, dst: []u8) usize {
        const n = @min(dst.len, self.readable());
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dst[i] = self.buf[(self.head +% i) % self.buf.len];
        }
        return n;
    }

    /// Mark the ring closed. Idempotent.
    pub fn close(self: *Ring) void {
        self.closed = true;
    }
};

/// One direction of a `Pipe`: the pair of rings a `Transport` end reads and
/// writes. Embedded inside `Pipe` (never separately allocated) so its address
/// stays stable for the `Pipe`'s lifetime — `Transport.ctx` needs a pointer
/// that outlives any individual call (S-01 §3.2).
const Endpoint = struct {
    tx: *Ring,
    rx: *Ring,

    fn writeMsg(ctx: *anyopaque, frame: []const u8) transport.Error!void {
        const self: *Endpoint = @ptrCast(@alignCast(ctx));
        if (frame.len < min_frame_len) return transport.Error.BadFrame;
        const prefix = std.mem.readInt(u32, frame[0..size_prefix_len], .little);
        if (prefix != frame.len) return transport.Error.BadFrame;
        if (frame.len > self.tx.buf.len) return transport.Error.FrameTooBig;
        if (self.tx.closed) return transport.Error.Closed;
        if (self.tx.writable() < frame.len) return transport.Error.WouldBlock;
        const n = self.tx.push(frame);
        std.debug.assert(n == frame.len); // guarded by the writable() check above
    }

    fn readMsg(ctx: *anyopaque, buf: []u8) transport.Error![]u8 {
        const self: *Endpoint = @ptrCast(@alignCast(ctx));
        if (self.rx.readable() < size_prefix_len) {
            if (self.rx.closed and self.rx.readable() == 0) return transport.Error.Closed;
            return transport.Error.WouldBlock;
        }
        var prefix_bytes: [size_prefix_len]u8 = undefined;
        std.debug.assert(self.rx.peek(&prefix_bytes) == size_prefix_len);
        const size = std.mem.readInt(u32, &prefix_bytes, .little);
        if (size < min_frame_len or size > self.rx.buf.len) return transport.Error.BadFrame;
        if (size > buf.len) return transport.Error.FrameTooBig;
        if (self.rx.readable() < size) return transport.Error.WouldBlock;
        const n = self.rx.pop(buf[0..size]);
        std.debug.assert(n == size);
        return buf[0..size];
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *Endpoint = @ptrCast(@alignCast(ctx));
        self.tx.close();
    }

    const vtable: transport.Transport.VTable = .{
        .writeMsg = writeMsg,
        .readMsg = readMsg,
        .close = closeFn,
    };
};

/// Heap-allocated in-process duplex loopback: two `capacity`-byte `Ring`s
/// (`c2s`, `s2c`) wired into a client `Transport` and a server `Transport`.
/// Heap-allocated (not a stack value) so the `Endpoint` pointers handed out as
/// `Transport.ctx` stay valid for the `Pipe`'s whole lifetime.
pub const Pipe = struct {
    allocator: std.mem.Allocator,
    c2s_buf: []u8,
    s2c_buf: []u8,
    c2s: Ring,
    s2c: Ring,
    client_ep: Endpoint,
    server_ep: Endpoint,

    /// Allocate a `Pipe` with two `capacity`-byte rings: client-to-server
    /// (`c2s`) and server-to-client (`s2c`).
    pub fn init(allocator: std.mem.Allocator, capacity: usize) error{OutOfMemory}!*Pipe {
        const self = try allocator.create(Pipe);
        errdefer allocator.destroy(self);
        const c2s_buf = try allocator.alloc(u8, capacity);
        errdefer allocator.free(c2s_buf);
        const s2c_buf = try allocator.alloc(u8, capacity);
        errdefer allocator.free(s2c_buf);

        self.* = .{
            .allocator = allocator,
            .c2s_buf = c2s_buf,
            .s2c_buf = s2c_buf,
            .c2s = Ring.init(c2s_buf),
            .s2c = Ring.init(s2c_buf),
            .client_ep = undefined,
            .server_ep = undefined,
        };
        self.client_ep = .{ .tx = &self.c2s, .rx = &self.s2c };
        self.server_ep = .{ .tx = &self.s2c, .rx = &self.c2s };
        return self;
    }

    /// Free both ring buffers and the `Pipe` itself.
    pub fn deinit(self: *Pipe) void {
        self.allocator.free(self.c2s_buf);
        self.allocator.free(self.s2c_buf);
        self.allocator.destroy(self);
    }

    /// The client side: writes enqueue on `c2s`, reads dequeue from `s2c`.
    pub fn clientEnd(self: *Pipe) transport.Transport {
        return .{ .ctx = &self.client_ep, .vtable = &Endpoint.vtable };
    }

    /// The server side: writes enqueue on `s2c`, reads dequeue from `c2s`.
    pub fn serverEnd(self: *Pipe) transport.Transport {
        return .{ .ctx = &self.server_ep, .vtable = &Endpoint.vtable };
    }
};

// ---- tests -----------------------------------------------------------------

/// Build a well-formed frame `size[4] type[1] tag[2] body` into `buf` (which
/// must be at least `7 + body.len` bytes) and return the frame slice.
/// Test-only helper; chan itself never constructs frames.
fn testFrame(buf: []u8, type_byte: u8, tag: u16, body: []const u8) []u8 {
    const total: u32 = @intCast(min_frame_len + body.len);
    std.mem.writeInt(u32, buf[0..4], total, .little);
    buf[4] = type_byte;
    std.mem.writeInt(u16, buf[5..7], tag, .little);
    @memcpy(buf[7..][0..body.len], body);
    return buf[0..total];
}

test "ring: round trip" {
    var buf: [16]u8 = undefined;
    var r = Ring.init(&buf);
    const data = "hello, ring!";
    try std.testing.expectEqual(data.len, r.push(data));
    try std.testing.expectEqual(@as(usize, data.len), r.readable());

    var out: [data.len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, data.len), r.pop(&out));
    try std.testing.expectEqualStrings(data, &out);
    try std.testing.expectEqual(@as(usize, 0), r.readable());
    try std.testing.expectEqual(@as(usize, buf.len), r.writable());
}

test "ring: wrap-around" {
    var buf: [8]u8 = undefined;
    var r = Ring.init(&buf);

    const first = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expectEqual(@as(usize, 6), r.push(&first));
    var drained: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), r.pop(&drained));
    try std.testing.expectEqualSlices(u8, &first, &drained);

    // head/tail are now both at 6; the next push of 5 bytes wraps past the
    // end of the 8-byte buffer (positions 6,7,0,1,2).
    const second = [_]u8{ 10, 20, 30, 40, 50 };
    try std.testing.expectEqual(@as(usize, 5), r.push(&second));
    var out: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), r.pop(&out));
    try std.testing.expectEqualSlices(u8, &second, &out);
}

test "ring: full/empty boundaries" {
    var buf: [4]u8 = undefined;
    var r = Ring.init(&buf);

    try std.testing.expectEqual(@as(usize, 0), r.readable());
    try std.testing.expectEqual(@as(usize, 4), r.writable());

    const four = [_]u8{ 9, 9, 9, 9 };
    try std.testing.expectEqual(@as(usize, 4), r.push(&four));
    try std.testing.expectEqual(@as(usize, 4), r.readable());
    try std.testing.expectEqual(@as(usize, 0), r.writable());
    try std.testing.expectEqual(r.buf.len, r.tail -% r.head); // full

    // Ring is full: pushing more copies nothing.
    try std.testing.expectEqual(@as(usize, 0), r.push(&.{1}));

    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), r.pop(&out));
    try std.testing.expectEqual(@as(usize, 0), r.tail -% r.head); // empty
    try std.testing.expectEqual(@as(usize, 0), r.readable());

    // Ring is empty: popping more copies nothing.
    try std.testing.expectEqual(@as(usize, 0), r.pop(&out));
}

test "ring: peek does not consume" {
    var buf: [8]u8 = undefined;
    var r = Ring.init(&buf);
    const data = [_]u8{ 5, 6, 7 };
    _ = r.push(&data);

    var peeked: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), r.peek(&peeked));
    try std.testing.expectEqualSlices(u8, &data, &peeked);
    try std.testing.expectEqual(@as(usize, 3), r.readable()); // unchanged

    var popped: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), r.pop(&popped));
    try std.testing.expectEqualSlices(u8, &data, &popped);
    try std.testing.expectEqual(@as(usize, 0), r.readable());
}

test "pipe: loopback frames intact" {
    const gpa = std.testing.allocator;
    const p = try Pipe.init(gpa, 4096);
    defer p.deinit();
    const client = p.clientEnd();
    const server = p.serverEnd();

    var fbuf: [64]u8 = undefined;
    const c1 = testFrame(&fbuf, 100, 1, "first client frame");
    try client.writeMsg(c1);
    var fbuf2: [64]u8 = undefined;
    const c2 = testFrame(&fbuf2, 101, 2, "second, different, client frame");
    try client.writeMsg(c2);

    var readbuf: [64]u8 = undefined;
    const got1 = try server.readMsg(&readbuf);
    try std.testing.expectEqualSlices(u8, c1, got1);
    var readbuf2: [64]u8 = undefined;
    const got2 = try server.readMsg(&readbuf2);
    try std.testing.expectEqualSlices(u8, c2, got2);

    var sbuf: [64]u8 = undefined;
    const s1 = testFrame(&sbuf, 102, 3, "first server reply");
    try server.writeMsg(s1);
    var sbuf2: [64]u8 = undefined;
    const s2 = testFrame(&sbuf2, 103, 4, "second server reply, longer");
    try server.writeMsg(s2);

    var rr1: [64]u8 = undefined;
    const gs1 = try client.readMsg(&rr1);
    try std.testing.expectEqualSlices(u8, s1, gs1);
    var rr2: [64]u8 = undefined;
    const gs2 = try client.readMsg(&rr2);
    try std.testing.expectEqualSlices(u8, s2, gs2);
}

test "pipe: empty read WouldBlock" {
    const gpa = std.testing.allocator;
    const p = try Pipe.init(gpa, 256);
    defer p.deinit();

    var buf: [64]u8 = undefined;
    try std.testing.expectError(transport.Error.WouldBlock, p.serverEnd().readMsg(&buf));
    try std.testing.expectError(transport.Error.WouldBlock, p.clientEnd().readMsg(&buf));
}

test "pipe: write full WouldBlock, atomic" {
    const gpa = std.testing.allocator;
    const p = try Pipe.init(gpa, 32);
    defer p.deinit();
    const client = p.clientEnd();
    const server = p.serverEnd();

    var fbuf: [20]u8 = undefined;
    const f1 = testFrame(&fbuf, 1, 1, "0123456789012"); // 13-byte body -> 20 bytes total
    try std.testing.expectEqual(@as(usize, 20), f1.len);
    try client.writeMsg(f1);
    try std.testing.expectEqual(@as(usize, 20), p.c2s.readable());

    // A second 20-byte frame needs 20 more bytes but only 12 remain: must
    // block, and must not partially enqueue (readable() stays exactly 20).
    var fbuf2: [20]u8 = undefined;
    const f2 = testFrame(&fbuf2, 2, 2, "9876543210987");
    try std.testing.expectError(transport.Error.WouldBlock, client.writeMsg(f2));
    try std.testing.expectEqual(@as(usize, 20), p.c2s.readable());

    // Drain the first frame, then the retry succeeds.
    var rbuf: [20]u8 = undefined;
    const got1 = try server.readMsg(&rbuf);
    try std.testing.expectEqualSlices(u8, f1, got1);
    try client.writeMsg(f2);
    var rbuf2: [20]u8 = undefined;
    const got2 = try server.readMsg(&rbuf2);
    try std.testing.expectEqualSlices(u8, f2, got2);
}

test "pipe: FrameTooBig" {
    const gpa = std.testing.allocator;
    const p = try Pipe.init(gpa, 16);
    defer p.deinit();
    const client = p.clientEnd();
    const server = p.serverEnd();

    // Write side: frame bigger than ring capacity.
    var big: [64]u8 = undefined;
    const oversized = testFrame(&big, 1, 1, "this body makes the frame way bigger than 16");
    try std.testing.expectError(transport.Error.FrameTooBig, client.writeMsg(oversized));
    try std.testing.expectEqual(@as(usize, 0), p.c2s.readable()); // nothing enqueued

    // Read side: a frame that fits the ring but not the caller's tiny buffer.
    var fbuf: [14]u8 = undefined; // 14 <= capacity 16
    const f = testFrame(&fbuf, 2, 2, "1234567");
    try client.writeMsg(f);

    var tiny: [4]u8 = undefined;
    try std.testing.expectError(transport.Error.FrameTooBig, server.readMsg(&tiny));
    try std.testing.expectEqual(@as(usize, f.len), p.c2s.readable()); // still queued

    var right_size: [14]u8 = undefined;
    const got = try server.readMsg(&right_size);
    try std.testing.expectEqualSlices(u8, f, got);
}

test "pipe: BadFrame" {
    const gpa = std.testing.allocator;
    const p = try Pipe.init(gpa, 64);
    defer p.deinit();
    const client = p.clientEnd();

    // Size prefix disagrees with the actual frame length.
    var bad_prefix: [10]u8 = undefined;
    std.mem.writeInt(u32, bad_prefix[0..4], 999, .little);
    bad_prefix[4] = 1;
    std.mem.writeInt(u16, bad_prefix[5..7], 1, .little);
    bad_prefix[7..10].* = .{ 1, 2, 3 };
    try std.testing.expectError(transport.Error.BadFrame, client.writeMsg(&bad_prefix));

    // Frame shorter than the 7-byte minimum header.
    var too_short: [5]u8 = undefined;
    std.mem.writeInt(u32, too_short[0..4], 5, .little);
    too_short[4] = 1;
    try std.testing.expectError(transport.Error.BadFrame, client.writeMsg(&too_short));

    try std.testing.expectEqual(@as(usize, 0), p.c2s.readable());
}

test "pipe: close semantics" {
    const gpa = std.testing.allocator;
    const p = try Pipe.init(gpa, 256);
    defer p.deinit();
    const client = p.clientEnd();
    const server = p.serverEnd();

    var fbuf: [12]u8 = undefined;
    const f = testFrame(&fbuf, 1, 1, "hi");
    try client.writeMsg(f);

    client.close();

    // Server still drains the frame that was already queued before close.
    var rbuf: [12]u8 = undefined;
    const got = try server.readMsg(&rbuf);
    try std.testing.expectEqualSlices(u8, f, got);

    // Once drained, the server sees Closed.
    try std.testing.expectError(transport.Error.Closed, server.readMsg(&rbuf));

    // The client itself cannot write anymore either.
    try std.testing.expectError(transport.Error.Closed, client.writeMsg(f));
}
