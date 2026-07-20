//! The Pike-VM executor — ported from acme's `regx.c` (larryr/plan9port@337c6ac):
//! `addinst` (534-550), `rxnull`/`classmatch` (512-556), `rxexecute` (559-692),
//! `newmatch` (694-700), `rxbexecute` (702-831), `bnewmatch` (833-843).
//!
//! Thread lists (`Regx.list[2][nlist+1]`) and the match register `sel` are the C's
//! globals `list`/`sel`, moved onto the struct / into locals. The machine runs one
//! step per character; `addinst` dedupes by inst index, keeping the thread with the
//! smaller `se[0].q0` (leftmost preference). Internally every position is `isize`
//! so the sentinels port verbatim (`sel[0].q0 = -1` no-match; bexecute's `-p` seed);
//! the public `Rangeset` is unsigned, converted only on return.
//!
//! End/wrap machinery (regx.c:587-601): at `p >= eof || p >= nc` the loop runs one
//! extra click with `c = 0` so END/RBRA can fire at eof; on the *second* expiry it
//! wraps to the top — but ONLY when `eof == Infinity` (our `eof == null`). A bounded
//! `eof` returns instead. Semantics pins: ANY excludes `\n`; BOL at p==0 or after a
//! `\n`; EOL only when the current char IS `\n` (so `$` never matches at a bare eof).
const std = @import("std");
const Regx = @import("Regx.zig");
const Buffer = @import("../Buffer.zig");
const Source = Regx.Source;
const Rangeset = Regx.Rangeset;
const SRangeset = Regx.SRangeset;
const ClassItem = Regx.ClassItem;
const Ilist = Regx.Ilist;
const ExecError = Regx.ExecError;
const nlist = Regx.nlist;
const nrange = Regx.nrange;
const zero_srangeset = Regx.zero_srangeset;

/// regx.c's `Infinity` (0x7FFFFFFF): the "search to end AND wrap" sentinel.
const Infinity: isize = 0x7FFFFFFF;

fn srcLen(src: Source) usize {
    return switch (src) {
        .buffer => |b| b.len(),
        .runes => |r| r.len,
    };
}

fn srcAt(src: Source, p: usize) u21 {
    return switch (src) {
        .buffer => |b| b.runeAt(p),
        .runes => |r| r[p],
    };
}

/// addinst (regx.c:534-550): append `inst` to the pending list `l` unless already
/// present; on a duplicate keep the thread whose `se[0].q0` is smaller (leftmost
/// preference). `*l` must be pending (not yet stepped) — the C's documented caveat.
fn addinst(l: []Ilist, inst: u16, sep: *const SRangeset) bool {
    var i: usize = 0;
    while (l[i].inst) |pinst| : (i += 1) {
        if (pinst == inst) {
            if (sep[0].q0 < l[i].se[0].q0) l[i].se = sep.*;
            return false;
        }
    }
    l[i].inst = inst;
    l[i].se = sep.*;
    l[i + 1].inst = null;
    return true;
}

/// classmatch (regx.c:512-527): membership in class `items`, negation inverting.
fn classmatch(items: []const ClassItem, c: u21, negate: bool) bool {
    for (items) |it| switch (it) {
        .single => |s| if (s == c) return !negate,
        .range => |rg| if (rg[0] <= c and c <= rg[1]) return !negate,
    };
    return negate;
}

/// newmatch (regx.c:694-700): keep leftmost, then longest.
fn newmatch(sel: *SRangeset, sp: *const SRangeset) void {
    if (sel[0].q0 < 0 or sp[0].q0 < sel[0].q0 or
        (sp[0].q0 == sel[0].q0 and sp[0].q1 > sel[0].q1))
        sel.* = sp.*;
}

/// bnewmatch (regx.c:833-843): keep the closest-below match, reversing every
/// q0/q1 so the returned ranges satisfy q0 ≤ q1.
fn bnewmatch(sel: *SRangeset, sp: *const SRangeset) void {
    if (sel[0].q0 < 0 or sp[0].q0 > sel[0].q1 or
        (sp[0].q0 == sel[0].q1 and sp[0].q1 < sel[0].q0))
    {
        var i: usize = 0;
        while (i < nrange) : (i += 1) {
            sel[i].q0 = sp[i].q1; // note the reversal
            sel[i].q1 = sp[i].q0;
        }
    }
}

fn toPublic(sel: SRangeset) Rangeset {
    var out: Rangeset = undefined;
    for (0..nrange) |i| out[i] = .{ .q0 = @intCast(sel[i].q0), .q1 = @intCast(sel[i].q1) };
    return out;
}

