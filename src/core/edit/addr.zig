//! Edit address evaluation — `cmdaddress`/`nextmatch`/`charaddr`/`lineaddr`
//! (larryr/plan9port@337c6ac, `src/cmd/acme/ecmd.c:54-60,1034-1146,1250-1325`).
//! Namespace module (S-07 P-1): evaluation functions ONLY — the AST types
//! (`Addr`/`Address`) live in `ast.zig` (R-P10-1); `Rangeset` lives in
//! `Regx.zig` (O20 §2.1). Import graph: `Regx` <- `ast` <- `addr` (acyclic,
//! R-P10-1) — this file never imports `parse`/`cmd`.
//!
//! No `*Editor` parameter (R-P10-3): the C's `File*`/`Text*` threading
//! collapses onto `ast.Address.t` (a `*Text`); where the C reassigns its local
//! `File *f` (only on `;`, ecmd.c:1118-1119), the port reassigns which
//! `Address.t` subsequent nodes read from.
//!
//! `sign` threads exactly as the C's local `int sign` does: mutated ONLY by
//! `+`/`-` nodes (for the NEXT term) and negated by `?` (falls into the same
//! regexp arm as `/`, ecmd.c:1090-1098) — never reset between terms, because
//! the parser already inserts an implicit `+` between adjacent address atoms
//! (edit.c:644-657), so a fresh atom always sees the sign its predecessor set.
//!
//! Divergence (documented, not a bug): the C's `,`/`;` arm also errors
//! "addresses in different files" when the two sides land on different
//! `File`s (ecmd.c:1125). v1 has no construct that can produce that split
//! (cross-file `"` filematch and `'` mark both error Unsupported before ever
//! reaching a different File), so the check is structurally unreachable and
//! is omitted — flagged for revisit if a later phase adds cross-file
//! addressing.
const std = @import("std");
const ast = @import("ast.zig");
const Regx = @import("Regx.zig");
const File = @import("../File.zig");
const Text = @import("../text/Text.zig");

pub const Error = error{
    OutOfMemory,
    BadRegexp, // "bad regexp in command address" (ecmd.c:1035)
    NoMatch, // "no match for regexp" / "address" (ecmd.c:1038,1049 collapsed)
    ListOverflow, // regx.c:622-627, surfaced rather than silently swallowed
    AddressOutOfRange, // "address out of range" (ecmd.c:1258,1291-1292,1319)
    AddressesOutOfOrder, // "addresses out of order" (ecmd.c:1128)
    Unsupported, // '\'' mark (ecmd.c:1086) and '"' filematch (v1, R-P10-7)
};

/// `mkaddr` (ecmd.c:54-60): the current dot, read straight off the Text.
pub fn mkAddr(t: *Text) ast.Address {
    return .{ .r = .{ .q0 = t.q0, .q1 = t.q1 }, .t = t };
}

/// `charaddr` (ecmd.c:1250-1262). `sign==0` sets an absolute point; `+`/`-`
/// collapse the range to `q1+l` / `q0-l`. Range-checked against `[0, nc]`
/// (usize already excludes the C's `q0<0` half; the `sign<0` underflow is
/// checked explicitly rather than left to wrap).
pub fn charAddr(l: usize, a: ast.Address, sign: i8) Error!ast.Address {
    var r = a.r;
    if (sign == 0) {
        r.q0 = l;
        r.q1 = l;
    } else if (sign < 0) {
        if (l > r.q0) return error.AddressOutOfRange; // would go negative
        r.q0 -= l;
        r.q1 = r.q0;
    } else {
        r.q1 = std.math.add(usize, r.q1, l) catch return error.AddressOutOfRange;
        r.q0 = r.q1;
    }
    if (r.q1 > a.t.file.buffer.len()) return error.AddressOutOfRange;
    return .{ .r = r, .t = a.t };
}

