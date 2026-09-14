//! `Conn` — one connection to a plan9port `devdraw`, file-as-struct (S-07 P-1).
//!
//! Ported from `larryr/plan9port@337c6ac` `src/libdraw/drawclient.c`:
//! `_displayconnect` (:23-137) spawns the server over a pipe, `_displaymux`
//! (:138-300) demultiplexes replies by tag, `displayrpc` (:255-300) is the
//! synchronous request/reply. Cite as `drawclient.c:NN`.
//!
//! WHAT LIBDRAW DOES AND WE DO TOO
//!   * tags 1..255, one outstanding request per tag (`drawclient.c:143-144`);
//!   * exactly ONE `Trdmouse` and ONE `Trdkbd4` in flight at all times — they
//!     are long polls, re-armed the instant their reply lands. Here they own
//!     the fixed tags 1 and 2; every other request rotates through 3..255.
//!   * every other message is request/reply, matched by tag.
//!
//! WHERE WE DIVERGE, AND WHY
//!   * libdraw runs a mux *thread* that owns the fd. Snarf is SINGLE-THREADED:
//!     the host loop blocks in `poll(2)` on the pipe with a timeout, then
//!     frames, demuxes and dispatches inline. That is exactly libdraw's own
//!     `canreadfd` (drawclient.c:470-490, a `select` with a zero timeout) used
//!     as the loop's wait instead of as a peek, and it keeps every 9P message
//!     handler above us on one thread, which is what those servers require.
//!     (The phase-15 contract §3a asked for a reader `std.Thread` feeding a
//!     mutex-protected queue. Zig 0.16 has no `std.Thread.Mutex`/`Condition`
//!     any more — the replacements are `std.Io.Mutex`/`Io.Condition`, which
//!     need an `Io` at every lock and offer no timed wait — so the thread
//!     would have bought concurrency we do not want at the price of an API we
//!     cannot use. Recorded as a phase-15 deviation.)
//!   * `Rrdmouse.msec` is unusable (`wsys.zig` header: the reference codec
//!     stamps `resized` inside it), so mouse records are timestamped from the
//!     local monotonic clock instead.
//!
//! The transport is a `Sink` + a byte queue, not a file: a test drives a `Conn`
//! by calling `feed` with scripted server bytes and reading back what the sink
//! captured, with no child process and no thread (see the tests at the foot).
//! `spawn` is the only part that touches the OS.
const std = @import("std");
const wsys = @import("wsys.zig");

const Conn = @This();

pub const Msg = wsys.Msg;

pub const Error = error{
    /// The peer hung up (devdraw exited, or the scripted double ran out).
    Closed,
    /// `Rerror` — the text is in `lastError()`.
    DrawError,
    /// A reply did not arrive within `rpc_timeout_ns`.
    Timeout,
    /// The peer sent a frame we cannot parse, or answered the wrong type.
    Protocol,
    WriteFailed,
} || std.mem.Allocator.Error;

