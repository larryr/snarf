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
//! Imports: `std` + sibling core files (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const errors = @import("errors.zig");
const exec = @import("exec/exec.zig");
const look = @import("look.zig");
const openfile = @import("openfile.zig");
const select = @import("text/select.zig");

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
///   * `reverse` — `e->reverse` (look.c:637-643), the caller's Shift-B3 flag
///     AFTER the two downgrades `expandfile` applies to it. NOTHING READS IT
///     YET: it is the one piece of the reverse-look backlog item that belongs
///     to this function, recorded here so the bookkeeping cannot be forgotten
///     when Shift-B3 lands. Its consumer will be `address()`'s last argument
///     (look.c:723/881), where a true `reverse` starts the address scan with
///     `dir = Back` (addr.c:188-189).
pub const Candidate = struct {
    name_q0: usize,
    name_q1: usize,
    addr_q0: usize = 0,
    addr_q1: usize = 0,
    has_addr: bool = false,
    q0: usize,
    q1: usize,
    kind: Kind,
    reverse: bool = false,
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
/// namespace.
///
/// `reverse_in` is the caller's Shift-B3 flag. `expandfile` DOWNGRADES it in
/// two places (look.c:637-643) and the result travels on as `e->reverse`; it
/// is reproduced here and handed back in `Candidate.reverse`. Nothing consumes
/// it yet — the rest of reverse look is still a backlog item — but the rule
/// lives where the C puts it instead of being rediscovered later.
///
/// Returns null for the C's `Isntfile` (look.c:727-729) and for an empty
/// expansion (look.c:646-648).
pub fn expandFile(t: *Text, q0_in: usize, q1_in: usize, reverse_in: bool) ?Candidate {
    const nc = t.file.buffer.len();
    var q0 = q0_in;
    var q1 = q1_in;
    var amax = q1; // look.c:604
    var amin = amax; // look.c:645
    var has_colon = false;
    var reverse = reverse_in;

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
        // look.c:640-641 `if(colon != q0) reverse = FALSE`. `colon` is an int
        // and `q0` a uint there, so the absent colon (-1) converts to a huge
        // unsigned and the test is TRUE — i.e. a reverse look survives only
        // when the expansion BEGINS at the colon, a bare `:addr` click.
        if (colon == null or colon.? != q0) reverse = false;
        amin = amax;
    } else if (reverse) {
        // look.c:642-644: an explicit selection keeps `reverse` only when it
        // starts with the colon.
        if (q0 >= nc or t.file.buffer.runeAt(q0) != ':') reverse = false;
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
        .reverse = reverse, // look.c:718 `e->reverse = reverse`
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
// Helpers. `pub` since phase 16a: `pendinglook.zig` — the parked half of the
// look that used to live below — is their other caller.
// ==========================================================================

/// `[q0,q1)` of `t` as owned UTF-8 (the C's `runetobyte(r, nname)`).
pub fn runeText(a: std.mem.Allocator, t: *Text, q0: usize, q1: usize) error{OutOfMemory}![]u8 {
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
pub fn runeSlice(a: std.mem.Allocator, t: *Text, q0: usize, q1: usize) error{OutOfMemory}![]u21 {
    const out = try a.alloc(u21, q1 - q0);
    for (out, 0..) |*r, i| r.* = t.file.buffer.runeAt(q0 + i);
    return out;
}

/// `dirname(t, r, nname)` (look.c:542-578) for the QUERY shape this wave needs:
/// a rooted name is already absolute; anything else hangs off the clicked
/// window's own directory (`errors.dirName`, R-EDIT-20), and `openfile.absName`
/// roots whatever is left at `wdir` = `/` (R-P13b-3).
pub fn absolute(ed: *Editor, a: std.mem.Allocator, t: *Text, name: []const u8) error{OutOfMemory}![]u8 {
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

// ===========================================================================
// Named battery (phase-13b contract §4, T7).
// ===========================================================================
const draw = @import("draw");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");
const Frame = draw.Frame;
const proto = draw.proto;

test "expand: expandFile — file+addr, bare addr, url, include, no-addr, whitespace (T7)" {
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    const Case = struct {
        text: []const u8,
        click: usize,
        kind: ?Kind, // null: expandFile returns null (Isntfile / empty click)
        name: []const u8 = "",
        addr: []const u8 = "",
        has_addr: bool = false,
    };
    // Click offsets are RUNE indices into `text`; see the phase-13b test
    // report for the full look.c:592-729 hand-trace behind each one.
    const cases = [_]Case{
        // "dat.h:27", click inside "dat.h" (index 2, 't'): name + line addr.
        .{ .text = "dat.h:27", .click = 2, .kind = .file, .name = "dat.h", .addr = "27", .has_addr = true },
        // ":/^main/", click inside "main" (index 3): nname==0 ("the window's
        // own file", look.c:822-826), addr is the whole regexp after the ':'.
        .{ .text = ":/^main/", .click = 3, .kind = .file, .name = "", .addr = "/^main/", .has_addr = true },
        // A URL: taken WHOLE, the "http://" colon is not a splitting colon
        // (look.c:607/615's breakingColon).
        .{ .text = "http://x/y:80", .click = 4, .kind = .url, .name = "http://x/y:80" },
        // "<stdio.h>": an include name, brackets stripped (look.c:691-699).
        .{ .text = "<stdio.h>", .click = 4, .kind = .include, .name = "stdio.h" },
        // A bare name, no colon at all: no address half.
        .{ .text = "foo", .click = 1, .kind = .file, .name = "foo", .has_addr = false },
        // A click squarely between two spaces: nothing isfilec/isaddrc/isregexc
        // on either side ⇒ n==0 ⇒ Isntfile (look.c:648-650).
        .{ .text = "a  b", .click = 2, .kind = null },
    };

    for (cases) |c| {
        var file = File.init(a, Buffer.initEmpty(a));
        defer file.deinit();
        var text = try Text.init(&file, a, proto.Rect.make(0, 0, 656, 470), fx.font, &fx.disp.image, .{ &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white });
        defer text.deinit();
        try text.insertAt(0, c.text, true);

        const got = expandFile(&text, c.click, c.click, false);
        if (c.kind == null) {
            try testing.expect(got == null);
            continue;
        }
        const cand = got.?;
        try testing.expectEqual(c.kind.?, cand.kind);

        const name = try runeText(a, &text, cand.name_q0, cand.name_q1);
        defer a.free(name);
        try testing.expectEqualStrings(c.name, name);

        if (c.has_addr) {
            try testing.expect(cand.has_addr);
            const addr = try runeText(a, &text, cand.addr_q0, cand.addr_q1);
            defer a.free(addr);
            try testing.expectEqualStrings(c.addr, addr);
        } else if (cand.kind == .file) {
            try testing.expect(!cand.has_addr);
        }
    }
}

test "expand: Candidate.reverse follows expandfile's two downgrades (16b item 6)" {
    // [look.c:637-643] — a reverse look survives only a bare `:addr` click
    // (the expansion BEGINS at the colon), or an explicit selection that
    // starts with the colon.
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var file = File.init(a, Buffer.initEmpty(a));
    defer file.deinit();
    var text = try Text.init(&file, a, proto.Rect.make(0, 0, 656, 470), fx.font, &fx.disp.image, .{ &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white });
    defer text.deinit();
    try text.insertAt(0, "x.c:12 :34", true); // a named address, then a bare one

    // A click anywhere in `x.c:12`: the expansion starts at the name, not the
    // colon, so `colon != q0` and reverse is dropped (look.c:640-641).
    try testing.expect(!expandFile(&text, 1, 1, true).?.reverse);
    try testing.expect(!expandFile(&text, 4, 4, true).?.reverse);
    // A click in the bare `:34`: the expansion IS the colon run, so it stays.
    try testing.expect(expandFile(&text, 8, 8, true).?.reverse);
    // An explicit selection keeps it only when it starts with the colon
    // (look.c:642-644).
    try testing.expect(expandFile(&text, 7, 10, true).?.reverse);
    try testing.expect(!expandFile(&text, 0, 6, true).?.reverse);
    // And a caller that never asked for reverse never gets it.
    try testing.expect(!expandFile(&text, 8, 8, false).?.reverse);
}