/// `lineaddr` (ecmd.c:1264-1325). Forward (`sign>=0`): absolute counting
/// (sign==0 or `a.r.q1==0`) starts at rune 0 treating it as already inside
/// line 1; relative counting starts at `q1-1`, crediting a newline sitting
/// right at dot-end as the first boundary (ecmd.c:1287-1288). `l==0` forward
/// is "rest of the current line" (dot-end -> end-of-line), with the
/// `a.r.q1==0` special case collapsing to `(0,0)` (ecmd.c:1275-1281).
/// Backward (`sign<0`): counts newlines walking down from `q0`; `l==0` is
/// "start-of-line -> dot-start". Running off either end mid-count errors
/// `AddressOutOfRange` (ecmd.c:1291-1292, backward for-loop `p==0` arm).
pub fn lineAddr(l: usize, a: ast.Address, sign: i8) Error!ast.Address {
    const buf = &a.t.file.buffer;
    const nc = buf.len();
    var r: File.Range = undefined;
    if (sign >= 0) {
        var p: usize = undefined;
        if (l == 0) {
            if (sign == 0 or a.r.q1 == 0) return .{ .r = .{ .q0 = 0, .q1 = 0 }, .t = a.t };
            r.q0 = a.r.q1;
            p = a.r.q1 - 1;
        } else {
            var n: usize = 0;
            if (sign == 0 or a.r.q1 == 0) {
                p = 0;
                n = 1;
            } else {
                p = a.r.q1 - 1;
                if (buf.runeAt(p) == '\n') n = 1;
                p += 1;
            }
            while (n < l) {
                if (p >= nc) return error.AddressOutOfRange;
                const c = buf.runeAt(p);
                p += 1;
                if (c == '\n') n += 1;
            }
            r.q0 = p;
        }
        while (p < nc) {
            const c = buf.runeAt(p);
            p += 1;
            if (c == '\n') break;
        }
        r.q1 = p;
    } else {
        var p: usize = a.r.q0;
        if (l == 0) {
            r.q1 = a.r.q0;
        } else {
            var n: usize = 0;
            while (n < l) {
                if (p == 0) {
                    n += 1;
                    if (n != l) return error.AddressOutOfRange;
                } else {
                    const c = buf.runeAt(p - 1);
                    if (c != '\n') {
                        p -= 1;
                    } else {
                        n += 1;
                        if (n != l) p -= 1;
                    }
                }
            }
            r.q1 = p;
            if (p > 0) p -= 1;
        }
        while (p > 0) {
            if (buf.runeAt(p - 1) == '\n') break;
            p -= 1;
        }
        r.q0 = p;
    }
    return .{ .r = r, .t = a.t };
}

/// `nextmatch` (ecmd.c:1034-1058): compile the pattern (a `CompileError`
/// becomes `error.BadRegexp`), search with `eof=null` (rx's Infinity — wraps
/// once, R-P10-2), and re-search once, advanced by one rune, when the hit is
/// empty and sits exactly on the start point (`p`). `sign<0` mirrors with
/// `bexecute` (which always wraps).
pub fn nextMatch(rx: *Regx, t: *Text, re: []const u21, p: usize, sign: i8) Error!File.Range {
    rx.compile(re) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.BadRegexp;
    };
    const src = Regx.Source{ .buffer = &t.file.buffer };
    const nc = t.file.buffer.len();
    if (sign >= 0) {
        var res = try rx.execute(src, p, null);
        if (res == null) return error.NoMatch;
        if (res.?[0].q0 == res.?[0].q1 and res.?[0].q0 == p) {
            var p2 = p + 1;
            if (p2 > nc) p2 = 0;
            res = try rx.execute(src, p2, null);
            if (res == null) return error.NoMatch;
        }
        return res.?[0];
    } else {
        var res = try rx.bexecute(src, p);
        if (res == null) return error.NoMatch;
        if (res.?[0].q0 == res.?[0].q1 and res.?[0].q1 == p) {
            const p2: usize = if (p == 0) nc else p - 1;
            res = try rx.bexecute(src, p2);
            if (res == null) return error.NoMatch;
        }
        return res.?[0];
    }
}

/// Forward/back regexp arm shared by `eval`'s `.re`/`.back_re` cases:
/// `nextmatch(f, re, sign>=0? a.r.q1 : a.r.q0, sign)` (ecmd.c:1090-1098).
fn evalRe(rx: *Regx, a: ast.Address, re: []const u21, sign: i8) Error!ast.Address {
    const startp = if (sign >= 0) a.r.q1 else a.r.q0;
    const range = try nextMatch(rx, a.t, re, startp, sign);
    return .{ .r = range, .t = a.t };
}

