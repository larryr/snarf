//! NATIVE entry point (S-07 §4, ADR-0005): the same editor core, in a real
//! window, through a plan9port `devdraw` child process.
//!
//! This file is the native twin of `main_wasm.zig`, and deliberately has the
//! same SHAPE: build the device stacks, mount them, boot the window tree, then
//! loop `drain → pump → frameEnd`. Everything that differs is below the
//! `/dev` boundary:
//!
//!            browser host                     native host
//!   draw     dev/draw.zig + a canvas   host/devdraw/dev_draw.zig → Twrdraw
//!   input    dev/input.zig + profiles  host/devdraw/dev_input.zig → Rrdmouse
//!   loop     requestAnimationFrame     poll(2) on the devdraw pipe
//!   warp     refused                   HONORED (Tmoveto) — R-P15-3
//!
//! and NOTHING differs above it: `core`, `draw` and `ninep` are the same module
//! objects the wasm build links, with no host switch anywhere inside them.
//! That identity is the whole point of the spike (R-P15-2 / R-OV-03).
//!
//! The namespace (phase 20, S-02 §4): the host file system, served
//! in-process by `hostfs.HostTree` over `HostFs` rooted at the real `/`, is
//! mounted at `/` — the fallthrough, since longest-prefix resolve keeps
//! `/dev`, `/dev/draw` and `/mnt/snarf-self` winning — and again at
//! `/mnt/host` (the S-02 alias). So the boot directory window lists the real
//! root, and Put/Get/B3 on any absolute path reach the disk, as in acme. The
//! synthetic prefixes (`dev/`, `mnt/`) are NOT in that listing: they are
//! mount-table entries, not host entries. Not here yet (ADR-0005 §5): a
//! process service, `/n/origin`, `/mnt/opfs`.
const std = @import("std");
const core = @import("core");
const dev = @import("dev");
const draw = @import("draw");
const host = @import("host");
const hostfs = @import("hostfs");
const ninep = @import("ninep");
const input_pump = @import("input_pump.zig");
const ns_boot = @import("ns_boot.zig");

const Conn = host.Conn;
const DevDraw9 = host.dev_draw.DevDraw9;
const DevInput9 = host.dev_input.DevInput9;

/// Standing-ticket read buffers — the `main_wasm` sizes.
const mouse_buf_len = dev.input.mouse_rec_len; // 49
const kbd_buf_len = 64;

/// How long the loop blocks in `poll(2)` waiting for the window system. A
/// frame budget, not a deadline: anything the editor still owes itself
/// (`Load` jobs, the parked look) is stepped by `frameEnd` on the next lap, so
/// the loop must not sleep indefinitely even with the user idle.
const frame_timeout_ms: i32 = 16;

/// The boot context. Like `main_wasm.App` it is heap-resident and never moves:
/// the servers capture `&device`, the clients capture the pipes, the standing
/// tickets borrow `mouse_buf`/`kbd_buf`, and the window tree's Row/Column/
/// Window addresses are live inside `editor`.
const App = struct {
    conn: Conn,
    // --- draw stack: devdraw ← dev_draw ← server ← client ← Display ---
    dd: DevDraw9,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,
    display: *draw.Display,
    font: draw.Font,
    // --- window tree + router ---
    tree: core.boot.Tree,
    editor: core.Editor,
    // --- input stack: devdraw ← dev_input ← server ← client ---
    devinput: DevInput9,
    pipe_input: *ninep.chan.Pipe,
    srv_input: ninep.server.Server,
    cl_input: ninep.Client,
    mouse_fid: u32,
    kbd_fid: u32,
    ticket_mouse: ninep.Client.ReadTicket,
    ticket_kbd: ninep.Client.ReadTicket,
    mouse_buf: [mouse_buf_len]u8,
    kbd_buf: [kbd_buf_len]u8,
    // --- host file system stack: HostFs ← HostTree ← server ← client ---
    host_fs: hostfs.HostFs,
    host_tree: hostfs.HostTree,
    pipe_fs: *ninep.chan.Pipe,
    srv_fs: ninep.server.Server,
    cl_fs: ninep.Client,
    // --- namespace ---
    ns: ninep.mount.Namespace,
    self_tree: ns_boot.SelfTree,
};

