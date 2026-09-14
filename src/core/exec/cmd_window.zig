//! Window/column builtins: `del` (Del/Delete), `new` (New), `newcol` (Newcol),
//! `delcol` (Delcol). The `colOf`/`rowOf` tree resolvers and the shared
//! empty-window creation helper now live in `core/place.zig` (phase 12b) and are
//! aliased/wrapped below. namespace module (S-07 P-1). Ported from
//! larryr/plan9port@337c6ac acme/exec.c (:349-410 newcol/delcol/del) + look.c
//! (:901-942 new); cite as `exec.c:NN` / `look.c:NN`.
//!
//! `new`'s creation helper is deliberately a NAMED function (`makeWindow`): it is
//! the seam the namespace-phase `openfile` (look.c:846-899) replaces/extends when
//! real disk loading lands. v1 `New`-with-argument makes a NAMED EMPTY window (no
//! disk load — FLAG-divergence, R-P9-9).
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const Window = @import("../Window.zig");
const Column = @import("../Column.zig");
const exec = @import("exec.zig");
const place = @import("../place.zig");

/// `t->col` / `t->row` (dat.h). The canonical definitions moved to
/// `core/place.zig` in phase 12b (`makenewwindow` and `Editor`'s `activecol`
/// writers need them too); aliased here so the builtins below read unchanged.
const colOf = place.colOf;
const rowOf = place.rowOf;

/// The New/Newcol empty-window creation helper (look.c:921-926 `coladd(col, nil,
/// nil, -1)` + `winsettag`) — `place.mintWindow` at the C's default `y == -1`.
///
/// `pub` per ruling R-P10-I (agents/contracts/phase10-served.md). NOTE (phase
/// 12b): the served tree's walk-to-`new` no longer calls this — acme.c:877 runs
/// `makenewwindow(nil)`, so `served/fsys.zig` goes through `place.makeNewWindow`
/// now. `New`/`Newcol` keep THIS path, faithfully: look.c:922 and exec.c:352-364
/// both place into the EXECUTING tag's own column (R-P12b-2).
pub fn makeWindow(c: *Column, name: []const u8) Text.Error!*Window {
    return place.mintWindow(c, -1, name);
}

/// `del` (exec.c:397-410), Del (flag1=false) and Delete (flag1=true). Close the
/// executing window; Delete (flag1) skips the two-strike clean check and closes
/// immediately. The C's `ntext>1` arm is n/a (single Text per File in v1).
pub fn del(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    _: ?*Text,
    flag1: bool,
    _: bool,
    _: []const u8,
) Text.Error!void {
    const w = et.w orelse return; // exec.c:405-406
    const c = w.col orelse return; // exec.c:405 (et->col==nil guard)
    if (flag1 or w.clean(ed, false)) { // exec.c:408-409
        try c.close(ed, w, true); // colclose(et->col, et->w, TRUE)
    }
}

/// `new` (look.c:901-942), v1 (R-P9-9): make named/unnamed EMPTY windows in the
/// executing column (no disk load — `openfile`/`dirname` are namespace-phase).
///   * a 2-1 chord argument (`argt` selection) ⇒ ONE window named after it
///     (look.c:911-915);
///   * each blank-separated word of the inline `arg` (a swept "New foo bar") ⇒ a
///     window named after it (look.c:917-941, the disk-load arm reduced);
///   * no argument at all ⇒ one UNNAMED empty window (look.c:921-926).
/// `et->col == nil` (a rowtag) ⇒ nothing (look.c:920-923).
pub fn new(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    argt: ?*Text,
    _: bool,
    _: bool,
    arg: []const u8,
) Text.Error!void {
    const c = colOf(et) orelse return; // look.c:920 et->col
    var made_any = false;

    // 2-1 chord argument (look.c:910-915): one window named after the argt
    // selection. `narg==0` (no inline arg) ⇒ done.
    if (try exec.getArg(ed, argt)) |name| {
        defer ed.allocator.free(name);
        _ = try makeWindow(c, name);
        made_any = true;
        if (arg.len == 0) return; // look.c:913-914
    }

    // Inline arg words (look.c:917-941): a window per blank-separated word.
    var it = std.mem.tokenizeAny(u8, arg, " \t");
    while (it.next()) |word| {
        _ = try makeWindow(c, word);
        made_any = true;
    }
    // No argument at all ⇒ one unnamed window (look.c:921-926).
    if (!made_any) _ = try makeWindow(c, "");
}

