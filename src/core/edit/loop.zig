//! The Edit-language loop commands — `s` (substitute) and `x`/`y`/`g`/`v`
//! (match/gap/guard loops), plus the bare-`x` linelooper (acme/ecmd.c:447-534,
//! 852-935, 370-385). Ported from larryr/plan9port@337c6ac; cite as `ecmd.c:NN`.
//!
//! The two-phase shape is what makes the Elog frozen-coordinate model correct
//! (ecmd.c:19-27): every collect phase reads the buffer BEFORE any mutation
//! (Elog defers all mutation to editcmd's single reverse `apply`), so a match /
//! gap / group range never shifts under a not-yet-applied edit. `s` collects its
//! matches, `x`/`y` pre-collect their ranges, then a child `cmdexec` runs per
//! collected range with `t.q0/q1` set to it (`loopcmd`). Loop commands copy
//! `x.addr.r` at entry because a nested `cmdexec` clobbers `x.addr`
//! (ecmd.c:857-859); `x.nest` is bumped around the child runs (ecmd.c:855/896)
//! so a top-level-only guard like `s`'s "no substitution" (ecmd.c:522) reads
//! correctly inside a loop.
//!
//! `rx.execute` is bounded (`eof = r.q1`, never the wrapping Infinity) — the
//! C's `rxexecute(t, nil, p, r.q1, &sel)`. Its `error.ListOverflow` (regx.c:622)
//! is mapped, like every other edit-time regexp failure, to `error.Edit` + a
//! `Diag` message; the whole Edit then aborts with one warning (consistent with
//! `addr.nextMatch`, which likewise propagates it — R-P10-2).
const std = @import("std");
const ast = @import("ast.zig");
const cmd = @import("cmd.zig");
const addr = @import("addr.zig");
const Regx = @import("Regx.zig");
const Text = @import("../text/Text.zig");
const Buffer = @import("../Buffer.zig");

/// `s_cmd` (ecmd.c:447-534). Two phases over the FROZEN buffer: collect the
/// matches (`--n>0` skips to the n-th; without `g` only the n-th survives the
/// substitution loop's `break`, but ALL from the n-th on are collected), then
/// expand each rhs and record an `elog.replace`. Dot = the addressed range
/// pre-apply (ecmd.c:524-525); "no substitution" errors ONLY at `nest==0`.
pub fn sCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    const re = cp.re orelse return x.diag.set("no regular expression defined", .{});
    x.rx.compile(re) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return x.diag.set("bad regexp in s command", .{});
    };
    const r = x.addr.r; // frozen (nested cmdexec never runs here, but be uniform)
    const rhs = textArg(cp);
    const src = Regx.Source{ .buffer = &t.file.buffer };

    // Collect phase (ecmd.c:461-484).
    var matches: std.ArrayList(Regx.Rangeset) = .empty;
    var n: i32 = cp.num;
    var op: isize = -1; // ecmd.c:456 (no empty match can equal -1 first time)
    var p1: usize = r.q0;
    while (p1 <= r.q1) {
        const sel = (try execBounded(x, src, p1, r.q1)) orelse break;
        if (sel[0].q0 == sel[0].q1) { // empty match (ecmd.c:463-472)
            if (@as(isize, @intCast(sel[0].q0)) == op) {
                p1 += 1;
                continue;
            }
            p1 = sel[0].q1 + 1;
        } else {
            p1 = sel[0].q1;
        }
        op = @intCast(sel[0].q1);
        n -= 1;
        if (n > 0) continue; // ecmd.c:475-476 skip to the n-th
        try matches.append(x.arena, sel);
    }

    // Substitution phase (ecmd.c:486-518).
    var didsub = false;
    var rbuf: std.ArrayList(u21) = .empty;
    for (matches.items) |sel| {
        rbuf.clearRetainingCapacity();
        var i: usize = 0;
        while (i < rhs.len) : (i += 1) {
            const c = rhs[i];
            if (c == '\\' and i + 1 < rhs.len) { // ecmd.c:492
                i += 1;
                const c2 = rhs[i];
                if (c2 >= '1' and c2 <= '9') { // \1-\9 group text (ecmd.c:494-501)
                    const j: usize = c2 - '0';
                    try appendRange(&rbuf, x.arena, &t.file.buffer, sel[j].q0, sel[j].q1);
                } else {
                    try rbuf.append(x.arena, c2); // \& \x \\ literal (ecmd.c:503)
                }
            } else if (c != '&') { // literal (ecmd.c:504-505)
                try rbuf.append(x.arena, c);
            } else { // & whole match (ecmd.c:506-511)
                try appendRange(&rbuf, x.arena, &t.file.buffer, sel[0].q0, sel[0].q1);
            }
        }
        const bytes = try runesToUtf8(x.arena, rbuf.items);
        try x.elog.replace(t.file, sel[0].q0, sel[0].q1, bytes, rbuf.items.len); // ecmd.c:512
        didsub = true;
        if (!cp.flag_g) break; // ecmd.c:516-517
    }

    if (!didsub and x.nest == 0) return x.diag.set("no substitution", .{}); // ecmd.c:522-523
    t.q0 = r.q0; // ecmd.c:524-525
    t.q1 = r.q1;
    return true;
}