/// Drive an in-process 9P server one poll at a time (the `main_wasm` pump).
fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // ADR-0007 §2: resolved before anything is spawned, so a bad name never
    // opens a window.
    const pal = colorsFromArgs(init.minimal.args) orelse std.process.exit(2);
    const a = try gpa.create(App);
    defer gpa.destroy(a);

    // ADR-0006 §4: $DEVDRAW → bundled (beside this executable) → $PLAN9/bin →
    // $PATH. No executable path just skips "bundled"; it is never fatal.
    const exe_path: ?[:0]u8 = std.process.executablePathAlloc(init.io, gpa) catch null;
    defer if (exe_path) |p| gpa.free(p);
    var io = init.io;
    var dd_path = try host.DevdrawPath.resolve(
        gpa,
        init.environ_map,
        if (exe_path) |p| std.fs.path.dirname(p) else null,
        .{ .ctx = &io, .exists = existsOnDisk },
    );
    defer dd_path.deinit(gpa);
    // R-P18-9: printed once, before the spawn's outcome is known.
    std.debug.print("snarf: devdraw: {s} ({s})\n", .{ dd_path.path, dd_path.describe() });

    a.conn = Conn.init(gpa);
    defer a.conn.deinit();
    a.conn.spawn(init.io, init.environ_map, .{
        .winsize = winsizeFromEnv(init.environ_map),
        .label = "snarf",
        .argv0 = "snarf",
        .path = dd_path.path,
    }) catch |e| {
        std.debug.print(
            \\snarf: cannot start devdraw ({t}).
            \\  Run `zig build native` to build the bundled devdraw (macOS), or set $DEVDRAW to a devdraw binary, or $PLAN9 to a plan9port tree.
            \\
        , .{e});
        return e;
    };

    try boot(gpa, init.io, a, pal);
    defer a.tree.deinit();
    defer a.editor.deinit();
    // R-P17-5 / PM Q6: the native `$home` is the real `$HOME` (acme.c:136),
    // null when unset. It resolves through the root mount, so `Dump` writes
    // `$HOME/acme.dump` on the real disk.
    a.editor.session.home = init.environ_map.get("HOME");

    // The two long polls, armed once and re-armed by `Conn.poll` from here on
    // (drawclient.c keeps exactly one of each outstanding).
    try a.conn.armMouse();
    try a.conn.armKbd();

    while (!a.conn.isClosed()) {
        _ = a.conn.poll(frame_timeout_ms) catch |e| switch (e) {
            error.Closed => break,
            else => return e,
        };
        try pumpWindowSystem(a);
        try tick(a);
    }
}

/// `DevdrawPath.Probe` over the real file system: an `access(2)` existence
/// check through `Io.Dir.access` (no open, no write). Relative `$PLAN9` values
/// resolve against the working directory, as the spawn itself would.
fn existsOnDisk(ctx: *anyopaque, path: []const u8) bool {
    const io: *const std.Io = @ptrCast(@alignCast(ctx));
    std.Io.Dir.cwd().access(io.*, path, .{}) catch return false;
    return true;
}

/// The scheme `-colors=NAME` selects (last one wins), or `Palette.default`.
/// Null after reporting an unknown name and the valid ones on stderr.
fn colorsFromArgs(args: std.process.Args) ?*const core.Palette {
    var pal = core.Palette.default;
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| switch (core.Palette.parseFlag(arg)) {
        .other => {},
        .palette => |p| pal = p,
        .unknown => |name| {
            std.debug.print("snarf: unknown color scheme \"{s}\"; -colors= takes one of:", .{name});
            for (core.Palette.names) |n| std.debug.print(" {s}", .{n});
            std.debug.print("\n", .{});
            return null;
        },
    };
    return pal;
}

/// `$winsize` is libdraw's own knob for the initial window geometry
/// (`parsewinsize` accepts "WxH" or "x0,y0,x1,y1", mac-screen.m:253-258).
/// Honoured here for the same reason: it is how a plan9port user says how big
/// they want the window.
fn winsizeFromEnv(env: *const std.process.Environ.Map) []const u8 {
    return env.get("winsize") orelse "1024x768";
}

