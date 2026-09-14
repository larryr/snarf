//! `expandfile` (look.c:592-729) — "is the text under B3 a FILE NAME?" — plus
//! the asynchronous existence check that answers it here. Namespace module
//! (S-07 P-1, lowercase). Ported from larryr/plan9port@337c6ac; cite as
//! `look.c:NN` / `addr.c:NN`.
//!
//! R-P13b-2 — THE ONE REAL DIVERGENCE OF THIS WAVE. acme decides with a
//! synchronous `access(e->bname, 0)` (look.c:706) and, if that fails, falls
//! straight through to the literal search in the SAME call. Snarf cannot: the
//! answer lives behind a 9P walk whose reply may not arrive until a later
//! browser tick (`wsPush`, R-9P-13), and the main thread must not block. So a
//! B3 look splits in two:
//!
//!   1. `startLook` expands TEXTUALLY (`expandFile`, pure, no I/O), resolves the
//!      candidate to an absolute name and parks a `StatJob` as `Editor.pending_look`;
//!   2. `stepPending`, run once a frame from `Load.stepAll`, resolves it —
//!      `.done` ⇒ `openfile.openFile`, any error (the `access` failure) ⇒
//!      `look.literal`, the alnum-expansion search arm exactly as before.
//!
//! ONE pending look at a time (contract §3d): a newer B3 cancels the older, the
//! way a user's second click supersedes the first. The observable difference
//! from acme is timing only — a look that resolves to a file opens a frame or
//! two later, a look that does not falls back to the search a frame or two
//! later. Documented in `look.zig`'s header, S-05 §6 and the R-02 revision log.
//!
//! Imports: `std` + `ninep` + sibling core files (S-07 §6 — never dev/shim).
const std = @import("std");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const errors = @import("errors.zig");
const exec = @import("exec/exec.zig");
const look = @import("look.zig");
const openfile = @import("openfile.zig");
const select = @import("text/select.zig");

const nsjob = ninep.nsjob;

/// What the textual expansion decided the click is (look.c:655-717): a plain
/// file name, a URL (`http://`/`https://` prefix, look.c:655-668) or an
/// `<include>` (look.c:697-699).
pub const Kind = enum { file, url, include };

/// The result of `expandFile` — the C's `Expand` (dat.h:294-306) reduced to
/// RANGES in the source Text, because the port reads the runes out later.
///
///   * `[name_q0, name_q1)` — `e->name`/`e->nname`, the file name half
///     (look.c:715-716). EMPTY when the click was a bare `:addr`, which means
///     "the window's own file" (look.c:822-826).
///   * `[addr_q0, addr_q1)` — `e->a0`/`amax`, the address text after the colon
///     (look.c:718, `address(TRUE, …, e->a0, amax, …)`). Null when there is no
///     colon.
///   * `[q0, q1)` — `e->q0`/`e->q1`, the whole expansion; the caller needs it
///     for the literal-search fallback.
pub const Candidate = struct {
    name_q0: usize,
    name_q1: usize,
    addr_q0: usize = 0,
    addr_q1: usize = 0,
    has_addr: bool = false,
    q0: usize,
    q1: usize,
    kind: Kind,
};

/// `isaddrc` (addr.c:28-34): the runes an address may be made of.
pub fn isAddrC(r: u21) bool {
    return r != 0 and std.mem.indexOfScalar(u21, &addr_runes, r) != null;
}
const addr_runes = [_]u21{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '-', '/', '$', '.', '#', ',', ';', '?' };

/// `isregexc` (addr.c:36-48): "could be almost anything but white space, but we
/// are a little conservative, aiming for regular expressions of alphanumerics
/// and no white space".
pub fn isRegexC(r: u21) bool {
    if (r == 0) return false;
    if (select.isAlnum(r)) return true;
    return std.mem.indexOfScalar(u21, &regex_runes, r) != null;
}
const regex_runes = [_]u21{ '^', '+', '-', '.', '*', '?', '#', ',', ';', '[', ']', '(', ')', '$' };

const http_prefix = [_]u21{ 'h', 't', 't', 'p', ':', '/', '/' };
const https_prefix = [_]u21{ 'h', 't', 't', 'p', 's', ':', '/', '/' };