/// `,`/`;` (ecmd.c:1109-1129). Missing left ⇒ `(0,0)`; missing right ⇒
/// `(nc,nc)`. `;` writes `a1` into `a.t.q0/q1` (the documented side effect,
/// ecmd.c:1118-1119) and evaluates the right side from `a1`; `,` evaluates
/// the right side from the ORIGINAL incoming `a`. `q1<q0` after combining ⇒
/// `AddressesOutOfOrder`.
fn evalCommaSemi(
    rx: *Regx,
    a: ast.Address,
    left: ?*const ast.Addr,
    right: ?*const ast.Addr,
    is_semi: bool,
) Error!ast.Address {
    const a1: ast.Address = if (left) |l|
        try eval(rx, l, a, 0)
    else
        .{ .r = .{ .q0 = 0, .q1 = 0 }, .t = a.t };

    var a_for_right = a;
    if (is_semi) {
        a1.t.q0 = a1.r.q0;
        a1.t.q1 = a1.r.q1;
        a_for_right = a1;
    }

    const a2: ast.Address = if (right) |r|
        try eval(rx, r, a_for_right, 0)
    else
        .{ .r = .{ .q0 = a_for_right.t.file.buffer.len(), .q1 = a_for_right.t.file.buffer.len() }, .t = a_for_right.t };

    if (a2.r.q1 < a1.r.q0) return error.AddressesOutOfOrder;
    return .{ .r = .{ .q0 = a1.r.q0, .q1 = a2.r.q1 }, .t = a1.t };
}

/// `cmdaddress` (ecmd.c:1064-1146): a do-while over `ap.next`, threading
/// `sign`. `,`/`;`/`*` return immediately (they never continue the chain in
/// the C either — each is its own `return`). `'` (mark) and `"` (filematch)
/// both collapse to `error.Unsupported` (v1, R-P10-7).
pub fn eval(rx: *Regx, ap: *const ast.Addr, a_in: ast.Address, sign_in: i8) Error!ast.Address {
    var a = a_in;
    var sign = sign_in;
    var node: *const ast.Addr = ap;
    while (true) {
        switch (node.kind) {
            .comma => |left| return evalCommaSemi(rx, a, left, node.next, false),
            .semi => |left| return evalCommaSemi(rx, a, left, node.next, true),
            .all => return .{ .r = .{ .q0 = 0, .q1 = a.t.file.buffer.len() }, .t = a.t },
            .mark => return error.Unsupported,
            .file => return error.Unsupported,
            .char => |l| a = try charAddr(l, a, sign),
            .line => |l| a = try lineAddr(l, a, sign),
            .dot => a = mkAddr(a.t),
            .end => {
                const nc = a.t.file.buffer.len();
                a = .{ .r = .{ .q0 = nc, .q1 = nc }, .t = a.t };
            },
            .re => |re| a = try evalRe(rx, a, re, sign),
            .back_re => |re| {
                sign = -sign;
                if (sign == 0) sign = -1;
                a = try evalRe(rx, a, re, sign);
            },
            .plus => {
                sign = 1;
                if (bareSignNext(node.next)) a = try lineAddr(1, a, sign);
            },
            .minus => {
                sign = -1;
                if (bareSignNext(node.next)) a = try lineAddr(1, a, sign);
            },
        }
        node = node.next orelse return a;
    }
}

/// `ap->next==0 || ap->next->type=='+' || ap->next->type=='-'` (ecmd.c:1136):
/// a bare sign (nothing after it, or another sign) means "one line" now.
fn bareSignNext(next: ?*const ast.Addr) bool {
    const n = next orelse return true;
    return switch (n.kind) {
        .plus, .minus => true,
        else => false,
    };
}

/// Static editerror-style messages for `cmd.zig`'s error-boundary translation.
pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.OutOfMemory => "out of memory",
        error.BadRegexp => "bad regexp in command address",
        error.NoMatch => "no match for regexp",
        error.ListOverflow => "regexp list overflow",
        error.AddressOutOfRange => "address out of range",
        error.AddressesOutOfOrder => "addresses out of order",
        error.Unsupported => "can't handle '",
        else => "bad address",
    };
}

