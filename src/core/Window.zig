//! A window: a tag `Text` stacked over a body `Text`, sharing one rectangle with
//! a 1px divider between them and a scroll/modified button at the body's
//! scrollbar origin. file-as-struct (S-07 P-1): this file *is* the Window.
//!
//! Ported from larryr/plan9port@337c6ac acme/wind.c; cite as `wind.c:NN`. This is
//! the no-clone `wininit` (wind.c:17-90) and the taglines==1 `winresize`
//! (wind.c:179-250) with the mouse-warp arms dropped (R-P8-7 — a browser can't
//! `moveto` the pointer). `winsettag`/`winclean`/`parsetag` are phase 9.
//!
//! The `Window`↔`Text` import cycle is intended and legal in Zig (the Display↔
//! Image precedent, see Image.zig's header): a `Text` back-points to its Window
//! via `?*Window`, and a Window embeds two `Text`s by value.
//!
//! Imports: `std` + `draw` + sibling core files only (S-07 §6).
const std = @import("std");
const draw = @import("draw");
const Chrome = @import("Chrome.zig");
const Text = @import("text/Text.zig");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");

const Window = @This();
const Rect = draw.Rect;
const Image = draw.Image;

pub const Error = Text.Error;

tag: Text,
body: Text,
/// The tag's backing `File` (its editable text), owned by the Window. The body's
/// `File` is passed in and owned by the caller.
tag_file: File,
r: Rect,
/// First tag line, for the collapsed-tag hit region (dat.h:275; wind.c:38).
tagtop: Rect,
id: u32,
/// The owning `Column`. TYPED `?*anyopaque` in wave 1 because `Column` is a
/// wave-2 file; W2 retypes this to `?*Column` when it lands (it is a stored
/// back-pointer only, untouched by any wave-1 method).
col: ?*anyopaque = null,
/// Tag height in lines — fixed at 1 this phase (R-P8-1; `wintaglines` is later).
taglines: i32 = 1,
maxlines: usize = 0,
chrome: *const Chrome,

/// `wininit` (wind.c:17-90), no-clone: lay out the tag over the top strip and the
/// body below a 1px purpleblue divider, draw the scrollbar + button. `body_file`
/// is borrowed (caller-owned); the tag's File is constructed here.
pub fn init(w: *Window, chrome: *const Chrome, body_file: *File, id: u32, r: Rect) Error!void {
    const a = chrome.allocator;
    const font = chrome.font;
    const fh: i32 = font.height;
    const screen = &chrome.display.image;

    w.chrome = chrome;
    w.taglines = 1; // wind.c:27
    w.id = id; // wind.c:30
    w.col = null;
    w.r = r;

    // tagtop = the first tag line (dat.h:275; wind.c:38-39).
    w.tagtop = r;
    w.tagtop.max.y = r.min.y + fh;

    // Tag over the 1-line strip (wind.c:36-45); its File is built here.
    var r1 = r;
    r1.max.y = r1.min.y + w.taglines * fh;
    w.tag_file = File.init(a, try Buffer.initFromBytes(a, ""));
    errdefer w.tag_file.deinit();
    w.tag = try Text.init(&w.tag_file, a, r1, font, screen, chrome.tag_cols);
    w.tag.what = .tag; // wind.c:45
    w.tag.w = w; // wind.c:26

    // Body below the tag + a 1px divider (wind.c:57-71).
    r1 = r;
    r1.min.y += w.taglines * fh + 1;
    if (r1.max.y < r1.min.y) r1.max.y = r1.min.y; // wind.c:59-60
    w.body = try Text.init(body_file, a, r1, font, screen, chrome.body_cols);
    w.body.what = .body; // wind.c:70
    w.body.w = w; // wind.c:29

    // 1px PURPLEBLUE divider above the body (wind.c:72-74 — tagcols[BORD], NOT
    // black).
    r1.min.y -= 1;
    r1.max.y = r1.min.y + 1;
    try screen.draw(r1, w.tag.fr.col(.bord), null, .{});

    try w.body.scrDraw(); // wind.c:75
    w.r = r; // wind.c:76
    try w.drawButton(); // wind.c:77-80
    w.maxlines = w.body.fr.maxlines; // wind.c:82
}

/// Free the two Texts and the tag's File. The body's File is caller-owned.
pub fn deinit(w: *Window) void {
    w.body.deinit();
    w.tag.deinit();
    w.tag_file.deinit();
}

