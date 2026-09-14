//! `openfile` (look.c:810-905) and `readfile` (acme.c:285-300) — the two doors
//! a NAME walks through to become a window. Namespace module (S-07 P-1,
//! lowercase). Ported from larryr/plan9port@337c6ac; cite as `look.c:NN` /
//! `acme.c:NN`.
//!
//! R-EDIT-03 (directory windows), R-EDIT-13 (`path`, `path:line`, `path:/re/`),
//! R-EDIT-23 (auto-placement through `makenewwindow`), R-EDIT-25 (the warp is
//! REQUESTED — as a `/dev/mouse` write — and honoured or ignored per host).
//!
//! THE ONE STRUCTURAL DIFFERENCE from the C: `textload` blocks there and is a
//! job here (`Load.zig`), so `openFile` returns as soon as the window EXISTS,
//! with its body still empty. Everything the C does after `textload` —
//! mod/dirty, the tag, the `:addr` evaluation, `textshow`, `seltext` — happens
//! on the frame the load completes (`Load.finishTail`). The one path that does
//! NOT load, reusing an already-open window, runs that tail immediately.
//!
//! `wdir` is `/` (R-P13b-3): Snarf has no process working directory, and the
//! namespace root is the only thing an unrooted name can sensibly mean.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Column = @import("Column.zig");
const Editor = @import("Editor.zig");
const File = @import("File.zig");
const Load = @import("Load.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const errors = @import("errors.zig");
const place = @import("place.zig");

/// acme's `wdir` (acme.c:36) for a port with no process working directory
/// (R-P13b-3). Every unrooted name openfile sees is resolved against it.
pub const wdir = "/";

/// Where the editor serves ITSELF (S-02 §1.3, `ns_boot.mount_point`). `core`
/// cannot import the boot glue that mounts it, so the constant is repeated here
/// — `isMtpt` below is the only reader.
pub const self_mtpt = "/mnt/snarf-self";

/// The subset of the C's `Expand` (dat.h:294-306) that `openFile` consumes.
/// `name` is ABSOLUTE and already cleaned when it comes from `expand.zig`; an
/// EMPTY name is the C's `e->nname == 0` — "the window the click happened in"
/// (look.c:822-826). `addr` is the address text after the `:`
/// (`e->a0..e->a1`), captured as runes because by the time an asynchronous load
/// completes the source selection may be gone.
pub const Expand = struct {
    name: []const u8,
    addr: ?[]const u21 = null,
    /// `e->jump` (look.c:897): whether the pointer should be warped into the
    /// window once it is loaded (R-P15-3, `warp.zig`).
    jump: bool = true,
    /// `e->q0`/`e->q1`, the expansion's range in the SOURCE text. Carried for
    /// the caller's literal-search fallback; `openFile` does not read them.
    q0: usize = 0,
    q1: usize = 0,
};

/// `openfile` (look.c:810-905). Returns the window the name now lives in.
///
/// * `e.name == ""` ⇒ `t`'s own window (look.c:822-826).
/// * an already-open name ⇒ that window, no reload (look.c:844-849). The C
///   follows with `colgrow` when the window is obscured by a full-column
///   neighbour (look.c:847-848) — DEFERRED with `place.makeNewWindow`'s own
///   colgrow arm (R-P12b-3).
/// * otherwise `makenewwindow(t)` + `winsetname` + `textload` (look.c:850-870),
///   the last of which is asynchronous here.
///
/// `xfidlog(w, "new")` (look.c:869) has no port — the log file is not served.
pub fn openFile(ed: *Editor, t: ?*Text, e: Expand) Text.Error!*Window {
    const a = ed.allocator;
    const row = ed.row orelse return error.IoError;

    if (e.name.len == 0) { // look.c:822-826
        const tt = t orelse return error.IoError;
        const w = tt.w orelse return error.IoError;
        try Load.addressAndShow(ed, w, e.addr, e.jump);
        return w;
    }

    // look.c:828-843: an unrooted name becomes `wdir/name`, cleaned.
    const abs = try absName(a, e.name);
    defer a.free(abs);

    if (errors.lookFile(row, abs)) |w| { // look.c:844-845 lookfile
        try Load.addressAndShow(ed, w, e.addr, e.jump);
        return w;
    }

    if (isMtpt(abs)) { // text.c:210-213 / look.c:708
        ed.warning("will not open self mount point {s}\n", .{abs});
        return error.IoError;
    }

    const w = try place.makeNewWindow(ed, t); // look.c:854
    try w.body.file.setName(abs); // look.c:856 winsetname
    try w.setTag1();
    const tnc = w.tag.file.buffer.len();
    try w.tag.setSelect(tnc, tnc);
    ed.seltext = &w.body; // look.c:896, brought forward: the window IS the target
    try Load.start(ed, w, abs, e.addr, e.jump); // look.c:857 textload(t, 0, bname, 1)
    ed.needs_flush = true;
    return w;
}

/// `readfile` (acme.c:285-300): the boot path — a window straight into column
/// `c` (the C's `coladd(c, nil, nil, -1)`), named absolutely, then loaded.
/// `winresize`/`textscrdraw` (acme.c:299-300) are `place.mintWindow`'s job here.
pub fn readFile(ed: *Editor, c: *Column, name: []const u8) Text.Error!*Window {
    const a = ed.allocator;
    const abs = try absName(a, name); // acme.c:291-294 + cleanrname
    defer a.free(abs);
    const w = try place.mintWindow(c, -1, abs); // acme.c:290 + :295 winsetname
    try Load.start(ed, w, abs, null, false); // acme.c:296 textload
    ed.needs_flush = true;
    return w;
}

// ==========================================================================
// Names
// ==========================================================================

/// `name` made absolute against `wdir` and run through `cleanName`
/// (look.c:834-840 `runesnprint("%s/%.*S", wdir, …)` + `cleanrname`,
/// acme.c:291-294). Caller frees.
pub fn absName(a: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    if (name.len != 0 and name[0] == '/') return cleanName(a, name);
    const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ wdir, name });
    defer a.free(joined);
    return cleanName(a, joined);
}

