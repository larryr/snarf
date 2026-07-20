//! The Edit-language parser (edit.c:196-687). Turns a `[]const u21` command line
//! into an arena-allocated `ast.Cmd` tree. It does NOT compile regexps and does NOT
//! import Regx (R-P10 note): `/re/`, `?re?`, `"re"` and the `x`/`g`/`s` pattern are
//! stored as raw `[]const u21` arena slices; addr.zig/loop.zig compile them at eval
//! time. Imports are `ast` + `std` + `Editor` (for the persistent `edit_lastpat`
//! last-regexp cache, edit.c:181) ONLY.
//!
//! The C's `editerror` longjmp becomes `error.Edit` + a message parked in `Diag`
//! (R-P10-4); the fixed input buffer / RBUFSIZE caps (edit.c:157-160,595) are
//! dropped in the port (no fixed buffers), flagged. The parser consumes runes that
//! `editcmd` has already UTF-8-decoded and newline-terminated (wave 10c); these
//! tests decode inline.
//!
//! Ported from larryr/plan9port@337c6ac; cite as `edit.c:NN`.
const std = @import("std");
const ast = @import("ast.zig");
const Editor = @import("../Editor.zig");
/// Argument-collection helpers (getregexp/getrhs/collecttext/collecttoken), split
/// out to keep both files under the ~400-line cap (S-07). Circular import is fine:
/// parse_text only needs the `Parser` TYPE + its pub primitives.
const text = @import("parse_text.zig");

/// Parse-relevant projection of the C's `struct cmdtab` (edit.h:48-58, table
/// edit.c:18-54): the columns the PARSER needs, with NO `fn` pointers. Wave 10c's
/// `cmd.zig` builds the real dispatch table (same rows + `fn_`) separately; a
/// shape-consistency test will pin the two together at 10c. Each row is cited to
/// its edit.c line.
const ParseRow = struct {
    cmdc: u16,
    text: bool = false,
    regexp: bool = false,
    addr: bool = false,
    defcmd: u8 = 0,
    defaddr: ast.Defaddr,
    count: u8 = 0,
    token: ?[]const u21 = null,
};

/// `static char linex[]="\n"` (edit.c:16) — the `=` command's token terminator set.
const linex = &[_]u21{'\n'};

/// The v1 command set (R-P10-7 / side contract §1.1). Deferred letters
/// (`b e f r w B D X Y < | >`) are DELIBERATELY absent, so a bare `Edit b` fails
/// `lookup` and falls to the `default` "unknown command" arm — the v1-honest
/// divergence flagged in R-P10-7. `{`/`}` are not table rows in the C either; they
/// are handled structurally in `parsecmd`.
const parse_tab = [_]ParseRow{
    .{ .cmdc = '\n', .defaddr = .dot }, // edit.c:20 nl_cmd
    .{ .cmdc = 'a', .text = true, .defaddr = .dot }, // edit.c:21 a_cmd
    .{ .cmdc = 'c', .text = true, .defaddr = .dot }, // edit.c:23 c_cmd
    .{ .cmdc = 'd', .defaddr = .dot }, // edit.c:24 d_cmd
    .{ .cmdc = 'g', .regexp = true, .defcmd = 'p', .defaddr = .dot }, // edit.c:27 g_cmd
    .{ .cmdc = 'i', .text = true, .defaddr = .dot }, // edit.c:28 i_cmd
    .{ .cmdc = 'm', .addr = true, .defaddr = .dot }, // edit.c:29 m_cmd
    .{ .cmdc = 'p', .defaddr = .dot }, // edit.c:30 p_cmd
    .{ .cmdc = 's', .regexp = true, .defaddr = .dot, .count = 1 }, // edit.c:32 s_cmd
    .{ .cmdc = 't', .addr = true, .defaddr = .dot }, // edit.c:33 m_cmd
    .{ .cmdc = 'u', .defaddr = .none, .count = 2 }, // edit.c:34 u_cmd
    .{ .cmdc = 'v', .regexp = true, .defcmd = 'p', .defaddr = .dot }, // edit.c:35 g_cmd
    .{ .cmdc = 'x', .regexp = true, .defcmd = 'p', .defaddr = .dot }, // edit.c:37 x_cmd
    .{ .cmdc = 'y', .regexp = true, .defcmd = 'p', .defaddr = .dot }, // edit.c:38 x_cmd
    .{ .cmdc = '=', .defaddr = .dot, .token = linex }, // edit.c:39 eq_cmd
};