/// `x_cmd`/`y_cmd` (ecmd.c:573-581): a compiled regexp drives `looper` (`x` =
/// match ranges, `y` = the gaps between them); a bare `x`/`y` (`re == null`,
/// synthesized `.*\n`) drives `linelooper`.
pub fn xCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    if (cp.re != null) {
        try looper(x, t, cp, cp.cmdc == 'x');
    } else {
        try linelooper(x, t, cp);
    }
    return true;
}

/// `g_cmd`/`v_cmd` (ecmd.c:370-385): ONE bounded `rxexecute` over the addressed
/// range; `found XOR (cmdc=='v')` ⇒ set dot to the WHOLE addressed range and run
/// the child ONCE. `g` does NOT bump `nest`.
pub fn gCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    const re = cp.re orelse return x.diag.set("no regular expression defined", .{});
    x.rx.compile(re) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return x.diag.set("bad regexp in g command", .{});
    };
    const r = x.addr.r; // ecmd.c:379-380 (before the child clobbers x.addr)
    const src = Regx.Source{ .buffer = &t.file.buffer };
    const found = (try execBounded(x, src, r.q0, r.q1)) != null;
    if (found != (cp.cmdc == 'v')) { // ecmd.c:378 rxexecute ^ cmdc=='v'
        t.q0 = r.q0; // ecmd.c:380-381
        t.q1 = r.q1;
        return cmd.cmdexec(x, t, childOf(cp));
    }
    return true;
}

// ==========================================================================
// Private machinery.
// ==========================================================================

/// `looper` (ecmd.c:852-894). Pre-collect ranges over the unmodified buffer:
/// `x` keeps each match; `y` keeps the gap `[op, match.q0)` and, after the last
/// match, the tail `[op, r.q1)`. Empty-match advance ecmd.c:872-877. `nest++`
/// spans the collect AND the child runs (ecmd.c:855/893).
fn looper(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd, xy: bool) ast.Error!void {
    const r = x.addr.r; // ecmd.c:857
    x.rx.compile(cp.re.?) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return x.diag.set("bad regexp in {u} command", .{loChar(cp.cmdc)});
    };
    x.nest += 1; // ecmd.c:859
    defer x.nest -= 1;

    var ranges: std.ArrayList(ast.Range) = .empty;
    const src = Regx.Source{ .buffer = &t.file.buffer };
    var op: isize = if (xy) -1 else @intCast(r.q0); // ecmd.c:858
    var p: usize = r.q0;
    while (p <= r.q1) {
        var tr: ast.Range = undefined;
        if (try execBounded(x, src, p, r.q1)) |sel| {
            if (sel[0].q0 == sel[0].q1) { // empty match (ecmd.c:872-877)
                if (@as(isize, @intCast(sel[0].q0)) == op) {
                    p += 1;
                    continue;
                }
                p = sel[0].q1 + 1;
            } else {
                p = sel[0].q1;
            }
            tr = if (xy) sel[0] else .{ .q0 = @intCast(op), .q1 = sel[0].q0 }; // ecmd.c:879-882
            op = @intCast(sel[0].q1); // ecmd.c:884
        } else { // no match — y still runs its final tail (ecmd.c:865-870)
            if (xy or op > @as(isize, @intCast(r.q1))) break;
            tr = .{ .q0 = @intCast(op), .q1 = r.q1 };
            p = r.q1 + 1; // exit next loop
        }
        try ranges.append(x.arena, tr);
    }
    try loopcmd(x, t, childOf(cp), ranges.items);
}

