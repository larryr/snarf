//! WsTransport — one browser WebSocket carrying 9P frames (R-P12-3), the
//! client-side twin of `tools/origin/ws_transport.zig`.
//!
//! Framing mirrors R-P11-3 exactly: binary messages only, ONE 9P message per
//! WebSocket message, `size[4]` required to equal the payload length. A
//! violation poisons the connection — the socket is closed and the queue
//! dropped, because a stream that has lost frame alignment cannot be resynced.
//!
//! Two halves, both non-blocking:
//!   - outbound: `writeMsg` hands the frame straight to the `abi.wsSend` import.
//!   - inbound:  the shim copies each arriving frame into the module's staging
//!     buffer and calls the `wsPush` export, which lands here as `pushRecord`.
//!     `readMsg` pops that queue and NEVER parks (R-P12-4): an empty queue on a
//!     live socket is `error.WouldBlock`, and the phase-6 async client's pump
//!     (`client.zig` drain) reads that as "nothing ready" and retries next tick.
//!
//! Layering (S-07 §6: `shim/*` → `std` only): this file does NOT import `ninep`.
//! `transport()` is comptime-generic over the vtable type, so the wasm root —
//! which imports both — writes `ws.transport(ninep.transport.Transport)` and
//! gets a real `Transport`. The error set below is member-identical to
//! `ninep.transport.Error`, so the generated function pointers coerce.
//!
//! Memory: the queue and every queued frame belong to the allocator handed to
//! `init` (no globals, CLAUDE.md). `deinit` frees whatever is still queued.
const std = @import("std");
const abi = @import("abi.zig");

const WsTransport = @This();

/// Mirror of `ninep.transport.Error` — same members, same meaning (see the
/// guarantees in `src/ninep/transport.zig`). Kept as a local declaration only
/// because this module may not import `ninep`; error sets are structural, so
/// values raised here ARE the values `ninep` matches on.
pub const Error = error{
    /// No frame queued right now on a live socket; pump and retry (R-P12-4).
    WouldBlock,
    /// The socket is gone (closed locally, closed/errored remotely, or never
    /// dialed) and the inbound queue is drained.
    Closed,
    /// The next queued frame does not fit `buf`; it stays queued (guarantee 3).
    FrameTooBig,
    /// A frame failed validation: shorter than a header, or `size[4]` != len.
    BadFrame,
};

/// Where the socket is. `idle` until `dial()`, `connecting` until the shim's
/// `onopen` arrives as a `.open` record, `closed` for good after any of local
/// `close()`, remote close, socket error, or a framing violation. There is no
/// path back to `open`: R-P12-6 forbids silent reconnects — `Reconnect` builds
/// a fresh transport.
pub const State = enum { idle, connecting, open, closed };

/// Why the connection ended — B2's warning line (R-P12-5/6/7) reports this
/// alongside `reasonText()`.
pub const Reason = enum { none, local, remote, socket_error, bad_frame, out_of_memory };

/// A 9P header: `size[4] type[1] tag[2]`. Mirrors `ninep.msg.header_size`,
/// which this module may not import (S-07 §6).
const header_size: usize = 7;

/// Longest close/error text retained; the rest is truncated. Fixed storage so a
/// dying socket never needs an allocation to explain itself.
const reason_cap: usize = 96;

allocator: std.mem.Allocator,
/// Connection id shared with the shim; every `abi.ws*` call carries it.
id: u32,
conn_state: State = .idle,
reason: Reason = .none,
reason_buf: [reason_cap]u8 = undefined,
reason_len: usize = 0,
/// FIFO of owned inbound frames; `head` is the read cursor, and the list is
/// compacted (and its memory retained) whenever it drains empty.
queue: std.ArrayList([]u8) = .empty,
head: usize = 0,
/// A one-shot error delivered by the next `readMsg` so the pump learns WHY the
/// connection died; afterwards reads fall through to the normal drain/`Closed`.
fault: ?Error = null,

/// A transport for connection `id`, not yet dialed. Call `dial()` to start.
pub fn init(allocator: std.mem.Allocator, id: u32) WsTransport {
    return .{ .allocator = allocator, .id = id };
}

