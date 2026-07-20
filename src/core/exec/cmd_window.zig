//! Window/column builtins: `del` (Del/Delete), `new` (New), `newcol` (Newcol),
//! `delcol` (Delcol), plus the `colOf`/`rowOf` tree resolvers and the shared
//! empty-window creation helper. namespace module (S-07 P-1). Ported from
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
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");
const Window = @import("../Window.zig");
const Column = @import("../Column.zig");
const Row = @import("../Row.zig");
const exec = @import("exec.zig");

/// `t->col` (dat.h): the Column a Text belongs to. A window text ⇒ the window's
/// column; a columntag ⇒ its own Column (via `@fieldParentPtr`); anything else
/// (a rowtag) ⇒ null.
fn colOf(et: *Text) ?*Column {
    if (et.w) |w| return w.col;
    if (et.what == .columntag) {
        const c: *Column = @fieldParentPtr("tag", et);
        return c;
    }
    return null;
}

/// `t->row` (dat.h): the Row a Text belongs to. A rowtag ⇒ its own Row (via
/// `@fieldParentPtr`); otherwise the row of `colOf(et)`.
fn rowOf(et: *Text) ?*Row {
    if (et.what == .rowtag) {
        const r: *Row = @fieldParentPtr("tag", et);
        return r;
    }
    const c = colOf(et) orelse return null;
    return c.row;
}

/// The New/Newcol empty-window creation helper (look.c:921-926 `coladd(col, nil,
/// nil, -1)` + `winsettag`). Mirrors `boot.addWinTo`: heap a body `File` over "",
/// hand it to the Column (which takes ownership, `owns_body`, R-P9-5), set the
/// name, compose the tag (`setTag1`), park the caret at the tag end, and fill both
/// frames. This is the seam the namespace phase's `openfile` replaces.
///
/// `pub` per ruling R-P10-I (agents/contracts/phase10-served.md): the served
/// tree's walk-to-`new` (`served/fsys.zig`) calls this directly — there is no
/// `cnewwindow` channel, so a 9P walk mints a window through the same helper New
/// uses (column chosen by the caller: `ed.seltext`'s, else the first column).
pub fn makeWindow(c: *Column, name: []const u8) Text.Error!*Window {
    const a = c.chrome.allocator;
    const f = try a.create(File);
    var transferred = false;
    errdefer if (!transferred) a.destroy(f);
    f.* = File.init(a, try Buffer.initFromBytes(a, ""));
    errdefer if (!transferred) f.deinit();

    const w = try c.add(&c.row.?.winid, f, -1); // coladd (steal / fill)
    w.owns_body = true; // the Window now owns and frees this body File
    transferred = true; // f is reachable from the tree; its deinit chain frees it

    try w.body.file.setName(name);
    try w.setTag1();
    const nc = w.tag.file.buffer.len();
    try w.tag.setSelect(nc, nc);
    try w.body.fill();
    try w.tag.fill();
    return w;
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
