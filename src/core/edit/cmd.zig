//! Edit-language dispatch + the SIMPLE command handlers (acme/ecmd.c). Namespace
//! module (S-07 P-1): the comptime `cmdtab` (the C's `struct cmdtab cmdtab[]`,
//! edit.c:18-54, v1 rows) plus `lookup`/`cmdexec` and the non-loop command
//! functions. The loop commands (`s x y g v`) live in `loop.zig` (wave 10d); their
//! rows here point at `loop.{sCmd,xCmd,gCmd}` so parse -> dispatch is complete now.
//!
//! Error model (R-P10-4): every `editerror` becomes `x.diag.set(fmt, args)`
//! returning `error.Edit`; OOM and Text mutation errors propagate in `ast.Error`.
//! The address evaluator returns ENUMERATED errors (addr.Error); this file
//! translates them to a `Diag` message at the eval boundary (R-P10-3):
//! `addr.eval(...) catch |e| ... x.diag.set("{s}", .{addr.describe(e)})`.
//!
//! Elog placement (R-P10-6): the transcript rides `Ctx`, not `File` — v1 is
//! single-file, so one Edit is one Elog and one `apply` on the target body.
//!
//! Ported from larryr/plan9port@337c6ac; cite as `ecmd.c:NN` / `edit.c:NN`.
const std = @import("std");
const ast = @import("ast.zig");
const addr = @import("addr.zig");
const Elog = @import("Elog.zig");
const Regx = @import("Regx.zig");
const loop = @import("loop.zig");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");

/// Per-Edit execution context (ecmd.c's file-static `addr`/`nest` + the C's
/// implicit File/thread state, collapsed). One `Ctx` lives for one `editcmd`
/// call; `addr` is the evaluated target range of the command in flight
/// (ecmd.c:20), rewritten before every dispatch.
pub const Ctx = struct {
    ed: *Editor,
    arena: std.mem.Allocator,
    diag: ast.Diag = .{},
    elog: Elog,
    addr: ast.Address = undefined, // ecmd.c:20 the current command's target
    rx: *Regx, // ed.regx (C-global lastregexp lifetime, R-P10-5)
    nest: u32 = 0, // ecmd.c:17 loop/brace nesting depth
};

/// One dispatch-table row (the C's `struct cmdtab`, edit.h:48-58). Carries the
/// same columns as `parse.zig`'s parse-only projection PLUS the `fn_` pointer;
/// `cmdexec` reads only `cmdc`/`defaddr`/`fn_` (the rest steer the PARSER).
pub const Cmdtab = struct {
    cmdc: u16,
    text: bool = false,
    regexp: bool = false,
    addr: bool = false,
    defcmd: u8 = 0,
    defaddr: ast.Defaddr,
    count: u8 = 0,
    token: ?[]const u8 = null,
    fn_: *const fn (*Ctx, *Text, *ast.Cmd) ast.Error!bool,
};

/// `static char linex[]="\n"` (edit.c:16) — the `=` token terminator set.
const linex: []const u8 = "\n";

