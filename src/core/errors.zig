//! The `+Errors` window (R-EDIT-21) — `errorwin1`/`errorwin` (util.c:79-135),
//! `flushwarnings` (util.c:211-258) and the two lookups they lean on, `lookfile`
//! (look.c:760-786) and the query arm of `dirname` (look.c:542-578). Namespace
//! module (S-07 P-1, lowercase); kept out of `Editor.zig` so that file stays
//! under the ~400-line-per-concern budget. Ported from larryr/plan9port@337c6ac;
//! cite as `util.c:NN` / `look.c:NN`.
//!
//! Acme never prints a diagnostic to a console: every `warning()` is buffered per
//! DIRECTORY CONTEXT and, from the main loop's `cwarn` arm, flushed into a window
//! named `dir/+Errors` (or plain `+Errors` with no directory), created in the
//! RIGHTMOST column — the paper's "output windows towards the right"
//! (acme paper §User interface; R-P12b-5). `Editor.frameEnd` is this port's main
//! loop, so `flushWarnings` runs there, before the live-tag sweep, and the new
//! window's tag is composed in the same frame.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const Column = @import("Column.zig");
const Row = @import("Row.zig");
const place = @import("place.zig");

/// One buffered warning bucket — the C's `struct Warning` (util.c:188-193), whose
/// key is the `Mntdir*` the message arrived through. The port has no Mntdir yet
/// (one namespace, no external command mounts), so the key is the directory
/// STRING the C would have read out of it (`md->dir`), `""` for `warning(nil,…)`.
/// `dir` is owned by `Editor.allocator`.
pub const Warning = struct {
    dir: []u8,
    text: std.ArrayList(u8),

    pub fn deinit(self: *Warning, a: std.mem.Allocator) void {
        a.free(self.dir);
        self.text.deinit(a);
    }
};

/// The file name of the error window for directory `dir` (util.c:85-92): `""` ⇒
/// `"+Errors"`, otherwise `dir ++ "/+Errors"`. Caller frees.
fn errorName(a: std.mem.Allocator, dir: []const u8) error{OutOfMemory}![]u8 {
    if (dir.len == 0) return a.dupe(u8, "+Errors"); // util.c:86-90 (ndir == 0)
    return std.fmt.allocPrint(a, "{s}/+Errors", .{dir});
}

/// `lookfile` (look.c:760-786): the window whose BODY file is named `name`,
/// scanning every column left-to-right and every window top-to-bottom. ONE
/// trailing `/` is ignored on either side so a directory window matches with or
/// without it (look.c:767-769, :776-777).
///
/// The C's `w = w->body.file->curtext->w` hop (look.c:779) collapses to `w`
/// itself — one Text per File in v1 — and with it the `w->col != nil` race guard
/// (single-threaded).
pub fn lookFile(row: *Row, name: []const u8) ?*Window {
    const want = trimSlash(name);
    for (row.col.items) |c| {
        for (c.w.items) |w| {
            if (std.mem.eql(u8, trimSlash(w.body.file.name.items), want)) return w;
        }
    }
    return null;
}

/// Drop ONE trailing `/` from a name longer than one rune (look.c:768/776 — the
/// `n>1` guard keeps bare `"/"` intact).
fn trimSlash(s: []const u8) []const u8 {
    if (s.len > 1 and s[s.len - 1] == '/') return s[0 .. s.len - 1];
    return s;
}

/// The QUERY arm of `dirname` (look.c:542-578 with `r == nil, n == 0`): the
/// directory part of window `w`'s name, `""` when the name holds no `/`
/// (look.c:554-559 `slash < 0` ⇒ Rescue ⇒ the empty Runestr). `errorwinforwin`
/// (util.c:145-150) additionally treats `"."` as no directory; that collapse is
/// the caller's job, as in the C.
///
/// Returns a SUBSLICE of `w.body.file.name` — no allocation, nothing to free.
///
/// TWO documented divergences:
///   1. The C reads the TAG through `parsetag` (look.c:552); the port reads
///      `body.file.name`. `winsettag1` (wind.c:487-495) keeps the tag's name half
///      equal to that field, so the two agree except in the window between a user
///      hand-editing the tag name and the next `winsettag` — v1 has no rename
///      path at all, so the difference is unobservable.
///   2. `cleanrname`/`cleanname` (look.c:454-465) is NOT ported: only its one
///      effect on this input is reproduced — the trailing `/` of `b[0..slash+1]`
///      is dropped unless the result is the root `"/"`. `.`/`..` collapsing is
///      DEFERRED (no host paths reach here yet); FLAG for the namespace phase.
pub fn dirName(w: *Window) []const u8 {
    const name = w.body.file.name.items;
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return ""; // look.c:554-559
    var end = slash + 1; // look.c:562 `b[0 .. slash+1]`
    if (end > 1) end -= 1; // cleanname: strip the trailing '/', keep root "/"
    return name[0..end];
}

