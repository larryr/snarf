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
//! Adapter seams live in sibling files so this one stays inside the ~400-line
//! cap (S-07): `input_pump.zig` (the device drain), `screen.zig` (the resize
//! sequence), `origin_glue.zig` (the `/n/origin` mount's ABI + tick half),
//! `opfs_glue.zig` (the `/mnt/opfs` half) — all four take borrowed pointers,
//! never the `App` context — and `wasm_boot.zig`, which owns the `App` struct
//! and `boot()` itself (phase 16a). This file keeps the `export fn`s, the panic
//! handler, the one `app` pointer and `tick`.
//!
//! The display size arrives from the browser through `init(w, h)` and follows the
//! window from then on via `EventKind.resize` (ABI v5, R-GFX-05) — nothing in the
//! module carries a size of its own any more.
const std = @import("std");
const dev = @import("dev");
const shim = @import("shim");
const screen = @import("screen.zig");
const input_pump = @import("input_pump.zig");
const origin_glue = @import("origin_glue.zig");
const opfs_glue = @import("opfs_glue.zig");
const wasm_boot = @import("wasm_boot.zig");

const DevInput = dev.input.DevInput;
const App = wasm_boot.App;

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
/// Declared with the App it feeds, in `wasm_boot.zig`.
const alloc = wasm_boot.alloc;

/// The display size now comes from the browser: the shim measures the window,
/// sizes the canvas backing store to it, and passes it to `init(w, h)`
/// (R-GFX-05). HISTORY: phases 5-12 hard-coded 640×480 here (R-P5-3) and
/// duplicated the numbers in `web/index.html`; the frozen acceptance goldens are
/// unaffected by the change because each builds its OWN 640×480 headless backend
/// (`src/accept.zig`) rather than booting this entry point (R-P12c-3). The two
/// clamps that guard those numbers live with the rest of the display-size policy
/// in `screen.zig`.
const clampDim = screen.clampDim;
const dimOf = screen.dimOf;

/// The ONE sanctioned module-level var: the boot context (see App's doc above).
var app: ?*App = null;

/// The ABI surface version the shim must agree with; shim.js reads this via the
/// export BEFORE calling init() and throws on mismatch (R-P5-4/R-P6-10).
export fn abi_version() u32 {
    return shim.abi.version;
}

/// Called once after instantiation (S-06 §2) with the display size in device
/// pixels — the canvas backing store the shim just sized to the browser window
/// (ABI v5, R-GFX-05). Any boot failure becomes a panic carrying the error name —
/// the shim sees it on the console, then the trap. `wasm_boot.boot` builds the
/// context; installing it as `app` is the root's job, so nothing can reach a
/// half-built App through an export.
export fn init(w: u32, h: u32) void {
    app = wasm_boot.boot(clampDim(w), clampDim(h), .{
        .opfs_log = .{ .write = opfsLog },
        .redial = redialOrigin,
    }) catch |e| @panic(@errorName(e));
}

/// The OPFS device's one-line diagnostic channel (R-P5-6: only the root may
/// name `consoleLog`). Used exactly once per session, for `/mnt/opfs:
/// unavailable`.
fn opfsLog(_: ?*anyopaque, line: []const u8) void {
    consoleLog(line.ptr, line.len);
}

/// Stage one `fsOp` completion payload (ABI v6) — trampoline over
/// `opfs_glue.stage`. 0 before `init`: nothing can be staged yet.
export fn fsStage(len: u32) u32 {
    const a = app orelse return 0;
    return opfs_glue.stage(opfsDevices(a), len);
}

/// Deliver one `fsOp` completion (ABI v6) — trampoline over `opfs_glue.push`,
/// which caches the answer and then retries whatever it unblocked. Dropped
/// before `init`. A transport failure traps the way every other export path
/// does: panic with the error name through the consoleLog handler.
export fn fsPush(ticket: u32, status: u32, ptr: [*]const u8, len: u32) void {
    const a = app orelse return;
    opfs_glue.push(opfsDevices(a), ticket, status, ptr, len) catch |e| @panic(@errorName(e));
}