/// `cmdtab` (edit.c:18-54), v1 rows (R-P10-7 / side contract §1.1). `{`/`}` are
/// NOT rows (handled structurally in `cmdexec`/`parsecmd`); deferred letters are
/// absent, so they fall to "unknown command".
pub const cmdtab = [_]Cmdtab{
    .{ .cmdc = '\n', .defaddr = .dot, .fn_ = nlCmd }, // edit.c:20 nl_cmd
    .{ .cmdc = 'a', .text = true, .defaddr = .dot, .fn_ = aCmd }, // edit.c:21 a_cmd
    .{ .cmdc = 'c', .text = true, .defaddr = .dot, .fn_ = cCmd }, // edit.c:23 c_cmd
    .{ .cmdc = 'd', .defaddr = .dot, .fn_ = dCmd }, // edit.c:24 d_cmd
    .{ .cmdc = 'g', .regexp = true, .defcmd = 'p', .defaddr = .dot, .fn_ = loop.gCmd }, // edit.c:27 g_cmd
    .{ .cmdc = 'i', .text = true, .defaddr = .dot, .fn_ = iCmd }, // edit.c:28 i_cmd
    .{ .cmdc = 'm', .addr = true, .defaddr = .dot, .fn_ = mCmd }, // edit.c:29 m_cmd
    .{ .cmdc = 'p', .defaddr = .dot, .fn_ = pCmd }, // edit.c:30 p_cmd
    .{ .cmdc = 's', .regexp = true, .count = 1, .defaddr = .dot, .fn_ = loop.sCmd }, // edit.c:32 s_cmd
    .{ .cmdc = 't', .addr = true, .defaddr = .dot, .fn_ = mCmd }, // edit.c:33 m_cmd (copy)
    .{ .cmdc = 'u', .count = 2, .defaddr = .none, .fn_ = uCmd }, // edit.c:34 u_cmd
    .{ .cmdc = 'v', .regexp = true, .defcmd = 'p', .defaddr = .dot, .fn_ = loop.gCmd }, // edit.c:35 g_cmd
    .{ .cmdc = 'x', .regexp = true, .defcmd = 'p', .defaddr = .dot, .fn_ = loop.xCmd }, // edit.c:37 x_cmd
    .{ .cmdc = 'y', .regexp = true, .defcmd = 'p', .defaddr = .dot, .fn_ = loop.xCmd }, // edit.c:38 x_cmd
    .{ .cmdc = '=', .token = linex, .defaddr = .dot, .fn_ = eqCmd }, // edit.c:39 eq_cmd
};

/// `cmdlookup` (edit.c:459-468) over the full table.
pub fn lookup(cmdc: u16) ?*const Cmdtab {
    for (&cmdtab) |*row| {
        if (row.cmdc == cmdc) return row;
    }
    return null;
}

/// `cmdexec` (ecmd.c:62-129), v1: no-window guard dropped (F-9 harness always has
/// a body); the address is evaluated ONCE into `x.addr` before dispatch. `{`
/// evaluates its dot once and reruns each child with `t.q0/q1` reset to it. The
/// no-current-window / `"` / cross-file arms are structurally unreachable in v1.
pub fn cmdexec(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    if (cp.cmdc == '{') return braces(x, t, cp);
    const ct = lookup(cp.cmdc) orelse
        return x.diag.set("unknown command {u} in cmdexec", .{loChar(cp.cmdc)});

    // Address synthesis + one-shot evaluation (ecmd.c:86-107). A missing address
    // on a `defaddr==dot` command is dot; `defaddr==none` (u) forbids an address
    // at parse, so its `x.addr` is a harmless unused dot. `'\n'` with no address
    // recomputes its own range inside `nlCmd`.
    if (cp.addr) |ap| {
        x.addr = try evalAddr(x, ap, addr.mkAddr(t));
    } else {
        x.addr = addr.mkAddr(t);
    }
    return ct.fn_(x, x.addr.t, cp);
}

/// The `{` arm (ecmd.c:110-121): evaluate dot once (the group's address, or the
/// incoming dot), then run each child with `t.q0/q1` reset to that dot. Guarded so
/// a child that grew the buffer past dot cannot run off the end.
fn braces(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    var dot = addr.mkAddr(t);
    if (cp.addr) |ap| dot = try evalAddr(x, ap, dot);
    var child: ?*ast.Cmd = switch (cp.arg) {
        .cmd => |c| c,
        else => null,
    };
    while (child) |c| {
        if (dot.r.q1 > t.file.buffer.len())
            return x.diag.set("dot extends past end of buffer during {{ command", .{});
        t.q0 = dot.r.q0;
        t.q1 = dot.r.q1;
        _ = try cmdexec(x, t, c);
        child = c.next;
    }
    return true;
}

/// The R-P10-3 translation boundary: run the enumerated-error evaluator and turn
/// any non-OOM failure into `error.Edit` + the C's editerror message.
fn evalAddr(x: *Ctx, ap: *const ast.Addr, base: ast.Address) ast.Error!ast.Address {
    return addr.eval(x.rx, ap, base, 0) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return x.diag.set("{s}", .{addr.describe(e)});
    };
}

fn callLineAddr(x: *Ctx, l: usize, base: ast.Address, sign: i8) ast.Error!ast.Address {
    return addr.lineAddr(l, base, sign) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return x.diag.set("{s}", .{addr.describe(e)});
    };
}

