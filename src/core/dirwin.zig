//! Directory windows — the `isdir` half of `textload` (text.c:200-275): the
//! entry sort (`dircmp`, text.c:121-133), the columnated layout
//! (`textcolumnate`, text.c:136-198) and the window-state flip a directory
//! listing performs. Namespace module (S-07 P-1, lowercase); kept out of
//! `Text.zig`/`Window.zig` so both stay inside the ~400-line budget.
//! Ported from larryr/plan9port@337c6ac; cite as `text.c:NN`.
//!
//! R-EDIT-03 / acme paper §User interface: "If a window represents a directory,
//! the name in the tag ends with a slash and the body contains a list of the
//! names of the files in the directory" — columnated, not one per line.
//!
//! WHO CALLS WHAT: the asynchronous `textload` lives in `Load.zig` (the 9P
//! listing arrives over several frames); once the stat records are in hand it
//! calls `applyListing` here, which is everything text.c:216-247 does after
//! `dirread` returns. `cmd_get.zig` re-enters through the same door.
//!
//! Imports: `std` + `draw` + `ninep` (stat records only) + sibling core files
//! (S-07 §6 — never dev/shim).
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");

const Stat = ninep.stat;

/// `TABDIR` (text.c:21): "width of tabs in directory windows", in units of the
/// '0' character.
pub const TABDIR: i32 = 3;

/// acme's `maxtab` default (acme.c:145-146: `if(maxtab == 0) maxtab = 4`), the
/// `$tabstop`/`-t` value. Snarf has no `-t` flag and no `ctl` tabstop write yet,
/// so the default is the only value; when either lands it overrides THIS
/// constant (dat.c:16 is a global, dat.h:514).
pub const default_maxtab: i32 = Text.maxtab;

/// One directory entry ready to lay out — the C's `Dirlist` (dat.h:288-292)
/// minus the byte copy: `name` is the entry name with a trailing '/' already
/// appended for directories, `wid` its `stringwidth` in the body's font.
pub const Entry = struct {
    name: []const u21,
    wid: i32,
};

/// `dircmp` (text.c:121-133): compare the first `min(nr)` RUNES, then the
/// lengths. The C `memcmp`s `Rune` arrays, i.e. it compares rune VALUES (on a
/// little-endian host a raw byte compare would order `0x100` before `0x02`);
/// this port compares values, which is what the C means everywhere it matters.
pub fn dirCmp(a: []const u21, b: []const u21) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    return std.math.order(a.len, b.len); // text.c:132 `da->nr - db->nr`
}

/// `qsort(dlp, ndl, …, dircmp)` (text.c:262) as a stable sort over `Entry`.
pub fn sortEntries(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, lessThan);
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return dirCmp(a.name, b.name) == .lt;
}

