//! Device servers (devdraw/devinput/dom/host/…). Imports: `ninep` (server|msg),
//! `shim`, `std` (S-07 §6). This is the only layer that touches the browser,
//! and it reaches it exclusively through `shim`.
const std = @import("std");

pub const draw = @import("draw.zig");
pub const draw_backend = @import("draw_backend.zig");
pub const draw_canvas = @import("draw_canvas.zig");

test {
    std.testing.refAllDecls(@This());
}