// ==========================================================================
// Simple command handlers. Each takes the target Text (x.addr.t) and reads its
// range from x.addr.r; buffered mutations go through x.elog (applied once, in
// reverse, by editcmd after the whole command string parses). Dot-out rules per
// side contract §1.4 (hand-verified against ecmd.c).
// ==========================================================================

/// `a_cmd` (ecmd.c:170-173): append at `addr.r.q1`. `append` (ecmd.c:791-799)
/// buffers the insert and collapses dot to the caret; the apply's
/// insert-at-caret rule then extends dot over the inserted text (elog.c:317-318).
fn aCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    return append(x, t, cp, x.addr.r.q1);
}

/// `i_cmd` (ecmd.c:388-391): insert at `addr.r.q0`.
fn iCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    return append(x, t, cp, x.addr.r.q0);
}

fn append(x: *Ctx, t: *Text, cp: *ast.Cmd, p: usize) ast.Error!bool {
    const runes = textArg(cp);
    if (runes.len > 0) {
        const bytes = try runesToUtf8(x.arena, runes);
        try x.elog.insert(t.file, p, bytes, runes.len); // ecmd.c:793 eloginsert
    }
    t.q0 = p; // ecmd.c:795-796
    t.q1 = p;
    return true;
}

/// `c_cmd` (ecmd.c:213-220): replace the addressed range; dot = the range
/// pre-apply, extended to the new text by the replace caret rule (elog.c:284-285).
fn cCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    const runes = textArg(cp);
    const bytes = try runesToUtf8(x.arena, runes);
    try x.elog.replace(t.file, x.addr.r.q0, x.addr.r.q1, bytes, runes.len);
    t.q0 = x.addr.r.q0; // ecmd.c:217-218
    t.q1 = x.addr.r.q1;
    return true;
}

/// `d_cmd` (ecmd.c:222-232): delete the addressed range; dot collapses to q0.
fn dCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    _ = cp;
    if (x.addr.r.q1 > x.addr.r.q0)
        try x.elog.delete(t.file, x.addr.r.q0, x.addr.r.q1); // ecmd.c:227
    t.q0 = x.addr.r.q0; // ecmd.c:228-229
    t.q1 = x.addr.r.q0;
    return true;
}

/// `m_cmd`/`t_cmd` (ecmd.c:395-438). The destination `addr2` is evaluated from
/// the CURRENT dot (`mkaddr`, ecmd.c:431). `t` copies the source to `addr2.q1`;
/// `m` moves — delete+copy or copy+delete by relative position, no-op for
/// move-to-self, else "move overlaps itself". Dot is NOT set explicitly; the log
/// adjusts the old dot coordinate.
fn mCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    const mtaddr = switch (cp.arg) {
        .mtaddr => |m| m,
        else => return x.diag.set("bad address", .{}),
    };
    const src = x.addr.r; // frozen before addr2 eval
    const addr2 = try evalAddr(x, mtaddr, addr.mkAddr(t));
    const dst = addr2.r;
    if (cp.cmdc == 'm') { // move (ecmd.c:412-424)
        if (src.q1 <= dst.q0) {
            try x.elog.delete(t.file, src.q0, src.q1);
            try copyRange(x, t, src, dst.q1);
        } else if (src.q0 >= dst.q1) {
            try copyRange(x, t, src, dst.q1);
            try x.elog.delete(t.file, src.q0, src.q1);
        } else if (src.q0 == dst.q0 and src.q1 == dst.q1) {
            // move to self: no-op (ecmd.c:420-421)
        } else {
            return x.diag.set("move overlaps itself", .{}); // ecmd.c:423
        }
    } else { // t (copy, ecmd.c:434-437)
        try copyRange(x, t, src, dst.q1);
    }
    return true;
}

/// `copy` (ecmd.c:395-410): buffer an insert of the FROZEN source text at `dest`.
fn copyRange(x: *Ctx, t: *Text, src: ast.Range, dest: usize) ast.Error!void {
    if (src.q1 <= src.q0) return;
    const n = src.q1 - src.q0;
    const bytes = try readRange(x.arena, t, src.q0, n);
    try x.elog.insert(t.file, dest, bytes, n);
}

