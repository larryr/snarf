//! Device servers (devdraw/devinput/dom/host/…). Imports: `ninep` (server|msg),
//! `shim`, `std` (S-07 §6). This is the only layer that touches the browser,
//! and it reaches it exclusively through `shim`.
const std = @import("std");

pub const draw = @import("draw.zig");
pub const draw_backend = @import("draw_backend.zig");
pub const draw_canvas = @import("draw_canvas.zig");
pub const profiles = @import("profiles.zig");
pub const input = @import("input.zig");
/// `/mnt/opfs` — the browser's Origin Private File System as a 9P tree
/// (phase 14b). Its two size seams are re-exported so their colocated tests
/// are reachable from this root (the phase-1 orchestration lesson).
pub const opfs = @import("opfs.zig");
pub const opfs_tree = @import("opfs_tree.zig");
pub const opfs_slots = @import("opfs_slots.zig");

test {
    std.testing.refAllDecls(@This());
}