/// `newcol` (exec.c:349-365): add a column to the executing row, then one UNNAMED
/// empty window in it (`coladd(c, nil, nil, -1)` + `winsettag`). A too-narrow
/// landing column makes `Row.add` return null ⇒ nothing.
pub fn newcol(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    _: ?*Text,
    _: bool,
    _: bool,
    _: []const u8,
) Text.Error!void {
    _ = ed;
    const r = rowOf(et) orelse return; // exec.c:362 et->row
    const c = (try r.add(-1)) orelse return; // rowadd(et->row, nil, -1)
    _ = try makeWindow(c, ""); // coladd(c, nil, nil, -1) + winsettag
}

/// `delcol` (exec.c:370-392): close the executing column IF it is clean. The C's
/// external-command check (`nopen`) is n/a. `Column.clean` (colclean, cols.c:
/// 582-590) strikes every dirty window in one pass (no short-circuit), so a
/// column with dirty windows refuses + warns on the first Delcol and succeeds on
/// the second. `Row.close` white-fills the row when the last column goes (R-P9-13
/// signature: `close(row, ed, c, dofree)`).
pub fn delcol(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    _: ?*Text,
    _: bool,
    _: bool,
    _: []const u8,
) Text.Error!void {
    const c = colOf(et) orelse return; // exec.c:383 et->col
    if (!c.clean(ed)) return; // exec.c:384 colclean(c)==0
    const r = rowOf(et) orelse return; // et->col->row (non-null for a tree column)
    try r.close(ed, c, true); // rowclose(et->col->row, et->col, TRUE)
}

// ===========================================================================
// Tests. Tree-mutating builtins are exercised end-to-end (with the full
// execute() dispatch) in exec.zig's tests 11-12; these check the resolvers and
// the creation helper directly.
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const boot = @import("../boot.zig");
const Chrome = @import("../Chrome.zig");

fn genLines(a: std.mem.Allocator, count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var line: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&line, "line{d:0>2}\n", .{i}) catch unreachable;
        try buf.appendSlice(a, &line);
    }
    return buf.toOwnedSlice(a);
}

test "cmd_window: colOf/rowOf resolve every tag flavor" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    const body = try genLines(testing.allocator, 20);
    defer testing.allocator.free(body);
    var tree = try boot.boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "one",
        .body = body,
    });
    defer tree.deinit();

    const c = tree.row.col.items[0];
    const w = c.w.items[0];

    // Window body/tag ⇒ the window's column; the column's row.
    try testing.expectEqual(c, colOf(&w.body).?);
    try testing.expectEqual(c, colOf(&w.tag).?);
    try testing.expectEqual(tree.row, rowOf(&w.body).?);
    // Columntag ⇒ its own column via @fieldParentPtr.
    try testing.expectEqual(c, colOf(&c.tag).?);
    try testing.expectEqual(tree.row, rowOf(&c.tag).?);
    // Rowtag ⇒ its own row; it has no column.
    try testing.expect(colOf(&tree.row.tag) == null);
    try testing.expectEqual(tree.row, rowOf(&tree.row.tag).?);
}

test "cmd_window: makeWindow creates a named empty owned window" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "one",
        .body = "seed\n",
    });
    defer tree.deinit();

    const c = tree.row.col.items[0];
    const before = c.w.items.len;
    const w = try makeWindow(c, "fresh");
    try testing.expectEqual(before + 1, c.w.items.len);
    try testing.expectEqual(@as(usize, 0), w.body.file.buffer.len()); // empty body
    try testing.expect(w.owns_body); // the window frees its own body File
    try testing.expectEqualStrings("fresh", w.body.file.name.items);
}

// ===========================================================================
// `makeNewWindow` placement tests (T10-T14, phase-12b contract §4). Live in
// `cmd_window.zig` alongside the builtins (per `place.zig`'s own doc note),
// using the same booted-tree pattern as the tests above.
// ===========================================================================

test "makeNewWindow: no activecol/seltext uses the LAST column (T10)" {
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "one",
        .body = "seed\n",
    });
    defer tree.deinit();
    const c2 = (try tree.row.add(-1)).?; // second (LAST) column

    var ed = Editor.init(a);
    defer ed.deinit();
    ed.row = tree.row;
    try testing.expect(ed.activecol == null);
    try testing.expect(ed.seltext == null);

    const before = c2.w.items.len;
    const w = try place.makeNewWindow(&ed, null);
    try testing.expectEqual(c2, w.col.?); // landed in the LAST column
    try testing.expectEqual(before + 1, c2.w.items.len);
    try testing.expectEqual(c2, ed.activecol.?); // util.c:466
}