/// `linelooper` (ecmd.c:896-935): the bare-`x` default `.*\n` — per-line ranges
/// via `lineAddr`, clipped to the addressed range. `nest++` spans the run.
fn linelooper(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!void {
    const r = x.addr.r; // ecmd.c:906
    x.nest += 1; // ecmd.c:903
    defer x.nest -= 1;

    var ranges: std.ArrayList(ast.Range) = .empty;
    var a3: ast.Range = .{ .q0 = r.q0, .q1 = r.q0 }; // ecmd.c:907-908
    var a = try lineAddr(x, 0, .{ .r = a3, .t = t }, 1); // ecmd.c:909
    var linesel = a.r;
    var p: usize = r.q0;
    while (p < r.q1) : (p = a3.q1) { // ecmd.c:911, for-update p = a3.r.q1
        a3.q0 = a3.q1; // ecmd.c:912
        if (p != r.q0 or linesel.q1 == p) { // ecmd.c:913-916
            a = try lineAddr(x, 1, .{ .r = a3, .t = t }, 1);
            linesel = a.r;
        }
        if (linesel.q0 >= r.q1) break; // ecmd.c:917-918
        if (linesel.q1 >= r.q1) linesel.q1 = r.q1; // ecmd.c:919-920
        if (linesel.q1 > linesel.q0 and linesel.q0 >= a3.q1 and linesel.q1 > a3.q1) { // ecmd.c:921-929
            a3 = linesel;
            try ranges.append(x.arena, linesel);
            continue;
        }
        break; // ecmd.c:930
    }
    try loopcmd(x, t, childOf(cp), ranges.items);
}

/// `loopcmd` (ecmd.c:841-850): run the child once per pre-collected range, with
/// `t.q0/q1` set to it so the child's default `.` address IS that range.
fn loopcmd(x: *cmd.Ctx, t: *Text, child: *ast.Cmd, ranges: []const ast.Range) ast.Error!void {
    for (ranges) |rng| {
        t.q0 = rng.q0;
        t.q1 = rng.q1;
        _ = try cmd.cmdexec(x, t, child);
    }
}

/// `cp->u.cmd` — the loop/guard body. The parser always fills `.cmd` for the
/// `x y g v` rows (a bare loop synthesizes a `p` child), so a non-`.cmd` arg is
/// a can't-happen.
fn childOf(cp: *ast.Cmd) *ast.Cmd {
    return switch (cp.arg) {
        .cmd => |c| c,
        else => unreachable, // parser guarantees a child for loop/guard commands
    };
}

/// Bounded `rx.execute` (`eof = r.q1`, no wrap) with `error.ListOverflow`
/// mapped to `error.Edit` + the regerror message (regx.c:622-627 / R-P10-2).
fn execBounded(x: *cmd.Ctx, src: Regx.Source, startp: usize, eof: usize) ast.Error!?Regx.Rangeset {
    return x.rx.execute(src, startp, eof) catch
        return x.diag.set("regexp list overflow", .{});
}

/// `lineaddr` with the enumerated-error → `error.Edit` translation (R-P10-3),
/// mirroring `cmd.zig`'s eval boundary.
fn lineAddr(x: *cmd.Ctx, l: usize, base: ast.Address, sign: i8) ast.Error!ast.Address {
    return addr.lineAddr(l, base, sign) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return x.diag.set("{s}", .{addr.describe(e)});
    };
}

fn textArg(cp: *ast.Cmd) []const u21 {
    return switch (cp.arg) {
        .text => |tx| tx,
        else => &[_]u21{},
    };
}

/// Low byte of a command char, for `{u}`-formatted messages.
fn loChar(cmdc: u16) u21 {
    return @intCast(cmdc & 0xff);
}

/// Append the FROZEN buffer's runes `[q0, q1)` to a rune accumulator (the s
/// command's `\j`/`&` expansion, ecmd.c:499-501/508-510).
fn appendRange(rbuf: *std.ArrayList(u21), a: std.mem.Allocator, buf: *const Buffer, q0: usize, q1: usize) error{OutOfMemory}!void {
    var k = q0;
    while (k < q1) : (k += 1) try rbuf.append(a, buf.runeAt(k));
}

