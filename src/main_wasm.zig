//! Freestanding WASM entry point (S-07 §4). Boots the whole editor stack on the
//! heap and renders the interactive editing scene through the real pipeline,
//! then exports the lifecycle hooks (init/wake/tick, S-06 §2) + the ABI probe
//! the shim checks before init() (R-P5-4) + the `pushEvent` input entry (R-P6-10).
//!
//! Module runs on the MAIN THREAD (R-P5-2 divergence — Worker + rings land later,
//! R-P6-1). Two in-process 9P stacks now: the DRAW stack (canvas ← devdraw ←
//! server ← client ← Display) from phase 5, and a second INPUT stack (devinput ←
//! server ← client) added here (the "devdraw pattern"). The core Editor routing
//! machine (core/Editor.zig, R-P6-12) is the only place gestures are interpreted;
//! this file is purely the adapter: pushEvent → devinput; tick → drain the input
//! device through standing read tickets (R-P6-4) → Editor.handle* → frameEnd.
//!
//! Boot scene DIVERGES from phase 5 (R-P6-9/F-10): the acme palette (BACK ivory
//! ground, HIGH highlight, black text) over an EMPTY buffer. The frozen phase-2..5
//! goldens are untouched — this is a NEW scene, so smoke's phase-5 pixel/text
//! assertions (white ground, "hello, acme" glyphs) are EXPECTED to fail until the
//! orchestrator updates the smoke script in Wave C.
const std = @import("std");
const core = @import("core");
const dev = @import("dev");
const draw = @import("draw");
const ninep = @import("ninep");
const origin = @import("origin");
const shim = @import("shim");

const DevInput = dev.input.DevInput;
const OriginMount = origin.OriginMount;

/// Root-only host log import (R-P5-6): declared HERE, never in abi.zig, so the
/// native shim test root never references the symbol. shim.js binds
/// env.consoleLog to the browser console.
extern "env" fn consoleLog(ptr: [*]const u8, len: usize) void;

/// Panic handler: surface the message to the JS console, then trap. Freestanding
/// has no stderr; consoleLog is the only channel out (R-P5-6).
fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    consoleLog(msg.ptr, msg.len);
    @trap();
}
pub const panic = std.debug.FullPanic(panicHandler);

/// Single-threaded brk allocator (std.heap.zig, BrkAllocator) — the only
/// allocator available freestanding, and wasm32 is single-threaded here.
const alloc = std.heap.wasm_allocator;

/// Display is a fixed 640×480 (R-P5-3), matching the frozen goldens; the same
/// numbers are duplicated in index.html until canvasResize/DPR land.
const width: u32 = 640;
const height: u32 = 480;
/// The window tree fills the whole display (rowinit lays the rowtag + white
/// ground; Chrome owns the acme palette solids now — the phase-6/7 hand-built
/// BACK/HIGH images are gone).
const screen_rect = draw.proto.Rect.make(0, 0, @intCast(width), @intCast(height));

/// The initial window body (a few demo lines so the scene shows text + wraps).
const demo_body =
    \\Snarf — the ACME port, phase 8.
    \\
    \\A row of columns of windows, each a tag over a body.
    \\Point the mouse at a window and type (point-to-type).
    \\B1 sweeps a selection; B1+B2 cuts, B1+B3 pastes.
    \\The left strip of each body is its scrollbar.
    \\
;

/// Standing-ticket read buffers. Mouse reads land exactly one 49-byte record
/// (dev/input.zig mouse_rec_len); kbd reads land a short UTF-8 burst.
const mouse_buf_len = dev.input.mouse_rec_len; // 49
const kbd_buf_len = 64;

