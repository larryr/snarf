//! Shared window-chrome resources: the scrollbar/border geometry constants, the
//! acme color palette, and the solid `Image`s the tag/body frames and the
//! scrollbar/button draw through. file-as-struct (S-07 P-1): this file *is* the
//! Chrome. One `Chrome` is built at boot and borrowed (`*const Chrome`) by every
//! `Window`/`Column`/`Row`.
//!
//! Ported from larryr/plan9port@337c6ac acme `iconinit` (acme.c:1036-1086) and
//! the `dat.h` scale macros (dat.h:475-479). DIVERGENCE (R-P8-1): the buttons are
//! drawn as fills (`windrawbutton`), not the pre-rendered `button`/`modbutton`
//! cache images the C allocates here — so `iconinit`'s button-image allocations
//! become the `mod_blue`/`colbutton` solids plus `buttonRect` geometry.
//! DIVERGENCE: acme mixes `tag_back`/`body_back` at runtime with `allocimagemix`
//! (c1·63/255 + white·192/255 on a deep display); we allocate solids of the
//! pre-computed mixed colors directly (the palette test proves the derivation).
//!
//! Imports: `std` + `draw` only (S-07 §6 — core never imports dev/shim).
const std = @import("std");
const draw = @import("draw");

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

/// The acme palette (acme.c:1042-1085), rrggbbaa alpha-premultiplied. Nested so
/// the color values don't collide with the drawable-`Image` fields of the same
/// role below. `allocimagemix(c1, DWhite)` on a deep display yields
/// `c1·63/255 + white·192/255` per channel (the mixed backs are pre-computed).
pub const palette = struct {
    /// mix(DPalebluegreen, DWhite) (acme.c:1044).
    pub const tag_back: Color = 0xEAFFFFFF;
    /// DPalegreygreen (acme.c:1045).
    pub const tag_high: Color = 0x9EEEEEFF;
    /// DPurpleblue (acme.c:1046).
    pub const tag_bord: Color = 0x8888CCFF;
    /// mix(DPaleyellow, DWhite) (acme.c:1051).
    pub const body_back: Color = 0xFFFFEAFF;
    /// DDarkyellow (acme.c:1052).
    pub const body_high: Color = 0xEEEE9EFF;
    /// DYellowgreen (acme.c:1053) — CHANGES from black in the phase-7 single
    /// window main_wasm (R-P8-13).
    pub const body_bord: Color = 0x99994CFF;
    /// DMedblue (acme.c:1077) — the modified-button center.
    pub const mod_blue: Color = 0x000099FF;
    /// DPurpleblue (acme.c:1082) — the column/row tag button.
    pub const col_button: Color = 0x8888CCFF;
};

allocator: std.mem.Allocator,
display: *Display,
font: *Font,

// Owned solids (1×1 repl fills, freed by `deinit`).
tag_back_img: Image,
tag_high_img: Image,
tag_bord_img: Image,
body_back_img: Image,
body_high_img: Image,
body_bord_img: Image,
mod_blue_img: Image,
colbutton_img: Image,

// Drawable handles (`*Image`, readable through a `*const Chrome`). TEXT/HTEXT and
// window/column border fills are all display black (acme.c:1047-1055,1069).
black: *Image,
white: *Image,
/// Modified-button center fill (acme.c:1077).
mod_blue: *Image,
/// Column/row tag button fill (acme.c:1082).
colbutton: *Image,

/// Color slots for a tag/columntag/rowtag frame (`Frame.ColorSlot` order:
/// back, high, bord, text, htext) — acme `tagcols` (acme.c:1044-1048).
tag_cols: [ncol]*Image,
/// Color slots for a body frame — acme `textcols` (acme.c:1051-1055).
body_cols: [ncol]*Image,