/// Free every queued frame and the queue itself. Does not close the socket —
/// call `close()` first if it may still be live.
pub fn deinit(self: *WsTransport) void {
    self.dropQueue();
    self.queue.deinit(self.allocator);
}

/// Ask the shim to open the socket (R-P12-1: it derives the same-origin URL;
/// the module never sees one). Returns immediately — boot does not wait
/// (R-P12-5). A second dial on a live or dead transport is ignored.
pub fn dial(self: *WsTransport) void {
    if (self.conn_state != .idle) return;
    self.conn_state = .connecting;
    abi.wsOpen(self.id);
}

/// Current connection state — B2 polls this to decide when to attach, and to
/// notice a death (R-P12-6).
pub fn state(self: *const WsTransport) State {
    return self.conn_state;
}

/// True once the shim has reported `onopen` and the socket has not since died.
pub fn isOpen(self: *const WsTransport) bool {
    return self.conn_state == .open;
}

/// The close/error text the shim supplied (empty when there is none). Valid
/// until the next state change; copy it if it must outlive that.
pub fn reasonText(self: *const WsTransport) []const u8 {
    return self.reason_buf[0..self.reason_len];
}

/// Number of frames waiting to be read — diagnostics only; `readMsg`'s
/// `WouldBlock` is the signal that matters.
pub fn pending(self: *const WsTransport) usize {
    return self.queue.items.len - self.head;
}

/// The inbound entry point (R-P12-2). `web/shim.js` stages the bytes into wasm
/// memory and calls the `wsPush` export, which forwards here:
///   - `.open`  — `onopen`; `bytes` empty. connecting → open.
///   - `.data`  — one binary message; `bytes` must be exactly one 9P frame.
///   - `.close` — `onclose`; `bytes` is "code reason" for the warning line.
///   - `.err`   — `onerror`; same shape.
/// Only queues; nothing is dispatched here, so there is no JS→WASM re-entrancy
/// (R-P12-2) — the module drains on `tick()`.
///
/// The only failure is the frame copy: on OOM the connection is poisoned (a
/// dropped frame desynchronizes the 9P stream, so it cannot be ignored) and the
/// error is returned as well, for the caller's log line.
pub fn pushRecord(self: *WsTransport, kind: abi.WsKind, bytes: []const u8) std.mem.Allocator.Error!void {
    switch (kind) {
        .open => if (self.conn_state == .connecting) {
            self.conn_state = .open;
        },
        .data => {
            // A frame arriving after the socket died is stale: drop it rather
            // than resurrect a queue nobody will drain.
            if (self.conn_state == .closed) return;
            if (!validFrame(bytes)) return self.poison(.bad_frame, "malformed 9P frame", Error.BadFrame);
            const copy = self.allocator.dupe(u8, bytes) catch |e| {
                self.poison(.out_of_memory, "out of memory", Error.Closed);
                return e;
            };
            self.queue.append(self.allocator, copy) catch |e| {
                self.allocator.free(copy);
                self.poison(.out_of_memory, "out of memory", Error.Closed);
                return e;
            };
        },
        // Remote death keeps the queue: frames delivered before the close are
        // still real replies (transport.zig guarantee 4 — drain, then `Closed`).
        .close => self.markDown(.remote, bytes),
        .err => self.markDown(.socket_error, bytes),
    }
}

/// Send one whole 9P frame as one binary WebSocket message (R-P12-3).
/// `WouldBlock` while the dial is still in flight — the caller retries on the
/// next tick rather than parking (R-P12-4).
pub fn writeMsg(self: *WsTransport, frame: []const u8) Error!void {
    switch (self.conn_state) {
        .open => {},
        .connecting => return Error.WouldBlock,
        .idle, .closed => return Error.Closed,
    }
    if (!validFrame(frame)) return Error.BadFrame;
    abi.wsSend(self.id, frame.ptr, @intCast(frame.len));
}