/// `textcolumnate` (text.c:136-198) verbatim, with one port-shaped change: the
/// C issues `ndl*2`-ish `fileinsert` calls straight into the File, then
/// `textload`'s tail re-`frinsert`s the displayed prefix; here the whole layout
/// is built as one UTF-8 string and handed to `Text.insertAt`, which updates
/// File AND Frame together. End state identical.
///
/// The `t->file->ntext > 1` early return (text.c:144-145) is n/a — one Text per
/// File in v1 (no Zerox).
///
/// TAB WIDTH (text.c:148): a directory window gets NARROWER tabs,
/// `min(maxtab, TABDIR) * stringwidth("0")` = 3×9 = 27 px at the 9×18 font.
/// `Frame` reads `maxtab` only at layout time (`frame/util.zig:134-135`
/// `_frnewwid0`) and neither `Frame.setRects` nor `Text.resize`/`fill` rewrites
/// it (only `Frame.init` does), so writing it here survives every later
/// redraw — no `maxtab_override` seam is needed.
///
/// A NON-directory Text gets `maxtab*stringwidth("0")` = 36 from `Text.init`
/// (text.c:53-60, ported in phase 16c — it used to keep libframe's `frinit`
/// default of 72). This narrowing to 27 is on top of that, exactly as in the C.
pub fn columnate(t: *Text, entries: []const Entry) Text.Error!void {
    const a = t.fr.allocator;
    const mint: i32 = t.fr.font.stringWidth("0"); // text.c:146
    t.fr.maxtab = @min(default_maxtab, TABDIR) * mint; // text.c:148
    const maxt: i32 = t.fr.maxtab; // text.c:149

    // --- column width (text.c:151-161) ---------------------------------
    var colw: i32 = 0;
    for (entries) |dl| {
        var w = dl.wid;
        if (maxt - @rem(w, maxt) < mint or @rem(w, maxt) == 0) w += mint; // text.c:155-156
        if (@rem(w, maxt) != 0) w += maxt - @rem(w, maxt); // text.c:157-158
        if (w > colw) colw = w; // text.c:159-160
    }
    const dx: i32 = t.fr.r.max.x - t.fr.r.min.x;
    const ncol: usize = if (colw == 0) 1 else @intCast(@max(1, @divTrunc(dx, colw))); // text.c:162-165
    const ndl = entries.len;
    if (ndl == 0) return; // nothing to lay out (the C's nrow==0 loop)
    const nrow: usize = (ndl + ncol - 1) / ncol; // text.c:166

    // --- the rows (text.c:168-197): row `i` holds entries i, i+nrow, … so the
    //     listing reads DOWN the columns. ------------------------------------
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < nrow) : (i += 1) {
        var j: usize = i;
        while (j < ndl) : (j += nrow) {
            const dl = entries[j];
            try appendRunes(&out, a, dl.name); // text.c:172-173
            if (j + nrow >= ndl) break; // text.c:174-175 last in this row
            var w = dl.wid; // text.c:176
            if (maxt - @rem(w, maxt) < mint) { // text.c:177-181
                try out.append(a, '\t');
                w += mint;
            }
            while (true) { // text.c:182-186 do/while
                try out.append(a, '\t');
                w += maxt - @rem(w, maxt);
                if (w >= colw) break;
            }
        }
        try out.append(a, '\n'); // text.c:188-189
    }
    try t.insertAt(0, out.items, true);
}

fn appendRunes(out: *std.ArrayList(u8), a: std.mem.Allocator, runes: []const u21) error{OutOfMemory}!void {
    var tmp: [4]u8 = undefined;
    for (runes) |r| {
        const n = std.unicode.utf8Encode(r, &tmp) catch std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
        try out.appendSlice(a, tmp[0..n]);
    }
}

/// `textreset` (text.c:112-124): empty the body WITHOUT building undo state —
/// `filereset` first (seq = 0, both stacks discarded), so the delete and the
/// reload that follows record nothing. Dot and origin go back to 0.
pub fn resetText(t: *Text) Text.Error!void {
    t.file.reset(); // text.c:114/122 `t->file->seq = 0` + filereset
    const nc = t.file.buffer.len();
    if (nc != 0) try t.deleteRange(0, nc, true); // seq==0 ⇒ nothing recorded
    t.org = 0; // text.c:119
    try t.setSelect(0, 0); // text.c:116/120-121
}

/// The `QTDIR` arm of `textload` (text.c:216-247) plus its tail (look.c:865-870,
/// which every caller of `textload` repeats): flip the window into a directory
/// window, give the name its trailing '/', sort + remember the entry names,
/// columnate them into the emptied body, and leave the window clean with a
/// fresh tag whose caret sits at the end.
///
/// `stats` is whatever the namespace listing produced, in namespace order — the
/// sort here is the one that matters (text.c:262). Entry names gain a trailing
/// '/' when the record is a directory (text.c:255-256).
pub fn applyListing(ed: *Editor, w: *Window, stats: []const Stat) Text.Error!void {
    // `ed` rides the contract signature (every other load-side entry takes it
    // and the C reaches the globals freely); nothing text.c:216-247 does needs
    // it — a listing is pure window state, and the allocator is the Chrome's.
    _ = ed;
    const a = w.chrome.allocator;
    const t = &w.body;

    // text.c:218-219: a directory window has no file menu.
    w.isdir = true;
    w.filemenu = false;

    // text.c:220-226: the name gains a trailing '/' if it lacks one.
    const name = t.file.name.items;
    if (name.len > 0 and name[name.len - 1] != '/') {
        const slashed = try std.fmt.allocPrint(a, "{s}/", .{name});
        defer a.free(slashed);
        try t.file.setName(slashed);
    }

    // text.c:230-260 `dirread` + Dirlist build. `windirfree` (wind.c:646-660)
    // first: a re-Get replaces the previous listing.
    freeDirNames(w);
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(a);
    errdefer freeDirNames(w);
    try entries.ensureTotalCapacity(a, stats.len);
    try w.dirnames.ensureTotalCapacity(a, stats.len);
    for (stats) |st| {
        const runes = try entryRunes(a, st.name, st.mode & Stat.DMDIR != 0);
        w.dirnames.appendAssumeCapacity(runes);
        entries.appendAssumeCapacity(.{ .name = runes, .wid = widthOf(t, runes) });
    }

    sortEntries(entries.items); // text.c:262
    // `w->dlp/w->ndl` (text.c:263-264) keeps the SORTED order for later use
    // (`Get` re-lists from the namespace, so these are the port's record of
    // what the window is currently showing).
    for (entries.items, 0..) |e, i| w.dirnames.items[i] = e.name;

    try resetText(t);
    try columnate(t, entries.items); // text.c:266

    // look.c:865-870 / acme.c:295-297: the load leaves the window clean.
    t.file.mod = false;
    w.dirty = false;
    try w.setTag1();
    const nc = w.tag.file.buffer.len();
    try w.tag.setSelect(nc, nc);
    w.tag_state = .{ .undo = false, .redo = false, .mod = false };
}