/// `cleanname` (lib9/cleanname.c) via `cleanrname` (look.c:453-465), ROOTED
/// case only — every name that reaches here has been rooted by `absName`, so
/// the C's "leading `..` survives in a relative path" arm is unreachable and a
/// `..` at the root is simply dropped, exactly as `cleanname` drops it.
/// Empty and `.` components go; a trailing `/` goes (so a directory window is
/// named `/mnt` until `applyListing` gives it back its acme slash).
/// `errors.dirName`'s FLAG ("cleanname is NOT ported") is retired by this.
pub fn cleanName(a: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    var comps: std.ArrayList([]const u8) = .empty;
    defer comps.deinit(a);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (comps.items.len != 0) _ = comps.pop();
            continue;
        }
        try comps.append(a, c);
    }
    if (comps.items.len == 0) return a.dupe(u8, "/");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (comps.items) |c| {
        try out.append(a, '/');
        try out.appendSlice(a, c);
    }
    return out.toOwnedSlice(a);
}

/// `ismtpt` (acme.c:1141-1151), NARROWED. In the C `mtpt` is nil unless the
/// user passed `-m`, so by default acme happily opens its own `/mnt/acme`; the
/// guard exists for the explicitly-mounted case, and it covers the whole
/// SUBTREE (`file[n]=='/' || file[n]==0`).
///
/// Snarf always serves itself at `self_mtpt`, so the guard is always armed —
/// but only for the directory ITSELF (contract §3c, "refuse to open
/// `/mnt/snarf-self` itself"). Reading files UNDER it is safe and required:
/// acme's prefix rule guards against the editor BLOCKING on its own server
/// inside `textload`, and Snarf's loads never block (they are `ninep.nsjob`
/// jobs polled a state per frame, `Load.zig`). What stays refused is the
/// genuinely self-referential case — a window whose body is the listing of the
/// tree that window is itself an entry in.
pub fn isMtpt(name: []const u8) bool {
    const n = if (name.len > 1 and name[name.len - 1] == '/') name[0 .. name.len - 1] else name;
    return std.mem.eql(u8, n, self_mtpt);
}