/// Drive an in-process 9P server one poll at a time; wired as a client's pump so
/// blocking client RPCs (version/attach/walk/open) advance the server. The input
/// client's parkable reads DON'T use this (they go through beginRead/checkRead,
/// R-P6-4) — only its setup RPCs do.
fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// The entry point's boot context (P-3 analog; future core/boot.zig absorbs it).
/// Every field lives here on the heap so the many captured interior pointers stay
/// valid for the session (nothing tears down — the tab owns the lifetime):
///   &canvas→dd, &dd→srv, &pipe→srv/cl, &srv→cl.pump, &cl→display; on the INPUT
///   side &devinput→srv_input, &pipe_input→srv_input/cl_input, &srv_input→
///   cl_input.pump; &mouse_buf/&kbd_buf are borrowed by the standing tickets so
///   they must not move; the window tree heap-allocates its Row/Column/Window so
///   their addresses are stable, and editor.row → tree.row.
const App = struct {
    // --- draw stack (phase 5) ---
    canvas: dev.draw_canvas.CanvasBackend,
    dd: dev.draw.DevDraw,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,
    display: *draw.Display,
    font: draw.Font,
    // --- window tree (phase 8): Chrome + Row + Column + Window(s) over heap
    //     body Files, assembled by core.boot; the Editor router hit-tests it. ---
    tree: core.boot.Tree,
    editor: core.Editor,
    // --- input stack (6c) ---
    devinput: DevInput,
    pipe_input: *ninep.chan.Pipe,
    srv_input: ninep.server.Server,
    cl_input: ninep.Client,
    mouse_fid: u32,
    kbd_fid: u32,
    ticket_mouse: ninep.Client.ReadTicket,
    ticket_kbd: ninep.Client.ReadTicket,
    mouse_buf: [mouse_buf_len]u8,
    kbd_buf: [kbd_buf_len]u8,
    // --- namespace + origin mount (phase 12) ---
    /// The session's mount table (S-02 §1). Empty at boot: the draw and input
    /// stacks are reached through their own captured clients, not by path. The
    /// origin binds `/mnt/origin` into it when (and only when) it comes up.
    ns: ninep.mount.Namespace,
    /// `/mnt/origin` (R-P12-5/6/7). Holds interior pointers (the client's
    /// transport captures `&origin.ws`), so like everything else here it lives
    /// in the heap App and never moves.
    origin: OriginMount,
    /// The `wsStage` staging buffer (R-P12-2): the shim copies each arriving
    /// WebSocket frame in here through the exported memory, then calls `wsPush`.
    /// Grown on demand, never shrunk — one buffer, reused for every frame, and
    /// only ever live between a `wsStage` call and the `wsPush` that follows it.
    ws_stage: []u8,
};

/// The ONE sanctioned module-level var: the boot context (see App's doc above).
var app: ?*App = null;

/// The ABI surface version the shim must agree with; shim.js reads this via the
/// export BEFORE calling init() and throws on mismatch (R-P5-4/R-P6-10).
export fn abi_version() u32 {
    return shim.abi.version;
}

/// Called once after instantiation (S-06 §2). Any boot failure becomes a panic
/// carrying the error name — the shim sees it on the console, then the trap.
export fn init() void {
    boot() catch |e| @panic(@errorName(e));
}

