//! 9P2000 protocol — pure, std-only. Imports: `std` only (S-07 §6).
//! Namespace root re-exporting the module's public surface.
const std = @import("std");

pub const Qid = @import("qid.zig");
pub const msg = @import("msg.zig");

test {
    std.testing.refAllDecls(@This());
}