test "makeNewWindow: activecol wins over t's own column (T11)" {
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "one",
        .body = "seed\n",
    });
    defer tree.deinit();
    const c1 = tree.row.col.items[0];
    const c2 = (try tree.row.add(-1)).?;
    const w2 = try tree.addWindow("two", "seed\n"); // lands in c2

    var ed = Editor.init(a);
    defer ed.deinit();
    ed.row = tree.row;
    ed.activecol = c1; // util.c:454-455 wins outright

    const before = c1.w.items.len;
    const w = try place.makeNewWindow(&ed, &w2.body); // t lives in c2
    try testing.expectEqual(c1, w.col.?);
    try testing.expectEqual(before + 1, c1.w.items.len);
    try testing.expectEqual(@as(usize, 1), c2.w.items.len); // c2 untouched
}

test "makeNewWindow: a big empty spot is used as-is (T12)" {
    // A TALL column with a short 2-line body: `blank = maxlines - nlines` is
    // comfortably >15 (util.c:483-486), so the new window is carved out of the
    // TOP of the empty space, `nlines*font.height` down from the body's top —
    // nowhere near the window's vertical midpoint (which the split arm, T13,
    // would use instead).
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 860), .{
        .win_name = "one",
        .body = "line1\nline2\n",
    });
    defer tree.deinit();
    const c = tree.row.col.items[0];
    const w1 = c.w.items[0];
    try testing.expect(w1.body.fr.maxlines - w1.body.fr.nlines > 15);

    const before_min_y = w1.body.fr.r.min.y;
    const before_nlines = w1.body.fr.nlines;
    const midpoint = @divTrunc(w1.r.min.y + w1.r.max.y, 2);
    const expected_y = before_min_y + @as(i32, @intCast(before_nlines)) * fx.font.height;

    var ed = Editor.init(a);
    defer ed.deinit();
    ed.row = tree.row;

    const w = try place.makeNewWindow(&ed, null);
    try testing.expectEqual(c, w.col.?);
    try testing.expectEqual(@as(usize, 2), c.w.items.len);

    // Distinguishes the empty-space arm from the split-midpoint arm: the new
    // window starts well ABOVE the old window's midpoint.
    try testing.expect(w.r.min.y < midpoint - 50);
    // Within a small band of the exact computed y (coladd's own line-boundary
    // clamp, cols.c:100-125, can shift it by a fraction of a line).
    try testing.expect(w.r.min.y >= expected_y - Chrome.border);
    try testing.expect(w.r.min.y <= expected_y + fx.font.height);
}

test "makeNewWindow: split arm bisects the biggest window; a tie picks the LOWER one (T13)" {
    // Two windows, geometry left alone but their Frame line-counts overridden
    // to force an EXACT tie with no blank space (`el <= 3`, util.c:483):
    // the `>=` comparison (util.c:475/479) must pick the SECOND (lower) window
    // as both `bigw` and `emptyw`, so the split lands at window 2's midpoint.
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "one",
        .body = "seed\n",
    });
    defer tree.deinit();
    const c = tree.row.col.items[0];
    const w1 = c.w.items[0];
    const w2 = try tree.addWindow("two", "seed\n");

    w1.body.fr.maxlines = 20;
    w1.body.fr.nlines = 18; // blank = 2
    w2.body.fr.maxlines = 20;
    w2.body.fr.nlines = 18; // blank = 2 — a genuine tie with w1

    const expected_y = @divTrunc(w2.r.min.y + w2.r.max.y, 2);

    var ed = Editor.init(a);
    defer ed.deinit();
    ed.row = tree.row;

    const w1_before = w1.r;
    const w = try place.makeNewWindow(&ed, null);
    try testing.expectEqual(c, w.col.?);
    try testing.expectEqual(@as(usize, 3), c.w.items.len);
    try testing.expect(w.r.min.y >= expected_y - fx.font.height);
    try testing.expect(w.r.min.y <= expected_y + fx.font.height);
    // w2 (the victim) shrank; w1 is untouched by the split.
    try testing.expectEqual(w1_before, w1.r); // w1's rect unchanged by the split
    try testing.expect(w2.r.max.y - w2.r.min.y < 200); // w2 visibly shrank from a full column
}

