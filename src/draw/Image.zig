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

pub const LoadError = Display.Error || error{ BadRect, ShortData };

/// Upload raw pixel rows into rectangle `r` of this image (loadimage.c:5-54).
/// `data` is `bytesPerLine(r, depth)` per row, top row first, byte-aligned
/// (G11). CHUNKED like libdraw: each 'y' carries at most `chunk = buf_size-64`
/// bytes (`dy = min(rows left, chunk/bpl)` rows), so a single upload never
/// trips `Display.emit`'s oversized guard. `dy == 0` (one row wider than the
/// chunk) ⇒ `BadRect`; `r ⊄ self.r` ⇒ `BadRect`; too little data ⇒ `ShortData`.
/// Ends with `display.doFlush()` (no 'v') so a failure is attributed here
/// (loadimage.c:51). Buffered otherwise — pixels are visible on the next flush.
pub fn load(self: *Image, r: proto.Rect, data: []const u8) LoadError!void {
    const disp = self.display;
    if (!rectInRect(r, self.r)) return error.BadRect;
    const depth = proto.chanDepth(self.chan) orelse return error.BadRect;
    const bpl = proto.bytesPerLine(r, depth);
    if (bpl == 0) return error.BadRect;
    const dy_total: usize = @intCast(r.max.y - r.min.y);
    if (data.len < bpl * dy_total) return error.ShortData;

    // loadimage.c:13 chunk = bufsize - 64. Guard the (unrealistic) tiny-buffer
    // underflow so a too-small display degrades to BadRect, not a panic.
    const chunk: usize = if (disp.buf_size > 64) disp.buf_size - 64 else 0;
    var y = r.min.y;
    var off: usize = 0;
    while (y < r.max.y) {
        var dy: usize = @intCast(r.max.y - y);
        if (dy * bpl > chunk) dy = chunk / bpl;
        if (dy == 0) return error.BadRect; // loadimage.c:30 "too wide for buffer"
        const n = dy * bpl;
        try disp.emit(.{ .load = .{
            .id = self.id,
            .r = proto.Rect.make(r.min.x, y, r.max.x, y + @as(i32, @intCast(dy))),
            .data = data[off .. off + n],
        } });
        off += n;
        y += @intCast(dy);
    }
    try disp.doFlush();
}

/// `rectinrect` (rectclip.c): `r` lies entirely within `s` (half-open).
fn rectInRect(r: proto.Rect, s: proto.Rect) bool {
    return s.min.x <= r.min.x and r.max.x <= s.max.x and
        s.min.y <= r.min.y and r.max.y <= s.max.y;
}

test {
    // Image has no pure behavior to exercise on its own; its draw/free paths
    // are covered by the fake-devdraw integration test in draw.zig.
    std.testing.refAllDecls(@This());
}