/// `p_cmd`/`pdisplay` (ecmd.c:441-445, 800-825): report the addressed range to
/// the warning sink (v1's +Errors surrogate, R-P9-6); dot = the range.
fn pCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    _ = cp;
    const nc = t.file.buffer.len();
    const q0 = x.addr.r.q0;
    var q1 = x.addr.r.q1;
    if (q1 > nc) q1 = nc; // ecmd.c:807-808
    if (q1 > q0) {
        const bytes = try readRange(x.arena, t, q0, q1 - q0);
        x.ed.warning("{s}", .{bytes});
    } else {
        x.ed.warning("", .{}); // empty range still "prints" nothing (test 12)
    }
    t.q0 = x.addr.r.q0; // ecmd.c:823-824
    t.q1 = x.addr.r.q1;
    return true;
}

/// `eq_cmd`/`printposn` (ecmd.c:694-766). Three modes keyed on the token: `` (line
/// range), `#` (char range), `+` (line+char). The file's name prefixes the report
/// when set (ecmd.c:705-706) — v1 uses `File.name` (empty ⇒ no prefix). Dot is
/// UNTOUCHED. Line numbers are 1-based; the trailing-newline shave matches
/// ecmd.c:719-720.
fn eqCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    const arg = textArg(cp);
    const buf = &t.file.buffer;
    const q0 = x.addr.r.q0;
    const q1 = x.addr.r.q1;

    if (arg.len == 0) { // PosnLine (ecmd.c:717-728)
        printName(x, t);
        const line0 = buf.lineOfRune(q0);
        const line1 = buf.lineOfRune(q1);
        const l1 = 1 + line0;
        var l2 = l1 + (line1 - line0);
        if (q1 > 0 and q1 > q0 and buf.runeAt(q1 - 1) == '\n') l2 -= 1;
        if (l2 != l1) x.ed.warning("{d},{d}\n", .{ l1, l2 }) else x.ed.warning("{d}\n", .{l1});
    } else if (arg.len == 1 and arg[0] == '#') { // PosnChars (ecmd.c:709-714)
        printName(x, t);
        if (q1 != q0) x.ed.warning("#{d},#{d}\n", .{ q0, q1 }) else x.ed.warning("#{d}\n", .{q0});
    } else if (arg.len == 1 and arg[0] == '+') { // PosnLineChars (ecmd.c:730-741)
        printName(x, t);
        const line0 = buf.lineOfRune(q0);
        const line1 = buf.lineOfRune(q1);
        const l1 = 1 + line0;
        const l2 = l1 + (line1 - line0);
        const r1 = colOf(buf, q0);
        var r2: usize = if (line1 > line0) colOf(buf, q1) else (q1 - q0);
        if (l2 == l1) r2 += r1;
        if (l2 != l1)
            x.ed.warning("{d}+#{d},{d}+#{d}\n", .{ l1, r1, l2, r2 })
        else
            x.ed.warning("{d}+#{d}\n", .{ l1, r1 });
    } else {
        return x.diag.set("newline expected", .{}); // ecmd.c:762-763
    }
    return true;
}

/// Chars since the last '\n' strictly before `pos` (the C's nlcount column output).
fn colOf(buf: *const Buffer, pos: usize) usize {
    var p = pos;
    while (p > 0 and buf.runeAt(p - 1) != '\n') p -= 1;
    return pos - p;
}

fn printName(x: *Ctx, t: *Text) void {
    const name = t.file.name.items;
    if (name.len > 0) x.ed.warning("{s}:", .{name}); // ecmd.c:705-706
}

/// `nl_cmd` (ecmd.c:769-788). With NO address: snap dot to whole-line boundaries;
/// if that equals the current dot, advance one line. With an address: `x.addr` is
/// already the evaluated target. Either way, `textshow` scrolls+selects it.
fn nlCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    if (cp.addr == null) {
        const base = addr.mkAddr(t);
        const lo = try callLineAddr(x, 0, base, -1); // ecmd.c:776
        const hi = try callLineAddr(x, 0, base, 1); // ecmd.c:777
        var r = lo.r;
        r.q1 = hi.r.q1; // ecmd.c:778
        if (r.q0 == t.q0 and r.q1 == t.q1) { // ecmd.c:779-782 already exact ⇒ advance
            const nxt = try callLineAddr(x, 1, base, 1);
            r = nxt.r;
        }
        x.addr = .{ .r = r, .t = t };
    }
    try t.show(x.addr.r.q0, x.addr.r.q1, true); // ecmd.c:785 textshow
    return true;
}

