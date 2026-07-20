//! The edit-language AST + diagnostics — THE home for the types acme's `edit.h`
//! declared (edit.h:9-78). R-P10-1: this file owns `Addr`/`Kind`, `Address`,
//! `String`, `Diag`, `Error`; `addr.zig` (evaluation, wave 10b) and `parse.zig`
//! (parser, this wave) both build on these. Import graph (R-P10-1): imports core
//! siblings (Text/File) but NEVER parse/cmd/addr — it is the leaf of the edit type
//! graph.
//!
//! Arena-allocated: the parser hands out `*Addr`/`*Cmd` nodes and `[]const u21`
//! rune slices from a per-Edit arena; nothing here is individually freed (this
//! replaces the C's cmdlist/addrlist/stringlist bookkeeping, edit.c:70-72,346-359).
//!
//! Ported from larryr/plan9port@337c6ac; cite as `edit.h:NN` / `edit.c:NN`.
const std = @import("std");
const File = @import("../File.zig");
const Text = @import("../text/Text.zig");

/// `editerror` (edit.c:137-149) has no longjmp/threadexits analogue in the port
/// (R-P10-4): a diagnostic becomes `error.Edit` carried out through `ast.Error`,
/// with the human message parked in the `Diag` that rides `cmd.Ctx`. OOM and the
/// Text mutation errors propagate transparently.
pub const Error = error{ Edit, OutOfMemory } || Text.Error;

pub const Range = File.Range;

/// The command's default target range + its Text. R-P10-1 amendment to edit.h:27-30
/// (`struct Address{ Range r; File *f; }`): snarf's File has no `curtext`, so where
/// the C reads `a.f` the port reads `a.t.file` — the field is the Text, not the File.
pub const Address = struct { r: Range, t: *Text };

/// A collected rune string (edit.h:9-14 `struct String`), the C's growable `Rune*`.
/// Parser results are handed out as plain `[]const u21` arena slices, so this alias
/// exists mainly for callers that ACCUMULATE across invocations — chiefly
/// `Editor.edit_lastpat` (the persistent last-regexp cache, edit.c:181).
pub const String = std.ArrayList(u21);

/// One address node (edit.h:16-25 `struct Addr`). The C's `char type` + tagged
/// `union{ String *re; Addr *left; }` + `ulong num` collapse into `Kind`; `next`
/// stays a sibling field — the `+`/`-` chain AND the right side of `,`/`;`.
pub const Addr = struct {
    kind: Kind,
    next: ?*Addr = null,

    /// Address atom kinds. Payloads replace edit.h's `num`/`u.re`/`u.left`:
    ///   char/line — `#n` / `n`      (edit.c:610-618; num carried in the payload)
    ///   re/back_re — `/re/` / `?re?` (edit.c:619-621; arena rune slice, NOT compiled —
    ///               parse.zig never imports Regx; addr.zig compiles at eval time)
    ///   dot end mark plus minus     — `.` `$` `'` `+` `-` (edit.c:622-628)
    ///   all                          — `*`, the whole-file default synthesized by
    ///               cmdexec for defaddr==aAll (ecmd.c:90-96); the PARSER never
    ///               produces it, but it is a valid eval-time node.
    ///   comma/semi — `,` / `;`; the payload is the LEFT side (null ⇒ line 0),
    ///               `next` is the right side (null ⇒ `$`) (edit.c:665-686).
    ///   file — `"re"` filename match (edit.c:619-621); parses in v1, eval defers.
    pub const Kind = union(enum) {
        char: usize,
        line: usize,
        re: []const u21,
        back_re: []const u21,
        dot,
        end,
        mark,
        plus,
        minus,
        all,
        comma: ?*Addr,
        semi: ?*Addr,
        file: []const u21,
    };
};

/// One parsed command (edit.h:33-46 `struct Cmd`). The C's `u.{cmd,text,mtaddr}`
/// union becomes `arg`; `re` stays an (uncompiled) rune slice. `cmdc` is u16 to
/// carry the sleazy `'c'|0x100` = `cd` marker (edit.c:487-490). `num` defaults to 1
/// (the C's getnum returns 1 for "no digits"); `flag_g` is the `s///g` trailing flag.
pub const Cmd = struct {
    addr: ?*Addr = null,
    re: ?[]const u21 = null,
    arg: union(enum) {
        none,
        cmd: *Cmd,
        text: []const u21,
        mtaddr: *Addr,
    } = .none,
    next: ?*Cmd = null,
    num: i32 = 1,
    flag_g: bool = false,
    cmdc: u16,
};

/// Default-address class (edit.h:74-78 `enum Defaddr`): `aNo`/`aDot`/`aAll`. The
/// parse table carries one per command row; cmdexec synthesizes `.`/`*` when a
/// command wants an address and none was written (ecmd.c:86-97).
pub const Defaddr = enum { none, dot, all };

/// The diagnostic sink that replaces `editerror`'s longjmp (R-P10-4). `set` formats
/// into the fixed buffer and RETURNS `error.Edit`, so call sites read
/// `return diag.set("...", .{...})`. Overflow TRUNCATES — a diagnostic must never
/// itself fail. Rides `cmd.Ctx`; `edit.editcmd` surfaces `msg` in one
/// `ed.warning("Edit: {s}\n", ...)`.
pub const Diag = struct {
    buf: [256]u8 = undefined,
    msg: []const u8 = "",

    pub fn set(d: *Diag, comptime fmt: []const u8, args: anytype) error{Edit} {
        var w = std.Io.Writer.fixed(&d.buf);
        w.print(fmt, args) catch {}; // truncate on overflow, never fail
        d.msg = w.buffered();
        return error.Edit;
    }
};

test "ast: Diag.set formats and returns error.Edit" {
    var d: Diag = .{};
    // `set` returns a bare error VALUE (call sites `return diag.set(...)`).
    try std.testing.expectEqual(error.Edit, d.set("bad delimiter {u}", .{@as(u21, 'x')}));
    try std.testing.expectEqualStrings("bad delimiter x", d.msg);
}

test "ast: Diag.set truncates on overflow, never fails" {
    var d: Diag = .{};
    const long = "x" ** 400;
    try std.testing.expectEqual(error.Edit, d.set("{s}", .{long}));
    try std.testing.expect(d.msg.len <= d.buf.len);
}
