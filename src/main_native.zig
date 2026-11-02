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
const native_shutdown = @import("native_shutdown.zig");
const native_args = @import("native_args.zig");
const native_options = @import("native_options");

const Conn = host.Conn;
const DevDraw9 = host.dev_draw.DevDraw9;
const DevInput9 = host.dev_input.DevInput9;

/// The teardown half of `boot` (#58) — its own file (S-07 P-2).
pub const Built = native_shutdown.Built;
pub const shutdown = native_shutdown.shutdown;

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
pub const App = struct {
    /// What `boot` has built so far — `shutdown` frees exactly that, so a boot
    /// that fails part-way is torn down as cleanly as a finished session.
    built: Built = .{},
    /// Where `shutdown` reports a discarded Put; null ⇒ stderr (#58 /
    /// PM ruling 2026-10-31). The tests point it at a buffer.
    exit_log: ?*std.Io.Writer = null,
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
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    {
        var it = init.minimal.args.iterate();
        _ = it.skip(); // argv[0]
        while (it.next()) |arg| try argv.append(gpa, arg);
    }
    const cmdline = native_args.split(argv.items);
    // #77: before anything touches devdraw.
    if (native_args.infoFlag(cmdline.flags)) |info| {
        const out = switch (info) {
            .help => native_args.usage,
            .version => "snarf " ++ native_options.version ++ "\n",
        };
        std.Io.File.stdout().writeStreamingAll(init.io, out) catch {};
        return;
    }
    const pal = colorsFromFlags(cmdline.flags) orelse std.process.exit(2);
    // acme.c:261-266: each file argument, rooted at the working directory
    // (acme's `wdir`, acme.c:293-294).
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    if (cmdline.files.len != 0) {
        const cwd = try std.process.currentPathAlloc(init.io, gpa);
        defer gpa.free(cwd);
        for (cmdline.files) |f| try files.append(gpa, try native_args.absolute(gpa, cwd, f));
    }
    const a = try gpa.create(App);
    defer gpa.destroy(a);
    a.built = .{};
    a.exit_log = null;

    // ADR-0006 §4: $DEVDRAW → bundled (beside this executable) → $PLAN9/bin →
    // $PATH. No executable path just skips "bundled"; it is never fatal.
    const exe_path: ?[:0]u8 = std.process.executablePathAlloc(init.io, gpa) catch null;
    defer if (exe_path) |p| gpa.free(p);
    var io = init.io;
    var dd_path = try host.DevdrawPath.resolve(
        gpa,
        init.environ_map,
        if (exe_path) |p| std.fs.path.dirname(p) else null,
        .{ .ctx = &io, .check = checkOnDisk },
    );
    defer dd_path.deinit(gpa);
    // #78: a derived candidate that exists but can't run, and why.
    for (dd_path.skipped) |k| if (k) |x|
        std.debug.print("snarf: devdraw: skipping {s} ({s}): {s}\n", .{ x.path, host.DevdrawPath.sourceName(x.source), x.verdict.reason() });
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

    // #58: every exit from here on — the devdraw hang-up below, an error, and
    // (#13) `Exit` — frees the whole session, before `conn.deinit` reaps
    // devdraw (so a live peer still gets the image frees).
    defer shutdown(a);
    try boot(gpa, init.io, a, pal, "/", files.items);
    // R-P17-5 / PM Q6: the native `$home` is the real `$HOME` (acme.c:136),
    // null when unset. It resolves through the root mount, so `Dump` writes
    // `$HOME/acme.dump` on the real disk.
    a.editor.session.home = init.environ_map.get("HOME");
    // #58 (Owner decision 2026-10-31, Larry): where a Put cut off by exit
    // keeps its bytes when its own directory refuses (`hostfs.Recovery`).
    a.host_tree.recovery.tmp_dir = init.environ_map.get("TMPDIR") orelse "/tmp";

    // The two long polls, armed once and re-armed by `Conn.poll` from here on
    // (drawclient.c keeps exactly one of each outstanding).
    try a.conn.armMouse();
    try a.conn.armKbd();

    while (running(a)) {
        _ = a.conn.poll(frame_timeout_ms) catch |e| switch (e) {
            error.Closed => break,
            else => return e,
        };
        try pumpWindowSystem(a);
        try tick(a);
    }
}

