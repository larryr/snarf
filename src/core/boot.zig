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
const ninep = @import("ninep");
const Chrome = @import("Chrome.zig");
const Editor = @import("Editor.zig");
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
    /// The session mount table this scene's editor reads files through
    /// (S-02 §1, phase 13a). Carried on the `Tree` and installed on the
    /// `Editor` by `Tree.bind`; null for every harness that never names a path.
    ns: ?*ninep.mount.Namespace = null,
};

/// The assembled window tree. Owns the `Chrome` and the heap `Row` (which owns
/// its columns → windows → tags). Body `File`s are now owned by their Windows
/// (`owns_body`, R-P9-5) and freed by the Row/Column/Window deinit chain; the
/// window-id counter lives on the `Row` (reachable from the Editor).
pub const Tree = struct {
    allocator: std.mem.Allocator,
    chrome: *Chrome,
    row: *Row,
    /// `Options.ns`, held for `bind`. The Tree does not use it itself — it has
    /// no 9P of its own; it is the editor that reads files (R-OV-03).
    ns: ?*ninep.mount.Namespace = null,

    /// Bind the routing machine to this scene: the window tree it hit-tests
    /// (`ed.row`) plus the namespace it reads files through (`ed.ns`, phase
    /// 13a). Every caller used to write the first line by hand; this is that
    /// line plus the handle, so a new scene cannot forget the namespace.
    pub fn bind(tree: *Tree, ed: *Editor) void {
        ed.row = tree.row;
        if (tree.ns) |n| ed.ns = n;
    }

    pub fn deinit(tree: *Tree) void {
        const a = tree.allocator;
        tree.row.deinit(); // frees columns → windows → owned body Files + tags
        a.destroy(tree.row);
        tree.chrome.deinit();
        tree.* = undefined;
    }

    /// Add a window carrying a fresh heap body `File` over `body` into `c`,
    /// stealing space per `coladd` (`y_in = -1` ⇒ split the last window / fill an
    /// empty column). The body `File` is heap-allocated and handed to the Window,
    /// which takes ownership (`owns_body`, R-P9-5). The tag is composed by
    /// `File.setName` + `Window.setTag1` (byte-identical to the old
    /// `name ++ tag_suffix` literal, wind.c:497-536); the caret parks at the tag
    /// end and both frames are filled (the W2 precondition above).
    fn addWinTo(tree: *Tree, c: *Column, name: []const u8, body: []const u8) !*Window {
        const a = tree.allocator;
        const f = try a.create(File);
        var transferred = false;
        errdefer if (!transferred) a.destroy(f);
        f.* = File.init(a, try Buffer.initFromBytes(a, body));
        errdefer if (!transferred) f.deinit();

        const w = try c.add(&tree.row.winid, f, -1); // coladd (steal / fill)
        w.owns_body = true; // the Window now owns and frees this body File
        transferred = true; // f is reachable from the tree; the tree frees it now

        // Fresh window tag via the winsettag composition (wind.c:497-536): set the
        // file name, compose, then park the caret at the tag end (the C leaves it
        // at 0, but Snarf's chrome parks it at the end — see the byte-identity pin).
        try w.body.file.setName(name);
        try w.setTag1();
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

    /// The screen is now `r`: repaint it and re-tile the whole window tree
    /// (R-GFX-05). This is acme's `MResize` arm after the reattach
    /// (acme.c:548-555) — `getwindow` has already run on the caller's side (the
    /// entry point, R-P12c-1), leaving exactly three C statements here:
    ///
    ///   * `draw(screen, screen->r, display->white, nil, ZP)` (acme.c:551) — the
    ///     white ground under everything;
    ///   * `rowresize(&row, screen->clipr)` (acme.c:555) — `Row.resize`, which
    ///     scales the columns proportionally and re-lays every window;
    ///   * `iconinit()` (acme.c:552) and `scrlresize()` (acme.c:553) have NO
    ///     Snarf analog: iconinit rebuilds the palette images, which for us are
    ///     1×1 replicated solids that no size can invalidate (`Chrome.init`), and
    ///     scrlresize rebuilds the scrollbar's temporary image, which our
    ///     scrollbar does not use (it draws straight onto the display).
    ///
    /// SNARF DIVERGENCE (contract §3f) — the rect is clamped to a usable minimum
    /// of 100 px wide by `3·font.height + 2·Border` tall before any of that. The
    /// C does not clamp; VERIFIED by driving the real tree at absurd sizes
    /// (phase 12c), the two axes fail differently:
    ///
    ///   * VERTICALLY the C degrades gracefully and so does the port.
    ///     `colresize` forces every window to at least `Border+font->height`
    ///     (cols.c:264) but then hands the LAST window `r1.max.y = r.max.y`
    ///     (cols.c:257), which by then can lie ABOVE `r1.min.y` — a
    ///     negative-height window rect. Nothing indexes out of range:
    ///     `Text.resize` collapses a non-positive height to zero (text.c:78-79)
    ///     and the backend drops the resulting empty draw rects (`drawclip`,
    ///     draw.c:236-245). A 640×58 row resize was exercised directly and is
    ///     clean; the tree merely tiles a taller region than the screen.
    ///   * HORIZONTALLY the C is FATAL, not merely ugly: every `Text` carves
    ///     `Scrollwid+Scrollgap` (16 px) off its left (text.c:85-87), and if what
    ///     remains cannot hold one rune libframe takes `drawerror` — measured at
    ///     the 9×18 font, a 25 px-wide Text still lays out and a 24 px-wide one
    ///     dies in `frinsert` (frinsert.c:169-170, ported as a panic). Hence the
    ///     100 px floor here, and — because a narrow row still scales its columns
    ///     down past that bound — the separate per-COLUMN floor in `Row.resize`
    ///     (see its divergence note). Screen clamp + column floor together cover
    ///     every reachable browser size: 1×1 through 4 columns was exercised and
    ///     no longer traps.
    ///
    /// Clamping keeps a 3-line minimum — row tag, column tag, one window line —
    /// which is the smallest layout that is still acme. A browser window smaller
    /// than that simply sees the top-left corner of a minimum-size editor.
    pub fn resize(tree: *Tree, r: Rect) !void {
        const chrome = tree.chrome;
        const rr = clampScreen(r, chrome.font.height);
        const screen = &chrome.display.image;
        try screen.draw(rr, chrome.white, null, .{}); // acme.c:551
        try tree.row.resize(rr); // acme.c:555 rowresize(&row, screen->clipr)
    }
};

/// The minimum screen width the tree is laid out in (see `Tree.resize`). 100 px
/// is the C's own idea of a viable column: `rowadd` refuses to split a column
/// narrower than that (`if(Dx(r) < 100) return nil`, rows.c:74-75).
const min_screen_width: i32 = 100;

/// Clamp a screen rectangle up to the usable minimum, growing `max` only (the
/// origin stays put, so a clamped screen still starts at the canvas corner).
fn clampScreen(r: Rect, font_height: i32) Rect {
    const min_h = 3 * font_height + 2 * Chrome.border; // rowtag + coltag + one body line
    var rr = r;
    if (rr.max.x - rr.min.x < min_screen_width) rr.max.x = rr.min.x + min_screen_width;
    if (rr.max.y - rr.min.y < min_h) rr.max.y = rr.min.y + min_h;
    return rr;
}

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

    var tree = Tree{ .allocator = a, .chrome = chrome, .row = row, .ns = opts.ns };
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

    // The body carries the seed text and the window got id 1 (++winid, now on Row).
    try expectTag(&w.body, "hello\nworld\n");
    try testing.expectEqual(@as(u32, 1), w.id);
    try testing.expectEqual(@as(u32, 1), tree.row.winid);

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

test "boot: setTag1 fresh tag is byte-identical to name ++ tag_suffix" {
    // R-P9-4 pin: the winsettag1 composition (name + " Del Snarf" + " |" +
    // " Look ", wind.c:497-536 for a fresh window with no pipe and seq==0) must be
    // byte-for-byte the old literal `name ++ tag_suffix`. `tag_suffix` survives
    // only as this test constant now that boot composes via setName + setTag1.
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var tree = try boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "scratch",
        .body = "",
    });
    defer tree.deinit();

    const w = tree.row.col.items[0].w.items[0];
    try expectTag(&w.tag, "scratch" ++ tag_suffix);
    // The caret parks at the tag end (Snarf chrome convention).
    try testing.expectEqual(w.tag.file.buffer.len(), w.tag.q1);
    // The body File is owned by the Window (R-P9-5).
    try testing.expect(w.owns_body);
}