/// Build the whole stack in place (pointer-capture hazards — see `App`).
fn boot(gpa: std.mem.Allocator, io: std.Io, a: *App, pal: *const core.Palette) !void {
    // ---- draw stack ----
    a.dd = DevDraw9.init(&a.conn);
    a.pipe = try ninep.chan.Pipe.init(gpa, 16384);
    a.srv = try ninep.server.Server.init(gpa, a.pipe.serverEnd(), &DevDraw9.ops, &a.dd, 8192);
    a.cl = try ninep.Client.init(gpa, a.pipe.clientEnd(), 8192);
    a.cl.pump = .{ .ctx = &a.srv, .run = pumpServer };
    _ = try a.cl.version(8192);
    const root = try a.cl.attach("larry", "");
    // `Display.init` walks `new`, opens it, and reads the connection line —
    // which is where the device installs the screen image and learns the
    // window's size. Nothing here decides a display size: the window system
    // does (contrast the browser, where `init(w,h)` carries it in, R-GFX-05).
    a.display = try draw.Display.init(gpa, &a.cl, root.fid);
    a.font = try draw.Font.init(gpa, a.display, draw.Font.default_subfont);

    // ---- namespace ----
    a.ns = ninep.mount.Namespace.init(gpa);

    // ---- window tree: the acme no-argument boot (acme.c:242-259) ----
    a.tree = try core.boot.boot(gpa, a.display, &a.font, a.display.conn.clipr, .{
        .dir_boot = true,
        .ns = &a.ns,
        .palette = pal,
    });
    a.editor = core.Editor.init(gpa);
    a.tree.bind(&a.editor);
    a.editor.but2col = a.tree.chrome.but2col;
    a.editor.but3col = a.tree.chrome.but3col;

    // ---- input stack ----
    a.devinput = DevInput9.init(gpa, &a.conn);
    a.pipe_input = try ninep.chan.Pipe.init(gpa, 16384);
    a.srv_input = try ninep.server.Server.init(gpa, a.pipe_input.serverEnd(), &DevInput9.ops, &a.devinput, 8192);
    a.cl_input = try ninep.Client.init(gpa, a.pipe_input.clientEnd(), 8192);
    a.cl_input.pump = .{ .ctx = &a.srv_input, .run = pumpServer };
    _ = try a.cl_input.version(8192);
    const iroot = try a.cl_input.attach("larry", "");
    const mw = try a.cl_input.walk(iroot.fid, &.{"mouse"});
    a.mouse_fid = mw.fid;
    _ = try a.cl_input.open(a.mouse_fid, ninep.msg.OREAD);
    const kw = try a.cl_input.walk(iroot.fid, &.{"kbd"});
    a.kbd_fid = kw.fid;
    _ = try a.cl_input.open(a.kbd_fid, ninep.msg.OREAD);
    // NO `profile modifier` write (the browser's boot line): devdraw hands us
    // real three-button records, so the ADR-0004 emulation is not in the stack
    // at all on this host.
    a.ticket_mouse = try a.cl_input.beginRead(a.mouse_fid, 0, &a.mouse_buf);
    a.ticket_kbd = try a.cl_input.beginRead(a.kbd_fid, 0, &a.kbd_buf);

    // ---- boot namespace (S-02 §1.3) ----
    try ns_boot.mountDevices(&a.ns, &a.cl, root.fid, &a.cl_input, iroot.fid);
    try a.self_tree.start(gpa, &a.editor, &a.ns);

    // ---- host file system at `/` and `/mnt/host` (phase 20, R-P20-2) ----
    // Same pipe/server/client pump as the input stack; one attach, mounted
    // twice (the same client + root fid serve both prefixes).
    a.host_fs = try hostfs.HostFs.open(io, "/");
    a.host_tree = hostfs.HostTree.init(gpa, &a.host_fs);
    a.pipe_fs = try ninep.chan.Pipe.init(gpa, 65536);
    a.srv_fs = try ninep.server.Server.init(gpa, a.pipe_fs.serverEnd(), &hostfs.HostTree.ops, &a.host_tree, 8192);
    a.cl_fs = try ninep.Client.init(gpa, a.pipe_fs.clientEnd(), 8192);
    a.cl_fs.pump = .{ .ctx = &a.srv_fs, .run = pumpServer };
    _ = try a.cl_fs.version(8192);
    const froot = try a.cl_fs.attach("larry", "");
    try a.ns.mount("/", &a.cl_fs, froot.fid);
    try a.ns.mount("/mnt/host", &a.cl_fs, froot.fid);

    // ---- the boot directory window (acme.c:258-259, R-EDIT-03) ----
    {
        const cols = a.tree.row.col.items;
        _ = try core.openfile.readFile(&a.editor, cols[cols.len - 1], "/");
    }
    try a.display.flush();
}

/// Move everything the window system said into the input device, and handle a
/// resize. This is the native half of `main_wasm.pushEvent` + `screen.resize`.
fn pumpWindowSystem(a: *App) !void {
    var resized = false;
    while (a.conn.nextMouse()) |ev| {
        if (ev.resized) resized = true;
        try a.devinput.pushMouse(ev);
    }
    while (a.conn.nextRune()) |r| try a.devinput.pushRune(r);
    _ = try a.srv_input.completeReads(DevInput9.mousePath());
    _ = try a.srv_input.completeReads(DevInput9.kbdPath());

    if (resized) {
        // acme.c:548-555 `MResize`. The window system has already resized its
        // own framebuffer (`gfx_replacescreenimage`, devdraw.c:34-60), so
        // unlike the browser there is no backend to resize first: re-reading
        // `ctl` (which the device answers by re-issuing J+I) IS
        // `getwindow(display, Refnone)`, and the tree re-tiles onto whatever
        // rectangle comes back. Same `Display.getWindow`/`Tree.resize` pair
        // phase 12c built — unchanged, on a second host.
        const clipr = try a.display.getWindow(); // acme.c:549
        a.dd.noteResize(.{ .x0 = clipr.min.x, .y0 = clipr.min.y, .x1 = clipr.max.x, .y1 = clipr.max.y });
        try a.tree.resize(clipr); // acme.c:551-555
        a.editor.needs_flush = true;
    }
}

/// One frame: drain the 9P stacks and the input device, then flush once.
/// The body of `main_wasm.tick`, minus the browser-only mounts.
fn tick(a: *App) !void {
    _ = try a.srv.poll(); // draw stack
    try a.self_tree.poll(); // /mnt/snarf-self stack
    _ = try a.srv_fs.poll(); // host file system stack (Load/Put jobs)
    try input_pump.drain(inputDevices(a), &a.editor); // input stack → Editor
    try a.editor.frameEnd(a.display);
}

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