/// `iconinit` (acme.c:1036-1086): allocate the palette solids. Returns a heap
/// `*Chrome` so the `Image` back-pointers in `tag_cols`/`body_cols` stay stable.
pub fn init(allocator: std.mem.Allocator, display: *Display, font: *Font) Display.Error!*Chrome {
    const chan = display.image.chan; // screen->chan (acme allocs solids in it)
    const c = try allocator.create(Chrome);
    errdefer allocator.destroy(c);
    c.allocator = allocator;
    c.display = display;
    c.font = font;
    c.black = &display.black;
    c.white = &display.white;
    c.tag_back_img = try solid(display, chan, palette.tag_back);
    c.tag_high_img = try solid(display, chan, palette.tag_high);
    c.tag_bord_img = try solid(display, chan, palette.tag_bord);
    c.body_back_img = try solid(display, chan, palette.body_back);
    c.body_high_img = try solid(display, chan, palette.body_high);
    c.body_bord_img = try solid(display, chan, palette.body_bord);
    c.mod_blue_img = try solid(display, chan, palette.mod_blue);
    c.colbutton_img = try solid(display, chan, palette.col_button);
    c.mod_blue = &c.mod_blue_img;
    c.colbutton = &c.colbutton_img;
    c.tag_cols = .{ &c.tag_back_img, &c.tag_high_img, &c.tag_bord_img, c.black, c.black };
    c.body_cols = .{ &c.body_back_img, &c.body_high_img, &c.body_bord_img, c.black, c.black };
    return c;
}

/// Free the palette solids and the heap allocation.
pub fn deinit(c: *Chrome) void {
    c.tag_back_img.free() catch {};
    c.tag_high_img.free() catch {};
    c.tag_bord_img.free() catch {};
    c.body_back_img.free() catch {};
    c.body_high_img.free() catch {};
    c.body_bord_img.free() catch {};
    c.mod_blue_img.free() catch {};
    c.colbutton_img.free() catch {};
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

/// `allocimagemix(c1, DWhite)` on a deep display (allocimagemix.c:28-42): blend
/// `c1` over white through a 0x3F (63/255) alpha mask, per channel.
fn mix(c1: u32) u32 {
    var out: u32 = 0;
    var shift: u5 = 24;
    while (true) {
        const c1b: u32 = (c1 >> shift) & 0xFF;
        const whiteb: u32 = 0xFF;
        const v: u32 = (c1b * 63 + whiteb * 192) / 255;
        out |= (v & 0xFF) << shift;
        if (shift == 0) break;
        shift -= 8;
    }
    return out;
}

test "chrome: palette matches acme" {
    // The mixed backgrounds derive from iconinit's allocimagemix (acme.c:1044,1051).
    try testing.expectEqual(@as(u32, 0xEAFFFFFF), mix(0xAAFFFFFF)); // mix(DPalebluegreen)
    try testing.expectEqual(palette.tag_back, mix(0xAAFFFFFF));
    try testing.expectEqual(@as(u32, 0xFFFFEAFF), mix(0xFFFFAAFF)); // mix(DPaleyellow)
    try testing.expectEqual(palette.body_back, mix(0xFFFFAAFF));

    // The direct-allocated solids are the named Plan 9 colors (draw.h).
    try testing.expectEqual(@as(u32, 0x9EEEEEFF), palette.tag_high); // DPalegreygreen
    try testing.expectEqual(@as(u32, 0x8888CCFF), palette.tag_bord); // DPurpleblue
    try testing.expectEqual(@as(u32, 0xEEEE9EFF), palette.body_high); // DDarkyellow
    try testing.expectEqual(@as(u32, 0x99994CFF), palette.body_bord); // DYellowgreen
    try testing.expectEqual(@as(u32, 0x000099FF), palette.mod_blue); // DMedblue
    try testing.expectEqual(@as(u32, 0x8888CCFF), palette.col_button); // DPurpleblue

    // Geometry (dat.h:475-479).
    try testing.expectEqual(@as(i32, 12), scrollwid);
    try testing.expectEqual(@as(i32, 4), scrollgap);
    try testing.expectEqual(@as(i32, 2), border);
    try testing.expectEqual(@as(i32, 2), button_border);
}

test "chrome: init builds the color slots and button rect" {
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();

    const c = try Chrome.init(testing.allocator, fx.disp, fx.font);
    defer c.deinit();

    // Frame.ColorSlot order: back, high, bord, text(black), htext(black).
    try testing.expectEqual(&c.tag_back_img, c.tag_cols[0]);
    try testing.expectEqual(&c.tag_high_img, c.tag_cols[1]);
    try testing.expectEqual(&c.tag_bord_img, c.tag_cols[2]);
    try testing.expectEqual(c.black, c.tag_cols[3]);
    try testing.expectEqual(c.black, c.tag_cols[4]);
    try testing.expectEqual(&c.body_back_img, c.body_cols[0]);
    try testing.expectEqual(c.black, c.body_cols[3]);
    try testing.expectEqual(&c.mod_blue_img, c.mod_blue);

    // buttonRect is Scrollwid × (height+1) for the 9x18 font (acme.c:1058).
    try testing.expectEqual(draw.proto.Rect.make(0, 0, 12, 19), c.buttonRect());
}