/// Build the App in place on the heap (pointer-capture hazards — see App's doc).
fn boot() !void {
    const a = try alloc.create(App);

    // ---- draw stack: canvas ← devdraw ← server ← client ← Display ----
    a.canvas = try dev.draw_canvas.CanvasBackend.init(alloc, width, height);
    a.dd = dev.draw.DevDraw.init(alloc, a.canvas.backend());
    a.pipe = try ninep.chan.Pipe.init(alloc, 16384);
    a.srv = try ninep.server.Server.init(alloc, a.pipe.serverEnd(), &dev.draw.DevDraw.ops, &a.dd, 8192);
    a.cl = try ninep.Client.init(alloc, a.pipe.clientEnd(), 8192);
    a.cl.pump = .{ .ctx = &a.srv, .run = pumpServer };
    _ = try a.cl.version(8192);
    const root = try a.cl.attach("larry", "");
    a.display = try draw.Display.init(alloc, &a.cl, root.fid);
    a.font = try draw.Font.init(alloc, a.display, draw.Font.default_subfont);

    // ---- window tree: Chrome + Row + Column + initial Window (phase 8) ----
    // boot draws the whole scene (white ground, rowtag/columntag/window chrome,
    // the demo body); no hand-built palette or manual ground fill needed.
    a.tree = try core.boot.boot(alloc, a.display, &a.font, screen_rect, .{
        .win_name = "scratch",
        .body = demo_body,
    });

    // Editor routing machine bound to the window tree (R-P8-9/10/11): keys
    // point-to-type, gestures pin to their Text, the wheel scrolls under-pointer.
    a.editor = core.Editor.init(alloc);
    a.editor.row = a.tree.row;
    // Bind the B2/B3 colored-sweep solids from Chrome (acme.c:1084-1085); the core
    // falls back to f.col(.high) when these are null (R-P9-12).
    a.editor.but2col = a.tree.chrome.but2col;
    a.editor.but3col = a.tree.chrome.but3col;

    // ---- input stack: devinput ← server ← client (the devdraw pattern) ----
    a.devinput = DevInput.init(alloc);
    a.pipe_input = try ninep.chan.Pipe.init(alloc, 16384);
    a.srv_input = try ninep.server.Server.init(alloc, a.pipe_input.serverEnd(), &DevInput.ops, &a.devinput, 8192);
    a.cl_input = try ninep.Client.init(alloc, a.pipe_input.clientEnd(), 8192);
    a.cl_input.pump = .{ .ctx = &a.srv_input, .run = pumpServer };
    _ = try a.cl_input.version(8192);
    const iroot = try a.cl_input.attach("larry", "");
    const mw = try a.cl_input.walk(iroot.fid, &.{"mouse"});
    a.mouse_fid = mw.fid;
    _ = try a.cl_input.open(a.mouse_fid, ninep.msg.OREAD);
    const kw = try a.cl_input.walk(iroot.fid, &.{"kbd"});
    a.kbd_fid = kw.fid;
    _ = try a.cl_input.open(a.kbd_fid, ninep.msg.OREAD);

    // Boot input profile (S-04 §2, minimal auto-select for v1): browser
    // hardware is mostly trackpads and one-button mice, so boot into the
    // MODIFIER profile — Option/Alt latches B2, Cmd/Ctrl latches B3, and (per
    // the 2026-09-04 S-04 §2.2 amendment) an unlatched press still passes the
    // physical button through, so real B2/B3 mice lose nothing. Overridable
    // any time by writing `profile native` to /dev/input/ctl.
    {
        const cw = try a.cl_input.walk(iroot.fid, &.{"ctl"});
        _ = try a.cl_input.open(cw.fid, ninep.msg.ORDWR);
        _ = try a.cl_input.write(cw.fid, 0, "profile modifier");
        try a.cl_input.clunk(cw.fid);
    }

    // Standing tickets (R-P6-4): one parkable read outstanding on each device,
    // re-armed on completion. The buffers are App-resident so they outlive the
    // tickets (beginRead borrows, never owns).
    a.ticket_mouse = try a.cl_input.beginRead(a.mouse_fid, 0, &a.mouse_buf);
    a.ticket_kbd = try a.cl_input.beginRead(a.kbd_fid, 0, &a.kbd_buf);

    // ---- namespace + origin mount (R-P12-5) ----
    // Boot NEVER waits on the socket: `dial` asks the shim to open it and
    // returns, the handshake is driven one step per `tick`, and if it does not
    // finish within OriginMount.dial_timeout_ms the mount is simply absent
    // (one warning line, no retry loop). Everything above this point — draw,
    // input, the window tree — is bit-identical with the origin down; that is
    // the acceptance bar. Both fields are assigned BEFORE `dial`, because the
    // mount captures `&a.origin.ws` and `&a.ns`.
    a.ns = ninep.mount.Namespace.init(alloc);
    a.origin = OriginMount.init(alloc, &a.ns);
    a.ws_stage = &.{};
    // Route the `Reconnect` builtin back out to the transport (R-P12-7). The
    // core cannot see `origin`/`shim` (R-OV-03), so this hook is the whole of
    // what it knows about the connection.
    a.editor.origin = .{ .ctx = a, .redial = redialOrigin };
    a.origin.dial();

    try a.display.flush();
    app = a;
}

/// `Editor.OriginHook.redial` (R-P12-7): tear down whatever connection exists
/// and start a fresh dial. Returns immediately — `tick` reports the outcome.
fn redialOrigin(ctx: *anyopaque) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    a.origin.dial();
}