// ==========================================================================
// Smoke tests. The named battery (T5/T6/T9/T10) is the test writer's; these
// pin the pure name helpers and keep the module's decls reachable.
// ==========================================================================
const testing = std.testing;
const ninep = @import("ninep");
const draw = @import("draw");
const boot = @import("boot.zig");
const served_fsys = @import("served/fsys.zig");
const Frame = draw.Frame;
const proto = draw.proto;

fn pumpTestServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// A booted tree over the phase-13a boot namespace shape: a fake `/dev` and the
/// real served `/mnt/snarf-self`, with `/` and `/mnt` synthesized (R-9P-16).
/// The same fixture `boot.zig`'s T10 builds, plus the frame loop a headless
/// caller must run for a `Load` to complete: poll EVERY server backing a mount,
/// then `Load.stepAll` — once per simulated frame.
const NsHarness = struct {
    fx: Frame.TestFixture,
    ns: ninep.mount.Namespace,
    tree: boot.Tree,
    ed: Editor,
    dev_tree: ninep.nsdir.FakeTree,
    dev: ninep.nsdir.FakeServer,
    fsys: served_fsys.Fsys,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,

    fn init(h: *NsHarness, opts: boot.Options) !void {
        const a = testing.allocator;
        h.fx = try Frame.TestFixture.init();
        h.ns = ninep.mount.Namespace.init(a);
        var o = opts;
        o.ns = &h.ns;
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 640, 480), o);
        h.ed = Editor.init(a);
        h.tree.bind(&h.ed);

        h.dev_tree = .{ .names = &.{"mouse"}, .tag = "m\n" };
        h.dev = try ninep.nsdir.FakeServer.init(a, &h.dev_tree);
        try h.ns.mount("/dev", h.dev.client, h.dev.root_fid);

        h.fsys = served_fsys.Fsys.init(&h.ed);
        h.pipe = try ninep.chan.Pipe.init(a, 16384);
        h.srv = try ninep.server.Server.init(a, h.pipe.serverEnd(), &served_fsys.Fsys.ops, &h.fsys, 8192);
        h.cl = try ninep.Client.init(a, h.pipe.clientEnd(), 8192);
        h.cl.pump = .{ .ctx = &h.srv, .run = pumpTestServer };
        _ = try h.cl.version(8192);
        const root = try h.cl.attach("larry", "");
        try h.ns.mount("/mnt/snarf-self", &h.cl, root.fid);
    }

    fn deinit(h: *NsHarness) void {
        h.ed.deinit();
        h.cl.deinit();
        h.srv.deinit();
        h.pipe.deinit();
        h.dev.deinit();
        h.tree.deinit();
        h.ns.deinit();
        h.fx.deinit();
    }

    /// `n` simulated frames: step the loads, then let every server answer.
    fn frames(h: *NsHarness, n: usize) !void {
        for (0..n) |_| {
            try Load.stepAll(&h.ed);
            _ = try h.srv.poll();
            _ = try h.dev.srv.poll();
        }
    }
};

fn bodyText(w: *Window) ![]u8 {
    const a = testing.allocator;
    const n = w.body.file.buffer.len();
    if (n == 0) return a.alloc(u8, 0);
    const dest = try a.alloc(u8, n * 4);
    defer a.free(dest);
    return a.dupe(u8, w.body.file.buffer.read(0, n, dest));
}

test "openfile: readFile('/') columnates the synthesized root (smoke)" {
    const a = testing.allocator;
    var h: NsHarness = undefined;
    try h.init(.{ .win_name = "scratch", .body = "" });
    defer h.deinit();

    const c = h.tree.row.col.items[0];
    const w = try readFile(&h.ed, c, "/");
    try h.frames(24);

    try testing.expect(w.isdir);
    try testing.expect(!w.filemenu);
    try testing.expectEqualStrings("/", w.body.file.name.items);
    const body = try bodyText(w);
    defer a.free(body);
    try testing.expectEqualStrings("dev/\tmnt/\n", body);
    // Two entries, sorted, each with the QTDIR slash (text.c:255-256).
    try testing.expectEqual(@as(usize, 2), w.dirnames.items.len);
    // The directory tab width (text.c:148): 3 zeroes, not libframe's 8.
    try testing.expectEqual(@as(i32, 27), w.body.fr.maxtab);
}