/// `strlen(name)` + the QTDIR '/' (text.c:253-257), decoded to runes.
fn entryRunes(a: std.mem.Allocator, name: []const u8, isdir: bool) error{OutOfMemory}![]const u21 {
    var out: std.ArrayList(u21) = .empty;
    errdefer out.deinit(a);
    const view = std.unicode.Utf8View.init(name) catch {
        for (name) |_| try out.append(a, 0xFFFD);
        if (isdir) try out.append(a, '/');
        return out.toOwnedSlice(a);
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try out.append(a, cp);
    if (isdir) try out.append(a, '/'); // text.c:255-256
    return out.toOwnedSlice(a);
}

/// `dl->wid = stringwidth(t->fr.font, tmp)` (text.c:258).
fn widthOf(t: *Text, runes: []const u21) i32 {
    var buf: [4]u8 = undefined;
    var w: i32 = 0;
    for (runes) |r| {
        const n = std.unicode.utf8Encode(r, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
        w += t.fr.font.stringWidth(buf[0..n]);
    }
    return w;
}

/// `windirfree` (wind.c:646-660): drop the remembered entry names.
pub fn freeDirNames(w: *Window) void {
    const a = w.chrome.allocator;
    for (w.dirnames.items) |n| a.free(n);
    w.dirnames.clearRetainingCapacity();
}

// ===========================================================================
// Smoke tests. The named battery (T1-T4 of the phase-13b contract) is the test
// writer's; these only keep the module's decls reachable and pin the two pure
// helpers.
// ===========================================================================
const testing = std.testing;

test "dirwin: dirCmp orders by rune then by length" {
    const a = [_]u21{ 'a', 'b' };
    const b = [_]u21{'b'};
    const c = [_]u21{'a'};
    try testing.expectEqual(std.math.Order.lt, dirCmp(&a, &b));
    try testing.expectEqual(std.math.Order.gt, dirCmp(&a, &c)); // longer wins ties
    try testing.expectEqual(std.math.Order.eq, dirCmp(&c, &c));
}

test "dirwin: the directory tab width is 3 zeroes, not 4" {
    try testing.expectEqual(@as(i32, 3), @min(default_maxtab, TABDIR));
}

// ===========================================================================
// Named battery (phase-13b contract §4, T1-T4).
// ===========================================================================
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");
const boot = @import("boot.zig");

test "dirwin: dirCmp — a < ab < b, length breaks a shared prefix, rune value not byte order (T1)" {
    // a < ab < b (text.c:121-133: compare min(nr) runes, then length).
    const a = [_]u21{'a'};
    const ab = [_]u21{ 'a', 'b' };
    const b = [_]u21{'b'};
    try testing.expectEqual(std.math.Order.lt, dirCmp(&a, &ab));
    try testing.expectEqual(std.math.Order.lt, dirCmp(&ab, &b));
    try testing.expectEqual(std.math.Order.lt, dirCmp(&a, &b));

    // "foo/" vs "foo": same prefix, the QTDIR-slashed name is LONGER and sorts
    // after (text.c:132 `da->nr - db->nr`).
    const foo = [_]u21{ 'f', 'o', 'o' };
    const foo_slash = [_]u21{ 'f', 'o', 'o', '/' };
    try testing.expectEqual(std.math.Order.lt, dirCmp(&foo, &foo_slash));
    try testing.expectEqual(std.math.Order.gt, dirCmp(&foo_slash, &foo));

    // RUNE-wise, not byte-wise: 0x02 vs 0x100. A little-endian BYTE memcmp of
    // the raw u21 storage would see 0x100's low byte (0x00) before 0x02's
    // (0x02) and order 0x100 first; comparing rune VALUES orders 0x02 first,
    // which is what the dirwin.zig doc comment claims this port does.
    const low = [_]u21{0x02};
    const high = [_]u21{0x100};
    try testing.expectEqual(std.math.Order.lt, dirCmp(&low, &high));
    try testing.expectEqual(std.math.Order.gt, dirCmp(&high, &low));
}

/// Build an `Entry` from an ASCII literal: `wid` from the FIXTURE's real font
/// (9x18, `stringWidth("0")==9`), `name` decoded to runes so `columnate`'s
/// output-comparison is byte-for-byte against `ascii`.
fn asciiEntry(a: std.mem.Allocator, t: *Text, ascii: []const u8) !Entry {
    const runes = try a.alloc(u21, ascii.len);
    for (ascii, 0..) |c, i| runes[i] = c;
    return .{ .name = runes, .wid = t.fr.font.stringWidth(ascii) };
}

test "dirwin: columnate golden — 7 names into a 640px body at the 9x18 font (T2)" {
    // mint = stringWidth("0") = 9; maxtab = min(default_maxtab=4, TABDIR=3)*9 = 27
    // (text.c:146-148). Hand-derivation (also cross-checked by simulating the
    // exact text.c:151-198 algorithm offline — see the phase-13b test report):
    //
    //   name        wid  colw-pass-w   colw
    //   Makefile     72   81            \
    //   README.md    81  108            |
    //   src          27   54            | max = 108
    //   docs         36   54            |
    //   build.zig    81  108            |
    //   LICENSE      63   81            |
    //   zig-cache    81  108           /
    //
    //   dx=640, ncol = max(1, 640/108) = 5, ndl=7, nrow = ceil(7/5) = 2.
    //
    // Row 0 (i=0, step nrow=2): indices 0,2,4,6 = Makefile, src, build.zig,
    // zig-cache (last in row: no trailing tabs). Row 1 (i=1): indices 1,3,5 =
    // README.md, docs, LICENSE (last in row).
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    var file = File.init(a, Buffer.initEmpty(a));
    defer file.deinit();
    // dx = (max.x - min.x) - (Scrollwid+Scrollgap) = 656 - 16 = 640 (text.c's
    // body Text, `textinit` scrollbar carve, S-07 divergence note in Text.init).
    var text = try Text.init(&file, a, proto.Rect.make(0, 0, 656, 470), fx.font, &fx.disp.image, .{ &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white });
    defer text.deinit();
    try testing.expectEqual(@as(i32, 640), text.fr.r.max.x - text.fr.r.min.x);

    const names = [_][]const u8{ "Makefile", "README.md", "src", "docs", "build.zig", "LICENSE", "zig-cache" };
    var entries: [names.len]Entry = undefined;
    for (names, 0..) |n, i| entries[i] = try asciiEntry(a, &text, n);
    defer for (entries) |e| a.free(e.name);

    try columnate(&text, &entries);

    try testing.expectEqual(@as(i32, 27), text.fr.maxtab); // TABDIR win (text.c:148)

    const n = text.file.buffer.len();
    const dest = try a.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer a.free(dest);
    const got = text.file.buffer.read(0, n, dest);
    try testing.expectEqualStrings(
        "Makefile\t\tsrc\t\t\tbuild.zig\tzig-cache\n" ++
            "README.md\tdocs\t\t\tLICENSE\n",
        got,
    );
}

test "dirwin: columnate sets the dir body's maxtab to 27; a normal Text gets acme's 36 (T3)" {
    // (renamed in 16c: the 72-px divergence this pinned is closed)
    // NAME NOTE: the divergence this test was written to pin is CLOSED — phase
    // 16c ported acme's `textinit` maxtab override (text.c:53-60), so a normal
    // Text is 36 (`maxtab*stringWidth("0")` = 4x9), not libframe's `frinit`
    // default of 72. The 16b/16c rule is that no test NAME disappears, so the
    // name still says 72; the expectations below are the live truth and the
    // test still pins BOTH sides — a normal body vs. a columnated directory.
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    // A normal (non-directory) window body: default maxtab, untouched by dirwin.
    var file1 = File.init(a, try Buffer.initFromBytes(a, "hello\n"));
    defer file1.deinit();
    var normal = try Text.init(&file1, a, proto.Rect.make(0, 0, 656, 470), fx.font, &fx.disp.image, .{ &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white });
    defer normal.deinit();
    try testing.expectEqual(@as(i32, 36), normal.fr.maxtab); // 4*9, textinit (16c)

    // A directory body: columnate narrows it to 27 (3*9, TABDIR).
    var file2 = File.init(a, Buffer.initEmpty(a));
    defer file2.deinit();
    var dir = try Text.init(&file2, a, proto.Rect.make(0, 0, 656, 470), fx.font, &fx.disp.image, .{ &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white, &fx.disp.white });
    defer dir.deinit();
    try testing.expectEqual(@as(i32, 36), dir.fr.maxtab); // still the normal 36 before columnate runs

    const e = try asciiEntry(a, &dir, "aaa");
    defer a.free(e.name);
    try columnate(&dir, &.{e});
    try testing.expectEqual(@as(i32, 27), dir.fr.maxtab);
}

test "dirwin: applyListing — trailing slash, isdir/filemenu, Get-not-Put tag, sorted dirnames (T4)" {
    const a = testing.allocator;
    var fx = try Frame.TestFixture.init();
    defer fx.deinit();

    // "one" is not yet a directory window; applyListing gives it the slash and
    // flips every flag textload's QTDIR arm flips (text.c:216-266).
    var tree = try boot.boot(a, fx.disp, fx.font, proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "one",
        .body = "stale\n",
    });
    defer tree.deinit();
    var ed = Editor.init(a);
    defer ed.deinit();
    tree.bind(&ed);

    const w = tree.row.col.items[0].w.items[0];
    // A recorded body edit before the listing lands, so `dirty`/`mod` are LIVE
    // going in — applyListing must clear both (look.c:865-870), not just leave
    // them at their already-false defaults.
    ed.seq += 1;
    w.body.file.mark(ed.seq);
    try w.body.insertAt(0, "X", true);
    try testing.expect(w.dirty);

    const stats = [_]Stat{
        .{ .qid = .{ .path = 0 }, .mode = Stat.DMDIR, .length = 0, .name = "zzz" },
        .{ .qid = .{ .path = 0 }, .mode = 0, .length = 0, .name = "aaa" },
    };
    try applyListing(&ed, w, &stats);

    try testing.expect(w.isdir);
    try testing.expect(!w.filemenu);
    try testing.expectEqualStrings("one/", w.body.file.name.items); // text.c:220-226

    try testing.expect(!w.dirty); // look.c:867
    try testing.expect(!w.body.file.mod); // look.c:866

    // dirnames sorted ("aaa" < "zzz/", text.c:262-264), the QTDIR entry slashed.
    try testing.expectEqual(@as(usize, 2), w.dirnames.items.len);
    const n0 = try utf8Of(a, w.dirnames.items[0]);
    defer a.free(n0);
    try testing.expectEqualStrings("aaa", n0);
    const n1 = try utf8Of(a, w.dirnames.items[1]);
    defer a.free(n1);
    try testing.expectEqualStrings("zzz/", n1);

    // The tag: name + " Del Snarf" + " Get" (wind.c:520-523, OUTSIDE the
    // filemenu arm) + " |" + " Look " — no "Undo"/"Redo"/"Put" (filemenu==FALSE).
    const tag = try tagOf(a, &w.tag);
    defer a.free(tag);
    try testing.expectEqualStrings("one/ Del Snarf Get | Look ", tag);
    // Caret parked at the tag end (look.c:868-869).
    try testing.expectEqual(w.tag.file.buffer.len(), w.tag.q1);
}

fn utf8Of(a: std.mem.Allocator, runes: []const u21) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var tmp: [4]u8 = undefined;
    for (runes) |r| {
        const n = std.unicode.utf8Encode(r, &tmp) catch unreachable;
        try out.appendSlice(a, tmp[0..n]);
    }
    return out.toOwnedSlice(a);
}

fn tagOf(a: std.mem.Allocator, t: *Text) ![]u8 {
    const n = t.file.buffer.len();
    if (n == 0) return a.alloc(u8, 0);
    const dest = try a.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer a.free(dest);
    return a.dupe(u8, t.file.buffer.read(0, n, dest));
}