/// `cmdlookup` (edit.c:459-468). Module-private; `cmd.zig` has its own over the full
/// table with fn pointers.
fn lookup(cmdc: u16) ?*const ParseRow {
    for (&parse_tab) |*row| {
        if (row.cmdc == cmdc) return row;
    }
    return null;
}

/// `c` present and equal to `ch` — the null-safe form of the C's raw int compares.
/// pub: `parse_text.zig` shares it.
pub inline fn is(c: ?u21, ch: u21) bool {
    return c != null and c.? == ch;
}

pub const Parser = struct {
    arena: std.mem.Allocator,
    ed: *Editor,
    diag: *ast.Diag,
    s: []const u21,
    pos: usize = 0,

    pub fn init(arena: std.mem.Allocator, ed: *Editor, diag: *ast.Diag, runes: []const u21) Parser {
        return .{ .arena = arena, .ed = ed, .diag = diag, .s = runes };
    }

    // --- lexing primitives (edit.c:196-249) -------------------------------

    /// `getch` (edit.c:196-201): consume one rune, or null at end. Like the C, it
    /// does NOT advance past the end, so a following `ungetch` stays in bounds.
    pub fn getch(p: *Parser) ?u21 {
        if (p.pos >= p.s.len) return null;
        defer p.pos += 1;
        return p.s[p.pos];
    }

    /// `nextc` (edit.c:203-208): peek without consuming.
    pub fn nextc(p: *Parser) ?u21 {
        if (p.pos >= p.s.len) return null;
        return p.s[p.pos];
    }

    /// `ungetch` (edit.c:210-215): back up one. Callers only invoke it after a
    /// `getch` that returned a real rune, so `pos > 0`.
    pub fn ungetch(p: *Parser) void {
        p.pos -= 1;
    }

    /// `getnum` (edit.c:217-234): optional leading `-` (only when `signok > 1`),
    /// then digits. "no number" defaults to the sign (i.e. 1 / -1).
    fn getnum(p: *Parser, signok: u8) i32 {
        var sign: i32 = 1;
        if (signok > 1 and is(p.nextc(), '-')) {
            sign = -1;
            _ = p.getch();
        }
        const c0 = p.nextc();
        if (c0 == null or c0.? < '0' or c0.? > '9') return sign; // no digits -> ±1
        var n: i32 = 0;
        while (p.nextc()) |c| {
            if (c < '0' or c > '9') break;
            _ = p.getch();
            n = n * 10 + @as(i32, @intCast(c - '0'));
        }
        return sign * n;
    }

    /// `cmdskipbl` (edit.c:236-245): skip spaces/tabs, return the first non-blank
    /// (left UNconsumed via ungetch), or null at end.
    pub fn skipbl(p: *Parser) ?u21 {
        var c = p.getch();
        while (c != null and (c.? == ' ' or c.? == '\t')) c = p.getch();
        if (c != null) p.ungetch();
        return c;
    }

    /// `okdelim` (edit.c:361-367): alnum and backslash are illegal delimiters.
    pub fn okdelim(p: *Parser, c: u21) error{Edit}!void {
        if (c == '\\' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))
            return p.diag.set("bad delimiter {u}", .{c});
    }

    /// `atnl` (edit.c:369-378): the rest of the line must be blank up to `\n`.
    pub fn atnl(p: *Parser) ast.Error!void {
        _ = p.skipbl();
        const c = p.getch();
        if (!is(c, '\n')) return p.diag.set("newline expected (saw {u})", .{c orelse @as(u21, 0)});
    }

    // --- addresses (edit.c:601-686) ---------------------------------------

    /// `simpleaddr` (edit.c:601-664): one address atom plus its right-recursive
    /// `+`/`-` chain, inserting the implicit `+` between adjacent terms
    /// (e.g. `/x/2` ⇒ `/x/` `+` `2`). Returns null when nothing addresses here.
    fn simpleaddr(p: *Parser) ast.Error!?*ast.Addr {
        const kind: ast.Addr.Kind = switch (p.skipbl() orelse return null) {
            '#' => blk: {
                _ = p.getch();
                break :blk .{ .char = @intCast(p.getnum(1)) };
            },
            '0'...'9' => .{ .line = @intCast(p.getnum(1)) },
            '/' => blk: {
                _ = p.getch();
                break :blk .{ .re = try text.getregexp(p, '/') };
            },
            '?' => blk: {
                _ = p.getch();
                break :blk .{ .back_re = try text.getregexp(p, '?') };
            },
            '"' => blk: {
                _ = p.getch();
                break :blk .{ .file = try text.getregexp(p, '"') };
            },
            '.' => blk: {
                _ = p.getch();
                break :blk .dot;
            },
            '$' => blk: {
                _ = p.getch();
                break :blk .end;
            },
            '+' => blk: {
                _ = p.getch();
                break :blk .plus;
            },
            '-' => blk: {
                _ = p.getch();
                break :blk .minus;
            },
            '\'' => blk: {
                _ = p.getch();
                break :blk .mark;
            },
            else => return null,
        };
        const node = try p.arena.create(ast.Addr);
        node.* = .{ .kind = kind };
        if (try p.simpleaddr()) |nxt| {
            const k = std.meta.activeTag(kind);
            const is_quote = k == .file;
            var insert = false;
            switch (nxt.kind) {
                .dot, .end, .mark => if (!is_quote) return p.diag.set("bad address syntax", .{}),
                .file => return p.diag.set("bad address syntax", .{}),
                .line, .char => if (!is_quote and k != .plus and k != .minus) {
                    insert = true;
                },
                .re, .back_re => if (k != .plus and k != .minus) {
                    insert = true;
                },
                .plus, .minus => {},
                else => unreachable, // simpleaddr never yields comma/semi/all
            }
            if (insert) {
                const plus = try p.arena.create(ast.Addr);
                plus.* = .{ .kind = .plus, .next = nxt }; // insert the missing '+'
                node.next = plus;
            } else {
                node.next = nxt;
            }
        }
        return node;
    }

    /// `compoundaddr` (edit.c:666-686): a `,`/`;` pair, right-recursive. The left
    /// side (null ⇒ line 0) rides the `comma`/`semi` payload; the right side rides
    /// `next`. A `,`/`;` whose own right side is a left-less pair is a syntax error.
    fn compoundaddr(p: *Parser) ast.Error!?*ast.Addr {
        const left = try p.simpleaddr();
        const t = p.skipbl();
        if (!is(t, ',') and !is(t, ';')) return left;
        _ = p.getch();
        const next = try p.compoundaddr();
        if (next) |n| switch (n.kind) {
            .comma => |l| if (l == null) return p.diag.set("bad address syntax", .{}),
            .semi => |l| if (l == null) return p.diag.set("bad address syntax", .{}),
            else => {},
        };
        const node = try p.arena.create(ast.Addr);
        node.* = .{
            .kind = if (t.? == ',') .{ .comma = left } else .{ .semi = left },
            .next = next,
        };
        return node;
    }

    // --- the command (edit.c:470-563) -------------------------------------

    /// `parsecmd` (edit.c:470-563): one command (with its `{}` children). Returns
    /// null at end of input and for a `}` that closes a group. Everything is
    /// arena-allocated.
    pub fn parsecmd(p: *Parser, nest: u32) ast.Error!?*ast.Cmd {
        var cmd: ast.Cmd = .{ .cmdc = 0 };
        cmd.addr = try p.compoundaddr();
        if (p.skipbl() == null) return null;
        const c0 = p.getch() orelse return null;
        var cc: u16 = @intCast(c0); // a command char is ASCII/BMP; fits u16
        // sleazy two-character `cd` case (edit.c:487-490): 'c'|0x100 has no table
        // row, so it becomes "unknown command" — keeping `Edit cd /x` from parsing
        // as `c` with text "d /x".
        if (cc == 'c' and is(p.nextc(), 'd')) {
            _ = p.getch();
            cc = 'c' | 0x100;
        }
        cmd.cmdc = cc;

        if (lookup(cc)) |ct| {
            if (cc == '\n') return try p.finish(cmd); // nl_cmd works it all out
            if (ct.defaddr == .none and cmd.addr != null)
                return p.diag.set("command takes no address", .{});
            if (ct.count != 0) cmd.num = p.getnum(ct.count);
            if (ct.regexp) try p.parseRegexp(&cmd, cc);
            if (ct.addr) {
                cmd.arg = .{ .mtaddr = (try p.simpleaddr()) orelse return p.diag.set("bad address", .{}) };
            }
            if (ct.defcmd != 0) {
                // bare newline after x/y/g/v ⇒ synthesize the default child `p`
                // (edit.c:524-530); otherwise recurse for the loop body.
                if (is(p.skipbl(), '\n')) {
                    _ = p.getch();
                    const child = try p.arena.create(ast.Cmd);
                    child.* = .{ .cmdc = ct.defcmd };
                    cmd.arg = .{ .cmd = child };
                } else {
                    cmd.arg = .{ .cmd = (try p.parsecmd(nest)) orelse return p.diag.set("defcmd", .{}) };
                }
            } else if (ct.text) {
                cmd.arg = .{ .text = try text.collecttext(p) };
            } else if (ct.token) |tok| {
                cmd.arg = .{ .text = try text.collecttoken(p, tok) };
            } else {
                try p.atnl();
            }
            return try p.finish(cmd);
        }

        switch (cc) {
            '{' => {
                // A `{}` group: chain child commands via `next` until parsecmd
                // returns null (a `}` at nest+1, or end of input).
                var head: ?*ast.Cmd = null;
                var last: ?*ast.Cmd = null;
                while (true) {
                    if (is(p.skipbl(), '\n')) _ = p.getch();
                    const ncp = try p.parsecmd(nest + 1);
                    if (last) |l| l.next = ncp else head = ncp;
                    if (ncp == null) break;
                    last = ncp;
                }
                if (head) |h| cmd.arg = .{ .cmd = h };
                return try p.finish(cmd);
            },
            '}' => {
                try p.atnl();
                if (nest == 0) return p.diag.set("right brace with no left brace", .{});
                return null;
            },
            else => return p.diag.set("unknown command {u}", .{@as(u21, cc)}),
        }
    }

    /// The `ct->regexp` arm of parsecmd (edit.c:500-519). Bare `x`/`X` (pattern is a
    /// blank or newline) leaves `cmd.re == null` (the `.*\n` linelooper default);
    /// `y` is DELIBERATELY excluded from that shortcut (the C tests only `x`/`X`), so
    /// a bare `y` errors "no address". `s` additionally collects the rhs + trailing
    /// `g` flag.
    fn parseRegexp(p: *Parser, cmd: *ast.Cmd, cc: u16) ast.Error!void {
        const bare = (cc == 'x' or cc == 'X') and blk: {
            const c = p.nextc();
            break :blk (c == null or c.? == ' ' or c.? == '\t' or c.? == '\n');
        };
        if (bare) return; // cmd.re stays null
        _ = p.skipbl();
        const d = p.getch();
        if (d == null or d.? == '\n') return p.diag.set("no address", .{});
        try p.okdelim(d.?);
        cmd.re = try text.getregexp(p, d.?);
        if (cc == 's') {
            var rhs: std.ArrayList(u21) = .empty;
            try text.getrhs(p, &rhs, d.?, 's');
            cmd.arg = .{ .text = rhs.items };
            if (is(p.nextc(), d.?)) {
                _ = p.getch();
                if (is(p.nextc(), 'g')) {
                    _ = p.getch();
                    cmd.flag_g = true;
                }
            }
        }
    }

    /// `Return:` — commit the local `cmd` to a fresh arena node (edit.c:557-559).
    fn finish(p: *Parser, cmd: ast.Cmd) ast.Error!*ast.Cmd {
        const cp = try p.arena.create(ast.Cmd);
        cp.* = cmd;
        return cp;
    }
};