/// Pop the next inbound frame into `buf`, returning a sub-slice of it. NEVER
/// parks (R-P12-4): an empty queue on a live socket is `WouldBlock`, and once
/// the socket is dead and drained it is `Closed`. A frame too big for `buf`
/// stays queued (guarantee 3).
pub fn readMsg(self: *WsTransport, buf: []u8) Error![]u8 {
    if (self.fault) |f| {
        self.fault = null; // one-shot: report the cause once, then behave normally
        return f;
    }
    if (self.head < self.queue.items.len) {
        const frame = self.queue.items[self.head];
        if (frame.len > buf.len) return Error.FrameTooBig;
        @memcpy(buf[0..frame.len], frame);
        self.head += 1;
        self.allocator.free(frame);
        if (self.head == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        }
        return buf[0..frame.len];
    }
    return switch (self.conn_state) {
        // `idle` is "dial not started yet", not a failure: the boot path dials
        // and polls, so treat it like a live-but-empty socket.
        .idle, .connecting, .open => Error.WouldBlock,
        .closed => Error.Closed,
    };
}

/// Close the socket. Idempotent. Unlike a REMOTE close, a local close abandons
/// the queue: the caller is walking away from this connection (R-P12-6 fails
/// its outstanding tickets), so every later op reports `Closed`.
pub fn close(self: *WsTransport) void {
    if (self.conn_state == .closed) return;
    const was_live = self.conn_state != .idle;
    self.conn_state = .closed;
    self.setReason(.local, "closed locally");
    self.fault = null;
    self.dropQueue();
    if (was_live) abi.wsClose(self.id);
}

/// Build a `ninep.transport.Transport` over this connection WITHOUT importing
/// `ninep` (S-07 §6). The caller — `src/main_wasm.zig`, the one root that sees
/// both modules — passes the type:
///
///     const t = ws.transport(ninep.transport.Transport);
///
/// The generated thunks return this file's `Error`, whose members are identical
/// to `ninep.transport.Error`, so the vtable's function pointers coerce.
pub fn transport(self: *WsTransport, comptime T: type) T {
    const gen = struct {
        fn ctxOf(ctx: *anyopaque) *WsTransport {
            return @ptrCast(@alignCast(ctx));
        }
        fn writeMsg(ctx: *anyopaque, frame: []const u8) Error!void {
            return ctxOf(ctx).writeMsg(frame);
        }
        fn readMsg(ctx: *anyopaque, buf: []u8) Error![]u8 {
            return ctxOf(ctx).readMsg(buf);
        }
        fn close(ctx: *anyopaque) void {
            ctxOf(ctx).close();
        }
    };
    return .{
        .ctx = self,
        .vtable = &.{ .writeMsg = gen.writeMsg, .readMsg = gen.readMsg, .close = gen.close },
    };
}

/// A well-formed 9P frame: at least a header, and `size[4]` == its length.
/// Same test as the server side (`tools/origin/ws_transport.zig`).
fn validFrame(frame: []const u8) bool {
    return frame.len >= header_size and
        std.mem.readInt(u32, frame[0..4], .little) == frame.len;
}

/// Protocol violation or resource failure: kill the socket, drop the queue, and
/// arm the one-shot error the next `readMsg` reports.
fn poison(self: *WsTransport, why: Reason, text: []const u8, err: Error) void {
    if (self.conn_state == .closed) return;
    const was_live = self.conn_state != .idle;
    self.conn_state = .closed;
    self.setReason(why, text);
    self.fault = err;
    self.dropQueue();
    if (was_live) abi.wsClose(self.id);
}

/// The peer went away (`onclose`/`onerror`). No `wsClose` — the socket is gone
/// already — and no queue drop: already-delivered frames stay readable.
fn markDown(self: *WsTransport, why: Reason, text: []const u8) void {
    if (self.conn_state == .closed) return;
    self.conn_state = .closed;
    self.setReason(why, text);
}

fn setReason(self: *WsTransport, why: Reason, text: []const u8) void {
    self.reason = why;
    const n = @min(text.len, reason_cap);
    @memcpy(self.reason_buf[0..n], text[0..n]);
    self.reason_len = n;
}

