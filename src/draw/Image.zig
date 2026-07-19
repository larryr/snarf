//! A draw-protocol image handle — the libdraw `Image` (alloc.c/draw.c),
//! file-as-struct (S-07 P-1): this file *is* the `Image`. An `Image` is a
//! lightweight handle over its `id`; the pixels live server-side in
//! `/dev/draw`. It carries a back-pointer to the `Display` that owns the
//! connection so `draw`/`free` can reach the write buffer.
//!
//! The `Display`↔`Image` import cycle is intended and legal in Zig (see
//! Display.zig's header) — do not "fix" it.
const std = @import("std");
const proto = @import("proto.zig");
const Display = @import("Display.zig");

const Image = @This();

/// The connection this image belongs to (borrowed, stable: `Display` is heap).
display: *Display,
/// Server-side image id. 0 is the display itself (G6); allocated images are
/// >= 1 and never 0.
id: u32,
r: proto.Rect,
clipr: proto.Rect,
chan: proto.Chan,
repl: bool,

/// SoverD-draw `src` (through `mask`) into `dst` over rectangle `r`, emitting
/// a 'd' verb (draw1, draw.c:20-45). A nil `mask` becomes the display's opaque
/// white 1×1 solid (G4; draw.c:31-32). The source and mask points coincide:
/// `draw` passes the same point for both (draw.c:48-51 `draw1(..,&p1,..,&p1,..)`),
/// so `sp == mp == p`. Buffered — reaches the wire on the next flush.
pub fn draw(dst: *Image, r: proto.Rect, src: *Image, mask: ?*Image, p: proto.Point) Display.Error!void {
    const maskid = (mask orelse &dst.display.white).id;
    try dst.display.emit(.{ .draw = .{
        .dstid = dst.id,
        .srcid = src.id,
        .maskid = maskid,
        .r = r,
        .sp = p,
        .mp = p,
    } });
}

/// Free (uninstall) the image, emitting an 'f' verb (freeimage, alloc.c). The
/// display image (id 0) must never be freed (G6). Buffered.
pub fn free(self: *Image) Display.Error!void {
    std.debug.assert(self.id != 0);
    try self.display.emit(.{ .free = .{ .id = self.id } });
}

test {
    // Image has no pure behavior to exercise on its own; its draw/free paths
    // are covered by the fake-devdraw integration test in draw.zig.
    std.testing.refAllDecls(@This());
}