// ===========================================================================
// Tests (side contract §3, tests 1-6, plus the parse-shape pins). A tiny helper
// decodes a UTF-8 command line into runes (editcmd's job in 10c) and runs one
// `parsecmd` against a throwaway Editor + arena.
// ===========================================================================
const testing = std.testing;

/// Decode `cmd` to runes in `arena`, appending the '\n' editcmd guarantees
/// (edit.c:168-169).
fn toRunes(arena: std.mem.Allocator, cmd: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var it = (try std.unicode.Utf8View.init(cmd)).iterator();
    while (it.nextCodepoint()) |c| try out.append(arena, c);
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
    return out.items;
}

/// A parse harness: owns an arena + a fresh Editor, parses one command.
const PT = struct {
    arena_state: std.heap.ArenaAllocator,
    ed: Editor,
    diag: ast.Diag = .{},

    fn init() PT {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .ed = Editor.init(testing.allocator),
        };
    }
    fn deinit(pt: *PT) void {
        pt.ed.deinit();
        pt.arena_state.deinit();
    }
    fn parse(pt: *PT, cmd: []const u8) !?*ast.Cmd {
        const a = pt.arena_state.allocator();
        const runes = try toRunes(a, cmd);
        var p = Parser.init(a, &pt.ed, &pt.diag, runes);
        return p.parsecmd(0);
    }
};

