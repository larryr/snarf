//! The devdraw connection's MUX: tag allocation, `send`, the synchronous `rpc`,
//! the two standing long polls, the `poll`/frame/dispatch receive path, and the
//! thin `rpc` wrappers the two devices call. Namespace module (S-07 P-1) over
//! `*Conn`, carved out of `Conn.zig` verbatim in phase 16a so both files stay
//! inside the ~400-line cap.
//!
//! Ported from `larryr/plan9port@337c6ac` `src/libdraw/drawclient.c`:
//! `_displaymux` (:138-300) demultiplexes replies by tag, `displayrpc`
//! (:255-300) is the synchronous request/reply. Cite as `drawclient.c:NN`.
//!
//! `Conn` re-exports every public function below as a DECL ALIAS, so
//! `conn.rpc(...)` method syntax is unchanged at every call site. What stayed
//! in `Conn.zig` is the connection's own state, `spawn`/`fill` (the only parts
//! that touch the OS) and the scripted test seam.
const std = @import("std");
const wsys = @import("wsys.zig");
const Conn = @import("Conn.zig");

const Msg = Conn.Msg;
const Error = Conn.Error;
const MouseEvent = Conn.MouseEvent;
const mouse_tag = Conn.mouse_tag;
const kbd_tag = Conn.kbd_tag;
const first_rpc_tag = Conn.first_rpc_tag;
const rpc_timeout_ns = Conn.rpc_timeout_ns;

// ==========================================================================
// Sending
// ==========================================================================

fn allocTag(self: *Conn) u8 {
    // 3..255, skipping any tag whose slot still holds an unclaimed reply.
    var tries: usize = 0;
    while (tries < 253) : (tries += 1) {
        const t = self.next_tag;
        self.next_tag = if (self.next_tag == 255) first_rpc_tag else self.next_tag + 1;
        if (self.pending[t] == null) return t;
    }
    return first_rpc_tag;
}

/// Write one message with an explicit tag, no reply expected here.
pub fn send(self: *Conn, tag: u8, m: Msg) Error!void {
    const sink = self.sink orelse return error.Closed;
    const n = wsys.sizeOf(m);
    if (n <= 512) {
        var stack: [512]u8 = undefined;
        _ = wsys.encode(m, tag, &stack) catch return error.Protocol;
        sink.writeAll(sink.ctx, stack[0..n]) catch return error.WriteFailed;
        return;
    }
    const buf = try self.gpa.alloc(u8, n);
    defer self.gpa.free(buf);
    _ = wsys.encode(m, tag, buf) catch return error.Protocol;
    sink.writeAll(sink.ctx, buf) catch return error.WriteFailed;
}

/// A reply frame, owned by the caller until `deinit`. `msg` borrows `frame`.
pub const Reply = struct {
    gpa: std.mem.Allocator,
    frame: []u8,
    msg: Msg,
    pub fn deinit(self: *Reply) void {
        self.gpa.free(self.frame);
        self.frame = &.{};
    }
};

/// `displayrpc` (drawclient.c:255-300): send, then pump until the reply with
/// our tag arrives. Mouse/kbd replies that land meanwhile are queued, not
/// dropped. An `Rerror` becomes `error.DrawError` + `lastError()`; a reply of
/// the wrong type is `error.Protocol` (drawclient.c:291-296).
pub fn rpc(self: *Conn, m: Msg) Error!Reply {
    const tag = allocTag(self);
    try self.send(tag, m);
    const want: wsys.Kind = @enumFromInt(@intFromEnum(std.meta.activeTag(m)) + 1);
    var waited: u64 = 0;
    while (true) {
        if (self.pending[tag]) |frame| {
            self.pending[tag] = null;
            const reply = wsys.decode(frame) catch {
                self.gpa.free(frame);
                return error.Protocol;
            };
            if (reply == .rerror) {
                self.setError(reply.rerror);
                self.gpa.free(frame);
                return error.DrawError;
            }
            if (std.meta.activeTag(reply) != want) {
                self.gpa.free(frame);
                return error.Protocol;
            }
            return .{ .gpa = self.gpa, .frame = frame, .msg = reply };
        }
        if (waited >= rpc_timeout_ns) return error.Timeout;
        const slice_ms: i32 = 20;
        const progressed = try self.poll(slice_ms);
        if (!progressed) {
            if (self.isClosed()) return error.Closed;
            waited += @as(u64, slice_ms) * std.time.ns_per_ms;
        }
    }
}

