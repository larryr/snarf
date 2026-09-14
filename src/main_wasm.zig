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
//! Two adapter seams live in sibling files so this one stays near the ~400-line
//! cap (S-07): `input_pump.zig` (the device drain), `screen.zig` (the resize
//! sequence) and `origin_glue.zig` (the `/n/origin` mount's ABI + tick half).
//! All three take borrowed pointers, never the `App` context.
//!
//! The display size arrives from the browser through `init(w, h)` and follows the
//! window from then on via `EventKind.resize` (ABI v5, R-GFX-05) — nothing in the
//! module carries a size of its own any more.
const std = @import("std");
const core = @import("core");
const dev = @import("dev");
const draw = @import("draw");
const ninep = @import("ninep");
const origin = @import("origin");
const shim = @import("shim");
const screen = @import("screen.zig");
const input_pump = @import("input_pump.zig");
const origin_glue = @import("origin_glue.zig");
const ns_boot = @import("ns_boot.zig");

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
    // --- namespace + origin mount (phase 12, populated in 13a) ---
    /// The session's mount table (S-02 §1.3). Since phase 13a it is REAL at
    /// boot — `/dev`, `/dev/draw` and `/mnt/snarf-self` are mounted by
    /// `ns_boot`, and `/` and `/mnt` are synthesized from those prefixes
    /// (R-9P-16). The origin binds `/n/origin` (+ `/bin`) into it when, and
    /// only when, it comes up. `a.editor.ns` points here: it is how `core`
    /// reaches any file at all (R-OV-03).
    ///
    /// SEAM (R-P13a-4, S-02 §1): `/mnt/snarf-self/ns` — a read-only file
    /// rendering `ns.list(w)` — is still not served. The handle it needs now
    /// exists (`Editor.ns`); what stops it is that a served-root dirtab row is
    /// also a listing row, so it moves an existing served-tree expectation.
    /// See the SEAM(ns) note in `core/served/fsys.zig`.
    ns: ninep.mount.Namespace,
    /// The in-process `/mnt/snarf-self` server + client (retires R-P10-E).
    /// Holds interior pointers, so like everything else here it never moves.
    self_tree: ns_boot.SelfTree,
    /// `/n/origin` (R-P12-5/6/7). Holds interior pointers (the client's
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

/// Called once after instantiation (S-06 §2) with the display size in device
/// pixels — the canvas backing store the shim just sized to the browser window
/// (ABI v5, R-GFX-05). Any boot failure becomes a panic carrying the error name —
/// the shim sees it on the console, then the trap.
export fn init(w: u32, h: u32) void {
    boot(clampDim(w), clampDim(h)) catch |e| @panic(@errorName(e));
}

/// Build the App in place on the heap (pointer-capture hazards — see App's doc).
fn boot(width: u32, height: u32) !void {
    const a = try alloc.create(App);
    // The window tree fills the whole display (rowinit lays the rowtag + white
    // ground; Chrome owns the acme palette solids).
    const screen_rect = draw.proto.Rect.make(0, 0, @intCast(width), @intCast(height));

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

    // ---- the session mount table (S-02 §1.3) ----
    // Created BEFORE the scene so the tree can carry it onto the Editor; the
    // devices and the served tree are mounted below, once their stacks exist.
    // `OriginMount` captures `&a.ns` later, so this must not move.
    a.ns = ninep.mount.Namespace.init(alloc);

    // ---- window tree: Chrome + Row + Column + initial Window (phase 8) ----
    // boot draws the whole scene (white ground, rowtag/columntag/window chrome,
    // the demo body); no hand-built palette or manual ground fill needed.
    a.tree = try core.boot.boot(alloc, a.display, &a.font, screen_rect, .{
        .win_name = "scratch",
        .body = demo_body,
        .ns = &a.ns,
    });

    // Editor routing machine bound to the window tree (R-P8-9/10/11): keys
    // point-to-type, gestures pin to their Text, the wheel scrolls under-pointer.
    // `bind` installs the window tree AND the namespace handle (phase 13a).
    a.editor = core.Editor.init(alloc);
    a.tree.bind(&a.editor);
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

    // ---- boot namespace (S-02 §1.3, R-P13a) ----
    // The two device stacks by path, then the served editor tree, served
    // in-process from boot (R-P10-E retired). `/` and `/mnt` need no mount —
    // `ninep.nsdir` synthesizes every directory that exists only as a prefix of
    // a mounted entry (R-9P-16, devroot.c's role).
    try ns_boot.mountDevices(&a.ns, &a.cl, root.fid, &a.cl_input, iroot.fid);
    try a.self_tree.start(alloc, &a.editor, &a.ns);

    // ---- origin mount (R-P12-5) ----
    // Boot NEVER waits on the socket: `dial` asks the shim to open it and
    // returns, the handshake is driven one step per `tick`, and if it does not
    // finish within OriginMount.dial_timeout_ms the mount is simply absent
    // (one warning line, no retry loop). Everything above this point — draw,
    // input, the window tree — is bit-identical with the origin down; that is
    // the acceptance bar. The mount is assigned BEFORE `dial`, because it
    // captures `&a.origin.ws` and `&a.ns` (`a.ns` itself was created above, so
    // the scene and the devices could already be bound to it).
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