fn expectRunes(want: []const u8, got: []const u21) !void {
    var buf: std.ArrayList(u21) = .empty;
    defer buf.deinit(testing.allocator);
    var it = (try std.unicode.Utf8View.init(want)).iterator();
    while (it.nextCodepoint()) |c| try buf.append(testing.allocator, c);
    try testing.expectEqualSlices(u21, buf.items, got);
}

test "edit: parser builds a/c/i text both forms" {
    // Inline form: a/hi/ -> text "hi".
    {
        var pt = PT.init();
        defer pt.deinit();
        const cp = (try pt.parse("a/hi/")).?;
        try testing.expectEqual(@as(u16, 'a'), cp.cmdc);
        try expectRunes("hi", cp.arg.text);
    }
    // Block form: the ".\n" terminator is stripped; kept lines keep their newline.
    {
        var pt = PT.init();
        defer pt.deinit();
        const cp = (try pt.parse("a\nhi\nthere\n.\n")).?;
        try testing.expectEqual(@as(u16, 'a'), cp.cmdc);
        try expectRunes("hi\nthere\n", cp.arg.text);
    }
    // c and i share collecttext.
    {
        var pt = PT.init();
        defer pt.deinit();
        const cp = (try pt.parse("i/x/")).?;
        try testing.expectEqual(@as(u16, 'i'), cp.cmdc);
        try expectRunes("x", cp.arg.text);
    }
}