// ==========================================================================
// Tests 24-41 (side contract §3). File "abc\ndef\nghi\n": nc=12,
// line1=(0,4), line2=(4,8), line3=(8,12). ASTs built by hand; dot set via
// `t.q0/q1` directly (no gesture machine, cf. look.zig's Harness).
// ==========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const Buffer = @import("../Buffer.zig");

const Harness = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,
    rx: Regx,

    fn init(seed: []const u8) !*Harness {
        const a = testing.allocator;
        const h = try a.create(Harness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        const rect = draw.proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };
        h.text = try Text.init(&h.file, a, rect, h.fx.font, &h.fx.disp.image, h.fx.cols());
        try h.text.fill();
        h.rx = Regx.init(a);
        return h;
    }
    fn deinit(h: *Harness) void {
        h.rx.deinit();
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }

    /// Wrap a rune-literal string as an arena-free `[]const u21` for a test's
    /// lifetime (leaked into the testing allocator; freed by the test).
    fn runes(alloc: std.mem.Allocator, s: []const u8) ![]u21 {
        const out = try alloc.alloc(u21, s.len);
        for (s, 0..) |c, i| out[i] = c;
        return out;
    }
};

fn addrNode(kind: ast.Addr.Kind) ast.Addr {
    return .{ .kind = kind };
}

test "addr: absolute line" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    var n = addrNode(.{ .line = 3 });
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 8, .q1 = 12 }, r.r);

    const h2 = try Harness.init("ab");
    defer h2.deinit();
    n = addrNode(.{ .line = 1 });
    const r2 = try eval(&h2.rx, &n, mkAddr(&h2.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 0, .q1 = 2 }, r2.r);

    const h3 = try Harness.init("ab\n");
    defer h3.deinit();
    n = addrNode(.{ .line = 2 });
    const r3 = try eval(&h3.rx, &n, mkAddr(&h3.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 3, .q1 = 3 }, r3.r);
}

test "addr: zero and dollar" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    var n = addrNode(.{ .line = 0 });
    const r0 = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 0, .q1 = 0 }, r0.r);

    n = addrNode(.end);
    const r1 = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 12, .q1 = 12 }, r1.r);
}

test "addr: char" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    var n = addrNode(.{ .char = 5 });
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 5, .q1 = 5 }, r.r);

    n = addrNode(.{ .char = 13 });
    try testing.expectError(error.AddressOutOfRange, eval(&h.rx, &n, mkAddr(&h.text), 0));
}

test "addr: dot" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 5;
    h.text.q1 = 6;
    var n = addrNode(.dot);
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 5, .q1 = 6 }, r.r);
}

test "addr: fwd regexp" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 0;
    h.text.q1 = 0;
    const re = try Harness.runes(testing.allocator, "de");
    defer testing.allocator.free(re);
    var n = addrNode(.{ .re = re });
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 4, .q1 = 6 }, r.r);
}

test "addr: back regexp" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 8;
    h.text.q1 = 8;
    const re = try Harness.runes(testing.allocator, "de");
    defer testing.allocator.free(re);
    var n = addrNode(.{ .back_re = re });
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 4, .q1 = 6 }, r.r);
}

test "addr: regexp wraps" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 4;
    h.text.q1 = 8;
    const re = try Harness.runes(testing.allocator, "abc");
    defer testing.allocator.free(re);
    var n = addrNode(.{ .re = re });
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 0, .q1 = 3 }, r.r);
}

test "addr: regexp plus lines" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 0;
    h.text.q1 = 0;
    const re = try Harness.runes(testing.allocator, "abc");
    defer testing.allocator.free(re);
    var plus = addrNode(.plus);
    var line2 = addrNode(.{ .line = 2 });
    plus.next = &line2;
    var n = addrNode(.{ .re = re });
    n.next = &plus;
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 8, .q1 = 12 }, r.r);
}

test "addr: bare plus" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 0;
    h.text.q1 = 4;
    var n = addrNode(.plus);
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 4, .q1 = 8 }, r.r);

    h.text.q0 = 0;
    h.text.q1 = 0;
    n = addrNode(.plus);
    const r2 = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 0, .q1 = 4 }, r2.r);
}

test "addr: bare minus" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 8;
    h.text.q1 = 12;
    var n = addrNode(.minus);
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 4, .q1 = 8 }, r.r);
}

