//! Shared window-chrome resources: the scrollbar/border geometry constants and
//! the solid `Image`s, allocated from the selected `Palette`, that the tag/body
//! frames, the scrollbar/button, and the row/column grounds and bands draw
//! through. file-as-struct (S-07 P-1): this file *is* the Chrome. One `Chrome`
//! is built at boot and borrowed (`*const Chrome`) by every `Window`/`Column`/`Row`.
//!
//! Ported from larryr/plan9port@337c6ac acme `iconinit` (acme.c:1036-1086) and
//! the `dat.h` scale macros (dat.h:475-479). DIVERGENCE (R-P8-1): the buttons are
//! drawn as fills (`windrawbutton`), not the pre-rendered `button`/`modbutton`
//! cache images the C allocates here — so `iconinit`'s button-image allocations
//! become the `mod_blue`/`colbutton` solids plus `buttonRect` geometry.
//! DIVERGENCE: acme mixes `tag_back`/`body_back` at runtime with `allocimagemix`
//! (c1·63/255 + white·192/255 on a deep display); we allocate solids of the
//! pre-computed mixed colors directly (the `Palette` tests prove the derivation).
//! DIVERGENCE (ADR-0007): the slot STRUCTURE is `iconinit`'s (acme.c:1044-1085),
//! but the VALUES come from a `Palette` chosen at boot — snarf's own schemes,
//! with acme's palette kept byte-exact as `Palette.acme`. TEXT/HTEXT and the
//! ground/rule fills that acme hard-wires to `display->black`/`display->white`
//! are palette slots too.
//!
//! Imports: `std` + `draw` + `Palette` only (S-07 §6 — core never imports dev/shim).
const std = @import("std");
const draw = @import("draw");
const Palette = @import("Palette.zig");

const Chrome = @This();
const Image = draw.Image;
const Font = draw.Font;
const Display = draw.Display;
const Color = draw.proto.Color;
const ncol = draw.Frame.ncol;

// --- geometry (dat.h:475-479, `scalesize` == identity at scale 1). ---
/// Scrollbar strip width (dat.h:475 `Scrollwid`).
pub const scrollwid: i32 = 12;
/// Gap between scrollbar and text (dat.h:476 `Scrollgap`).
pub const scrollgap: i32 = 4;
/// Window/column border thickness (dat.h:478 `Border`).
pub const border: i32 = 2;
/// Button border thickness (dat.h:479 `ButtonBorder`).
pub const button_border: i32 = 2;

allocator: std.mem.Allocator,
display: *Display,
font: *Font,
/// The scheme the solids below were allocated from.
pal: *const Palette,

// Owned solids (1×1 repl fills, freed by `deinit`).
tag_back_img: Image,
tag_high_img: Image,
tag_bord_img: Image,
body_back_img: Image,
body_high_img: Image,
body_bord_img: Image,
mod_blue_img: Image,
colbutton_img: Image,
but2_img: Image,
but3_img: Image,
tag_text_img: Image,
body_text_img: Image,
ground_img: Image,
rule_img: Image,

// Drawable handles (`*Image`, readable through a `*const Chrome`).
/// True display black/white, whatever the scheme.
black: *Image,
white: *Image,
/// Empty-space fill under the tree (acme.c:551, cols.c:32, rows.c:31).
ground: *Image,
/// Column/row separator bands (cols.c:45, rows.c:45).
rule: *Image,
/// Modified-button center fill (acme.c:1077).
mod_blue: *Image,
/// Column/row tag button fill (acme.c:1082).
colbutton: *Image,
/// B2 sweep highlight — dark red (acme.c:1084, dat.c:25).
but2col: *Image,
/// B3 sweep highlight — dark green (acme.c:1085, dat.c:26).
but3col: *Image,

/// Color slots for a tag/columntag/rowtag frame (`Frame.ColorSlot` order:
/// back, high, bord, text, htext) — acme `tagcols` (acme.c:1044-1048).
tag_cols: [ncol]*Image,
/// Color slots for a body frame — acme `textcols` (acme.c:1051-1055).
body_cols: [ncol]*Image,