/// The borrowed view of the OPFS stack `opfs_glue` works through.
fn opfsDevices(a: *App) opfs_glue.Devices {
    return .{
        .allocator = alloc,
        .dev = &a.dev_opfs,
        .srv = &a.opfs_tree.srv,
        .stage = &a.fs_stage,
    };
}

/// `Editor.OriginHook.redial` (R-P12-7) — trampoline over `origin_glue.redial`.
fn redialOrigin(ctx: *anyopaque) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    origin_glue.redial(originDevices(a));
}

/// Stage one inbound WebSocket frame (R-P12-2) — trampoline over
/// `origin_glue.stage`. 0 before `init`: nothing can be staged yet.
export fn wsStage(len: u32) u32 {
    const a = app orelse return 0;
    return origin_glue.stage(originDevices(a), len);
}

/// Deliver one inbound WebSocket record (R-P12-2) — trampoline over
/// `origin_glue.push`. Dropped before `init`.
export fn wsPush(id: u32, kind: u32, ptr: [*]const u8, len: u32) void {
    const a = app orelse return;
    origin_glue.push(originDevices(a), id, kind, ptr, len);
}

/// The borrowed view of the origin stack `origin_glue` works through — the
/// `inputDevices` pattern; every field points into the heap `App`.
fn originDevices(a: *App) origin_glue.Devices {
    return .{
        .allocator = alloc,
        .mount = &a.origin,
        .stage = &a.ws_stage,
        .editor = &a.editor,
        .log = consoleLog,
    };
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
///   resize:               a=width, b=height (device px; NOT an input event —
///                         it rides this export because it is the same
///                         browser→module edge, and the two completeReads below
///                         are no-ops for it)
export fn pushEvent(kind: u32, a_: i32, b_: i32, c: u32, t: u32) void {
    const a = app orelse return;
    decodeEvent(a, kind, a_, b_, c, t);
    _ = a.srv_input.completeReads(DevInput.mousePath()) catch |e| @panic(@errorName(e));
    _ = a.srv_input.completeReads(DevInput.kbdPath()) catch |e| @panic(@errorName(e));
}

fn decodeEvent(a: *App, kind: u32, x: i32, y: i32, c: u32, t: u32) void {
    const ek: shim.abi.EventKind = switch (kind) {
        1...8 => @enumFromInt(kind), // range-checked (std.meta.intToEnum is gone in 0.16)
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
        // The browser window changed size (R-GFX-05). The shim has ALREADY
        // resized the canvas — which clears it — so the module owes a full
        // repaint; `screen.resize` arranges one and re-tiles the tree. Fatal on
        // failure, like acme's `error("attach to window")` (acme.c:550), and
        // reported the way every other export path reports one: panic with the
        // error name through the consoleLog panic handler.
        .resize => {
            const w = dimOf(x);
            const h = dimOf(y);
            if (w == a.canvas.headless.width and h == a.canvas.headless.height) return; // same size: nothing to do
            screen.resize(&a.canvas, &a.dd, a.display, &a.tree, w, h) catch |e| @panic(@errorName(e));
            a.editor.needs_flush = true; // present the repaint on this tick's frameEnd
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
    a.self_tree.poll() catch |e| @panic(@errorName(e)); // /mnt/snarf-self stack
    a.opfs_tree.poll() catch |e| @panic(@errorName(e)); // /mnt/opfs stack (parks; fsPush retries)
    input_pump.drain(inputDevices(a), &a.editor) catch |e| @panic(@errorName(e)); // input stack → Editor
    origin_glue.poll(originDevices(a), now_ms); // /n/origin handshake + disconnect watch
    a.editor.frameEnd(a.display) catch |e| @panic(@errorName(e));
}

/// The borrowed view of the input stack that `input_pump.drain` works through.
/// Every field is a pointer into the heap `App`, which never moves — the standing
/// tickets borrow `mouse_buf`/`kbd_buf` and are re-armed in place.
fn inputDevices(a: *App) input_pump.Devices {
    return .{
        .srv = &a.srv_input,
        .cl = &a.cl_input,
        .mouse_fid = a.mouse_fid,
        .kbd_fid = a.kbd_fid,
        .ticket_mouse = &a.ticket_mouse,
        .ticket_kbd = &a.ticket_kbd,
        .mouse_buf = &a.mouse_buf,
        .kbd_buf = &a.kbd_buf,
    };
}