/// `texthas` (look.c:578-590): does `t` hold `s` verbatim starting at `at`?
/// `at` is SIGNED because every call site passes `q-4`/`q-5`, which the C tests
/// with `if((int)q0 < 0) return FALSE`.
fn textHas(t: *Text, at: isize, s: []const u21) bool {
    if (at < 0) return false;
    const p: usize = @intCast(at);
    const nc = t.file.buffer.len();
    for (s, 0..) |r, i| {
        if (p + i >= nc or t.file.buffer.runeAt(p + i) != r) return false;
    }
    return true;
}

/// A ':' that is NOT the one inside `http://` / `https://` (look.c:607/615).
fn breakingColon(t: *Text, q: usize) bool {
    const i: isize = @intCast(q);
    return !textHas(t, i - 4, &http_prefix) and !textHas(t, i - 5, &https_prefix);
}

/// `expandfile` (look.c:592-729) MINUS its I/O: everything up to (but not
/// including) `access()`/`lookfile`. Purely textual, so it is trivially
/// testable and the asynchronous half below is the only thing that needs a
/// namespace. `reverse` (Shift-B3, look.c:636-643) is DEFERRED with the rest of
/// the reverse-look backlog item and is not a parameter here.
///
/// Returns null for the C's `Isntfile` (look.c:727-729) and for an empty
/// expansion (look.c:646-648).
pub fn expandFile(t: *Text, q0_in: usize, q1_in: usize) ?Candidate {
    const nc = t.file.buffer.len();
    var q0 = q0_in;
    var q1 = q1_in;
    var amax = q1; // look.c:604
    var amin = amax; // look.c:645
    var has_colon = false;

    if (q1 == q0) { // look.c:605
        var colon: ?usize = null;
        // look.c:607-613: forward over isfilec, noting the first BREAKING colon.
        while (q1 < nc) {
            const c = t.file.buffer.runeAt(q1);
            if (!exec.isfilec(c)) break;
            if (c == ':' and breakingColon(t, q1)) {
                colon = q1;
                break;
            }
            q1 += 1;
        }
        // look.c:614-618: backward over isfilec || isaddrc || isregexc.
        while (q0 > 0) {
            const c = t.file.buffer.runeAt(q0 - 1);
            if (!exec.isfilec(c) and !isAddrC(c) and !isRegexC(c)) break;
            q0 -= 1;
            if (colon == null and c == ':' and breakingColon(t, q0)) colon = q0;
        }
        // look.c:620-632: "if it looks like it might begin file: , consume
        // address chars after :, otherwise terminate expansion at :".
        if (colon) |col| {
            q1 = col;
            if (col + 1 < nc and isAddrC(t.file.buffer.runeAt(col + 1))) {
                q1 = col + 1;
                while (q1 < nc and isAddrC(t.file.buffer.runeAt(q1))) q1 += 1;
            }
        }
        if (q1 > q0) {
            if (colon) |col| { // look.c:634-637 stop at white space
                amax = col + 1;
                while (amax < nc) : (amax += 1) {
                    const c = t.file.buffer.runeAt(amax);
                    if (c == ' ' or c == '\t' or c == '\n') break;
                }
            } else amax = nc; // look.c:638-639
        }
        amin = amax;
    }

    const n = q1 - q0; // look.c:648
    if (n == 0) return null; // look.c:649-650

    // look.c:654-668: a URL is taken whole, trailing sentence '.' shaved.
    if (hasPrefix(t, q0, n, &http_prefix) or hasPrefix(t, q0, n, &https_prefix)) {
        var uq1 = q1;
        if (t.file.buffer.runeAt(q1 - 1) == '.') uq1 -= 1; // look.c:657-660
        return .{ .name_q0 = q0, .name_q1 = uq1, .q0 = q0, .q1 = uq1, .kind = .url };
    }

    // look.c:670-683: "first, does it have bad chars?" — the colon splitting
    // name from address, then every name rune must be isfilec (or a space).
    var nname: ?usize = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = t.file.buffer.runeAt(q0 + i);
        if (c == ':' and nname == null) {
            // look.c:674-677
            if (q0 + i + 1 < nc and (i == n - 1 or isAddrC(t.file.buffer.runeAt(q0 + i + 1)))) {
                amin = q0 + i;
                has_colon = true;
            } else return null; // Isntfile
            nname = i;
        }
    }
    const nn = nname orelse n; // look.c:680-681
    i = 0;
    while (i < nn) : (i += 1) {
        const c = t.file.buffer.runeAt(q0 + i);
        if (!exec.isfilec(c) and c != ' ') return null; // look.c:682-683
    }

    // look.c:691-699: `<name>` is an include-file name.
    const include = q0 > 0 and t.file.buffer.runeAt(q0 - 1) == '<' and
        q1 < nc and t.file.buffer.runeAt(q1) == '>';

    return .{
        .name_q0 = q0,
        .name_q1 = q0 + nn,
        .addr_q0 = amin + 1, // look.c:717 `e->a0 = amin+1`
        .addr_q1 = amax,
        .has_addr = has_colon and amin + 1 <= amax,
        .q0 = q0,
        .q1 = q1,
        .kind = if (include) .include else .file,
    };
}