/// Encode a rune slice to arena-owned UTF-8 (elog copies it into its own store).
fn runesToUtf8(a: std.mem.Allocator, runes: []const u21) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [4]u8 = undefined;
    for (runes) |r| {
        const nb = std.unicode.utf8Encode(r, &tmp) catch
            std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
        try buf.appendSlice(a, tmp[0..nb]);
    }
    return buf.toOwnedSlice(a);
}

// ==========================================================================
// Tests (side contract §3: tests 18-31). Driven through `edit.editcmd` on a
// standalone Text harness (mirroring edit.zig's EH). Every expected buffer/dot
// is hand-derived against the pinned C.
// ==========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("../File.zig");
const Editor = @import("../Editor.zig");
const edit = @import("edit.zig");

const rect = proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

/// A standalone Text over `seed` with an Editor (no window). `run` bumps
/// `ed.seq` first, mirroring the `Edit` builtin (exec.c:1141).
const EH = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,
    ed: Editor,

    fn init(seed: []const u8) !*EH {
        const a = testing.allocator;
        const h = try a.create(EH);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.text = try Text.init(&h.file, a, rect, h.fx.font, &h.fx.disp.image, h.fx.cols());
        h.ed = Editor.init(a);
        h.ed.text = &h.text;
        try h.text.fill();
        return h;
    }
    fn deinit(h: *EH) void {
        h.ed.deinit();
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn sel(h: *EH, q0: usize, q1: usize) !void {
        try h.text.setSelect(q0, q1);
    }
    fn run(h: *EH, command: []const u8) void {
        h.ed.seq += 1; // the builtin's exec.c:1141 seq++
        edit.editcmd(&h.ed, &h.text, command);
    }
    fn bufText(h: *EH) ![]u8 {
        const n = h.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, h.file.buffer.read(0, n, dest));
    }
    fn expectText(h: *EH, want: []const u8) !void {
        const got = try h.bufText();
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
    fn expectDot(h: *EH, q0: usize, q1: usize) !void {
        try testing.expectEqual(q0, h.text.q0);
        try testing.expectEqual(q1, h.text.q1);
    }
    fn warnings(h: *EH) []const u8 {
        return h.ed.warnings.items;
    }
};

test "edit: s first match only" {
    const h = try EH.init("abcabc");
    defer h.deinit();
    h.run(",s/b/X/"); // no g: only the first match
    try h.expectText("aXcabc");

    // Top-level miss ⇒ "no substitution" (nest==0, ecmd.c:522-523).
    const g = try EH.init("abcabc");
    defer g.deinit();
    g.run(",s/z/X/");
    try testing.expect(std.mem.indexOf(u8, g.warnings(), "no substitution") != null);
    try g.expectText("abcabc");
}

test "edit: s global flag" {
    const h = try EH.init("abcabc");
    defer h.deinit();
    h.run(",s/b/X/g");
    try h.expectText("aXcaXc");
}

test "edit: s nth and nth-plus-g" {
    {
        const h = try EH.init("abcabc");
        defer h.deinit();
        h.run(",s2/b/X/"); // only the 2nd match
        try h.expectText("abcaXc");
    }
    {
        const h = try EH.init("b b b b");
        defer h.deinit();
        h.run(",s2/b/X/g"); // 1st kept, rest replaced
        try h.expectText("b X X X");
    }
}

test "edit: s groups ampersand" {
    {
        const h = try EH.init("abcabc");
        defer h.deinit();
        h.run(",s/(a)(b)/\\2\\1/g"); // swap the two groups
        try h.expectText("bacbac");
    }
    {
        const h = try EH.init("abcabc");
        defer h.deinit();
        h.run(",s/b/[&]/g"); // & = whole match
        try h.expectText("a[b]ca[b]c");
    }
    {
        const h = try EH.init("abcabc");
        defer h.deinit();
        h.run(",s/b/\\&/"); // \& = literal ampersand
        try h.expectText("a&cabc");
    }
}

