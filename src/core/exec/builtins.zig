//! The B2 builtin command table (`exectab`, acme/exec.c:59-130), v1 subset
//! (R-P9-7). namespace module (S-07 P-1): a `lowercase.zig` holding the comptime
//! dispatch table, not a struct-file. Ported from larryr/plan9port@337c6ac; cite
//! as `exec.c:NN`.
//!
//! The C's 28-entry table reduces to the ten builtins that need no served
//! namespace or session semantics: Cut, Del, Delcol, Delete, New, Newcol, Paste,
//! Redo, Snarf, Undo (exec.c:98-130, alphabetical). Deferred per R-P9-7: the
//! external `run` path (unknown word ⇒ silent no-op) and Sort/Zerox/Exit (need
//! multi-Text-per-File or session work). The command functions live in the
//! sibling `cmd_edit.zig`/`cmd_window.zig`.
//!
//! The `mark` column mirrors exec.c exactly: only Cut/Paste mark here (Send is
//! deferred); Snarf does NOT mark (no edit); Undo/Redo manage seq themselves;
//! Del/New/Newcol/Delcol never mark.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const cmd_edit = @import("cmd_edit.zig");
const cmd_window = @import("cmd_window.zig");
const edit = @import("../edit/edit.zig");

/// One `exectab` row (exec.c:59-67). `fn_` is the C's `void (*fn)(Text*, Text*,
/// Text*, int, int, Rune*, int)` reshaped to the port's call convention: `ed` is
/// the explicit Editor context (P-3, no globals), `et` is the Text where B2
/// happened, `t` is `ed.seltext` (execute's default target), `argt` is the 2-1
/// chord argument source, and `arg` is the UTF-8 remainder of the executed text
/// after the command word (the C's `(Rune*, int)`).
pub const Entry = struct {
    name: []const u8,
    fn_: *const fn (
        ed: *Editor,
        et: *Text,
        t: ?*Text,
        argt: ?*Text,
        flag1: bool,
        flag2: bool,
        arg: []const u8,
    ) Text.Error!void,
    mark: bool,
    flag1: bool,
    flag2: bool,
};

/// `exectab` (exec.c:98-130), v1 subset in the C's alphabetical order. The `XXX`
/// enum value is 2 (dat.h:488-493 `enum{FALSE,TRUE,XXX}`) — TRUTHY where it
/// reaches a flag test. Genuinely-unused XXX flags are ported as `false` with a
/// `// XXX` comment; the ONE truthy-XXX-that-matters (Paste.flag2 ⇒ `tobody`) is
/// `true` with the dat.h cite.
pub const exectab = [_]Entry{
    .{ .name = "Cut", .fn_ = cmd_edit.cut, .mark = true, .flag1 = true, .flag2 = true }, // exec.c:101
    .{ .name = "Del", .fn_ = cmd_window.del, .mark = false, .flag1 = false, .flag2 = false }, // exec.c:102 (flag2 XXX unused)
    .{ .name = "Delcol", .fn_ = cmd_window.delcol, .mark = false, .flag1 = false, .flag2 = false }, // exec.c:103 (flag1/flag2 XXX unused)
    .{ .name = "Delete", .fn_ = cmd_window.del, .mark = false, .flag1 = true, .flag2 = false }, // exec.c:104 (flag2 XXX unused; free twin of Del)
    // exec.c:106 — Edit manages its own transaction (seq++ in the builtin,
    // File.mark lazily in the first Elog.apply), so mark=FALSE (R-P10-8).
    .{ .name = "Edit", .fn_ = edit.builtin, .mark = false, .flag1 = false, .flag2 = false }, // exec.c:106
    .{ .name = "New", .fn_ = cmd_window.new, .mark = false, .flag1 = false, .flag2 = false }, // exec.c:117 (flag1/flag2 XXX unused)
    .{ .name = "Newcol", .fn_ = cmd_window.newcol, .mark = false, .flag1 = false, .flag2 = false }, // exec.c:118 (flag1/flag2 XXX unused)
    // exec.c:119 — flag2 is the C's XXX==2, TRUTHY (dat.h:488-493): tobody=TRUE is
    // LOAD-BEARING (a tag Paste lands in the body), so it is ported as `true`.
    .{ .name = "Paste", .fn_ = cmd_edit.paste, .mark = true, .flag1 = true, .flag2 = true }, // exec.c:119
    .{ .name = "Redo", .fn_ = cmd_edit.undo, .mark = false, .flag1 = false, .flag2 = false }, // exec.c:122 (isundo=FALSE; flag2 XXX unused)
    .{ .name = "Snarf", .fn_ = cmd_edit.cut, .mark = false, .flag1 = true, .flag2 = false }, // exec.c:124 (docut=FALSE)
    .{ .name = "Undo", .fn_ = cmd_edit.undo, .mark = false, .flag1 = true, .flag2 = false }, // exec.c:127 (isundo=TRUE; flag2 XXX unused)
};

test "builtins: table shape and flags match exec.c" {
    const testing = std.testing;
    // Grew by one row (R-P10-8): Edit sits alphabetically between Delete and New.
    try testing.expectEqual(@as(usize, 11), exectab.len);
    // Alphabetical order (exec.c:98-130 subset + Edit at :106).
    const names = [_][]const u8{ "Cut", "Del", "Delcol", "Delete", "Edit", "New", "Newcol", "Paste", "Redo", "Snarf", "Undo" };
    for (names, 0..) |n, i| try testing.expectEqualStrings(n, exectab[i].name);
    // Cut marks + snarfs + cuts; Snarf marks NOT, snarfs, does not cut.
    try testing.expect(exectab[0].mark and exectab[0].flag1 and exectab[0].flag2); // Cut
    try testing.expect(!exectab[9].mark and exectab[9].flag1 and !exectab[9].flag2); // Snarf
    // Paste's flag2 (tobody) is the truthy XXX.
    try testing.expect(exectab[7].mark and exectab[7].flag1 and exectab[7].flag2); // Paste
    // Undo/Redo differ only in flag1 (isundo).
    try testing.expect(exectab[10].flag1 and !exectab[8].flag1); // Undo vs Redo
    // Delete = Del with flag1 (skip-clean twin).
    try testing.expect(exectab[3].flag1 and !exectab[1].flag1);
    // Edit manages its own seq, so it never marks (R-P10-8).
    try testing.expect(!exectab[4].mark and std.mem.eql(u8, exectab[4].name, "Edit"));
}