test "boot: the ns option reaches the editor through Tree.bind" {
    // Phase 13a: `core` reads files ONLY through `ed.ns` (R-OV-03). A scene
    // booted with no namespace leaves it null — every pre-13a harness.
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var ns = ninep.mount.Namespace.init(testing.allocator);
    defer ns.deinit();

    var tree = try boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "scratch",
        .body = "",
        .ns = &ns,
    });
    defer tree.deinit();

    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect(ed.ns == null);
    tree.bind(&ed);
    try testing.expectEqual(&ns, ed.ns.?);
    try testing.expectEqual(tree.row, ed.row.?);
}

// ===========================================================================
// Phase 12c — Tree.resize (R-GFX-05, contract §3f).
// ===========================================================================

test "boot: resize grows the tree to fill a larger screen (T6)" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var tree = try boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "scratch",
        .body = "hello\n",
    });
    defer tree.deinit();

    const c = tree.row.col.items[0];
    const w = c.w.items[0];
    const bottom_before = w.body.fr.r.max.y;

    try tree.resize(proto.Rect.make(0, 0, 1024, 768));

    try testing.expectEqual(proto.Rect.make(0, 0, 1024, 768), tree.row.r);

    // The single column spans the full new width.
    try testing.expectEqual(@as(usize, 1), tree.row.col.items.len);
    try testing.expectEqual(@as(i32, 0), c.r.min.x);
    try testing.expectEqual(@as(i32, 1024), c.r.max.x);

    // The window's body reaches the bottom of the new screen: it grew, and it
    // is within one text line of the screen bottom — `Text.resize` quantizes
    // a non-keepextra resize down to a whole number of lines (text.c:80-81),
    // so exact pixel equality to 768 is not guaranteed, only "as close as a
    // whole line allows".
    try testing.expect(w.body.fr.r.max.y > bottom_before);
    try testing.expect(w.body.fr.r.max.y <= 768);
    try testing.expect(768 - w.body.fr.r.max.y < fx.font.height);

    // No rect exceeds the screen.
    try testing.expect(tree.row.r.max.x <= 1024 and tree.row.r.max.y <= 768);
    try testing.expect(c.r.max.x <= 1024 and c.r.max.y <= 768);
    try testing.expect(w.r.max.x <= 1024 and w.r.max.y <= 768);
    try testing.expect(w.tag.fr.r.max.x <= 1024 and w.body.fr.r.max.x <= 1024);
}