/// rxexecute (regx.c:559-692). `eof == null` ⇒ Infinity: search to end AND wrap
/// once; a bounded `eof` never wraps.
pub fn execute(self: *Regx, src: Source, startp: usize, eof: ?usize) ExecError!?Rangeset {
    const startinst = self.startinst orelse return null;

    var flag: usize = 0;
    var p: isize = @intCast(startp);
    var wrapped: u32 = 0;
    var nnl: i32 = 0;
    var ntl: i32 = 0;
    var c: u21 = 0;

    const startchar: ?u21 = switch (self.prog.items[startinst].op) {
        .rune => |r| r,
        else => null,
    };
    self.list[0][0].inst = null;
    self.list[1][0].inst = null;
    var sel: SRangeset = zero_srangeset;
    sel[0].q0 = -1;
    const nc: isize = @intCast(srcLen(src));
    const eof_v: isize = if (eof) |e| @intCast(e) else Infinity;
    const startp_i: isize = @intCast(startp);

    main: while (true) : (p += 1) {
        doloop: while (true) {
            if (p >= eof_v or p >= nc) {
                switch (wrapped) {
                    0, 2 => {
                        wrapped += 1; // let the loop run one more click
                        c = 0;
                    },
                    1 => {
                        wrapped += 1; // expired; wrap to the beginning
                        if (sel[0].q0 >= 0 or eof_v != Infinity) break :main;
                        self.list[0][0].inst = null;
                        self.list[1][0].inst = null;
                        p = 0;
                        continue :doloop;
                    },
                    else => break :main,
                }
            } else {
                if (((wrapped > 0 and p >= startp_i) or sel[0].q0 > 0) and nnl == 0) break :main;
                c = srcAt(src, @intCast(p));
            }
            break :doloop;
        }

        // fast check for first char (regx.c:610-612)
        if (startchar) |sc| {
            if (nnl == 0 and c != sc) continue :main;
        }

        const tl_idx = flag;
        flag ^= 1;
        const nl_idx = flag;
        self.list[nl_idx][0].inst = null;
        ntl = nnl;
        nnl = 0;

        // seed the start instruction (regx.c:618-628)
        if (sel[0].q0 < 0 and (wrapped == 0 or p < startp_i or startp_i == eof_v)) {
            var sempty = zero_srangeset;
            sempty[0].q0 = p;
            if (addinst(self.list[tl_idx][0..], startinst, &sempty)) {
                ntl += 1;
                if (ntl >= nlist) return error.ListOverflow;
            }
        }

        var tlp: usize = 0;
        while (self.list[tl_idx][tlp].inst) |inst0| : (tlp += 1) {
            var inst = inst0;
            const se = &self.list[tl_idx][tlp].se;
            sw: while (true) {
                const in = self.prog.items[inst];
                switch (in.op) {
                    .rune => |r| {
                        if (r == c) {
                            if (addinst(self.list[nl_idx][0..], in.next, se)) {
                                nnl += 1;
                                if (nnl >= nlist) return error.ListOverflow;
                            }
                        }
                        break :sw;
                    },
                    .any => { // ANY excludes '\n' (regx.c:651-654)
                        if (c != '\n') {
                            if (addinst(self.list[nl_idx][0..], in.next, se)) {
                                nnl += 1;
                                if (nnl >= nlist) return error.ListOverflow;
                            }
                        }
                        break :sw;
                    },
                    .bol => { // p==0 or previous char == '\n' (regx.c:655-660)
                        if (p == 0 or (p > 0 and srcAt(src, @intCast(p - 1)) == '\n')) {
                            inst = in.next;
                            continue :sw;
                        }
                        break :sw;
                    },
                    .eol => { // current char == '\n' only (regx.c:662-664)
                        if (c == '\n') {
                            inst = in.next;
                            continue :sw;
                        }
                        break :sw;
                    },
                    .class => |cl| { // c >= 0 always (regx.c:666-673)
                        if (classmatch(self.classes.items[cl.idx].items, c, cl.negate)) {
                            if (addinst(self.list[nl_idx][0..], in.next, se)) {
                                nnl += 1;
                                if (nnl >= nlist) return error.ListOverflow;
                            }
                        }
                        break :sw;
                    },
                    .lbra => |subid| {
                        if (subid >= 0) se[@intCast(subid)].q0 = p;
                        inst = in.next;
                        continue :sw;
                    },
                    .rbra => |subid| {
                        if (subid >= 0) se[@intCast(subid)].q1 = p;
                        inst = in.next;
                        continue :sw;
                    },
                    .alt => |right| { // OR: right branch later, advance to left now
                        if (addinst(self.list[tl_idx][tlp..], right, se)) {
                            ntl += 1;
                            if (ntl >= nlist) return error.ListOverflow;
                        }
                        inst = in.next;
                        continue :sw;
                    },
                    .end => { // match!
                        se[0].q1 = p;
                        newmatch(&sel, se);
                        break :sw;
                    },
                    .nop => break :sw, // spliced out by optimize; a stray NOP kills the thread
                }
            }
        }
    }

    if (sel[0].q0 < 0) return null;
    return toPublic(sel);
}

