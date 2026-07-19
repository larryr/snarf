//! Freestanding WASM entry point (S-07 §4). Boots the whole editor stack on the
//! heap and renders the phase-4 demo scene through the real pipeline, then
//! exports the three lifecycle hooks (init/wake/tick, S-06 §2) plus the ABI
//! version probe the shim checks before it calls init() (R-P5-4).
//!
//! This is the phase-5 boot: module runs on the MAIN THREAD (R-P5-2 divergence
//! — the Worker + rings land with devinput). The assembly mirrors accept.zig's
//! phase-4 test, the strongest native proof of this exact boot path (R-P5-8).
const std = @import("std");
const core = @import("core");
const dev = @import("dev");
const draw = @import("draw");
const ninep = @import("ninep");
const shim = @import("shim");

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

/// Single-threaded brk allocator (std.heap.zig:359, BrkAllocator) — the only
/// allocator available freestanding, and wasm32 is single-threaded in phase 5.
const alloc = std.heap.wasm_allocator;

/// 33-rune demo: an exact-fit wrap, a newline and a tab — golden-locked
/// natively by accept.zig's phase-4 test.
const demo_text = "hello, acme wraps\nsecond line\ttab";
/// Display is a fixed 640×480 (R-P5-3), matching the frozen goldens; the same
/// numbers are duplicated in index.html until canvasResize/DPR land.
const width: u32 = 640;
const height: u32 = 480;
/// Frame rect per R-P5-8 — the 33 runes render as two lines through the frame.
const text_rect = draw.proto.Rect.make(20, 20, 620, 470);

/// Drive the in-process 9P server one poll at a time; wired as the client's
/// pump so blocking client calls advance the server (verbatim from accept.zig).
fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// The entry point's boot context (P-3 analog of main_native's frame; future
/// core/boot.zig absorbs it). Fields are in INIT order; teardown is the exact
/// reverse: text → black → file → font → display → cl → srv → pipe → dd →
/// canvas. Nothing tears down in phase 5 (the tab lives for the session), but
/// the ordering is the contract every later phase inherits.
const App = struct {
    canvas: dev.draw_canvas.CanvasBackend,
    dd: dev.draw.DevDraw,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,
    display: *draw.Display,
    font: draw.Font,
    file: core.File,
    black: draw.Image,
    text: core.Text,
};

/// The ONE sanctioned module-level var: the boot context (see App's doc above).
var app: ?*App = null;

/// The ABI surface version the shim must agree with; shim.js reads this via the
/// export BEFORE calling init() and throws on mismatch (R-P5-4).
export fn abi_version() u32 {
    return shim.abi.version;
}

/// Called once after instantiation (S-06 §2). Any boot failure becomes a panic
/// carrying the error name — the shim sees it on the console, then the trap.
export fn init() void {
    boot() catch |e| @panic(@errorName(e));
}

/// Build every App field IN PLACE on the heap so the many captured interior
/// pointers stay valid (heap-create App FIRST — pointer-capture hazards:
/// &a.canvas→dd, &a.dd→srv, &a.srv→pump, &a.cl→display, &a.font/&a.black/
/// &a.file→text). Assembly is accept.zig's phase-4 scene.
fn boot() !void {
    const a = try alloc.create(App);

    // Device side: canvas backend behind devdraw behind an in-process 9P server.
    a.canvas = try dev.draw_canvas.CanvasBackend.init(alloc, width, height);
    a.dd = dev.draw.DevDraw.init(alloc, a.canvas.backend());
    a.pipe = try ninep.chan.Pipe.init(alloc, 16384);
    a.srv = try ninep.server.Server.init(alloc, a.pipe.serverEnd(), &dev.draw.DevDraw.ops, &a.dd, 8192);

    // Client side: 9P client pumped against the server, draw Display on top.
    a.cl = try ninep.Client.init(alloc, a.pipe.clientEnd(), 8192);
    a.cl.pump = .{ .ctx = &a.srv, .run = pumpServer };
    _ = try a.cl.version(8192);
    const root = try a.cl.attach("larry", "");
    a.display = try draw.Display.init(alloc, &a.cl, root.fid);
    a.font = try draw.Font.init(alloc, a.display, draw.Font.default_subfont);

    // A real Buffer/File carrying the demo text.
    a.file = core.File.init(alloc, try core.Buffer.initFromBytes(alloc, demo_text));

    // Scene: white ground, a black solid, the wrapped text through the frame.
    try a.display.image.draw(draw.proto.Rect.make(0, 0, @intCast(width), @intCast(height)), &a.display.white, null, .{});
    a.black = try a.display.allocImage(draw.proto.Rect.make(0, 0, 1, 1), draw.proto.RGBA32, true, draw.proto.DBlack);
    a.text = core.Text.init(&a.file, alloc, text_rect, &a.font, &a.display.image, .{ &a.display.white, &a.display.white, &a.black, &a.black, &a.black });
    try a.text.fill();
    try a.display.flush();

    app = a;
}

/// Called by the shim when inbound events are waiting in the ring buffer. No
/// inbound events exist until devinput lands, so this is a no-op in phase 5.
export fn wake() void {}

/// Called on each animation-frame tick with the current time in milliseconds.
/// Drains any pending server work; a failure traps through the panic handler.
export fn tick(now_ms: u32) void {
    _ = now_ms;
    if (app) |a| {
        _ = a.srv.poll() catch |e| @panic(@errorName(e));
    }
}