test "makeNewWindow: t's own window wins when it is not much smaller (T14)" {
    // Same forced-full-tie setup as T13, but `t` names window 1's own body and
    // window 1 is in `c` and not much smaller than `bigw` (util.c:489-490,
    // `Dy(t->w->r) > 2*Dy(bigw->r)/3`) — window 1 is seeded with enough lines
    // that `coladd`'s "shrink to just fit its content" clamp does not carve it
    // down to a sliver, so the natural half-split easily clears the 2/3 bar.
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    const seed1 = try genLines(a, 30);
    defer a.free(seed1);
    var tree = try boot.boot(a, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "one",
        .body = seed1,
    });
    defer tree.deinit();
    const c = tree.row.col.items[0];
    const w1 = c.w.items[0];
    const w2 = try tree.addWindow("two", "seed\n");
    try testing.expect(dy(w1.r) > @divTrunc(2 * dy(w2.r), 3)); // qualifies (util.c:489)

    w1.body.fr.maxlines = 20;
    w1.body.fr.nlines = 18; // blank = 2
    w2.body.fr.maxlines = 20;
    w2.body.fr.nlines = 18; // blank = 2 (tie; bigw would default to w2)

    const expected_y = @divTrunc(w1.r.min.y + w1.r.max.y, 2);

    var ed = Editor.init(a);
    defer ed.deinit();
    ed.row = tree.row;

    const w = try place.makeNewWindow(&ed, &w1.body); // t names w1
    try testing.expectEqual(c, w.col.?);
    try testing.expect(w.r.min.y >= expected_y - fx.font.height);
    try testing.expect(w.r.min.y <= expected_y + fx.font.height);
}

fn dy(r: proto.Rect) i32 {
    return r.max.y - r.min.y;
}

test "makeNewWindow: a squeezed new window is grown by colgrow, wired at util.c:494-495 (16b item 11 integration)" {
    // The `but == 1` arm itself is `column: grow gives a starved window lines
    // from its neighbours (16b item 11)` in Column.zig — this test pins the
    // ONE-LINE wire in `makeNewWindow` that calls it (util.c:494-495
    // `if(w->body.fr.maxlines < 2) colgrow(w->col, w, 1)`), by comparing the
    // real call against a CONTROL that lands the new window at the identical
    // split point via `mintWindow` alone, with no `colgrow` call at all.
    //
    // A 600x125 column with one 30-line window, split against itself (`t`
    // names its own body, so `makeNewWindow`'s victim is that same window —
    // util.c:489-490): the plain split leaves the new window at ONE line
    // (verified below via the control), which is exactly `makenewwindow`'s
    // trigger. Hand-computed against the 9x18 test font; a font/geometry
    // change may need new numbers, not a different assertion.
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();
    const seed = try genLines(a, 30);
    defer a.free(seed);
    const rect = proto.Rect.make(0, 0, 600, 125);

    // CONTROL: identical column, identical landing spot, `mintWindow` alone —
    // no `colgrow` in the path at all.
    {
        var tree = try boot.boot(a, fx.disp, fx.font, rect, .{ .win_name = "one", .body = seed });
        defer tree.deinit();
        const c = tree.row.col.items[0];
        const w1 = c.w.items[0];
        const mid = @divTrunc(w1.r.min.y + w1.r.max.y, 2);
        const w = try place.mintWindow(c, mid, "");
        try testing.expect(w.body.fr.maxlines < 2); // the scenario genuinely needs growth
    }

    // REAL: the same scenario through `makeNewWindow`, which wires `colgrow`
    // in when the freshly split window comes out under two lines.
    var tree = try boot.boot(a, fx.disp, fx.font, rect, .{ .win_name = "one", .body = seed });
    defer tree.deinit();
    const c = tree.row.col.items[0];
    const w1 = c.w.items[0];

    var ed = Editor.init(a);
    defer ed.deinit();
    ed.row = tree.row;
    const w = try place.makeNewWindow(&ed, &w1.body);

    try testing.expect(w.body.fr.maxlines >= 2); // colgrow fixed what the split alone would not
    try testing.expectEqual(@as(usize, 2), c.w.items.len);
    // Still tiled, in order, no overlap (colgrow's own invariant, cross-checked here).
    try testing.expect(c.w.items[0] == w1 and c.w.items[1] == w);
    try testing.expect(w1.r.max.y <= w.r.min.y);
    try testing.expect(w.r.max.y <= c.r.max.y);
}
