//! WASM boundary. Imports: `std` only (S-07 §6). Nothing in `core` may import
//! this module — that is the R-CON-02 boundary.
const std = @import("std");

pub const abi = @import("abi.zig");

test {
    std.testing.refAllDecls(@This());
}