fn dropQueue(self: *WsTransport) void {
    for (self.queue.items[self.head..]) |frame| self.allocator.free(frame);
    self.queue.clearRetainingCapacity();
    self.head = 0;
}

// ---------------------------------------------------------------------------
// Tests (R-P12-9a): a scripted queue stands in for the browser. No socket, no
// shim — `abi.is_wasm` is false natively, so no extern is reachable and the
// `abi.test_ws_*` seams record the outbound half.
// ---------------------------------------------------------------------------

/// Records what the "browser" was told to do, via the abi test seams.
const Recorder = struct {
    var opens: usize = 0;
    var closes: usize = 0;
    var sent_len: usize = 0;
    var sent_last: [64]u8 = undefined;
    var sent_count: usize = 0;

    fn install() void {
        opens = 0;
        closes = 0;
        sent_len = 0;
        sent_count = 0;
        abi.test_ws_open = onOpen;
        abi.test_ws_send = onSend;
        abi.test_ws_close = onClose;
    }
    fn uninstall() void {
        abi.test_ws_open = null;
        abi.test_ws_send = null;
        abi.test_ws_close = null;
    }
    fn onOpen(_: u32) void {
        opens += 1;
    }
    fn onSend(_: u32, ptr: [*]const u8, len: u32) void {
        sent_count += 1;
        sent_len = @min(len, sent_last.len);
        @memcpy(sent_last[0..sent_len], ptr[0..sent_len]);
    }
    fn onClose(_: u32) void {
        closes += 1;
    }
};

/// A minimal `size[4] type[1] tag[2] body` frame with the size prefix set right.
fn testFrame(buf: []u8, msg_type: u8, tag: u16, body: []const u8) []u8 {
    const n = header_size + body.len;
    std.mem.writeInt(u32, buf[0..4], @intCast(n), .little);
    buf[4] = msg_type;
    std.mem.writeInt(u16, buf[5..7], tag, .little);
    @memcpy(buf[header_size..n], body);
    return buf[0..n];
}

/// A dialed, opened transport ready for records.
fn testOpen(allocator: std.mem.Allocator) WsTransport {
    var ws = WsTransport.init(allocator, 1);
    ws.dial();
    ws.pushRecord(.open, "") catch unreachable;
    return ws;
}

test "ws: dial then open record reaches the open state" {
    Recorder.install();
    defer Recorder.uninstall();

    var ws = WsTransport.init(std.testing.allocator, 7);
    defer ws.deinit();
    try std.testing.expectEqual(State.idle, ws.state());

    ws.dial();
    try std.testing.expectEqual(State.connecting, ws.state());
    try std.testing.expectEqual(@as(usize, 1), Recorder.opens);
    // A redundant dial does not re-open the socket.
    ws.dial();
    try std.testing.expectEqual(@as(usize, 1), Recorder.opens);

    try ws.pushRecord(.open, "");
    try std.testing.expect(ws.isOpen());
}

test "ws: a good frame round-trips through the queue" {
    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    var fbuf: [32]u8 = undefined;
    const frame = testFrame(&fbuf, 100, 1, "hi");
    try ws.pushRecord(.data, frame);
    try std.testing.expectEqual(@as(usize, 1), ws.pending());

    var rbuf: [64]u8 = undefined;
    const got = try ws.readMsg(&rbuf);
    try std.testing.expectEqualSlices(u8, frame, got);
    try std.testing.expectEqual(@as(usize, 0), ws.pending());
}

test "ws: frames are delivered whole and in order" {
    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    var fbuf: [32]u8 = undefined;
    try ws.pushRecord(.data, testFrame(&fbuf, 101, 1, "one"));
    try ws.pushRecord(.data, testFrame(&fbuf, 101, 2, "two"));

    var rbuf: [64]u8 = undefined;
    const a = try ws.readMsg(&rbuf);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, a[5..7], .little));
    const b = try ws.readMsg(&rbuf);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, b[5..7], .little));
    try std.testing.expectError(Error.WouldBlock, ws.readMsg(&rbuf));
}