/// rxbexecute (regx.c:702-831): the backward machine. `p` decrements, reading the
/// char just before it; the wrap goes 0→end; the seed records `q0 = -p`; END negates
/// q0 back and `bnewmatch` swaps every q0/q1 so the result reads q0 ≤ q1.
pub fn bexecute(self: *Regx, src: Source, startp: usize) ExecError!?Rangeset {
    const bstartinst = self.bstartinst orelse return null;

    var flag: usize = 0;
    var p: isize = @intCast(startp);
    var wrapped: u32 = 0;
    var nnl: i32 = 0;
    var ntl: i32 = 0;
    var c: u21 = 0;

    const startchar: ?u21 = switch (self.prog.items[bstartinst].op) {
        .rune => |r| r,
        else => null,
    };
    self.list[0][0].inst = null;
    self.list[1][0].inst = null;
    var sel: SRangeset = zero_srangeset;
    sel[0].q0 = -1;
    const nc: isize = @intCast(srcLen(src));
    const startp_i: isize = @intCast(startp);

    main: while (true) : (p -= 1) {
        doloop: while (true) {
            if (p <= 0) {
                switch (wrapped) {
                    0, 2 => {
                        wrapped += 1; // let the loop run one more click
                        c = 0;
                    },
                    1 => {
                        wrapped += 1; // expired; wrap to the end
                        if (sel[0].q0 >= 0) break :main;
                        self.list[0][0].inst = null;
                        self.list[1][0].inst = null;
                        p = nc;
                        continue :doloop;
                    },
                    else => break :main,
                }
            } else {
                if (((wrapped > 0 and p <= startp_i) or sel[0].q0 > 0) and nnl == 0) break :main;
                c = srcAt(src, @intCast(p - 1));
            }
            break :doloop;
        }

        if (startchar) |sc| {
            if (nnl == 0 and c != sc) continue :main;
        }

        const tl_idx = flag;
        flag ^= 1;
        const nl_idx = flag;
        self.list[nl_idx][0].inst = null;
        ntl = nnl;
        nnl = 0;

        // seed; the minus makes addinst's leftmost preference read backward (regx.c:755-758)
        if (sel[0].q0 < 0 and (wrapped == 0 or p > startp_i)) {
            var sempty = zero_srangeset;
            sempty[0].q0 = -p;
            if (addinst(self.list[tl_idx][0..], bstartinst, &sempty)) {
                ntl += 1;
                if (ntl >= nlist) return error.ListOverflow;
            }
        }

        var tlp: usize = 0;
        while (self.list[tl_idx][tlp].inst) |inst0| : (tlp += 1) {
            var inst = inst0;
            const se = &self.list[tl_idx][tlp].se;
            sw: while (true) {
                const in = self.prog.items[inst];
                switch (in.op) {
                    .rune => |r| {
                        if (r == c) {
                            if (addinst(self.list[nl_idx][0..], in.next, se)) {
                                nnl += 1;
                                if (nnl >= nlist) return error.ListOverflow;
                            }
                        }
                        break :sw;
                    },
                    .any => {
                        if (c != '\n') {
                            if (addinst(self.list[nl_idx][0..], in.next, se)) {
                                nnl += 1;
                                if (nnl >= nlist) return error.ListOverflow;
                            }
                        }
                        break :sw;
                    },
                    .bol => { // c=='\n' || p==0 (regx.c:793-798)
                        if (c == '\n' or p == 0) {
                            inst = in.next;
                            continue :sw;
                        }
                        break :sw;
                    },
                    .eol => { // char AT p is '\n' (regx.c:800-802)
                        if (p < nc and srcAt(src, @intCast(p)) == '\n') {
                            inst = in.next;
                            continue :sw;
                        }
                        break :sw;
                    },
                    .class => |cl| { // c > 0 in the backward machine (regx.c:804-810)
                        if (c != 0 and classmatch(self.classes.items[cl.idx].items, c, cl.negate)) {
                            if (addinst(self.list[nl_idx][0..], in.next, se)) {
                                nnl += 1;
                                if (nnl >= nlist) return error.ListOverflow;
                            }
                        }
                        break :sw;
                    },
                    .lbra => |subid| {
                        if (subid >= 0) se[@intCast(subid)].q0 = p;
                        inst = in.next;
                        continue :sw;
                    },
                    .rbra => |subid| {
                        if (subid >= 0) se[@intCast(subid)].q1 = p;
                        inst = in.next;
                        continue :sw;
                    },
                    .alt => |right| { // backward OR seeds the base list, not tlp (regx.c:814)
                        if (addinst(self.list[tl_idx][0..], right, se)) {
                            ntl += 1;
                            if (ntl >= nlist) return error.ListOverflow;
                        }
                        inst = in.next;
                        continue :sw;
                    },
                    .end => {
                        se[0].q0 = -se[0].q0; // undo the seed's minus (regx.c:821)
                        se[0].q1 = p;
                        bnewmatch(&sel, se);
                        break :sw;
                    },
                    .nop => break :sw,
                }
            }
        }
    }

    if (sel[0].q0 < 0) return null;
    return toPublic(sel);
}