test "boot: shrink with two columns, two windows in one column (T7)" {
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var tree = try boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "one",
        .body = "hello\n",
    });
    defer tree.deinit();

    // Second column, then a second window stacked into the FIRST column (so
    // one column carries both windows and the other carries none — the more
    // demanding shape for the shrink).
    _ = (try tree.row.add(-1)).?;
    _ = try tree.addWinTo(tree.row.col.items[0], "two", "world\n");
    try testing.expectEqual(@as(usize, 2), tree.row.col.items.len);
    try testing.expectEqual(@as(usize, 2), tree.row.col.items[0].w.items.len);

    try tree.resize(proto.Rect.make(0, 0, 400, 300));

    try testing.expectEqual(proto.Rect.make(0, 0, 400, 300), tree.row.r);

    const c0 = tree.row.col.items[0];
    const c1 = tree.row.col.items[1];

    // Columns keep left-to-right order and neither overlaps the screen.
    try testing.expect(c0.r.min.x >= 0);
    try testing.expect(c0.r.max.x <= c1.r.min.x);
    try testing.expect(c1.r.max.x <= 400);
    try testing.expect(c0.r.max.y <= 300 and c1.r.max.y <= 300);

    // Every window in the doubly-occupied column stays within the screen.
    for (c0.w.items) |w| {
        try testing.expect(w.r.min.x >= c0.r.min.x and w.r.max.x <= c0.r.max.x);
        try testing.expect(w.r.max.y <= 300);
    }
}

test "boot: degenerate resize clamps to the usable minimum (T8)" {
    // SNARF DIVERGENCE (contract §3f, R-P12c chosen ruling): clamp, don't
    // error — acme.c has no analog for a screen this small, but a browser
    // window can shrink there and a trap is not acceptable (see the doc
    // comment on `Tree.resize`).
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var tree = try boot(testing.allocator, fx.disp, fx.font, proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "scratch",
        .body = "hello\n",
    });
    defer tree.deinit();

    // No error: clamping, not rejection.
    try tree.resize(proto.Rect.make(0, 0, 50, 20));

    // 100 px wide, 3*font.height + 2*Border tall — 18*3 + 2*2 = 58 at the 9x18
    // font (min_screen_width / clampScreen in this file).
    try testing.expectEqual(proto.Rect.make(0, 0, 100, 58), tree.row.r);

    // Every column is at least scrollwid+scrollgap+font.height (34px) wide.
    const min_col: i32 = Chrome.scrollwid + Chrome.scrollgap + fx.font.height;
    try testing.expectEqual(@as(i32, 34), min_col);
    for (tree.row.col.items) |c| {
        try testing.expect(c.r.max.x - c.r.min.x >= min_col);
    }

    // The tree is still consistent: still one column, one window, reachable.
    try testing.expectEqual(@as(usize, 1), tree.row.col.items.len);
    try testing.expectEqual(@as(usize, 1), tree.row.col.items[0].w.items.len);
}