test "addr: plus zero / minus zero" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 5;
    h.text.q1 = 6;
    var plus = addrNode(.plus);
    var zero = addrNode(.{ .line = 0 });
    plus.next = &zero;
    const r = try eval(&h.rx, &plus, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 6, .q1 = 8 }, r.r);

    var minus = addrNode(.minus);
    minus.next = &zero;
    const r2 = try eval(&h.rx, &minus, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 4, .q1 = 5 }, r2.r);
}

test "addr: comma vs semi dot update" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 8;
    h.text.q1 = 12;

    var one = addrNode(.{ .line = 1 });
    var plus = addrNode(.plus);
    var comma = addrNode(.{ .comma = &one });
    comma.next = &plus;
    const r1 = try eval(&h.rx, &comma, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 0, .q1 = 12 }, r1.r);

    h.text.q0 = 8;
    h.text.q1 = 12;
    var one2 = addrNode(.{ .line = 1 });
    var plus2 = addrNode(.plus);
    var semi = addrNode(.{ .semi = &one2 });
    semi.next = &plus2;
    const r2 = try eval(&h.rx, &semi, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 0, .q1 = 8 }, r2.r);
    try testing.expectEqual(@as(usize, 0), h.text.q0);
    try testing.expectEqual(@as(usize, 4), h.text.q1);
}

test "addr: bare comma" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 0;
    h.text.q1 = 0;
    var comma = addrNode(.{ .comma = null });
    const r = try eval(&h.rx, &comma, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 0, .q1 = 12 }, r.r);

    var zero = addrNode(.{ .line = 0 });
    var dollar = addrNode(.end);
    var semi = addrNode(.{ .semi = &zero });
    semi.next = &dollar;
    const r2 = try eval(&h.rx, &semi, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 0, .q1 = 12 }, r2.r);
}

test "addr: out of order" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 0;
    h.text.q1 = 0;
    var three = addrNode(.{ .line = 3 });
    var one = addrNode(.{ .line = 1 });
    var comma = addrNode(.{ .comma = &three });
    comma.next = &one;
    try testing.expectError(error.AddressesOutOfOrder, eval(&h.rx, &comma, mkAddr(&h.text), 0));
}

test "addr: empty match advances" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 2;
    h.text.q1 = 2;
    const rex = try Harness.runes(testing.allocator, "x*");
    defer testing.allocator.free(rex);
    var n = addrNode(.{ .re = rex });
    const r = try eval(&h.rx, &n, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 3, .q1 = 3 }, r.r);

    h.text.q0 = 3;
    h.text.q1 = 3;
    var b = addrNode(.{ .back_re = rex });
    const r2 = try eval(&h.rx, &b, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 2, .q1 = 2 }, r2.r);
}

test "addr: line out of range" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    h.text.q0 = 0;
    h.text.q1 = 0;
    var n = addrNode(.{ .line = 9 });
    try testing.expectError(error.AddressOutOfRange, eval(&h.rx, &n, mkAddr(&h.text), 0));
}

test "addr: char arithmetic" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    var three = addrNode(.{ .char = 3 });
    var plus = addrNode(.plus);
    var two = addrNode(.{ .char = 2 });
    plus.next = &two;
    three.next = &plus;
    const r = try eval(&h.rx, &three, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 5, .q1 = 5 }, r.r);

    var dollar = addrNode(.end);
    var minus = addrNode(.minus);
    var two2 = addrNode(.{ .char = 2 });
    minus.next = &two2;
    dollar.next = &minus;
    const r2 = try eval(&h.rx, &dollar, mkAddr(&h.text), 0);
    try testing.expectEqual(File.Range{ .q0 = 10, .q1 = 10 }, r2.r);
}

test "addr: mark and filematch unsupported" {
    const h = try Harness.init("abc\ndef\nghi\n");
    defer h.deinit();
    var mark = addrNode(.mark);
    try testing.expectError(error.Unsupported, eval(&h.rx, &mark, mkAddr(&h.text), 0));

    const re = try Harness.runes(testing.allocator, "re");
    defer testing.allocator.free(re);
    var file = addrNode(.{ .file = re });
    try testing.expectError(error.Unsupported, eval(&h.rx, &file, mkAddr(&h.text), 0));
}