/// The main loop's test: devdraw is still up (closing the window hangs it
/// up), and `Exit` (#13, `cexit`) has not been accepted — or was, but a Put
/// or Dump it followed is still writing (`Editor.exitReady`: acme's are
/// synchronous, so one issued before Exit has always finished). Either way
/// out, `main`'s deferred `shutdown` (#58/#68) frees the session and
/// `conn.deinit` ends devdraw.
pub fn running(a: *App) bool {
    return !a.conn.isClosed() and !a.editor.exitReady();
}

/// `DevdrawPath.Probe` over the real file system: `access(2)` for existence
/// and then execute permission, plus a stat for "regular file" (#78), all
/// through `Io.Dir` (no open, no write). Relative `$PLAN9` values resolve
/// against the working directory, as the spawn itself would.
fn checkOnDisk(ctx: *anyopaque, path: []const u8) host.DevdrawPath.Verdict {
    const io: *const std.Io = @ptrCast(@alignCast(ctx));
    const cwd = std.Io.Dir.cwd();
    cwd.access(io.*, path, .{}) catch return .absent;
    const st = cwd.statFile(io.*, path, .{}) catch return .absent;
    if (st.kind != .file) return .not_a_file;
    cwd.access(io.*, path, .{ .execute = true }) catch return .not_executable;
    return .runnable;
}