/// Where outbound frames go. One indirection so the tests can capture them.
pub const Sink = struct {
    ctx: *anyopaque,
    writeAll: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

/// A mouse event lifted out of an `Rrdmouse`, already timestamped locally.
pub const MouseEvent = struct {
    x: i32,
    y: i32,
    buttons: u32,
    msec: u32,
    resized: bool,
};

/// The long-poll tags (`drawclient.c` keeps one of each outstanding).
pub const mouse_tag: u8 = 1;
pub const kbd_tag: u8 = 2;
const first_rpc_tag: u8 = 3;

/// How long a synchronous request may take before we give up. devdraw answers
/// every one of ours from its message loop, so this only ever fires when the
/// peer has wedged or died in a way `poll(2)` has not reported yet.
pub const rpc_timeout_ns: u64 = 5 * std.time.ns_per_s;

gpa: std.mem.Allocator,
sink: ?Sink = null,

// --- inbound bytes, framed on demand -------------------------------------
rx: std.ArrayListUnmanaged(u8) = .empty,
closed: bool = false,

// --- demux state ---------------------------------------------------------
/// One slot per tag; a complete frame parked here waits for its `rpc` caller.
pending: [256]?[]u8 = @splat(null),
next_tag: u8 = first_rpc_tag,
mouse_q: std.ArrayListUnmanaged(MouseEvent) = .empty,
kbd_q: std.ArrayListUnmanaged(u32) = .empty,
scratch: std.ArrayListUnmanaged([]u8) = .empty,
err_buf: [192]u8 = undefined,
err_len: usize = 0,

// --- the spawned peer, when there is one ---------------------------------
child: ?std.process.Child = null,
io: ?std.Io = null,
/// The read end of the pipe, as a raw fd: the loop waits on it with `poll(2)`.
/// `-1` when the peer is scripted rather than executed.
rfd: std.posix.fd_t = -1,
/// The write end, kept as an `Io.File` so writes go through the std API.
wfile: ?std.Io.File = null,

pub fn init(gpa: std.mem.Allocator) Conn {
    return .{ .gpa = gpa };
}

/// Tear everything down: kill the peer (its window goes with it), free every
/// buffered frame.
pub fn deinit(self: *Conn) void {
    if (self.child) |*c| {
        if (self.io) |io| c.kill(io);
        self.child = null;
    }
    self.rx.deinit(self.gpa);
    for (&self.pending) |*slot| {
        if (slot.*) |f| self.gpa.free(f);
        slot.* = null;
    }
    for (self.scratch.items) |f| self.gpa.free(f);
    self.scratch.deinit(self.gpa);
    self.mouse_q.deinit(self.gpa);
    self.kbd_q.deinit(self.gpa);
}

/// The text of the last `Rerror` (or a peer-framing complaint).
pub fn lastError(self: *const Conn) []const u8 {
    return self.err_buf[0..self.err_len];
}

fn setError(self: *Conn, s: []const u8) void {
    self.err_len = @min(s.len, self.err_buf.len);
    @memcpy(self.err_buf[0..self.err_len], s[0..self.err_len]);
}

// ==========================================================================
// Spawning the peer (drawclient.c:88-136 `_displayconnect`, pipe/fork/exec arm)
// ==========================================================================

pub const SpawnOptions = struct {
    /// `Tinit winsize` — `parsewinsize` accepts "WxH" or "x0,y0,x1,y1"
    /// (mac-screen.m:253-258). Empty ⇒ devdraw picks 2/3 of the screen.
    winsize: []const u8 = "1024x768",
    /// The window title (`Tinit label`, then `Tlabel`).
    label: []const u8 = "snarf",
    /// argv[0] for the child, purely cosmetic in `ps` (drawclient.c:104-119).
    argv0: []const u8 = "snarf",
};

/// Find the `devdraw` binary: `$DEVDRAW` (drawclient.c:96-98), else
/// `$PLAN9/bin/devdraw`, else bare `devdraw` for the PATH search. The returned
/// slice is owned by the caller's allocator.
pub fn devdrawPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("DEVDRAW")) |p| return gpa.dupe(u8, p);
    if (env.get("PLAN9")) |p9| return std.fmt.allocPrint(gpa, "{s}/bin/devdraw", .{p9});
    return gpa.dupe(u8, "devdraw");
}