fn hasPrefix(t: *Text, q0: usize, n: usize, s: []const u21) bool {
    if (n < s.len) return false;
    for (s, 0..) |r, i| {
        if (t.file.buffer.runeAt(q0 + i) != r) return false;
    }
    return true;
}

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
    /// Absolute, cleaned. Owned; BORROWED by the job, so it must not move.
    name: []u8,
    /// The `:addr` runes. Owned.
    addr: ?[]u21,
    job: nsjob.StatJob,
};

/// look.c:783 — the `expandfile` arm of `expand`. Returns TRUE when the look is
/// handled (opened, parked or diagnosed) and the caller must NOT run the
/// literal search; FALSE for the C's `Isntfile`, which falls through.
pub fn startLook(ed: *Editor, t: *Text, q0: usize, q1: usize, reverse: bool) Text.Error!bool {
    dropPending(ed); // one at a time: a newer B3 supersedes the older
    const a = ed.allocator;
    const cand = expandFile(t, q0, q1) orelse return false;

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
        _ = openfile.openFile(ed, t, .{ .name = "", .addr = addr, .q0 = cand.q0, .q1 = cand.q1 }) catch return false;
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
        _ = openfile.openFile(ed, t, .{ .name = abs, .addr = addr, .q0 = cand.q0, .q1 = cand.q1 }) catch return false;
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
        dropPending(ed);
        return look.literal(ed, t, q0, q1, reverse);
    };
    if (st == .pending) return;
    const t = pl.t;
    _ = openfile.openFile(ed, t, .{ .name = pl.name, .addr = pl.addr }) catch {};
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

// ==========================================================================
// Helpers
// ==========================================================================

/// `[q0,q1)` of `t` as owned UTF-8 (the C's `runetobyte(r, nname)`).
fn runeText(a: std.mem.Allocator, t: *Text, q0: usize, q1: usize) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var tmp: [4]u8 = undefined;
    var i = q0;
    while (i < q1) : (i += 1) {
        const n = std.unicode.utf8Encode(t.file.buffer.runeAt(i), &tmp) catch
            std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
        try out.appendSlice(a, tmp[0..n]);
    }
    return out.toOwnedSlice(a);
}

/// `[q0,q1)` of `t` as owned runes.
fn runeSlice(a: std.mem.Allocator, t: *Text, q0: usize, q1: usize) error{OutOfMemory}![]u21 {
    const out = try a.alloc(u21, q1 - q0);
    for (out, 0..) |*r, i| r.* = t.file.buffer.runeAt(q0 + i);
    return out;
}

/// `dirname(t, r, nname)` (look.c:542-578) for the QUERY shape this wave needs:
/// a rooted name is already absolute; anything else hangs off the clicked
/// window's own directory (`errors.dirName`, R-EDIT-20), and `openfile.absName`
/// roots whatever is left at `wdir` = `/` (R-P13b-3).
fn absolute(ed: *Editor, a: std.mem.Allocator, t: *Text, name: []const u8) error{OutOfMemory}![]u8 {
    _ = ed;
    if (name[0] == '/') return openfile.cleanName(a, name);
    const dir: []const u8 = if (t.w) |w| errors.dirName(w) else "";
    if (dir.len == 0) return openfile.absName(a, name);
    const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
    defer a.free(joined);
    return openfile.absName(a, joined);
}

// ==========================================================================
// Smoke tests. The named battery (T7/T8) is the test writer's; these keep the
// module's decls reachable and pin the two rune classes against addr.c.
// ==========================================================================
const testing = std.testing;

test "expand: isAddrC and isRegexC match addr.c's sets" {
    for ("0123456789+-/$.#,;?") |c| try testing.expect(isAddrC(c));
    try testing.expect(!isAddrC('a'));
    try testing.expect(!isAddrC(' '));
    for ("^+-.*?#,;[]()$") |c| try testing.expect(isRegexC(c));
    try testing.expect(isRegexC('z'));
    try testing.expect(!isRegexC(' '));
}