test "ws: readMsg never parks — empty queue is WouldBlock" {
    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    var rbuf: [64]u8 = undefined;
    try std.testing.expectError(Error.WouldBlock, ws.readMsg(&rbuf));
    // Still WouldBlock while the dial is in flight (nothing is ever awaited).
    var dialing = WsTransport.init(std.testing.allocator, 2);
    defer dialing.deinit();
    dialing.dial();
    try std.testing.expectError(Error.WouldBlock, dialing.readMsg(&rbuf));
}

test "ws: an oversized frame stays queued (guarantee 3)" {
    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    var fbuf: [32]u8 = undefined;
    const frame = testFrame(&fbuf, 102, 3, "abcdefgh");
    try ws.pushRecord(.data, frame);

    var small: [8]u8 = undefined;
    try std.testing.expectError(Error.FrameTooBig, ws.readMsg(&small));
    var big: [64]u8 = undefined;
    try std.testing.expectEqualSlices(u8, frame, try ws.readMsg(&big));
}

test "ws: a size-prefix mismatch poisons the connection" {
    Recorder.install();
    defer Recorder.uninstall();

    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    var fbuf: [32]u8 = undefined;
    try ws.pushRecord(.data, testFrame(&fbuf, 103, 1, "queued"));

    var bad: [16]u8 = undefined;
    _ = testFrame(&bad, 104, 2, "x");
    std.mem.writeInt(u32, bad[0..4], 99, .little); // size[4] != len
    try ws.pushRecord(.data, bad[0..8]);

    try std.testing.expectEqual(State.closed, ws.state());
    try std.testing.expectEqual(Reason.bad_frame, ws.reason);
    try std.testing.expectEqual(@as(usize, 1), Recorder.closes); // socket killed
    try std.testing.expectEqual(@as(usize, 0), ws.pending()); // queue dropped

    var rbuf: [64]u8 = undefined;
    try std.testing.expectError(Error.BadFrame, ws.readMsg(&rbuf)); // cause, once
    try std.testing.expectError(Error.Closed, ws.readMsg(&rbuf)); // then Closed
}

test "ws: a short frame is rejected too" {
    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    try ws.pushRecord(.data, &.{ 3, 0, 0 }); // shorter than a header
    try std.testing.expectEqual(Reason.bad_frame, ws.reason);
    var rbuf: [64]u8 = undefined;
    try std.testing.expectError(Error.BadFrame, ws.readMsg(&rbuf));
}

test "ws: close makes every subsequent op fail with Closed" {
    Recorder.install();
    defer Recorder.uninstall();

    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    var fbuf: [32]u8 = undefined;
    const frame = testFrame(&fbuf, 105, 1, "gone");
    try ws.pushRecord(.data, frame);

    ws.close();
    try std.testing.expectEqual(@as(usize, 1), Recorder.closes);
    ws.close(); // idempotent
    try std.testing.expectEqual(@as(usize, 1), Recorder.closes);

    var rbuf: [64]u8 = undefined;
    try std.testing.expectError(Error.Closed, ws.readMsg(&rbuf));
    try std.testing.expectError(Error.Closed, ws.writeMsg(frame));
    // A late frame on a dead socket is dropped, not queued.
    try ws.pushRecord(.data, frame);
    try std.testing.expectEqual(@as(usize, 0), ws.pending());
    try std.testing.expectError(Error.Closed, ws.readMsg(&rbuf));
}

test "ws: a remote close leaves queued replies readable, then Closed" {
    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    var fbuf: [32]u8 = undefined;
    const frame = testFrame(&fbuf, 106, 1, "last");
    try ws.pushRecord(.data, frame);
    try ws.pushRecord(.close, "1006 abnormal closure");

    try std.testing.expectEqual(State.closed, ws.state());
    try std.testing.expectEqual(Reason.remote, ws.reason);
    try std.testing.expectEqualStrings("1006 abnormal closure", ws.reasonText());

    var rbuf: [64]u8 = undefined;
    try std.testing.expectEqualSlices(u8, frame, try ws.readMsg(&rbuf));
    try std.testing.expectError(Error.Closed, ws.readMsg(&rbuf));
}