/// `errorwin1` (util.c:79-114) + `errorwin` (util.c:116-135). Find the window
/// named `dir/+Errors` (or `+Errors`), creating it in the RIGHTMOST column when
/// it does not exist (util.c:98 `row.col[row.ncol-1]`, R-P12b-5 — deliberately
/// NOT `makenewwindow`: an error window always goes right). An empty row grows a
/// column first (util.c:95-97; the C `error()`s when it cannot, the port raises
/// IoError).
///
/// DROPPED: `winlock`/retry (util.c:121-133, single-threaded), the `incl` list
/// (no `Include` in v1) and `w->autoindent` (no autoindent in v1), and
/// `xfidlog(w, "new")` (the log file is not served yet).
pub fn errorWin(ed: *Editor, dir: []const u8) Text.Error!*Window {
    const a = ed.allocator;
    const name = try errorName(a, dir);
    defer a.free(name);

    const row = ed.row orelse return error.IoError;
    if (lookFile(row, name)) |w| return w; // util.c:93-94

    if (row.col.items.len == 0) {
        // util.c:95-97 rowadd(&row, nil, -1) or error("can't create column…")
        _ = (try row.add(-1)) orelse return error.IoError;
    }
    const c: *Column = row.col.items[row.col.items.len - 1]; // util.c:98 rightmost
    const w = try place.mintWindow(c, -1, name); // util.c:98 coladd + :100 winsetname
    w.filemenu = false; // util.c:99
    try w.setTag1(); // recompose without the Undo/Redo/Put menu (wind.c:505)
    return w;
}

/// `flushwarnings` (util.c:211-258), called from `Editor.frameEnd` (this port's
/// main loop) BEFORE the live-tag sweep, so a freshly created `+Errors` window
/// gets its tag in the same frame. Every bucket is appended to its own error
/// window, the appended run is shown, the tag is refreshed and the window is left
/// CLEAN (util.c:250 `w->dirty = FALSE` — machine-generated output is not the
/// user's unsaved work, so Del must not two-strike on it).
///
/// With no window tree (`ed.row == null`: the headless unit harnesses) the
/// buckets are LEFT PENDING rather than dropped — the C always has a row.
///
/// DIVERGENCES:
///   * `textbsinsert` (util.c:243, text.c:307-364) is reduced to a plain
///     `insertAt`: backspace/^U processing of command output is DEFERRED (no
///     external commands write here yet — the only writers are `ed.warning`
///     lines). FLAG for the host-command wave.
///   * The C's `w->owner` juggling (util.c:236-239/249) and `wincommit`
///     (util.c:240, no tag cache in the port) are n/a; the RBUFSIZE chunking
///     (util.c:247-253) is a `bufread` optimization — `Buffer` already blocks.
pub fn flushWarnings(ed: *Editor) Text.Error!void {
    if (ed.warnings.items.len == 0) return;
    if (ed.row == null) return; // headless: keep buffering (see above)

    // Detach the list first so a warning raised DURING the flush lands in the
    // next frame's batch instead of being freed underfoot (the C's `warnings =
    // nil` at util.c:257).
    var list = ed.warnings;
    ed.warnings = .empty;
    defer {
        for (list.items) |*wn| wn.deinit(ed.allocator);
        list.deinit(ed.allocator);
    }

    for (list.items) |*wn| {
        if (wn.text.items.len == 0) continue;
        const w = try errorWin(ed, wn.dir); // util.c:219 errorwin(warn->md, 'E')
        const t = &w.body;
        const q0 = t.file.buffer.len(); // util.c:241
        try t.insertAt(q0, wn.text.items, true); // util.c:243 textbsinsert (see above)
        try t.show(q0, t.file.buffer.len(), true); // util.c:245 textshow(t, q0, nc, 1)
        try w.setTag1(); // util.c:247 winsettag
        w.dirty = false; // util.c:250
        ed.needs_flush = true;
    }
}

// ===========================================================================
// Tests. The named `+Errors` tests (T16-T20 of the phase-12b contract) are
// written separately; these smoke tests only keep the pure helpers reachable.
// ===========================================================================
const testing = std.testing;

test "errors: errorName joins the directory" {
    const a = testing.allocator;
    const bare = try errorName(a, "");
    defer a.free(bare);
    try testing.expectEqualStrings("+Errors", bare);
    const sub = try errorName(a, "/a/b");
    defer a.free(sub);
    try testing.expectEqualStrings("/a/b/+Errors", sub);
}

test "errors: trimSlash drops one trailing slash but keeps root" {
    try testing.expectEqualStrings("/a/b", trimSlash("/a/b/"));
    try testing.expectEqualStrings("/a/b", trimSlash("/a/b"));
    try testing.expectEqualStrings("/", trimSlash("/"));
}