test "edit: getrhs escapes" {
    // \n -> newline.
    {
        var pt = PT.init();
        defer pt.deinit();
        const cp = (try pt.parse("s/a/\\n/")).?;
        try expectRunes("a", cp.re.?);
        try expectRunes("\n", cp.arg.text);
    }
    // \,  with ',' as the delimiter -> literal ','.
    {
        var pt = PT.init();
        defer pt.deinit();
        const cp = (try pt.parse("s,a,\\,x,")).?;
        try expectRunes(",x", cp.arg.text);
    }
    // s preserves \1 and \& RAW for s_cmd.
    {
        var pt = PT.init();
        defer pt.deinit();
        const cp = (try pt.parse("s/a/\\1\\&/")).?;
        try expectRunes("\\1\\&", cp.arg.text);
    }
}

test "edit: bad delimiter rejected" {
    var pt = PT.init();
    defer pt.deinit();
    try testing.expectError(error.Edit, pt.parse("sxaxbx"));
    try testing.expect(std.mem.indexOf(u8, pt.diag.msg, "bad delimiter") != null);
}

test "edit: unknown command" {
    // `z` is not a v1 command: parsecmd's default arm errors (edit.c:555). This
    // fires at PARSE, not exec — cmdexec's i<0 path (ecmd.c:123) is defensive and
    // unreachable for a genuine unknown, since parsecmd already rejected it.
    {
        var pt = PT.init();
        defer pt.deinit();
        try testing.expectError(error.Edit, pt.parse("z"));
        try testing.expect(std.mem.indexOf(u8, pt.diag.msg, "unknown command") != null);
    }
    // `cd` -> the 'c'|0x100 sleazy case -> no table row -> "unknown command".
    {
        var pt = PT.init();
        defer pt.deinit();
        try testing.expectError(error.Edit, pt.parse("cd /tmp"));
        try testing.expect(std.mem.indexOf(u8, pt.diag.msg, "unknown command") != null);
    }
}

