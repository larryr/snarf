//! The PARKED B3 LOOK (R-P13b-2): `look.c:783`'s `expandfile` arm, split in
//! half by the browser's main thread. acme decides "is this text a file name?"
//! with a synchronous `access(e->bname, 0)` (look.c:706); Snarf can only answer
//! with a `ninep.nsjob.StatJob` that completes on a LATER frame, so the look
//! waits here (`Editor.pending_look`) until the verdict arrives.
//!
//! Namespace module (S-07 P-1) carved out of `expand.zig` verbatim in phase 16a
//! so both files stay inside the ~400-line cap; the pure, synchronous
//! `expandFile` classifier stays in `expand.zig`, which is also where the three
//! rune/path helpers this file calls live.
//!
//! Imports: `std` + `ninep` + sibling core files only (S-07 §6).
const std = @import("std");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const errors = @import("errors.zig");
const expand = @import("expand.zig");
const look = @import("look.zig");
const openfile = @import("openfile.zig");

const nsjob = ninep.nsjob;

const expandFile = expand.expandFile;
const runeText = expand.runeText;
const runeSlice = expand.runeSlice;
const absolute = expand.absolute;

// ==========================================================================
// The parked look (R-P13b-2)
// ==========================================================================

/// One B3 look waiting on a `StatJob` — the asynchronous stand-in for
/// look.c:706's `access(e->bname, 0)`. Heap-allocated and never moved: the job
/// hands its reply buffer to a live ticket (nsjob.zig's pointer-stability rule).
pub const PendingLook = struct {
    allocator: std.mem.Allocator,
    /// The Text the click happened in — the literal fallback's target, and
    /// `openfile`'s `t` argument. Dropped by `dropWindow` if its window dies.
    t: *Text,
    /// The ORIGINAL (selection-expanded) click range, so the fallback runs the
    /// alnum arm from exactly where `expand` would have (look.c:786-791).
    q0: usize,
    q1: usize,
    reverse: bool,
    /// `e->jump` (look.c:735/741), carried across the park so the warp
    /// decision made at click time survives the asynchronous verdict.
    jump: bool,
    /// Absolute, cleaned. Owned; BORROWED by the job, so it must not move.
    name: []u8,
    /// The `:addr` runes. Owned.
    addr: ?[]u21,
    job: nsjob.StatJob,
};

/// look.c:783 — the `expandfile` arm of `expand`. Returns TRUE when the look is
/// handled (opened, parked or diagnosed) and the caller must NOT run the
/// literal search; FALSE for the C's `Isntfile`, which falls through.
pub fn startLook(ed: *Editor, t: *Text, q0: usize, q1: usize, reverse: bool, jump: bool) Text.Error!bool {
    dropPending(ed); // one at a time: a newer B3 supersedes the older
    const a = ed.allocator;
    // `cand.reverse` is `e->reverse` after expandfile's downgrades
    // (look.c:637-643). Nothing reads it yet — see `expand.Candidate`.
    const cand = expandFile(t, q0, q1, reverse) orelse return false;

    if (cand.kind == .include) return false; // no `incl` list in v1 ⇒ literal

    const name = try runeText(a, t, cand.name_q0, cand.name_q1);
    defer a.free(name);

    if (cand.kind == .url) {
        // look.c:661-666 opens the URL through the plumber; Snarf has neither a
        // plumber nor a browser-navigation device yet (R-EDIT-13, backlog).
        ed.warning("{s}: opening URLs is deferred (R-EDIT-13)\n", .{name});
        return true;
    }

    const addr: ?[]u21 = if (cand.has_addr and cand.addr_q1 > cand.addr_q0)
        try runeSlice(a, t, cand.addr_q0, cand.addr_q1)
    else
        null;
    defer if (addr) |ap| a.free(ap);

    // look.c:822-826 via openfile: `nname == 0` (a bare `:addr`) addresses the
    // window the click happened in — no name to check the existence of.
    if (name.len == 0) {
        if (t.w == null) return false;
        _ = openfile.openFile(ed, t, .{ .name = "", .addr = addr, .jump = jump, .q0 = cand.q0, .q1 = cand.q1 }) catch return false;
        return true;
    }

    // look.c:700-703 `dirname(t, r, nname)`: an unrooted name is relative to the
    // WINDOW's directory (R-EDIT-20), not to `wdir` — that is openfile's job
    // for whatever is still unrooted afterwards.
    const abs = try absolute(ed, a, t, name);
    defer a.free(abs);

    const row = ed.row orelse return false;
    // look.c:704-705: "if it's already a window name, it's a file" — no
    // existence check at all, so this arm stays synchronous.
    if (errors.lookFile(row, abs) != null) {
        _ = openfile.openFile(ed, t, .{ .name = abs, .addr = addr, .jump = jump, .q0 = cand.q0, .q1 = cand.q1 }) catch return false;
        return true;
    }

    // look.c:706-710 `ismtpt(e->bname) || access(e->bname, 0) < 0` ⇒ Isntfile.
    if (openfile.isMtpt(abs)) return false;
    const ns = ed.ns orelse return false; // nothing to check against ⇒ Isntfile

    const pl = try a.create(PendingLook);
    errdefer a.destroy(pl);
    pl.* = .{
        .allocator = a,
        .t = t,
        .q0 = q0,
        .q1 = q1,
        .reverse = reverse,
        .jump = jump,
        .name = try a.dupe(u8, abs),
        .addr = if (addr) |ap| try a.dupe(u21, ap) else null,
        .job = undefined,
    };
    errdefer {
        a.free(pl.name);
        if (pl.addr) |ap| a.free(ap);
    }
    pl.job = nsjob.StatJob.init(ns, pl.name) catch {
        a.free(pl.name);
        if (pl.addr) |ap| a.free(ap);
        a.destroy(pl);
        return false; // a path the walker refuses outright is simply not a file
    };
    ed.pending_look = pl;
    return true;
}

/// Advance the parked look by one 9P state. Called once a frame from
/// `Load.stepAll`; a no-op when nothing is parked.
pub fn stepPending(ed: *Editor) Text.Error!void {
    const pl = ed.pending_look orelse return;
    const st = pl.job.step() catch {
        // The `access()` failure of look.c:706 — fall through to the literal
        // search, from the ORIGINAL expansion (look.c:786-791).
        const t = pl.t;
        const q0 = pl.q0;
        const q1 = pl.q1;
        const reverse = pl.reverse;
        const jump = pl.jump;
        dropPending(ed);
        return look.literal(ed, t, q0, q1, reverse, jump);
    };
    if (st == .pending) return;
    const t = pl.t;
    _ = openfile.openFile(ed, t, .{ .name = pl.name, .addr = pl.addr, .jump = pl.jump }) catch {};
    dropPending(ed);
}

/// `textclose`'s backpointer hygiene (text.c:109-118): a window that dies with
/// a look parked on one of its Texts drops it. Reached from
/// `Editor.dropTextRefs` through `Load.dropWindow`.
pub fn dropWindow(ed: *Editor, w: *Window) void {
    const pl = ed.pending_look orelse return;
    if (pl.t == &w.tag or pl.t == &w.body) dropPending(ed);
}

/// Cancel and free the parked look (tombstone-safe: `StatJob.deinit` is
/// fire-and-forget, 13a).
pub fn dropPending(ed: *Editor) void {
    const pl = ed.pending_look orelse return;
    ed.pending_look = null;
    pl.job.deinit();
    pl.allocator.free(pl.name);
    if (pl.addr) |ap| pl.allocator.free(ap);
    pl.allocator.destroy(pl);
}