test "openfile: a parked B3 look opens the entry it names (smoke)" {
    const a = testing.allocator;
    const look = @import("look.zig");
    var h: NsHarness = undefined;
    try h.init(.{ .win_name = "scratch", .body = "" });
    defer h.deinit();

    const c = h.tree.row.col.items[0];
    const root = try readFile(&h.ed, c, "/");
    try h.frames(24);
    try testing.expect(root.isdir);

    // B3 inside `mnt/` of "dev/\tmnt/\n": textually a file name, so the look
    // PARKS on a StatJob (R-P13b-2) instead of searching.
    try look.look(&h.ed, &root.body, 6, 6, false);
    try testing.expect(h.ed.pending_look != null);
    try h.frames(24);
    try testing.expect(h.ed.pending_look == null);

    const opened = errors.lookFile(h.tree.row, "/mnt").?;
    try testing.expect(opened != root);
    try testing.expect(opened.isdir);
    try testing.expectEqualStrings("/mnt/", opened.body.file.name.items);
    const body = try bodyText(opened);
    defer a.free(body);
    try testing.expectEqualStrings("snarf-self/\n", body);
}

test "openfile: a look that names no file falls back to the literal search (smoke)" {
    const look = @import("look.zig");
    var h: NsHarness = undefined;
    try h.init(.{ .win_name = "hay", .body = "zzz one zzz\n" });
    defer h.deinit();

    const w = h.tree.row.col.items[0].w.items[0];
    const t = &w.body;
    try t.setSelect(0, 0);
    try look.look(&h.ed, t, 1, 1, false); // inside the first "zzz"
    try testing.expect(h.ed.pending_look != null); // "/zzz" might exist: parked
    try h.frames(24);
    try testing.expect(h.ed.pending_look == null);

    // It does not, so the literal arm ran: the SECOND "zzz" is selected and no
    // window was opened.
    try testing.expectEqual(@as(usize, 8), t.q0);
    try testing.expectEqual(@as(usize, 11), t.q1);
    try testing.expectEqual(@as(usize, 1), h.tree.row.col.items[0].w.items.len);
}