/// `u_cmd` (ecmd.c:537-553). `num` is the signed count (parse `count==2` allows a
/// leading `-`); negative ⇒ redo. Step until the count runs out or the file's seq
/// stops moving; `show` the last reversed range (R-P9-10). The undo/redo bypasses
/// the frame, so the show refills + reselects.
fn uCmd(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    _ = x; // u touches File.undo/redo directly; no elog/diag needed
    var n = cp.num;
    var isundo = true;
    if (n < 0) { // ecmd.c:543-546
        n = -n;
        isundo = false;
    }
    const f = t.file;
    var oseq: i64 = -1; // ecmd.c:547
    var last: ?ast.Range = null;
    while (n > 0 and @as(i64, @intCast(f.seq)) != oseq) : (n -= 1) { // ecmd.c:548-551
        oseq = @intCast(f.seq);
        const r = if (isundo) try f.undo() else try f.redo();
        if (r) |rr| last = rr;
    }
    if (last) |r| try t.show(r.q0, r.q1, true); // R-P9-10 (winundo's textshow)
    return true;
}

// --- shared helpers -------------------------------------------------------

fn textArg(cp: *ast.Cmd) []const u21 {
    return switch (cp.arg) {
        .text => |tx| tx,
        else => &[_]u21{},
    };
}

/// Low byte of a command char, for messages (strips the `'c'|0x100` cd marker).
fn loChar(cmdc: u16) u21 {
    return @intCast(cmdc & 0xff);
}

/// Encode a rune slice to arena-owned UTF-8 (elog copies it into its own store).
fn runesToUtf8(a: std.mem.Allocator, runes: []const u21) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var tmp: [4]u8 = undefined;
    for (runes) |r| {
        const n = std.unicode.utf8Encode(r, &tmp) catch
            std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
        try buf.appendSlice(a, tmp[0..n]);
    }
    return buf.toOwnedSlice(a);
}

/// Read `[q0, q0+nrunes)` of the (FROZEN) buffer as arena-owned UTF-8.
fn readRange(a: std.mem.Allocator, t: *Text, q0: usize, nrunes: usize) error{OutOfMemory}![]u8 {
    if (nrunes == 0) return a.alloc(u8, 0);
    const dest = try a.alloc(u8, nrunes * Buffer.max_bytes_per_rune);
    defer a.free(dest);
    return a.dupe(u8, t.file.buffer.read(q0, nrunes, dest));
}

// ==========================================================================
// Table-shape pins. The command tests (7-17, 32-35) drive `edit.editcmd` and
// live in edit.zig; here we only pin the dispatch table's shape.
// ==========================================================================
const testing = std.testing;

test "cmd: table has the v1 command set with matching defaddr" {
    try testing.expectEqual(@as(usize, 15), cmdtab.len);
    const cmds = "\na c d g i m p s t u v x y =";
    _ = cmds;
    // Every v1 command resolves; a deferred/unknown letter does not.
    for ([_]u16{ '\n', 'a', 'c', 'd', 'g', 'i', 'm', 'p', 's', 't', 'u', 'v', 'x', 'y', '=' }) |c| {
        try testing.expect(lookup(c) != null);
    }
    for ([_]u16{ 'b', 'e', 'f', 'r', 'w', 'B', 'D', 'X', 'Y', 'z', 'c' | 0x100 }) |c| {
        try testing.expect(lookup(c) == null);
    }
    // u is the only aNo row; the loop rows carry a defcmd of 'p'.
    try testing.expect(lookup('u').?.defaddr == .none);
    try testing.expectEqual(@as(u8, 'p'), lookup('x').?.defcmd);
    try testing.expectEqual(@as(u8, 'p'), lookup('g').?.defcmd);
    // s carries a count of 1; u a count of 2 (sign allowed).
    try testing.expectEqual(@as(u8, 1), lookup('s').?.count);
    try testing.expectEqual(@as(u8, 2), lookup('u').?.count);
}