/// Reserve `len` bytes of module memory for one inbound WebSocket frame and
/// hand the shim its address (R-P12-2). The shim writes the frame there through
/// the exported memory and immediately calls `wsPush`; nothing else touches the
/// buffer in between (JS is single-threaded and `wsPush` does not re-enter JS).
/// Returns 0 — "cannot stage", the shim drops the frame — before `init`, on a
/// frame larger than any 9P message we would accept, or on allocation failure.
export fn wsStage(len: u32) u32 {
    const a = app orelse return 0;
    if (len > stage_cap) return 0;
    // The shim stages EVERY record, including the empty payload of `open`, and
    // reads 0 as "cannot stage". So always hand back a real allocation: the
    // pointer of an empty slice is not guaranteed to be non-zero.
    const want = @max(len, 1);
    if (a.ws_stage.len < want) {
        if (a.ws_stage.len > 0) alloc.free(a.ws_stage);
        a.ws_stage = alloc.alloc(u8, want) catch {
            a.ws_stage = &.{};
            return 0;
        };
    }
    return @intFromPtr(a.ws_stage.ptr);
}

/// The staging ceiling: a frame this large is not a 9P message we ever
/// negotiated (OriginMount proposes 8192), so refusing it early keeps a hostile
/// or confused peer from sizing our heap.
const stage_cap: u32 = 1 << 20;

/// Deliver one inbound WebSocket record to the connection it belongs to
/// (R-P12-2). `kind` mirrors `shim.abi.WsKind`; `ptr[0..len]` is the staged
/// payload (empty for `open`). This ONLY queues — the module drains on `tick`,
/// so there is no JS→WASM re-entrancy. An unknown kind or a record for a
/// connection this session has walked away from is dropped.
export fn wsPush(id: u32, kind: u32, ptr: [*]const u8, len: u32) void {
    const a = app orelse return;
    const k: shim.abi.WsKind = switch (kind) {
        1...4 => @enumFromInt(kind), // range-checked (no std.meta.intToEnum in 0.16)
        else => return,
    };
    a.origin.push(id, k, ptr[0..len]);
}

/// The single input entry (R-P6-10, S-06 §4: input has NO env imports — it flows
/// browser → module via this ONE export; the record layout doubles as the future
/// SAB-ring slot). Decode per kind, push into devinput, then signal BOTH device
/// paths (R-P6-3): completeReads is a cheap no-op when nothing is parked, and
/// records that arrive before the standing read is parked are picked up by the
/// next tick's poll instead — so calling both unconditionally is safe.
///   pointer_down/up/move: a=x, b=y, c=DOM button (0/1/2)
///   wheel:                a=notches (b/c reserved)
///   key:                  a=rune,  c=mods bitfield
///   mod_down/up:          c=Mod id
export fn pushEvent(kind: u32, a_: i32, b_: i32, c: u32, t: u32) void {
    const a = app orelse return;
    decodeEvent(a, kind, a_, b_, c, t);
    _ = a.srv_input.completeReads(DevInput.mousePath()) catch |e| @panic(@errorName(e));
    _ = a.srv_input.completeReads(DevInput.kbdPath()) catch |e| @panic(@errorName(e));
}

fn decodeEvent(a: *App, kind: u32, x: i32, y: i32, c: u32, t: u32) void {
    const ek: shim.abi.EventKind = switch (kind) {
        1...7 => @enumFromInt(kind), // range-checked (std.meta.intToEnum is gone in 0.16)
        else => return, // unknown kind: drop
    };
    switch (ek) {
        .pointer_down => a.devinput.pushPointer(.down, x, y, @truncate(c), t),
        .pointer_up => a.devinput.pushPointer(.up, x, y, @truncate(c), t),
        .pointer_move => a.devinput.pushPointer(.move, x, y, @truncate(c), t),
        // a=notches; y/0 unused (F-7 ignores wheel). FLAG (phase 8): the wheel
        // record does not carry the pointer position, so Editor.handleMouse
        // scrolls whatever Text `mouse_pt` last landed on (the previous move) —
        // shim wheel-coordinate plumbing is deferred with the Worker+SAB move.
        .wheel => a.devinput.pushWheel(x, y, 0, t),
        .key => a.devinput.pushKey(@intCast(x), @bitCast(@as(u8, @truncate(c))), t),
        .mod_down, .mod_up => {
            const which: dev.input.Mod = switch (c) {
                0...3 => @enumFromInt(c),
                else => return, // unknown modifier id: drop
            };
            if (ek == .mod_down) a.devinput.pushMod(.down, which, t) else a.devinput.pushMod(.up, which, t);
        },
    }
}

