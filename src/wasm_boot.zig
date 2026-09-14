//! The WASM entry point's BOOT half (S-07 §4): the `App` context struct and the
//! `boot()` that assembles it. Carved out of `main_wasm.zig` verbatim in phase
//! 16a so that file stays inside the ~400-line cap; `main_wasm.zig` keeps the
//! `export fn`s, the panic handler, the `app` pointer and `tick`.
//!
//! Like `screen.zig`, `input_pump.zig`, `origin_glue.zig` and `opfs_glue.zig`
//! this file never declares a host import of its own (R-P5-6): the root's
//! `consoleLog` reaches it as a `Hooks` field, so the native shim test root
//! never references the symbol. It is the one sibling that DOES see the `App`
//! type — it defines it.
const std = @import("std");
const core = @import("core");
const dev = @import("dev");
const draw = @import("draw");
const ninep = @import("ninep");
const origin = @import("origin");
const ns_boot = @import("ns_boot.zig");

const DevInput = dev.input.DevInput;
const DevOpfs = dev.opfs.DevOpfs;
const OriginMount = origin.OriginMount;

/// Single-threaded brk allocator (std.heap.zig, BrkAllocator) — the only
/// allocator available freestanding, and wasm32 is single-threaded here.
pub const alloc = std.heap.wasm_allocator;

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

/// The two root-owned callbacks `boot` needs but may not name itself (R-P5-6):
/// both are declared in `main_wasm.zig`, which owns the `consoleLog` import and
/// the `app` pointer.
pub const Hooks = struct {
    /// The OPFS device's one-line diagnostic channel, used exactly once per
    /// session for `/mnt/opfs: unavailable`.
    opfs_log: dev.opfs.LogHook,
    /// `Editor.OriginHook.redial` (R-P12-7) — routes the `Reconnect` builtin
    /// back out to the transport. Bound with `ctx = a`, the App itself.
    redial: *const fn (ctx: *anyopaque) void,
};

/// The entry point's boot context (P-3 analog; future core/boot.zig absorbs it).
/// Every field lives here on the heap so the many captured interior pointers stay
/// valid for the session (nothing tears down — the tab owns the lifetime):
///   &canvas→dd, &dd→srv, &pipe→srv/cl, &srv→cl.pump, &cl→display; on the INPUT
///   side &devinput→srv_input, &pipe_input→srv_input/cl_input, &srv_input→
///   cl_input.pump; &mouse_buf/&kbd_buf are borrowed by the standing tickets so
///   they must not move; the window tree heap-allocates its Row/Column/Window so
///   their addresses are stable, and editor.row → tree.row.
pub const App = struct {
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
    // --- /mnt/opfs (phase 14b) ---
    /// The OPFS device (R-9P-09). Lives here because `opfs_tree.srv` captures
    /// it and the standing `fsOp` tickets are keyed against it, so like
    /// everything else in this struct it never moves.
    dev_opfs: DevOpfs,
    /// Its pipe/server/client triple, mounted at `/mnt/opfs` by `ns_boot`.
    opfs_tree: ns_boot.OpfsTree,
    /// The `fsStage` staging buffer — the `ws_stage` story, for the OTHER
    /// record stream. Deliberately a SECOND buffer: the two completion paths
    /// must never be able to interleave into one another's bytes.
    fs_stage: []u8,
};

/// Build the App in place on the heap (pointer-capture hazards — see App's doc)
/// and hand it back; the root installs it as the module's one `app` pointer.
pub fn boot(width: u32, height: u32, hooks: Hooks) !*App {
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

    // ---- window tree: Chrome + Row + TWO empty Columns (acme.c:242-257) ----
    // The acme no-argument boot (phase 13b): `ncol = 2` and no window yet. The
    // scratch demo window that stood here through phase 12 is gone; the
    // directory window for `/` is opened below, once the namespace exists
    // (acme.c:258-259 `readfile(row.col[row.ncol-1], wdir)`).
    a.tree = try core.boot.boot(alloc, a.display, &a.font, screen_rect, .{
        .dir_boot = true,
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

    // ---- /mnt/opfs (R-9P-09, R-P14b-2) ----
    // Mounted UNCONDITIONALLY, before anything can ask for it: the device
    // itself asks the browser nothing until a 9P op arrives (boot issues no
    // `fsOp` at all), and a browser with no OPFS answers every ticket with
    // `i/o error` plus one console line rather than leaving a hole in the
    // namespace. `/mnt/` therefore lists `opfs/` from the first frame.
    a.dev_opfs = DevOpfs.init(alloc, dev.opfs.shimRequester());
    a.dev_opfs.log = hooks.opfs_log;
    a.fs_stage = &.{};
    try a.opfs_tree.start(alloc, &a.dev_opfs, &a.ns);

    // ---- the boot directory window (acme.c:258-259, R-EDIT-03) ----
    // `readfile(row.col[row.ncol-1], wdir)`: the working directory — `/` here
    // (R-P13b-3) — in the RIGHTMOST column, the left one left empty. Boot does
    // NOT wait for it: the listing arrives through `Editor.loads` over the next
    // frames (`Load.stepAll` from `frameEnd`), which with the in-process pipes
    // is a frame or two. `/n/origin` and `/bin` are not mounted yet, so the
    // first listing reads `dev/ mnt/`; a `Get` after the origin attaches adds
    // `bin/` and `n/` (acme does not auto-refresh a directory window either).
    {
        const cols = a.tree.row.col.items;
        _ = try core.openfile.readFile(&a.editor, cols[cols.len - 1], "/");
    }

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
    a.editor.origin = .{ .ctx = a, .redial = hooks.redial };
    a.origin.dial();

    try a.display.flush();
    return a;
}