// ---------------------------------------------------------------------------
// Named tests (side contract §3, tests 1-23). Every expected Range is the
// contract's hand-derived value; the implementation reproduces them.
// ---------------------------------------------------------------------------
const testing = std.testing;

/// A comptime []const u21 from an ASCII/UTF-8 literal (each byte ⇒ one rune;
/// tests use only bytes < 0x80, and '\n').
fn L(comptime s: []const u8) [s.len]u21 {
    var out: [s.len]u21 = undefined;
    for (s, 0..) |ch, i| out[i] = ch;
    return out;
}

/// Compile `pat` and run over runes `src` from `start` to `eof` (null ⇒ wrap).
fn run(rx: *Regx, comptime pat: []const u8, comptime src: []const u8, start: usize, eof: ?usize) !?Rangeset {
    const p = L(pat);
    try rx.compile(&p);
    const s = L(src);
    return rx.execute(.{ .runes = &s }, start, eof);
}

fn expectMatch(rs: ?Rangeset, q0: usize, q1: usize) !void {
    const r = rs orelse return error.TestExpectedMatch;
    try testing.expectEqual(q0, r[0].q0);
    try testing.expectEqual(q1, r[0].q1);
}

test "regx: literal" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "hello", "say hello", 0, ("say hello").len);
    try expectMatch(r, 4, 9);
}

test "regx: leftmost wins" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "a*", "baaa", 0, ("baaa").len);
    try expectMatch(r, 0, 0);
}

test "regx: longest at same start" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "aa|a", "xaa", 0, ("xaa").len);
    try expectMatch(r, 1, 3);
}

test "regx: plus" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "ba+", "abaaac", 0, ("abaaac").len);
    try expectMatch(r, 1, 5);
}

test "regx: quest" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    try expectMatch(try run(&rx, "ab?c", "ac", 0, 2), 0, 2);
    try expectMatch(try run(&rx, "ab?c", "abc", 0, 3), 0, 3);
}

test "regx: class range" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "[a-c]+", "zabcz", 0, ("zabcz").len);
    try expectMatch(r, 1, 4);
}

test "regx: negated class excludes newline" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "[^a]", "\nb", 0, 2);
    try expectMatch(r, 1, 2);
}

test "regx: class escaped dash" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "[\\-x]", "a-b", 0, 3);
    try expectMatch(r, 1, 2);
}

test "regx: dot excludes newline" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "a.c", "a\nc", 0, 3);
    try testing.expect(r == null);
}

test "regx: bol" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    try expectMatch(try run(&rx, "^ab", "zz\nab", 0, 5), 3, 5);
    try expectMatch(try run(&rx, "^ab", "ab", 0, 2), 0, 2);
}

test "regx: eol before newline only" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    try expectMatch(try run(&rx, "b$", "ab\ncb", 0, 5), 1, 2);
    // no trailing '\n' ⇒ $ does not match at eof (c==0, regx.c:662-664)
    try testing.expect((try run(&rx, "b$", "ab", 0, 2)) == null);
}

test "regx: match ending at eof" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = try run(&rx, "ab", "ab", 0, 2);
    try expectMatch(r, 0, 2);
}