/// `winresize` (wind.c:179-250), taglines==1, no mouse warp: relayout the tag
/// over the top strip and the body below the divider (or collapse the body when
/// the rect is too short for even one line). Returns the new `r.max.y`.
///
/// `safe` (the C's tagsafe/eqrect short-circuits) is accepted for call-site
/// parity with `Column.resize` but unused: we always relayout — behaviourally
/// identical, only skipping an optimization we don't track.
pub fn resize(w: *Window, r: Rect, safe: bool, keepextra: bool) Error!i32 {
    _ = safe;
    const font = w.chrome.font;
    const fh: i32 = font.height;
    const screen = &w.chrome.display.image;

    // tagtop is the first tag line (wind.c:190-191).
    w.tagtop = r;
    w.tagtop.max.y = r.min.y + fh;

    var r1 = r; // wind.c:193-194
    r1.max.y = @min(r.max.y, r1.min.y + w.taglines * fh);
    // taglines stays 1 (no wintaglines recompute, wind.c:196-200).

    // Resize & redraw the tag (wind.c:204-208).
    _ = try w.tag.resize(r1, true);
    var y = w.tag.fr.r.max.y; // wind.c:206
    try w.drawButton(); // wind.c:207
    // (mouse-warp arms wind.c:210-222 dropped, R-P8-7.)

    // Resize & redraw the body (wind.c:226-247).
    r1 = r;
    r1.min.y = y;
    const oy = y; // wind.c:229
    if (y + 1 + fh <= r.max.y) { // wind.c:230 room for one line
        r1.min.y = y;
        r1.max.y = y + 1;
        try screen.draw(r1, w.tag.fr.col(.bord), null, .{}); // wind.c:233 divider
        y += 1;
        r1.min.y = @min(y, r.max.y); // wind.c:235
        r1.max.y = r.max.y; // wind.c:236
    } else { // wind.c:237-241 too short: fill leftover, give the body an empty rect
        try screen.draw(r1, w.body.fr.col(.back), null, .{}); // wind.c:238
        r1.min.y = y; // wind.c:239
        r1.max.y = y; // wind.c:240
    }
    y = try w.body.resize(r1, keepextra); // wind.c:242
    w.r = r; // wind.c:243
    w.r.max.y = y; // wind.c:244
    try w.body.scrDraw(); // wind.c:245
    w.body.all.min.y = oy; // wind.c:246
    w.maxlines = @min(w.body.fr.nlines, @max(w.maxlines, w.body.fr.maxlines)); // wind.c:248
    return w.r.max.y; // wind.c:249
}

/// `windrawbutton` (wind.c:95-108) as fills (R-P8-1, not the cached button
/// images): a `tag_back` ground, a 2px `tag_bord` ring, and — when the body file
/// is modified — a `mod_blue` center (the `modbutton`, iconinit acme.c:1073-1078).
/// isdir/isscratch/ncache are dropped (single-window F-9).
pub fn drawButton(w: *Window) Error!void {
    const screen = &w.chrome.display.image;
    const dim = w.chrome.buttonRect(); // (0,0,Scrollwid,height+1)
    const dx = dim.max.x - dim.min.x;
    const dy = dim.max.y - dim.min.y;
    var br: Rect = undefined;
    br.min = w.tag.scrollr.min; // wind.c:105
    br.max = .{ .x = br.min.x + dx, .y = br.min.y + dy }; // wind.c:106-107
    try screen.draw(br, w.tag.fr.col(.back), null, .{}); // iconinit acme.c:1069
    try border(screen, br, Chrome.button_border, w.tag.fr.col(.bord)); // acme.c:1070
    if (w.body.file.mod) { // wind.c:102 (mod ⇒ modbutton)
        try screen.draw(insetRect(br, Chrome.button_border), w.chrome.mod_blue, null, .{});
    }
}

/// `border` SoverD (border.c:6-24): a ring of thickness `i` inside `r` — top,
/// bottom, then the left/right sides between them.
fn border(img: *Image, r: Rect, i: i32, color: *Image) Error!void {
    try img.draw(.{ .min = .{ .x = r.min.x, .y = r.min.y }, .max = .{ .x = r.max.x, .y = r.min.y + i } }, color, null, .{});
    try img.draw(.{ .min = .{ .x = r.min.x, .y = r.max.y - i }, .max = .{ .x = r.max.x, .y = r.max.y } }, color, null, .{});
    try img.draw(.{ .min = .{ .x = r.min.x, .y = r.min.y + i }, .max = .{ .x = r.min.x + i, .y = r.max.y - i } }, color, null, .{});
    try img.draw(.{ .min = .{ .x = r.max.x - i, .y = r.min.y + i }, .max = .{ .x = r.max.x, .y = r.max.y - i } }, color, null, .{});
}

/// `insetrect` (rectclip.c): shrink `r` by `n` on every side.
fn insetRect(r: Rect, n: i32) Rect {
    return .{ .min = .{ .x = r.min.x + n, .y = r.min.y + n }, .max = .{ .x = r.max.x - n, .y = r.max.y - n } };
}