// ==========================================================================
// Receiving
// ==========================================================================

/// Arm the standing `Trdmouse` (drawclient.c:308-332).
pub fn armMouse(self: *Conn) Error!void {
    return self.send(mouse_tag, .trdmouse);
}

/// Arm the standing keyboard read. libdraw's `_displayrdkbd` sends `Trdkbd4`
/// (drawclient.c:334-344) — full 32-bit runes; devdraw answers `Trdkbd` and
/// `Trdkbd4` from the same queue (srv.c:233-234).
pub fn armKbd(self: *Conn) Error!void {
    return self.send(kbd_tag, .trdkbd4);
}

/// Drain whatever the peer has sent, waiting up to `timeout_ms` for the first
/// byte (`-1` blocks, `0` peeks). Returns true when at least one frame was
/// dispatched. Long-poll replies are re-armed here, exactly where libdraw's
/// mux thread re-arms them.
pub fn poll(self: *Conn, timeout_ms: i32) Error!bool {
    try takeFrames(self, timeout_ms);
    if (self.scratch.items.len == 0) return false;
    // `scratch` is drained into the queues/slots; `dispatch` takes ownership of
    // each frame (storing or freeing it), so a failure mid-way only has to free
    // the ones it never reached.
    var i: usize = 0;
    while (i < self.scratch.items.len) : (i += 1) {
        dispatch(self, self.scratch.items[i]) catch |e| {
            var j = i + 1;
            while (j < self.scratch.items.len) : (j += 1) self.gpa.free(self.scratch.items[j]);
            self.scratch.clearRetainingCapacity();
            return e;
        };
    }
    self.scratch.clearRetainingCapacity();
    return true;
}

/// Move every COMPLETE frame out of `rx` into `scratch`, reading from the peer
/// first if nothing complete is buffered yet.
fn takeFrames(self: *Conn, timeout_ms: i32) Error!void {
    if (!hasFrame(self.rx.items)) {
        _ = try self.fill(timeout_ms);
        // One more non-blocking top-up: a large reply can span reads.
        while (!hasFrame(self.rx.items) and self.rx.items.len != 0) {
            if (!try self.fill(0)) break;
        }
    }
    while (hasFrame(self.rx.items)) {
        const n = wsys.frameLen(self.rx.items) catch {
            // Unrecoverable framing error: drop everything and mark closed.
            self.rx.clearRetainingCapacity();
            self.closed = true;
            return error.Protocol;
        };
        const frame = try self.gpa.dupe(u8, self.rx.items[0..n]);
        errdefer self.gpa.free(frame);
        try self.scratch.append(self.gpa, frame);
        const rest = self.rx.items.len - n;
        std.mem.copyForwards(u8, self.rx.items[0..rest], self.rx.items[n..]);
        self.rx.shrinkRetainingCapacity(rest);
    }
}

fn hasFrame(buf: []const u8) bool {
    const n = wsys.frameLen(buf) catch return false;
    return buf.len >= n;
}

/// Route one frame: the two long-poll tags feed the event queues and re-arm,
/// everything else parks in its tag's slot for `rpc`.
fn dispatch(self: *Conn, frame: []u8) Error!void {
    const tag = wsys.tagOf(frame);
    if (tag != mouse_tag and tag != kbd_tag) {
        if (self.pending[tag]) |old| self.gpa.free(old); // an abandoned rpc's reply
        self.pending[tag] = frame;
        return;
    }
    defer self.gpa.free(frame);
    const m = wsys.decode(frame) catch return error.Protocol;
    switch (m) {
        .rrdmouse => |r| {
            try self.mouse_q.append(self.gpa, .{
                .x = r.mouse.x,
                .y = r.mouse.y,
                .buttons = r.mouse.buttons,
                .msec = nowMsec(),
                .resized = r.resized,
            });
            try self.armMouse();
        },
        .rrdkbd4 => |r| {
            try self.kbd_q.append(self.gpa, r);
            try self.armKbd();
        },
        .rrdkbd => |r| {
            try self.kbd_q.append(self.gpa, r);
            try self.armKbd();
        },
        // An Rerror on a long poll (devdraw's "too many queued reads",
        // srv.c:225) is fatal to that poll: record it and do NOT re-arm, or we
        // would spin. The host surfaces it as a dead input channel.
        .rerror => |e| {
            self.setError(e);
            return error.DrawError;
        },
        else => return error.Protocol,
    }
}