/// `iconinit` (acme.c:1036-1086): allocate `pal`'s solids. Returns a heap
/// `*Chrome` so the `Image` back-pointers in `tag_cols`/`body_cols` stay stable.
pub fn init(allocator: std.mem.Allocator, display: *Display, font: *Font, pal: *const Palette) Display.Error!*Chrome {
    const chan = display.image.chan; // screen->chan (acme allocs solids in it)
    const c = try allocator.create(Chrome);
    errdefer allocator.destroy(c);
    c.allocator = allocator;
    c.display = display;
    c.font = font;
    c.pal = pal;
    c.black = &display.black;
    c.white = &display.white;
    c.tag_back_img = try solid(display, chan, pal.tag_back);
    c.tag_high_img = try solid(display, chan, pal.tag_high);
    c.tag_bord_img = try solid(display, chan, pal.tag_bord);
    c.body_back_img = try solid(display, chan, pal.body_back);
    c.body_high_img = try solid(display, chan, pal.body_high);
    c.body_bord_img = try solid(display, chan, pal.body_bord);
    c.mod_blue_img = try solid(display, chan, pal.mod);
    c.colbutton_img = try solid(display, chan, pal.col_button);
    c.but2_img = try solid(display, chan, pal.but2);
    c.but3_img = try solid(display, chan, pal.but3);
    c.tag_text_img = try solid(display, chan, pal.tag_text);
    c.body_text_img = try solid(display, chan, pal.body_text);
    c.ground_img = try solid(display, chan, pal.ground);
    c.rule_img = try solid(display, chan, pal.rule);
    c.mod_blue = &c.mod_blue_img;
    c.colbutton = &c.colbutton_img;
    c.but2col = &c.but2_img;
    c.but3col = &c.but3_img;
    c.ground = &c.ground_img;
    c.rule = &c.rule_img;
    c.tag_cols = .{ &c.tag_back_img, &c.tag_high_img, &c.tag_bord_img, &c.tag_text_img, &c.tag_text_img };
    c.body_cols = .{ &c.body_back_img, &c.body_high_img, &c.body_bord_img, &c.body_text_img, &c.body_text_img };
    return c;
}

/// Free the solids and the heap allocation.
pub fn deinit(c: *Chrome) void {
    c.tag_back_img.free() catch {};
    c.tag_high_img.free() catch {};
    c.tag_bord_img.free() catch {};
    c.body_back_img.free() catch {};
    c.body_high_img.free() catch {};
    c.body_bord_img.free() catch {};
    c.mod_blue_img.free() catch {};
    c.colbutton_img.free() catch {};
    c.but2_img.free() catch {};
    c.but3_img.free() catch {};
    c.tag_text_img.free() catch {};
    c.body_text_img.free() catch {};
    c.ground_img.free() catch {};
    c.rule_img.free() catch {};
    c.allocator.destroy(c);
}

/// One 1×1 replicated solid of `color` (alloc.c-style repl fill).
fn solid(display: *Display, chan: draw.proto.Chan, color: Color) Display.Error!Image {
    return display.allocImage(draw.proto.Rect.make(0, 0, 1, 1), chan, true, color);
}

/// `iconinit`'s button rectangle: `Rect(0, 0, Scrollwid, font.height+1)`
/// (acme.c:1058). The scrollbar-aligned button sits at `tag.scrollr.min`.
pub fn buttonRect(c: *const Chrome) draw.Rect {
    return draw.proto.Rect.make(0, 0, scrollwid, @as(i32, c.font.height) + 1);
}

// ===========================================================================
// Tests.
// ===========================================================================
const testing = std.testing;

test "chrome: geometry matches dat.h" {
    try testing.expectEqual(@as(i32, 12), scrollwid);
    try testing.expectEqual(@as(i32, 4), scrollgap);
    try testing.expectEqual(@as(i32, 2), border);
    try testing.expectEqual(@as(i32, 2), button_border);
}

test "chrome: init builds the color slots and button rect" {
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();

    const c = try Chrome.init(testing.allocator, fx.disp, fx.font, Palette.default);
    defer c.deinit();

    // Frame.ColorSlot order: back, high, bord, text, htext (HTEXT == TEXT).
    try testing.expectEqual(Palette.default, c.pal);
    try testing.expectEqual(&c.tag_back_img, c.tag_cols[0]);
    try testing.expectEqual(&c.tag_high_img, c.tag_cols[1]);
    try testing.expectEqual(&c.tag_bord_img, c.tag_cols[2]);
    try testing.expectEqual(&c.tag_text_img, c.tag_cols[3]);
    try testing.expectEqual(&c.tag_text_img, c.tag_cols[4]);
    try testing.expectEqual(&c.body_back_img, c.body_cols[0]);
    try testing.expectEqual(&c.body_text_img, c.body_cols[3]);
    try testing.expectEqual(&c.body_text_img, c.body_cols[4]);
    try testing.expectEqual(&c.mod_blue_img, c.mod_blue);
    try testing.expectEqual(&c.ground_img, c.ground);
    try testing.expectEqual(&c.rule_img, c.rule);
    // The true black/white handles stay the display's, whatever the scheme.
    try testing.expectEqual(&fx.disp.black, c.black);
    try testing.expectEqual(&fx.disp.white, c.white);

    // buttonRect is Scrollwid × (height+1) for the 9x18 font (acme.c:1058).
    try testing.expectEqual(draw.proto.Rect.make(0, 0, 12, 19), c.buttonRect());
}

test "chrome: but2/but3 handles point at the owned sweep solids" {
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    const c = try Chrome.init(testing.allocator, fx.disp, fx.font, &Palette.monadnock);
    defer c.deinit();

    // dat.c:25-26 extern into iconinit (acme.c:1084-1085).
    try testing.expectEqual(&c.but2_img, c.but2col);
    try testing.expectEqual(&c.but3_img, c.but3col);
    try testing.expectEqual(&Palette.monadnock, c.pal);
}