test "edit: right brace without left" {
    // A `}` at nest 0 errors.
    {
        var pt = PT.init();
        defer pt.deinit();
        try testing.expectError(error.Edit, pt.parse("}"));
        try testing.expect(std.mem.indexOf(u8, pt.diag.msg, "right brace") != null);
    }
    // An UNCLOSED `{` does NOT error: the inner parsecmd hits end-of-input and
    // returns null, terminating the group (pinned behavior — the loop just ends).
    {
        var pt = PT.init();
        defer pt.deinit();
        const cp = (try pt.parse("{ d")).?;
        try testing.expectEqual(@as(u16, '{'), cp.cmdc);
        try testing.expectEqual(@as(u16, 'd'), cp.arg.cmd.cmdc);
    }
}

test "edit: command takes no address" {
    // u has defaddr==aNo; a leading address is rejected at parse.
    var pt = PT.init();
    defer pt.deinit();
    try testing.expectError(error.Edit, pt.parse("2u"));
    try testing.expect(std.mem.indexOf(u8, pt.diag.msg, "takes no address") != null);
}

// --- parse-shape pins -----------------------------------------------------

test "edit: /x/2 inserts the implicit plus" {
    var pt = PT.init();
    defer pt.deinit();
    const cp = (try pt.parse("/x/2d")).?;
    const a0 = cp.addr.?;
    try expectRunes("x", a0.kind.re);
    const a1 = a0.next.?;
    try testing.expect(a1.kind == .plus); // the inserted '+'
    const a2 = a1.next.?;
    try testing.expectEqual(@as(usize, 2), a2.kind.line);
    try testing.expectEqual(@as(?*ast.Addr, null), a2.next);
}

test "edit: bare comma is a null,null pair" {
    var pt = PT.init();
    defer pt.deinit();
    const cp = (try pt.parse(",d")).?;
    const a = cp.addr.?;
    try testing.expect(a.kind == .comma);
    try testing.expectEqual(@as(?*ast.Addr, null), a.kind.comma); // left missing
    try testing.expectEqual(@as(?*ast.Addr, null), a.next); // right missing
}

test "edit: s2/a/b/g fills num and flag" {
    var pt = PT.init();
    defer pt.deinit();
    const cp = (try pt.parse("s2/a/b/g")).?;
    try testing.expectEqual(@as(i32, 2), cp.num);
    try testing.expect(cp.flag_g);
    try expectRunes("a", cp.re.?);
    try expectRunes("b", cp.arg.text);
}

test "edit: bare x has null re and a synthesized child p" {
    var pt = PT.init();
    defer pt.deinit();
    const cp = (try pt.parse("x")).?;
    try testing.expectEqual(@as(u16, 'x'), cp.cmdc);
    try testing.expectEqual(@as(?[]const u21, null), cp.re);
    try testing.expectEqual(@as(u16, 'p'), cp.arg.cmd.cmdc);
}

test "edit: lastpat reuse across parser runs; fresh editor errors" {
    // Same Editor across two Parser runs: s//y/ reuses the "a" from s/a/x/.
    {
        var pt = PT.init();
        defer pt.deinit();
        const first = (try pt.parse("s/a/x/")).?;
        try expectRunes("a", first.re.?);
        const second = (try pt.parse("s//y/")).?;
        try expectRunes("a", second.re.?); // reused
        try expectRunes("y", second.arg.text);
    }
    // Fresh Editor: an empty pattern with no prior lastpat is an error.
    {
        var pt = PT.init();
        defer pt.deinit();
        try testing.expectError(error.Edit, pt.parse("s//x/"));
        try testing.expect(std.mem.indexOf(u8, pt.diag.msg, "no regular expression") != null);
    }
}

test "edit: = collects a token argument" {
    var pt = PT.init();
    defer pt.deinit();
    const cp = (try pt.parse("=#")).?;
    try testing.expectEqual(@as(u16, '='), cp.cmdc);
    try expectRunes("#", cp.arg.text);
}
