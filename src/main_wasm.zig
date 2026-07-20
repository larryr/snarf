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
const shim = @import("shim");

const DevInput = dev.input.DevInput;

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
/// Frame rect (R-P5-8 numbers): the interactive text body.
const text_rect = draw.proto.Rect.make(20, 20, 620, 470);

// The acme palette (R-P6-9/F-10). Colors are RGBA (0xRRGGBBAA); the display is
// opaque so alpha is 0xFF throughout.
const acme_back: draw.proto.Color = 0xFFFFEAFF; // ivory ground (BACK)
const acme_high: draw.proto.Color = 0xEEEE9EFF; // selection highlight (HIGH)

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
///   they must not move; &text→editor.text, and text.fr is pointed at by its own
///   SelectState, so text must not move either.
const App = struct {
    // --- draw stack (phase 5) ---
    canvas: dev.draw_canvas.CanvasBackend,
    dd: dev.draw.DevDraw,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,
    display: *draw.Display,
    font: draw.Font,
    // --- palette images (acme scene, F-10) ---
    back: draw.Image,
    high: draw.Image,
    black: draw.Image,
    // --- document ---
    file: core.File,
    text: core.Text,
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

    // ---- acme palette + EMPTY buffer (R-P6-9/F-10) ----
    a.back = try a.display.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, acme_back);
    a.high = try a.display.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, acme_high);
    a.black = try a.display.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DBlack);
    a.file = core.File.init(alloc, core.Buffer.initEmpty(alloc));
    // cols = {BACK, HIGH, bord, text, htext} = {back, high, black, black, black}.
    a.text = try core.Text.init(&a.file, alloc, text_rect, &a.font, &a.display.image, .{ &a.back, &a.high, &a.black, &a.black, &a.black });

    // Ivory ground fill over the whole display, then lay out the (empty) buffer.
    try a.display.image.draw(draw.proto.Rect.make(0, 0, @intCast(width), @intCast(height)), &a.back, null, .{});
    try a.text.fill();

    // Editor routing machine bound to the single Text (F-9).
    a.editor = core.Editor.init(alloc);
    a.editor.text = &a.text;

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

    // Standing tickets (R-P6-4): one parkable read outstanding on each device,
    // re-armed on completion. The buffers are App-resident so they outlive the
    // tickets (beginRead borrows, never owns).
    a.ticket_mouse = try a.cl_input.beginRead(a.mouse_fid, 0, &a.mouse_buf);
    a.ticket_kbd = try a.cl_input.beginRead(a.kbd_fid, 0, &a.kbd_buf);

    try a.display.flush();
    app = a;
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
        .wheel => a.devinput.pushWheel(x, y, 0, t), // a=notches; y/0 unused (F-7 ignores wheel)
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
    _ = now_ms;
    const a = app orelse return;
    _ = a.srv.poll() catch |e| @panic(@errorName(e)); // draw stack
    drainInput(a) catch |e| @panic(@errorName(e)); // input stack → Editor
    a.editor.frameEnd(a.display) catch |e| @panic(@errorName(e));
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