/// Called by the shim when inbound events are waiting. The main-thread build is
/// tick-driven (the shim calls tick() from requestAnimationFrame, which drains
/// the input device), so wake is a no-op reserved for the future Worker + ring
/// path (R-P6-1). Left as an exported hook so the ABI surface is stable.
export fn wake() void {}

/// Called on each animation-frame tick with the current time in milliseconds.
/// Drains both 9P stacks and the input device, then flushes once. A failure
/// traps through the panic handler.
export fn tick(now_ms: u32) void {
    const a = app orelse return;
    _ = a.srv.poll() catch |e| @panic(@errorName(e)); // draw stack
    drainInput(a) catch |e| @panic(@errorName(e)); // input stack → Editor
    pollOrigin(a, now_ms); // /mnt/origin handshake + disconnect watch
    a.editor.frameEnd(a.display) catch |e| @panic(@errorName(e));
}

/// Advance the origin connection and turn a state change into EXACTLY one
/// warning line (R-P12-5/6/7). `now_ms` is the animation-frame clock: freestanding
/// wasm has no `std.Io` and no OS, so this is the module's only source of time and
/// the 10 s dial budget is counted in these ticks. A failure here never touches
/// the editor — an absent `/mnt/origin` is a supported state, not an error.
fn pollOrigin(a: *App, now_ms: u32) void {
    switch (a.origin.poll(now_ms)) {
        .none => {},
        .mounted => a.editor.warning("/mnt/origin: mounted\n", .{}),
        .failed => |why| a.editor.warning("/mnt/origin: not mounted ({s})\n", .{why}),
        .lost => |why| a.editor.warning("/mnt/origin: disconnected ({s})\n", .{why}),
    }
}

/// Drain every mouse record and kbd rune the input device can produce right now,
/// routing each through the Editor and re-arming the standing ticket. Each loop
/// polls the input server first: a poll parks the standing read when the queue is
/// empty (→ checkRead null → done) or serves it immediately when a record is
/// queued (→ checkRead a byte count → handle → re-arm → loop).
fn drainInput(a: *App) !void {
    // Mouse: one 49-byte record per completion.
    while (true) {
        _ = try a.srv_input.poll();
        const n = (try a.cl_input.checkRead(a.ticket_mouse)) orelse break;
        if (parseMouseRec(a.mouse_buf[0..n])) |ev| try a.editor.handleMouse(ev);
        a.ticket_mouse = try a.cl_input.beginRead(a.mouse_fid, 0, &a.mouse_buf);
    }
    // Kbd: a UTF-8 burst; decode whole runes and hand each to the Editor.
    while (true) {
        _ = try a.srv_input.poll();
        const n = (try a.cl_input.checkRead(a.ticket_kbd)) orelse break;
        var i: usize = 0;
        while (i < n) {
            const seq = std.unicode.utf8ByteSequenceLength(a.kbd_buf[i]) catch {
                i += 1;
                continue;
            };
            if (i + seq > n) break; // never split a rune (device guarantees whole runes)
            const r = std.unicode.utf8Decode(a.kbd_buf[i .. i + seq]) catch {
                i += seq;
                continue;
            };
            try a.editor.handleKey(@intCast(r));
            i += seq;
        }
        a.ticket_kbd = try a.cl_input.beginRead(a.kbd_fid, 0, &a.kbd_buf);
    }
}

/// Parse a `/dev/mouse` record ("m" + four space-padded decimal fields) into an
/// Editor.MouseEvent. Skips the leading 'm', then trim-parses the four ints
/// (devmouse.c:306-309 format). Returns null on any malformation.
fn parseMouseRec(rec: []const u8) ?core.Editor.MouseEvent {
    if (rec.len < 1 or rec[0] != 'm') return null;
    var it = std.mem.tokenizeScalar(u8, rec[1..], ' ');
    const xs = it.next() orelse return null;
    const ys = it.next() orelse return null;
    const bs = it.next() orelse return null;
    const ts = it.next() orelse return null;
    const x = std.fmt.parseInt(i32, xs, 10) catch return null;
    const y = std.fmt.parseInt(i32, ys, 10) catch return null;
    const b = std.fmt.parseInt(u32, bs, 10) catch return null;
    const ms = std.fmt.parseInt(u32, ts, 10) catch return null;
    return .{ .x = x, .y = y, .buttons = @truncate(b), .msec = ms };
}