// ===========================================================================
// Tests. 9x18 font (height 18), Scrollwid 12 / Scrollgap 4 / ButtonBorder 2.
// ===========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;

/// Count draw ('d')/string ('s') verbs in one flushed write (mirrors select.zig).
fn countDraws(buf: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < buf.len) {
        switch (buf[i]) {
            'v' => i += 1,
            'd' => {
                i += 45;
                n += 1;
            },
            's' => {
                const ni = std.mem.readInt(u16, buf[i + 45 ..][0..2], .little);
                i += 47 + 2 * ni;
                n += 1;
            },
            else => break,
        }
    }
    return n;
}

const WinHarness = struct {
    fx: Frame.TestFixture,
    chrome: *Chrome,
    body_file: File,
    w: Window,

    fn init(seed: []const u8, r: Rect) !*WinHarness {
        const a = testing.allocator;
        const h = try a.create(WinHarness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.chrome = try Chrome.init(a, h.fx.disp, h.fx.font);
        h.body_file = File.init(a, try Buffer.initFromBytes(a, seed));
        try h.w.init(h.chrome, &h.body_file, 1, r);
        return h;
    }
    fn deinit(h: *WinHarness) void {
        h.w.deinit();
        h.body_file.deinit();
        h.chrome.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
};

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

test "window: resize splits tag/divider/body with 9x18 font" {
    const seed = try genLines(testing.allocator, 40);
    defer testing.allocator.free(seed);
    const h = try WinHarness.init(seed, proto.Rect.make(0, 20, 300, 380));
    defer h.deinit();
    const w = &h.w;

    const bot = try w.resize(proto.Rect.make(0, 20, 300, 380), false, false);

    // Two texts, correctly typed and back-pointed.
    try testing.expect(w.tag.what == .tag);
    try testing.expect(w.body.what == .body);
    try testing.expect(w.tag.w == w and w.body.w == w);

    // tagtop + tag occupy exactly one 18px line at the top.
    try testing.expectEqual(@as(i32, 38), w.tagtop.max.y); // 20 + 18
    try testing.expectEqual(@as(i32, 38), w.tag.fr.r.max.y);

    // Body begins one pixel below the tag (the divider), and its `all.min.y` is
    // pinned to the tag bottom (wind.c:246).
    try testing.expectEqual(@as(i32, 38), w.body.all.min.y); // oy
    try testing.expectEqual(@as(i32, 39), w.body.fr.r.min.y); // past the 1px divider

    // Scrollbar carved off the body's left: strip [x,x+12), text at x+16.
    try testing.expectEqual(w.body.all.min.x + 12, w.body.scrollr.max.x);
    try testing.expectEqual(w.body.all.min.x + 16, w.body.fr.r.min.x);

    // resize returns w.r.max.y (the body's trimmed bottom).
    try testing.expectEqual(w.r.max.y, bot);
    try testing.expectEqual(w.body.all.max.y, bot);
}

test "window: too-short rect collapses the body" {
    const seed = try genLines(testing.allocator, 40);
    defer testing.allocator.free(seed);
    const h = try WinHarness.init(seed, proto.Rect.make(0, 20, 300, 380));
    defer h.deinit();
    const w = &h.w;

    // Height 30: room for the 18px tag, but y(38)+1+18 > 50 ⇒ the body collapses
    // to an empty rect at the tag bottom (wind.c:237-241).
    const bot = try w.resize(proto.Rect.make(0, 20, 300, 50), false, false);
    try testing.expectEqual(@as(usize, 0), w.body.fr.maxlines);
    try testing.expectEqual(@as(i32, 38), w.body.all.min.y);
    try testing.expectEqual(@as(i32, 38), bot); // w.r.max.y == the tag bottom
}

test "window: drawButton reflects file.mod" {
    const seed = try genLines(testing.allocator, 40);
    defer testing.allocator.free(seed);
    const h = try WinHarness.init(seed, proto.Rect.make(0, 20, 300, 380));
    defer h.deinit();
    const w = &h.w;

    // Unmodified: a tag_back ground + a 4-rect tag_bord ring = 5 fills.
    try testing.expect(!w.body.file.mod);
    try h.fx.disp.flush();
    var base = h.fx.tree.writes.items.len;
    try w.drawButton();
    try h.fx.disp.flush();
    try testing.expectEqual(@as(usize, 5), countDraws(h.fx.tree.writes.items[base]));

    // Modified: the mod_blue center adds a 6th fill (the modbutton).
    w.body.file.mod = true;
    base = h.fx.tree.writes.items.len;
    try w.drawButton();
    try h.fx.disp.flush();
    try testing.expectEqual(@as(usize, 6), countDraws(h.fx.tree.writes.items[base]));
}
