//! Scene birth (S-07 §4): assemble the acme window tree — a shared `Chrome`, a
//! top-level `Row`, its first `Column`, and an initial `Window` over a body
//! `File` — and hand back a `Tree` the entry point (`main_wasm`) or a test binds
//! the `Editor` router to. namespace module (S-07 P-1): `lowercase.zig`, no
//! file-as-struct — `Tree`/`Options` are the exported types.
//!
//! Ported composition from larryr/plan9port@337c6ac acme `main`/`rowinit`/
//! `rowadd`/`coladd`/`wininit` (acme.c, rows.c, cols.c, wind.c); cite as before.
//! This is the no-clone/no-dump startup: one row, one column, one (or more)
//! windows, each carrying a heap body `File`. `Dump`/`Load`, the command-line
//! file list, and `winsettag`'s directory/name composition are later phases —
//! the window tag here is the fixed fresh-window literal (wind.c:475-534).
//!
//! IMPORTANT (W2 precondition): `Window.init` lays out its frames but does NOT
//! lay out text into them (`Text.init` only back-fills BACK). A freshly-added
//! window therefore has an EMPTY body frame; `coladd`'s split math for the NEXT
//! window reads `v.body.fr.nlines`, so every window's body (and tag) is `fill()`ed
//! here right after creation, exactly as the Column/Row test harnesses do.
//!
//! Imports: `std` + `draw` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const draw = @import("draw");
const Chrome = @import("Chrome.zig");
const Row = @import("Row.zig");
const Column = @import("Column.zig");
const Window = @import("Window.zig");
const Text = @import("text/Text.zig");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");

const Rect = draw.Rect;
const Display = draw.Display;
const Font = draw.Font;

/// The command band a fresh window tag carries after its name (wind.c:475-534
/// `winsettag` — the fixed-command suffix; the leading space separates it from
/// the window name / file path).
pub const tag_suffix = " Del Snarf | Look ";

/// Boot parameters. `win_name` seeds the initial window's tag (its "filename"
/// slot — here a placeholder, since the served namespace is a later phase);
/// `body` is the initial body text.
pub const Options = struct {
    win_name: []const u8 = "scratch",
    body: []const u8 = "",
};

/// The assembled window tree. Owns the `Chrome`, the heap `Row` (which owns its
/// columns → windows → tags), and every heap body `File` (the Row/Column/Window
/// deinit chain frees tags but leaves body Files to their caller — here, us).
pub const Tree = struct {
    allocator: std.mem.Allocator,
    chrome: *Chrome,
    row: *Row,
    /// Heap body `File`s handed to windows, freed by `deinit` (Window/Column own
    /// only their tag Files).
    bodies: std.ArrayList(*File) = .empty,
    /// Running window id, pre-incremented by `coladd` (the C's `++winid`).
    winid: u32 = 0,

    pub fn deinit(tree: *Tree) void {
        const a = tree.allocator;
        tree.row.deinit();
        a.destroy(tree.row);
        for (tree.bodies.items) |f| {
            f.deinit();
            a.destroy(f);
        }
        tree.bodies.deinit(a);
        tree.chrome.deinit();
        tree.* = undefined;
    }

    /// Add a window carrying a fresh heap body `File` over `body` into `c`,
    /// stealing space per `coladd` (`y_in = -1` ⇒ split the last window / fill an
    /// empty column). Writes the fresh-window tag `name ++ tag_suffix`, parks the
    /// tag caret at its end, and fills both frames (the W2 precondition above).
    fn addWinTo(tree: *Tree, c: *Column, name: []const u8, body: []const u8) !*Window {
        const a = tree.allocator;
        const f = try a.create(File);
        errdefer a.destroy(f);
        f.* = File.init(a, try Buffer.initFromBytes(a, body));
        errdefer f.deinit();
        try tree.bodies.append(a, f);

        const w = try c.add(&tree.winid, f, -1); // coladd (steal / fill)

        // Fresh window tag: `name` then the fixed command suffix, caret at end
        // (winsettag composition, wind.c:475-534).
        try w.tag.insertAt(0, name, true);
        try w.tag.insertAt(w.tag.file.buffer.len(), tag_suffix, true);
        const nc = w.tag.file.buffer.len();
        try w.tag.setSelect(nc, nc);

        // Displayed-content precondition for subsequent coladds (W2 flag).
        try w.body.fill();
        try w.tag.fill();
        return w;
    }

    /// Add a second (or later) window into the tree's last column. The acceptance
    /// two-window variant and the routing tests drive this.
    pub fn addWindow(tree: *Tree, name: []const u8, body: []const u8) !*Window {
        const cols = tree.row.col.items;
        std.debug.assert(cols.len > 0);
        return tree.addWinTo(cols[cols.len - 1], name, body);
    }
};

