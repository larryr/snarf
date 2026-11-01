//! The native host's teardown (#58): `shutdown` frees everything
//! `main_native.boot` built, as recorded in `App.built`. Split out of
//! `main_native.zig` along the boot/shutdown seam (S-07 P-2). `main` defers
//! it right after the devdraw spawn; #13's `Exit` will call it too.
const std = @import("std");
const core = @import("core");
const App = @import("main_native.zig").App;

/// One flag per `boot` step that allocates (or opens) something.
pub const Built = struct {
    pipe: bool = false,
    srv: bool = false,
    cl: bool = false,
    display: bool = false,
    font: bool = false,
    ns: bool = false,
    /// `tree` + `editor` (the latter cannot fail, so they come as a pair).
    tree: bool = false,
    pipe_input: bool = false,
    srv_input: bool = false,
    cl_input: bool = false,
    self_tree: bool = false,
    host_fs: bool = false,
    pipe_fs: bool = false,
    srv_fs: bool = false,
    cl_fs: bool = false,
};

/// Free everything `boot` built (#58) — whatever `a.built` says, so it is
/// equally right after a full session, a failed boot, or (#13) `Exit`. The
/// `Conn` is NOT freed here: it predates `boot` and `main` reaps it after.
///
/// ORDER: the host-fs session is hung up BEFORE anything is torn down. A Put's
/// Tclunk may already be queued, and teardown queues more (`discardClunk`);
/// `srv_fs.poll()` first lets Tclunks of Puts that really finished commit, then
/// `hangUp` makes every later Tclunk a discard even if a blocked write pumps it
/// (#68 review finding 1). Then the editor and window tree (`core.shutdown.teardown`):
/// their in-flight jobs hold host-fs/self-tree client handles, and the
/// `Chrome` solids are freed through the display. Then each 9P stack is
/// unwound server-side first (`releaseFids`: lib9p's `freefidpool`, so the
/// file servers free their per-fid state; `HostTree.endSession` also discards
/// a Put that never finished), then client → server → pipe. The draw stack is
/// last because `Font`/`Display` free themselves through it. After a devdraw
/// hang-up the image frees just fail (each `deinit` there is best-effort and
/// ignores them); the memory is freed either way.
pub fn shutdown(a: *App) void {
    const b = &a.built;
    var lines: std.Io.Writer.Allocating = undefined;
    const have_lines = b.srv_fs and a.exit_log == null;
    if (b.srv_fs) {
        _ = a.srv_fs.poll() catch {};
        if (have_lines) lines = .init(a.host_tree.gpa);
        a.host_tree.hangUp(a.exit_log orelse &lines.writer);
    }
    defer if (have_lines) lines.deinit();
    if (b.tree) core.shutdown.teardown(&a.editor, &a.tree);
    // ---- host file system stack ----
    if (b.srv_fs) endHostSession(a, if (have_lines) &lines else null);
    if (b.cl_fs) a.cl_fs.deinit();
    if (b.srv_fs) a.srv_fs.deinit();
    if (b.pipe_fs) a.pipe_fs.deinit();
    if (b.host_fs) a.host_fs.close();
    // ---- /mnt/snarf-self ----
    if (b.self_tree) a.self_tree.stop();
    // ---- input stack ----
    if (b.srv_input) a.srv_input.releaseFids();
    if (b.cl_input) a.cl_input.deinit();
    if (b.srv_input) a.srv_input.deinit();
    if (b.pipe_input) a.pipe_input.deinit();
    if (b.pipe_input) a.devinput.deinit(); // initialised just before its pipe
    // ---- namespace (borrowed pointers only; the stacks above owned the fids) ----
    if (b.ns) a.ns.deinit();
    // ---- draw stack ----
    if (b.font) a.font.deinit();
    if (b.display) a.display.deinit();
    if (b.srv) a.srv.releaseFids();
    if (b.cl) a.cl.deinit();
    if (b.srv) a.srv.deinit();
    if (b.pipe) a.pipe.deinit();
    a.built = .{};
}

/// `HostTree.endSession`, with each discarded Put reported (PM ruling
/// 2026-10-31, SnarfProdd): to `a.exit_log` when set (the tests), else to
/// stderr. The stderr case collects the lines first and prints after the
/// release, so no stderr lock is held while the fids are torn down.
fn endHostSession(a: *App, lines: ?*std.Io.Writer.Allocating) void {
    if (a.exit_log) |w| return a.host_tree.endSession(&a.srv_fs, w);
    const l = lines.?; // `shutdown` made it whenever there is no `exit_log`
    a.host_tree.endSession(&a.srv_fs, &l.writer);
    if (l.written().len != 0) std.debug.print("{s}", .{l.written()});
}
