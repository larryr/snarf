//! devdraw's PER-FONT STATE: the glyph-metrics cache a font image carries.
//! Namespace module (S-07 P-1) over `*DevDraw`, split out of `draw.zig`
//! verbatim in phase 16a so that file stays inside the ~400-line cap.
//!
//! Ported from `9/port/devdraw.c` (the kernel's DImage font fields); cite as
//! `devdraw.c:NN`. `DevDraw` keeps decl aliases for the three functions, so
//! `self.freeFont(...)`/`self.fontLadder(...)` resolve exactly as before.
const std = @import("std");
const ninep = @import("ninep");

const OpError = ninep.errors.OpError;

const DevDraw = @import("draw.zig").DevDraw;

// ===========================================================================
// Per-font state (mirrors the kernel's DImage font fields, devdraw.c:107-115,
// 130-132). A font is a normal image ('b') promoted by an 'i' verb: it grows a
// glyph-metrics table whose entries 'l' fills. `miny`/`maxy` are TRUNCATED to
// u8 exactly as the kernel's `uchar` FChar fields (devdraw.c:130-131, G18).
// ===========================================================================

pub const FChar = struct { minx: i32, maxx: i32, miny: u8, maxy: u8, left: i8, width: u8 };
pub const FontRec = struct { ascent: u8, chars: []FChar };
pub const zero_fchar: FChar = .{ .minx = 0, .maxx = 0, .miny = 0, .maxy = 0, .left = 0, .width = 0 };

/// Free the metrics table owned by font `id`, if any (devdraw.c:1679 `free`).
pub fn freeFont(self: *DevDraw, id: u32) void {
    if (self.fonts.fetchRemove(id)) |kv| self.allocator.free(kv.value.chars);
}

/// Free every font's `chars` slice and empty the map (clunk-reset / deinit).
pub fn freeAllFonts(self: *DevDraw) void {
    var it = self.fonts.valueIterator();
    while (it.next()) |fr| self.allocator.free(fr.chars);
    self.fonts.clearRetainingCapacity();
}

/// Is `id` a live image on this connection (a 'b'-allocation not yet freed)?
pub fn isAllocated(self: *DevDraw, id: u32) bool {
    for (self.allocated.items) |v| if (v == id) return true;
    return false;
}

/// Font ladder shared by 'l' and 's' (devdraw.c:1691-1694, 1963-1966): a
/// live font ⇒ its record; an allocated image that is not a font ⇒ NotFont;
/// anything else ⇒ NoDrawImage.
pub fn fontLadder(self: *DevDraw, id: u32) OpError!*FontRec {
    if (self.fonts.getPtr(id)) |fr| return fr;
    if (self.isAllocated(id)) return error.NotFont;
    return error.NoDrawImage;
}