/// Assemble the tree over screen rect `r`: `Chrome.init` (the palette solids),
/// a heap `Row` (rowtag + white ground), its first `Column` (columntag), and the
/// initial `Window`. The `Row`/`Column`/`Window` are individually heap-allocated
/// for address stability (a `Text`'s `SelectState` aliases its `Frame`, a
/// `Text.w` aliases its `Window`) — the Tree only moves by value, and nothing
/// points at the Tree itself.
pub fn boot(
    a: std.mem.Allocator,
    display: *Display,
    font: *Font,
    r: Rect,
    opts: Options,
) !Tree {
    const chrome = try Chrome.init(a, display, font);
    errdefer chrome.deinit();

    const row = try a.create(Row);
    errdefer a.destroy(row);
    try row.init(chrome, r);
    errdefer row.deinit();

    // First column fills the row (rowadd with no prior column, rows.c:87-90).
    const c = (try row.add(-1)) orelse return error.ColumnTooNarrow;

    var tree = Tree{ .allocator = a, .chrome = chrome, .row = row };
    errdefer tree.bodies.deinit(a);
    _ = try tree.addWinTo(c, opts.win_name, opts.body);
    return tree;
}

// ===========================================================================
// Tests. 9x18 font (height 18); Border 2, Scrollwid 12. Layout pins follow the
// Row/Column/Window contracts; the tag strings are byte-exact against the C.
// ===========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;

/// A Text's whole content as decoded UTF-8 (caller frees).
fn tagText(t: *Text) ![]u8 {
    const n = t.file.buffer.len();
    if (n == 0) return testing.allocator.alloc(u8, 0);
    const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer testing.allocator.free(dest);
    return testing.allocator.dupe(u8, t.file.buffer.read(0, n, dest));
}

fn expectTag(t: *Text, want: []const u8) !void {
    const got = try tagText(t);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "boot: tree shape and default tag strings" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var tree = try boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "scratch",
        .body = "hello\nworld\n",
    });
    defer tree.deinit();

    // One row → one column → one window.
    try testing.expectEqual(@as(usize, 1), tree.row.col.items.len);
    const c = tree.row.col.items[0];
    try testing.expectEqual(@as(usize, 1), c.w.items.len);
    const w = c.w.items[0];

    // Back-pointers wired through the tree.
    try testing.expectEqual(tree.row, c.row.?);
    try testing.expectEqual(c, w.col.?);
    try testing.expect(w.tag.w == w and w.body.w == w);
    try testing.expect(w.tag.what == .tag and w.body.what == .body);

    // Byte-exact tag strings (rows.c:16-23, cols.c:15-24, wind.c fresh tag).
    try expectTag(&tree.row.tag, "Newcol Kill Putall Dump Exit ");
    try expectTag(&c.tag, "New Cut Paste Snarf Sort Zerox Delcol ");
    try expectTag(&w.tag, "scratch Del Snarf | Look ");
    // The window tag caret parks at the end (wind.c winsettag tail).
    try testing.expectEqual(w.tag.file.buffer.len(), w.tag.q1);

    // The body carries the seed text and the window got id 1 (++winid).
    try expectTag(&w.body, "hello\nworld\n");
    try testing.expectEqual(@as(u32, 1), w.id);
    try testing.expectEqual(@as(u32, 1), tree.winid);

    // Rect tiling sanity: rowtag over the top strip, the column below its band,
    // the window filling the column region below the columntag.
    try testing.expectEqual(@as(i32, 18), tree.row.tag.fr.r.max.y); // 0 + fh
    try testing.expectEqual(proto.Rect.make(0, 0, 600, 460), tree.row.r);
    try testing.expectEqual(@as(i32, 600), c.r.max.x); // one column spans the row
    try testing.expect(c.r.min.y >= 20); // below rowtag(18) + Border(2)
    try testing.expect(w.r.min.y >= c.tag.fr.r.max.y + Chrome.border); // below columntag
    try testing.expectEqual(@as(i32, 460), w.r.max.y); // fills the column bottom
}

test "boot: addWindow stacks a second window in the column" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var tree = try boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "one",
        .body = "a\nb\nc\nd\ne\n",
    });
    defer tree.deinit();

    const w2 = try tree.addWindow("two", "x\ny\nz\n");
    const c = tree.row.col.items[0];
    try testing.expectEqual(@as(usize, 2), c.w.items.len);
    try testing.expectEqual(w2, c.w.items[1]);
    try testing.expectEqual(@as(u32, 2), w2.id); // second ++winid
    try expectTag(&w2.tag, "two Del Snarf | Look ");
    try expectTag(&w2.body, "x\ny\nz\n");

    // The two windows tile top-to-bottom: window 1 above window 2, no overlap.
    const w1 = c.w.items[0];
    try testing.expect(w1.r.max.y <= w2.r.min.y);
    try testing.expect(w2.r.max.y <= c.r.max.y);
}