/// Spawn `devdraw` and wire the pipes up. `env` is
/// COPIED into the child's environment with `NOLIBTHREADDAEMONIZE=1` added —
/// without it libthread daemonizes and the pipe we hold goes nowhere
/// (drawclient.c:110-123, libthread/thread.c:729).
pub fn spawn(self: *Conn, io: std.Io, env: *const std.process.Environ.Map, opts: SpawnOptions) !void {
    const gpa = self.gpa;
    const path = try devdrawPath(gpa, env);
    defer gpa.free(path);

    var child_env: std.process.Environ.Map = .init(gpa);
    defer child_env.deinit();
    for (env.keys(), env.values()) |k, v| try child_env.put(k, v);
    try child_env.put("NOLIBTHREADDAEMONIZE", "1");

    var child = try std.process.spawn(io, .{
        .argv = &.{ path, opts.argv0, "(devdraw)" },
        .environ_map = &child_env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    self.child = child;
    self.io = io;
    self.rfd = child.stdout.?.handle;
    self.wfile = child.stdin.?;
    self.sink = .{ .ctx = self, .writeAll = fdWrite };

    // drawclient.c:295-303 `_displayinit`, then `_displaylabel`: devdraw sets
    // the NSWindow title from `rpc_setlabel`, not from `Tinit` (mac-screen.m:
    // 268 hard-codes "devdraw"), so the label has to be sent twice.
    var r1 = try self.rpc(.{ .tinit = .{ .winsize = opts.winsize, .label = opts.label } });
    r1.deinit();
    var r2 = try self.rpc(.{ .tlabel = opts.label });
    r2.deinit();
}

fn fdWrite(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const self: *Conn = @ptrCast(@alignCast(ctx));
    const f = self.wfile orelse return error.Closed;
    try f.writeStreamingAll(self.io.?, bytes);
}

/// Wait up to `timeout_ms` for the peer to say something, then read whatever
/// it said into `rx`. `-1` blocks indefinitely, `0` peeks (the `canreadfd`
/// use, drawclient.c:470-490). Returns true when bytes arrived. A scripted
/// peer (no fd) never has anything to fill from; its bytes come via `feed`.
fn fill(self: *Conn, timeout_ms: i32) Error!bool {
    if (self.rfd < 0 or self.closed) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = self.rfd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, timeout_ms) catch {
        self.closed = true;
        return false;
    };
    if (ready == 0) return false;
    var buf: [64 * 1024]u8 = undefined;
    const n = std.posix.read(self.rfd, &buf) catch {
        self.closed = true;
        return false;
    };
    if (n == 0) { // EOF: devdraw exited (its window was closed)
        self.closed = true;
        return false;
    }
    try self.rx.appendSlice(self.gpa, buf[0..n]);
    return true;
}

// ==========================================================================
// The test seam: a sink the caller owns plus hand-fed server bytes
// ==========================================================================

/// Point this connection's outbound frames at `sink`. Used instead of `spawn`
/// when the peer is scripted rather than executed.
pub fn useSink(self: *Conn, sink: Sink) void {
    self.sink = sink;
}

/// Hand `bytes` to the connection as if the peer had written them.
pub fn feed(self: *Conn, bytes: []const u8) !void {
    try self.rx.appendSlice(self.gpa, bytes);
}

/// Encode `m` with `tag` and hand it to the peer — used by `feed`-based tests
/// to build scripted replies, and by `send` itself.
pub fn encodeAlloc(gpa: std.mem.Allocator, m: Msg, tag: u8) ![]u8 {
    const buf = try gpa.alloc(u8, wsys.sizeOf(m));
    errdefer gpa.free(buf);
    _ = try wsys.encode(m, tag, buf);
    return buf;
}

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
    const tag = self.allocTag();
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
    try self.takeFrames(timeout_ms);
    if (self.scratch.items.len == 0) return false;
    // `scratch` is drained into the queues/slots; `dispatch` takes ownership of
    // each frame (storing or freeing it), so a failure mid-way only has to free
    // the ones it never reached.
    var i: usize = 0;
    while (i < self.scratch.items.len) : (i += 1) {
        self.dispatch(self.scratch.items[i]) catch |e| {
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

// ==========================================================================
// Tests — a scripted peer: no child process, no thread (contract §3c.6).
// ==========================================================================
const testing = std.testing;

/// The scripted peer. Captures every outbound frame; optionally answers each
/// one from a queue of templates, stamping the caller's own tag onto the reply
/// exactly as `replymsg` does (srv.c:326-336). `expect` nothing and the tests
/// can hand-feed instead.
pub const Script = struct {
    gpa: std.mem.Allocator,
    /// Set after the `Conn` exists; auto-replies need somewhere to go.
    conn: ?*Conn = null,
    out: std.ArrayListUnmanaged(u8) = .empty,
    replies: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Script) void {
        self.out.deinit(self.gpa);
        for (self.replies.items) |r| self.gpa.free(r);
        self.replies.deinit(self.gpa);
    }

    pub fn sink(self: *Script) Sink {
        return .{ .ctx = self, .writeAll = writeAll };
    }

    /// Queue one reply, to be sent (with the right tag) for the next request.
    pub fn expect(self: *Script, m: Msg) !void {
        const buf = try encodeAlloc(self.gpa, m, 0);
        errdefer self.gpa.free(buf);
        try self.replies.append(self.gpa, buf);
    }

    fn writeAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const s: *Script = @ptrCast(@alignCast(ctx));
        try s.out.appendSlice(s.gpa, bytes);
        if (s.replies.items.len == 0) return;
        const c = s.conn orelse return;
        const reply = s.replies.orderedRemove(0);
        defer s.gpa.free(reply);
        reply[4] = wsys.tagOf(bytes); // the request's tag, back on the reply
        try c.feed(reply);
    }

    /// Decode the `i`-th frame the connection wrote, or null.
    pub fn frame(self: *Script, i: usize) ?struct { tag: u8, msg: Msg } {
        var off: usize = 0;
        var k: usize = 0;
        while (off < self.out.items.len) {
            const rest = self.out.items[off..];
            const n = wsys.frameLen(rest) catch return null;
            if (rest.len < n) return null;
            if (k == i) {
                const m = wsys.decode(rest[0..n]) catch return null;
                return .{ .tag = wsys.tagOf(rest[0..n]), .msg = m };
            }
            off += n;
            k += 1;
        }
        return null;
    }

    pub fn count(self: *Script) usize {
        var off: usize = 0;
        var k: usize = 0;
        while (off < self.out.items.len) {
            const rest = self.out.items[off..];
            const n = wsys.frameLen(rest) catch return k;
            if (rest.len < n) return k;
            off += n;
            k += 1;
        }
        return k;
    }
};

/// Feed `conn` a reply as the scripted peer would send it.
pub fn feedMsg(self: *Conn, m: Msg, tag: u8) !void {
    const buf = try encodeAlloc(self.gpa, m, tag);
    defer self.gpa.free(buf);
    try self.feed(buf);
}

test "conn: rpc matches its own tag and rejects the wrong reply type" {
    var script: Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());

    // The peer answers before we ask — the queue is a queue, order is all that
    // matters. Tag 3 is the first rpc tag.
    try c.feedMsg(.rinit, first_rpc_tag);
    var r = try c.rpc(.{ .tinit = .{ .winsize = "8x8", .label = "snarf" } });
    r.deinit();
    const sent = script.frame(0).?;
    try testing.expectEqual(first_rpc_tag, sent.tag);
    try testing.expectEqualStrings("8x8", sent.msg.tinit.winsize);

    // Wrong reply type for the next tag ⇒ Protocol.
    try c.feedMsg(.rlabel, first_rpc_tag + 1);
    try testing.expectError(error.Protocol, c.rpc(.{ .tmoveto = .{ .x = 1, .y = 1 } }));
}