test "regx: groups" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    {
        const r = (try run(&rx, "(a+)(b+)", "xaabb", 0, 5)).?;
        try testing.expectEqual(@as(usize, 1), r[0].q0);
        try testing.expectEqual(@as(usize, 5), r[0].q1);
        try testing.expectEqual(@as(usize, 1), r[1].q0);
        try testing.expectEqual(@as(usize, 3), r[1].q1);
        try testing.expectEqual(@as(usize, 3), r[2].q0);
        try testing.expectEqual(@as(usize, 5), r[2].q1);
    }
    {
        const r = (try run(&rx, "((a)b)", "ab", 0, 2)).?;
        try testing.expectEqual(@as(usize, 0), r[1].q0);
        try testing.expectEqual(@as(usize, 2), r[1].q1);
        try testing.expectEqual(@as(usize, 0), r[2].q0);
        try testing.expectEqual(@as(usize, 1), r[2].q1);
    }
}

test "regx: unmatched group is zero" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const r = (try run(&rx, "(a)|b", "b", 0, 1)).?;
    try testing.expectEqual(@as(usize, 0), r[0].q0);
    try testing.expectEqual(@as(usize, 1), r[0].q1);
    try testing.expectEqual(@as(usize, 0), r[1].q0); // group 1 unmatched ⇒ {0,0}
    try testing.expectEqual(@as(usize, 0), r[1].q1);
}

test "regx: escaped metachar" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    try expectMatch(try run(&rx, "a\\*", "xa*", 0, 3), 1, 3);
    try expectMatch(try run(&rx, "\\n", "\n", 0, 1), 0, 1);
}

// test 16 (compile errors) lives in regx_compile.zig.

test "regx: recompile cache" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    const p = L("ab");
    try rx.compile(&p);
    try rx.compile(&p); // identical pattern ⇒ cached no-op
    const s = L("xaby");
    try expectMatch(try rx.execute(.{ .runes = &s }, 0, 4), 1, 3);
}

test "regx: wrap when eof null" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    var buf = try Buffer.initFromBytes(testing.allocator, "abcab");
    defer buf.deinit();
    {
        const p = L("ab");
        try rx.compile(&p);
        try expectMatch(try rx.execute(.{ .buffer = &buf }, 4, null), 0, 2);
    }
    {
        const p = L("zz");
        try rx.compile(&p);
        try testing.expect((try rx.execute(.{ .buffer = &buf }, 2, null)) == null);
    }
}

test "regx: no wrap when eof given" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    var buf = try Buffer.initFromBytes(testing.allocator, "abcab");
    defer buf.deinit();
    const p = L("ab");
    try rx.compile(&p);
    try testing.expect((try rx.execute(.{ .buffer = &buf }, 4, 5)) == null);
}

test "regx: bexecute basic" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    var buf = try Buffer.initFromBytes(testing.allocator, "abcab");
    defer buf.deinit();
    const p = L("ab");
    try rx.compile(&p);
    try expectMatch(try rx.bexecute(.{ .buffer = &buf }, 5), 3, 5);
    try expectMatch(try rx.bexecute(.{ .buffer = &buf }, 3), 0, 2);
}

test "regx: bexecute wraps to end" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    var buf = try Buffer.initFromBytes(testing.allocator, "abcab");
    defer buf.deinit();
    const p = L("ab");
    try rx.compile(&p);
    try expectMatch(try rx.bexecute(.{ .buffer = &buf }, 1), 3, 5);
}

test "regx: bexecute bol/eol" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    {
        var buf = try Buffer.initFromBytes(testing.allocator, "b\na");
        defer buf.deinit();
        const p = L("^a");
        try rx.compile(&p);
        try expectMatch(try rx.bexecute(.{ .buffer = &buf }, 3), 2, 3);
    }
    {
        var buf = try Buffer.initFromBytes(testing.allocator, "ab\ncb");
        defer buf.deinit();
        const p = L("b$");
        try rx.compile(&p);
        try expectMatch(try rx.bexecute(.{ .buffer = &buf }, 2), 1, 2);
    }
}

test "regx: list overflow" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();
    // `a?`×128 then `a`×128 — a thread explosion that overruns the 127-thread list.
    comptime var pat: []const u8 = "";
    comptime {
        var i: usize = 0;
        while (i < 128) : (i += 1) pat = pat ++ "a?";
        i = 0;
        while (i < 128) : (i += 1) pat = pat ++ "a";
    }
    const p = L(pat);
    try rx.compile(&p); // must compile (growable arena; see Regx.zig NPROG note)
    const s = L("a" ** 128);
    try testing.expectError(error.ListOverflow, rx.execute(.{ .runes = &s }, 0, 128));
}