test "ws: an error record kills the connection like a close" {
    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();

    try ws.pushRecord(.err, "socket error");
    try std.testing.expectEqual(State.closed, ws.state());
    try std.testing.expectEqual(Reason.socket_error, ws.reason);
    var rbuf: [64]u8 = undefined;
    try std.testing.expectError(Error.Closed, ws.readMsg(&rbuf));
}

test "ws: writeMsg validates and reaches the send import" {
    Recorder.install();
    defer Recorder.uninstall();

    var ws = WsTransport.init(std.testing.allocator, 3);
    defer ws.deinit();

    var fbuf: [32]u8 = undefined;
    const frame = testFrame(&fbuf, 100, 9, "v");

    // Never dialed: Closed. Dial in flight: WouldBlock, never a park.
    try std.testing.expectError(Error.Closed, ws.writeMsg(frame));
    ws.dial();
    try std.testing.expectError(Error.WouldBlock, ws.writeMsg(frame));
    try std.testing.expectEqual(@as(usize, 0), Recorder.sent_count);

    try ws.pushRecord(.open, "");
    try ws.writeMsg(frame);
    try std.testing.expectEqual(@as(usize, 1), Recorder.sent_count);
    try std.testing.expectEqualSlices(u8, frame, Recorder.sent_last[0..Recorder.sent_len]);

    // A frame whose size prefix lies never reaches the socket.
    var bad: [16]u8 = undefined;
    _ = testFrame(&bad, 100, 9, "v");
    std.mem.writeInt(u32, bad[0..4], 42, .little);
    try std.testing.expectError(Error.BadFrame, ws.writeMsg(bad[0..8]));
    try std.testing.expectError(Error.BadFrame, ws.writeMsg(&.{ 1, 2 }));
    try std.testing.expectEqual(@as(usize, 1), Recorder.sent_count);
}

test "ws: the vtable adapter drives the same behavior" {
    Recorder.install();
    defer Recorder.uninstall();

    // A structural stand-in for `ninep.transport.Transport` — this module may
    // not import ninep (S-07 §6), so the test proves the coercion locally.
    const Erased = struct {
        ctx: *anyopaque,
        vtable: *const VTable,
        const VTable = struct {
            writeMsg: *const fn (ctx: *anyopaque, frame: []const u8) Error!void,
            readMsg: *const fn (ctx: *anyopaque, buf: []u8) Error![]u8,
            close: *const fn (ctx: *anyopaque) void,
        };
    };

    var ws = testOpen(std.testing.allocator);
    defer ws.deinit();
    const t: Erased = ws.transport(Erased);

    var fbuf: [32]u8 = undefined;
    const frame = testFrame(&fbuf, 107, 4, "vt");
    try t.vtable.writeMsg(t.ctx, frame);
    try std.testing.expectEqual(@as(usize, 1), Recorder.sent_count);

    var rbuf: [64]u8 = undefined;
    try std.testing.expectError(Error.WouldBlock, t.vtable.readMsg(t.ctx, &rbuf));
    try ws.pushRecord(.data, frame);
    try std.testing.expectEqualSlices(u8, frame, try t.vtable.readMsg(t.ctx, &rbuf));

    t.vtable.close(t.ctx);
    try std.testing.expectEqual(State.closed, ws.state());
    try std.testing.expectError(Error.Closed, t.vtable.readMsg(t.ctx, &rbuf));
}

test "ws: a failed frame copy poisons rather than dropping a frame" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ws = testOpen(failing.allocator());
    defer ws.deinit();

    var fbuf: [32]u8 = undefined;
    const frame = testFrame(&fbuf, 108, 1, "nope");
    try std.testing.expectError(error.OutOfMemory, ws.pushRecord(.data, frame));
    try std.testing.expectEqual(State.closed, ws.state());
    try std.testing.expectEqual(Reason.out_of_memory, ws.reason);

    var rbuf: [64]u8 = undefined;
    try std.testing.expectError(Error.Closed, ws.readMsg(&rbuf));
}