/// Local monotonic milliseconds — see the header on `Rrdmouse.msec`. (Zig
/// 0.16 moved the clock behind `Io`; `Conn` has no `Io` on the scripted path,
/// so it reads the POSIX clock directly.)
fn nowMsec() u32 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    const ms = @as(u64, @intCast(ts.sec)) *% 1000 +% @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
    return @truncate(ms);
}

pub fn nextMouse(self: *Conn) ?MouseEvent {
    if (self.mouse_q.items.len == 0) return null;
    const ev = self.mouse_q.items[0];
    _ = self.mouse_q.orderedRemove(0);
    return ev;
}

pub fn nextRune(self: *Conn) ?u32 {
    if (self.kbd_q.items.len == 0) return null;
    const r = self.kbd_q.items[0];
    _ = self.kbd_q.orderedRemove(0);
    return r;
}

pub fn isClosed(self: *Conn) bool {
    return self.closed and self.rx.items.len == 0;
}

// ==========================================================================
// Convenience wrappers over `rpc` (the ones the two devices need)
// ==========================================================================

/// `_displaywrdraw` (drawclient.c:437-448): the bytes libdraw would have
/// written to `/dev/draw/N/data`, verbatim. Returns the accepted count.
pub fn wrDraw(self: *Conn, data: []const u8) Error!u32 {
    var r = try self.rpc(.{ .twrdraw = data });
    defer r.deinit();
    return r.msg.rwrdraw;
}

/// `_displayrddraw` (drawclient.c:423-435): read back whatever the last draw
/// read-verb queued (devdraw.c:617-637 `draw_dataread`). Copies into `out`.
pub fn rdDraw(self: *Conn, out: []u8) Error!usize {
    var r = try self.rpc(.{ .trddraw = @intCast(out.len) });
    defer r.deinit();
    const d = r.msg.rrddraw;
    const n = @min(d.len, out.len);
    @memcpy(out[0..n], d[0..n]);
    return n;
}

/// `_displaymoveto` (drawclient.c:346-357) — THE WARP.
pub fn moveTo(self: *Conn, x: i32, y: i32) Error!void {
    var r = try self.rpc(.{ .tmoveto = .{ .x = x, .y = y } });
    r.deinit();
}

/// `_displaylabel` (drawclient.c:392-400).
pub fn label(self: *Conn, s: []const u8) Error!void {
    var r = try self.rpc(.{ .tlabel = s });
    r.deinit();
}

/// `_displaycursor` (drawclient.c:359-380). Passing `null` restores the arrow.
pub fn cursor(self: *Conn, c: ?wsys.Cursor) Error!void {
    var r = if (c) |cc|
        try self.rpc(.{ .tcursor = .{ .cursor = cc, .arrow = false } })
    else
        try self.rpc(.{ .tcursor = .{ .cursor = .{}, .arrow = true } });
    r.deinit();
}

/// `_displayrdsnarf` (drawclient.c:402-414). The result is COPIED (owned).
pub fn rdSnarf(self: *Conn, gpa: std.mem.Allocator) Error![]u8 {
    var r = try self.rpc(.trdsnarf);
    defer r.deinit();
    return gpa.dupe(u8, r.msg.rrdsnarf);
}

/// `_displaywrsnarf` (drawclient.c:416-421).
pub fn wrSnarf(self: *Conn, s: []const u8) Error!void {
    var r = try self.rpc(.{ .twrsnarf = s });
    r.deinit();
}
