//! libdraw-like client + frame. Imports: `ninep` (client|msg), `std` (S-07 §6).
//! The editor core draws ONLY by emitting draw-protocol messages here (ADR-0003).
const std = @import("std");

pub const proto = @import("proto.zig");

test {
    std.testing.refAllDecls(@This());
}