test "edit: s empty match advance" {
    const h = try EH.init("abc");
    defer h.deinit();
    h.run(",s/x*/-/g"); // empty match before every rune AND at end
    try h.expectText("-a-b-c-");
}

test "edit: x deletes matches" {
    {
        const h = try EH.init("abcabc");
        defer h.deinit();
        h.run(",x/b/d"); // delete each match
        try h.expectText("acac");
    }
    {
        const h = try EH.init("abcabc");
        defer h.deinit();
        h.run(",y/b/d"); // delete the gaps between matches
        try h.expectText("bb");
    }
}

test "edit: x default pattern is lines" {
    const h = try EH.init("a\nb\nc\n");
    defer h.deinit();
    h.run(",x d"); // bare x ⇒ linelooper over each line
    try h.expectText("");
}

test "edit: x m$ reorders via elog" {
    const h = try EH.init("abcb");
    defer h.deinit();
    h.run(",x/b/m$"); // move each "b" to end (frozen coordinates)
    try h.expectText("acbb");
}

test "edit: g and v guards" {
    {
        const h = try EH.init("a\nab\nb\n");
        defer h.deinit();
        h.run(",x/.*\\n/ g/a/d"); // delete each line that matches /a/
        try h.expectText("b\n");
    }
    {
        const h = try EH.init("a\nab\nb\n");
        defer h.deinit();
        h.run(",x/.*\\n/ v/a/d"); // delete each line that does NOT match /a/
        try h.expectText("a\nab\n");
    }
}

test "edit: composed x g s" {
    const h = try EH.init("a\nab\nb\n");
    defer h.deinit();
    // Only line 2 ("ab\n") passes the /ab/ guard; s/b/X/ edits it. The s-miss on
    // the guarded-out lines never happens (guard skips them), and even if it did
    // the loop nest>0 keeps it silent.
    h.run(",x/.*\\n/ g/ab/ s/b/X/");
    try h.expectText("a\naX\nb\n");
}

test "edit: braces address once" {
    const h = try EH.init("a\nb\n");
    defer h.deinit();
    // `2{a/X/ a/Y/}`: dot (line 2 = (2,4)) evaluated once; each `a` appends at
    // q1=4. Two inserts at the same q0 coalesce into ONE Elog record ⇒ "XY".
    h.run("2{\na/X/\na/Y/\n}");
    try h.expectText("a\nb\nXY");
    try h.expectDot(4, 6); // dot = the coalesced insertion "XY"
}

test "edit: lastpat reuse" {
    // Cross-invocation reuse: s//y/ reuses the "a" compiled by the earlier Edit.
    const h = try EH.init("aa");
    defer h.deinit();
    try h.sel(0, 2);
    h.run("s/a/x/"); // first "a" ⇒ "xa"
    try h.expectText("xa");
    h.run("s//y/"); // reuse "a": the remaining "a" ⇒ "xy"
    try h.expectText("xy");

    // Fresh editor: an empty pattern with no prior lastpat errors.
    const g = try EH.init("aa");
    defer g.deinit();
    try g.sel(0, 2);
    g.run("s//x/");
    try testing.expect(std.mem.indexOf(u8, g.warnings(), "no regular expression defined") != null);
    try g.expectText("aa");
}

test "edit: replace gap merge" {
    // Two s hits 1 rune apart (< Minstring): the gap text "c" must survive the
    // merge into one Replace record (elog.c:137-149) ⇒ correct "aXcXd".
    {
        const h = try EH.init("abcbd");
        defer h.deinit();
        h.run(",s/b/X/g");
        try h.expectText("aXcXd");
    }
    // Adjacent deletes coalesce (elog.c:205-207): two contiguous matches deleted.
    {
        const h = try EH.init("abbc");
        defer h.deinit();
        h.run(",x/b/d");
        try h.expectText("ac");
    }
}

test "edit: one undo per Edit" {
    const h = try EH.init("abcabc");
    defer h.deinit();
    const seq0 = h.ed.seq;
    h.run(",s/b/X/g"); // 2 substitutions, ONE transaction
    try h.expectText("aXcaXc");
    try testing.expectEqual(seq0 + 1, h.ed.seq); // exactly one seq bump per Edit
    _ = try h.file.undo(); // one undo restores everything
    try h.expectText("abcabc");
}