test "conn: Rerror becomes DrawError with the text" {
    var script: Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());
    try c.feedMsg(.{ .rerror = "no draw data" }, first_rpc_tag);
    try testing.expectError(error.DrawError, c.rpc(.{ .trddraw = 144 }));
    try testing.expectEqualStrings("no draw data", c.lastError());
}

test "conn: the two long polls stay armed and demux around an rpc" {
    var script: Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());

    try c.armMouse();
    try c.armKbd();
    try testing.expectEqual(@as(usize, 2), script.count());
    try testing.expectEqual(mouse_tag, script.frame(0).?.tag);
    try testing.expectEqual(wsys.Kind.trdmouse, std.meta.activeTag(script.frame(0).?.msg));
    try testing.expectEqual(kbd_tag, script.frame(1).?.tag);
    try testing.expectEqual(wsys.Kind.trdkbd4, std.meta.activeTag(script.frame(1).?.msg));

    // A mouse reply, a kbd reply and OUR reply, all interleaved: the rpc must
    // pick its own out and queue the other two, re-arming both polls.
    try c.feedMsg(.{ .rrdmouse = .{ .mouse = .{ .x = 10, .y = 20, .buttons = 4 }, .resized = false } }, mouse_tag);
    try c.feedMsg(.{ .rrdkbd4 = 'q' }, kbd_tag);
    try c.feedMsg(.{ .rwrdraw = 2 }, first_rpc_tag);
    try testing.expectEqual(@as(u32, 2), try c.wrDraw("JI"));

    const ev = c.nextMouse().?;
    try testing.expectEqual(@as(i32, 10), ev.x);
    try testing.expectEqual(@as(i32, 20), ev.y);
    try testing.expectEqual(@as(u32, 4), ev.buttons);
    try testing.expectEqual(false, ev.resized);
    try testing.expectEqual(@as(?MouseEvent, null), c.nextMouse());
    try testing.expectEqual(@as(u32, 'q'), c.nextRune().?);
    // Re-armed: Trdmouse and Trdkbd4 sent again, after the Twrdraw.
    try testing.expectEqual(@as(usize, 5), script.count());
    try testing.expectEqual(wsys.Kind.twrdraw, std.meta.activeTag(script.frame(2).?.msg));
    try testing.expectEqual(wsys.Kind.trdmouse, std.meta.activeTag(script.frame(3).?.msg));
    try testing.expectEqual(wsys.Kind.trdkbd4, std.meta.activeTag(script.frame(4).?.msg));
}

test "conn: a frame split across two feeds is assembled" {
    var script: Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());

    const whole = try encodeAlloc(testing.allocator, .{ .rrdkbd4 = 'z' }, kbd_tag);
    defer testing.allocator.free(whole);
    try c.feed(whole[0..3]);
    try testing.expectEqual(false, try c.poll(0));
    try c.feed(whole[3..]);
    try testing.expectEqual(true, try c.poll(0));
    try testing.expectEqual(@as(u32, 'z'), c.nextRune().?);
}

test "conn: a closed peer with nothing buffered fails the rpc" {
    var script: Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());
    c.closed = true;
    try testing.expectError(error.Closed, c.rpc(.ttop));
}

test "conn: moveTo emits Tmoveto with the point" {
    var script: Script = .{ .gpa = testing.allocator };
    defer script.deinit();
    var c = Conn.init(testing.allocator);
    defer c.deinit();
    c.useSink(script.sink());
    try c.feedMsg(.rmoveto, first_rpc_tag);
    try c.moveTo(100, 200);
    const sent = script.frame(0).?.msg;
    try testing.expectEqual(@as(i32, 100), sent.tmoveto.x);
    try testing.expectEqual(@as(i32, 200), sent.tmoveto.y);
}