/// The scheme `-colors=NAME` selects (last one wins), or `Palette.default`.
/// Null after reporting an unknown name and the valid ones on stderr.
/// Only the flag arguments count (`native_args.split`): after the first file
/// name, `-colors=…` is a file name, as in acme's `ARGBEGIN`.
fn colorsFromFlags(flags: []const []const u8) ?*const core.Palette {
    var pal = core.Palette.default;
    for (flags) |arg| switch (core.Palette.parseFlag(arg)) {
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
/// `host_root` is the host directory served at `/` and `/mnt/host` — the
/// real `/` in `main`, a scratch directory in the tests. `files` are the
/// command line's file arguments as rooted names in the namespace (acme.c:
/// 261-266); none opens the `/` directory window (acme.c:258-259). Each
/// allocating step sets its `a.built` flag, so `shutdown` can undo a partial
/// boot.
pub fn boot(gpa: std.mem.Allocator, io: std.Io, a: *App, pal: *const core.Palette, host_root: []const u8, files: []const []const u8) !void {
    // ---- draw stack ----
    a.dd = DevDraw9.init(&a.conn);
    a.pipe = try ninep.chan.Pipe.init(gpa, 16384);
    a.built.pipe = true;
    a.srv = try ninep.server.Server.init(gpa, a.pipe.serverEnd(), &DevDraw9.ops, &a.dd, 8192);
    a.built.srv = true;
    a.cl = try ninep.Client.init(gpa, a.pipe.clientEnd(), 8192);
    a.built.cl = true;
    a.cl.pump = .{ .ctx = &a.srv, .run = pumpServer };
    _ = try a.cl.version(8192);
    const root = try a.cl.attach("larry", "");
    // `Display.init` walks `new`, opens it, and reads the connection line —
    // which is where the device installs the screen image and learns the
    // window's size. Nothing here decides a display size: the window system
    // does (contrast the browser, where `init(w,h)` carries it in, R-GFX-05).
    a.display = try draw.Display.init(gpa, &a.cl, root.fid);
    a.built.display = true;
    a.font = try draw.Font.init(gpa, a.display, draw.Font.default_subfont);
    a.built.font = true;

    // ---- namespace ----
    a.ns = ninep.mount.Namespace.init(gpa);
    a.built.ns = true;

    // ---- window tree: acme's boot columns (acme.c:241-254) ----
    a.tree = try core.boot.boot(gpa, a.display, &a.font, a.display.conn.clipr, .{
        .dir_boot = true,
        .ncol = if (files.len == 0) 2 else native_args.ncolFor(files.len),
        .ns = &a.ns,
        .palette = pal,
    });
    a.editor = core.Editor.init(gpa);
    a.built.tree = true;
    a.tree.bind(&a.editor);
    a.editor.but2col = a.tree.chrome.but2col;
    a.editor.but3col = a.tree.chrome.but3col;

    // ---- input stack ----
    a.devinput = DevInput9.init(gpa, &a.conn);
    a.pipe_input = try ninep.chan.Pipe.init(gpa, 16384);
    a.built.pipe_input = true;
    a.srv_input = try ninep.server.Server.init(gpa, a.pipe_input.serverEnd(), &DevInput9.ops, &a.devinput, 8192);
    a.built.srv_input = true;
    a.cl_input = try ninep.Client.init(gpa, a.pipe_input.clientEnd(), 8192);
    a.built.cl_input = true;
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
    a.built.self_tree = true;

    // ---- host file system at `/` and `/mnt/host` (phase 20, R-P20-2) ----
    // Same pipe/server/client pump as the input stack; one attach, mounted
    // twice (the same client + root fid serve both prefixes).
    a.host_fs = try hostfs.HostFs.open(io, host_root);
    a.built.host_fs = true;
    a.host_tree = hostfs.HostTree.init(gpa, &a.host_fs);
    a.pipe_fs = try ninep.chan.Pipe.init(gpa, 65536);
    a.built.pipe_fs = true;
    a.srv_fs = try ninep.server.Server.init(gpa, a.pipe_fs.serverEnd(), &hostfs.HostTree.ops, &a.host_tree, 8192);
    a.built.srv_fs = true;
    a.cl_fs = try ninep.Client.init(gpa, a.pipe_fs.clientEnd(), 8192);
    a.built.cl_fs = true;
    a.cl_fs.pump = .{ .ctx = &a.srv_fs, .run = pumpServer };
    _ = try a.cl_fs.version(8192);
    const froot = try a.cl_fs.attach("larry", "");
    try a.ns.mount("/", &a.cl_fs, froot.fid);
    try a.ns.mount("/mnt/host", &a.cl_fs, froot.fid);

    // ---- the boot windows (acme.c:258-266, R-EDIT-03) ----
    {
        const cols = a.tree.row.col.items;
        if (files.len == 0) {
            _ = try core.openfile.readFile(&a.editor, cols[cols.len - 1], "/");
        } else for (files, 0..) |f, i| {
            // A missing file is acme's too: an empty window under that name,
            // and `can't open` in +Errors (text.c:214-217).
            _ = try core.openfile.readFile(&a.editor, cols[native_args.columnFor(i, f, cols.len)], f);
            // acme's readfile runs textload to the end before the next
            // coladd (acme.c:261-266, :292-304), and that coladd shrinks the
            // window it lands on to its loaded lines (cols.c:117). Snarf's
            // load is asynchronous, so wait for it here (#82).
            try loadNow(a);
        }
    }
    try a.display.flush();
}

/// Run the boot window's load to the end, as acme's synchronous `textload`
/// does: step the load and answer its 9P requests until it has finished. No
/// input is read and nothing is drawn meanwhile.
fn loadNow(a: *App) !void {
    while (a.editor.loads.items.len != 0) {
        try core.Load.stepAll(&a.editor);
        _ = try a.srv.poll(); // draw stack
        try a.self_tree.poll(); // /mnt/snarf-self stack
        _ = try a.srv_fs.poll(); // host file system stack
    }
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
        try a.tree.resize(&a.editor, clipr); // acme.c:551-555
        a.editor.needs_flush = true;
    }
}

/// One frame: drain the 9P stacks and the input device, then flush once.
/// The body of `main_wasm.tick`, minus the browser-only mounts.
pub fn tick(a: *App) !void {
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

test {
    _ = @import("main_native_test.zig"); // #58: boot → session → shutdown, leak-checked
    _ = @import("main_native_clipboard_test.zig"); // #12/#31: Snarf/Paste ↔ the pasteboard
    _ = @import("native_args.zig"); // the command line (acme.c:71-124, :241-266)
    _ = @import("main_native_args_test.zig"); // file arguments open windows
    _ = @import("main_native_exit_test.zig"); // #13: Exit ends the loop through the #58/#68 shutdown
}
