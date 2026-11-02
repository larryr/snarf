//! Session-level builtins (#13): `Sort` (exec.c:412-423), `Kill`
//! (exec.c:1239-1262) and `Exit` (exec.c:1148-1163). `Zerox` joins them once
//! multi-Text-per-File lands. Namespace module (S-07 P-1). Ported from
//! larryr/plan9port@337c6ac acme/exec.c; cite as `exec.c:NN`.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const Row = @import("../Row.zig");
const exec = @import("exec.zig");
const place = @import("../place.zig");

/// `sort` (exec.c:412-423): `if(et->col) colsort(et->col)` — the executing
/// Text's column, whether that is a window's tag or body or the column tag.
pub fn sort(ed: *Editor, et: *Text, _: ?*Text, _: ?*Text, _: bool, _: bool, _: []const u8) Text.Error!void {
    const c = place.colOf(et) orelse return; // exec.c:421
    try c.sort(ed); // exec.c:422
}

/// `xkill` (exec.c:1239-1262): each blank-separated word of the argument (and
/// first of the 2-1 chord argument, exec.c:1250-1252) names an external
/// command to kill. The port runs no external commands yet (#17, the `run`
/// path is deferred, R-P9-7), so every name gets acme's own "not found" line
/// from the wait thread (acme.c:735-746), and a bare `Kill` — no names —
/// does nothing at all, as in acme (the loop exits at once, exec.c:1254-1256).
pub fn kill(ed: *Editor, _: *Text, _: ?*Text, argt: ?*Text, _: bool, _: bool, arg: []const u8) Text.Error!void {
    if (try exec.getArg(ed, argt)) |r| { // exec.c:1250 getarg(argt, FALSE, FALSE, …)
        defer ed.allocator.free(r);
        killNames(ed, r); // exec.c:1251-1252
    }
    killNames(ed, arg);
}

/// The `ckill` side (acme.c:733-747) with an empty command list.
fn killNames(ed: *Editor, arg: []const u8) void {
    var it = std.mem.tokenizeAny(u8, arg, " \t\n");
    while (it.next()) |name| ed.warning("Kill: no process {s}\n", .{name}); // acme.c:745-746
}

/// `rowclean` (rows.c:520-529): `colclean` over every column with NO short
/// circuit, so every dirty window is warned (and takes its first strike) in
/// one pass.
pub fn rowClean(ed: *Editor, row: *Row) bool {
    var clean = true;
    for (row.col.items) |c| clean = c.clean(ed) and clean;
    return clean;
}

/// `xexit` (exec.c:1148-1163): if the whole row is clean, quit. A dirty
/// window makes `winclean` warn "<name> modified" and clear its `dirty`, so
/// the second `Exit` goes through (the two-strike, PM Q4). acme's
/// `sendul(cexit, 0)` is `ed.exit_requested`: the host's loop stops on it
/// (once `ed.exitReady()`) and runs the #58/#68 shutdown, which frees the
/// session and ends devdraw.
///
/// acme's Put and Dump are synchronous, so `xexit` never meets one still
/// writing. The port's are not: an Exit issued while one is in flight waits
/// for them all to finish (`ed.exit_waiting`), and only then runs `rowclean`
/// (`exitStep`), so a window its Put just saved is clean, exactly as in acme.
/// A second Exit while that one waits stops at once through the #58/#68
/// shutdown, which discards the unfinished Put and keeps its bytes
/// (SnarfProdd, PR #74 Q4).
pub fn exit(ed: *Editor, et: *Text, _: ?*Text, _: ?*Text, _: bool, _: bool, _: []const u8) Text.Error!void {
    const row = place.rowOf(et) orelse ed.row orelse return; // acme's global `row`
    if (ed.exit_waiting != null) { // the second Exit: no more waiting
        ed.exit_waiting = null;
        ed.exit_now = true;
        ed.exit_requested = true;
        return;
    }
    if (ed.writing()) {
        ed.exit_waiting = row;
        return;
    }
    if (rowClean(ed, row)) ed.exit_requested = true; // exec.c:1158-1160
}

/// Per frame (`Editor.frameEnd`, after the Put/Dump steps): an Exit that was
/// waiting runs its `rowclean` once nothing is writing any more.
pub fn exitStep(ed: *Editor) void {
    const row = ed.exit_waiting orelse return;
    if (ed.writing()) return;
    ed.exit_waiting = null;
    if (rowClean(ed, row)) ed.exit_requested = true; // exec.c:1158-1160
}
