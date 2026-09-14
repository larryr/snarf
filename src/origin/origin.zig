//! Origin mount — boot glue between the browser WebSocket transport (`shim`) and
//! the editor's 9P namespace (`ninep`). Imports: `std`, `ninep`, `shim` (S-07 §6).
//!
//! This module exists because `/n/origin` needs BOTH sides of that boundary and
//! `core` may see neither: the editor core reaches the origin only through the
//! namespace, and the `Reconnect` builtin reaches it only through the narrow hook
//! on `Editor` that `src/main_wasm.zig` installs (R-OV-03, R-P12-7).
const std = @import("std");

pub const OriginMount = @import("OriginMount.zig");
/// The hand-driven version+attach+bin-walk handshake `OriginMount.poll`
/// dispatches into (phase 12e carve-out).
pub const handshake = @import("handshake.zig");

test {
    std.testing.refAllDecls(@This());
    _ = OriginMount;
    _ = handshake;
}