test "openfile: cleanName collapses . and .. against the root" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "/a/b", "/a/b" },
        .{ "/a/b/", "/a/b" },
        .{ "/a/./b", "/a/b" },
        .{ "/a/b/../c", "/a/c" },
        .{ "/..", "/" },
        .{ "//", "/" },
        .{ "/", "/" },
    };
    for (cases) |c| {
        const got = try cleanName(a, c[0]);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "openfile: absName roots an unrooted name at wdir (R-P13b-3)" {
    const a = testing.allocator;
    const rel = try absName(a, "dev/mouse");
    defer a.free(rel);
    try testing.expectEqualStrings("/dev/mouse", rel);
    const abs = try absName(a, "/mnt/x/");
    defer a.free(abs);
    try testing.expectEqualStrings("/mnt/x", abs);
}

test "openfile: isMtpt refuses the self mount point itself, not its files" {
    try testing.expect(isMtpt("/mnt/snarf-self"));
    try testing.expect(isMtpt("/mnt/snarf-self/"));
    try testing.expect(!isMtpt("/mnt/snarf-self/index"));
    try testing.expect(!isMtpt("/mnt"));
}

// ===========================================================================
// Named battery (phase-13b contract §4, T5/T6/T8/T9/T10). T8 lives here
// (rather than look.zig/expand.zig, where the contract table lists it)
// because `NsHarness`, above, is what it needs and the fixture is private to
// this file's test section.
// ===========================================================================

test "openfile: openFile(\"/\") mints a window via makeNewWindow and columnates dev/ mnt/ (T5)" {
    const a = testing.allocator;
    var h: NsHarness = undefined;
    try h.init(.{ .win_name = "scratch", .body = "" });
    defer h.deinit();

    const c = h.tree.row.col.items[0];
    const src = c.w.items[0]; // the reference window makeNewWindow places beside
    const w = try openFile(&h.ed, &src.body, .{ .name = "/" });
    try h.frames(24);

    // makeNewWindow(ed, t) picked `src`'s own column (place.colOf(t)).
    try testing.expectEqual(c, w.col.?);
    try testing.expect(w.isdir);
    try testing.expect(!w.filemenu);
    try testing.expectEqualStrings("/", w.body.file.name.items);
    const body = try bodyText(w);
    defer a.free(body);
    try testing.expectEqualStrings("dev/\tmnt/\n", body);
    try testing.expectEqual(@as(i32, 27), w.body.fr.maxtab);
}

test "openfile: openFile reuses an already-open window; trailing-slash names match (T6)" {
    const look = @import("look.zig");
    var h: NsHarness = undefined;
    try h.init(.{ .win_name = "scratch", .body = "" });
    defer h.deinit();

    const c = h.tree.row.col.items[0];
    const root = try readFile(&h.ed, c, "/");
    try h.frames(24);
    try testing.expect(root.isdir);

    // Open "/mnt/" via B3 on the "mnt/" entry of "dev/\tmnt/\n" (col 6).
    try look.look(&h.ed, &root.body, 6, 6, false);
    try h.frames(24);
    const mnt = errors.lookFile(h.tree.row, "/mnt").?;
    try testing.expect(mnt.isdir);
    const n_windows = c.w.items.len;

    // Re-open by the exact same absolute name: reused, no new window, no load.
    const again = try openFile(&h.ed, null, .{ .name = "/mnt/" });
    try testing.expectEqual(mnt, again);
    try testing.expectEqual(n_windows, c.w.items.len);
    try testing.expectEqual(@as(usize, 0), h.ed.loads.items.len);

    // Re-open by the BARE name (no trailing slash): `errors.lookFile`'s
    // trimSlash rule (look.c:768/776) matches the same window too.
    const again2 = try openFile(&h.ed, null, .{ .name = "/mnt" });
    try testing.expectEqual(mnt, again2);
    try testing.expectEqual(n_windows, c.w.items.len);
    try testing.expectEqual(@as(usize, 0), h.ed.loads.items.len);
}

test "openfile: B3 on a directory-window entry opens it; B3 on a nonfile falls back to search (T8)" {
    const a = testing.allocator;
    const look = @import("look.zig");
    var h: NsHarness = undefined;
    try h.init(.{ .win_name = "scratch", .body = "" });
    defer h.deinit();

    const c = h.tree.row.col.items[0];
    const root = try readFile(&h.ed, c, "/");
    try h.frames(24);
    const body0 = try bodyText(root);
    defer a.free(body0);
    try testing.expectEqualStrings("dev/\tmnt/\n", body0);

    // B3 on "dev/" (the FIRST entry): the fake /dev mount exists, so the
    // StatJob resolves and a "/dev/" directory window opens listing it.
    try look.look(&h.ed, &root.body, 1, 1, false);
    try testing.expect(h.ed.pending_look != null);
    try h.frames(24);
    try testing.expect(h.ed.pending_look == null);
    const devw = errors.lookFile(h.tree.row, "/dev").?;
    try testing.expect(devw.isdir);
    const devbody = try bodyText(devw);
    defer a.free(devbody);
    try testing.expectEqualStrings("mouse/\n", devbody);

    // B3 on "zzz", which names no file anywhere in this namespace: the parked
    // StatJob errors and falls through to the literal (alnum) search — the
    // SECOND "zzz" is found and selected, and no new window opens.
    const hay = try h.tree.addWindow("hay", "zzz one zzz\n");
    try hay.body.setSelect(0, 0);
    const n_before = c.w.items.len;
    try look.look(&h.ed, &hay.body, 1, 1, false);
    try testing.expect(h.ed.pending_look != null);
    try h.frames(24);
    try testing.expect(h.ed.pending_look == null);
    try testing.expectEqual(@as(usize, 8), hay.body.q0);
    try testing.expectEqual(@as(usize, 11), hay.body.q1);
    try testing.expectEqual(n_before, c.w.items.len); // no window opened
}

test "openfile: a bare :addr selects the line, a regexp addr selects the match, an out-of-order addr warns (T9)" {
    const a = testing.allocator;
    var h: NsHarness = undefined;
    try h.init(.{ .win_name = "one", .body = "l1\nl2\nl3\nl4\nl5\n" });
    defer h.deinit();

    const w = h.tree.row.col.items[0].w.items[0];
    const path = try std.fmt.allocPrint(a, "/mnt/snarf-self/{d}/body", .{w.id});
    defer a.free(path);

    // A bare line number selects the WHOLE line, including its newline
    // (edit/addr.zig "addr: absolute line"; addr.c line addressing).
    const addr3 = [_]u21{'3'};
    const opened = try openFile(&h.ed, null, .{ .name = path, .addr = &addr3 });
    try h.frames(24);
    try testing.expectEqual(@as(usize, 6), opened.body.q0);
    try testing.expectEqual(@as(usize, 9), opened.body.q1);

    // A regexp address selects the MATCH, not the whole line (the window is
    // already open, so this evaluates synchronously — no more frames needed).
    const addr_re = [_]u21{ '/', 'l', '4', '/' };
    _ = try openFile(&h.ed, null, .{ .name = path, .addr = &addr_re });
    try testing.expectEqual(@as(usize, 9), opened.body.q0);
    try testing.expectEqual(@as(usize, 11), opened.body.q1);

    // An out-of-order compound address ("5,1": line 5's start, line 1's end,
    // q0 > q1) warns and leaves the selection exactly where it was
    // (Load.addressAndShow's default `r`, look.c:882-884) — pinned by
    // resetting the selection first so "unchanged" is unambiguous.
    try opened.body.setSelect(0, 0);
    const addr_oo = [_]u21{ '5', ',', '1' };
    _ = try openFile(&h.ed, null, .{ .name = path, .addr = &addr_oo });
    try testing.expect(std.mem.indexOf(u8, h.ed.warningText(), "addresses out of order") != null);
    try testing.expectEqual(@as(usize, 0), opened.body.q0);
    try testing.expectEqual(@as(usize, 0), opened.body.q1);
}

test "openfile: a relative name resolves against the clicked window's directory; with no window, against wdir (T10)" {
    const look = @import("look.zig");
    var h: NsHarness = undefined;
    try h.init(.{ .win_name = "scratch", .body = "" });
    defer h.deinit();

    // A window whose OWN name is a directory: a relative click inside it
    // resolves against THAT directory (R-EDIT-20, `errors.dirName`), not wdir.
    const selfdir = try h.tree.addWindow("/mnt/snarf-self/", "index\n");
    try look.look(&h.ed, &selfdir.body, 2, 2, false); // inside "index"
    try testing.expect(h.ed.pending_look != null);
    try h.frames(24);
    try testing.expect(h.ed.pending_look == null);
    try testing.expect(errors.lookFile(h.tree.row, "/mnt/snarf-self/index") != null);

    // A click with NO window behind it (the row tag): falls back to wdir="/".
    // "dev" names the /dev mount itself, which exists, so it resolves and
    // opens — landing on "/dev", not "/mnt/snarf-self/dev".
    const nc = h.tree.row.tag.file.buffer.len();
    try h.tree.row.tag.insertAt(nc, "dev", true);
    try testing.expect(h.tree.row.tag.w == null); // the no-window case (T10)
    try look.look(&h.ed, &h.tree.row.tag, nc + 1, nc + 1, false);
    try testing.expect(h.ed.pending_look != null);
    try h.frames(24);
    try testing.expect(h.ed.pending_look == null);
    try testing.expect(errors.lookFile(h.tree.row, "/dev") != null);
    try testing.expect(errors.lookFile(h.tree.row, "/mnt/snarf-self/dev") == null);
}
