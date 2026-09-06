//! WASM boundary. Imports: `std` only (S-07 §6). Nothing in `core` may import
//! this module — that is the R-CON-02 boundary.
const std = @import("std");

pub const abi = @import("abi.zig");
/// 9P frames over one browser WebSocket (R-P12-3). Comptime-generic over the
/// `ninep.transport.Transport` type so this module stays `std`-only (S-07 §6);
/// `src/main_wasm.zig` supplies the type.
pub const WsTransport = @import("WsTransport.zig");

test {
    std.testing.refAllDecls(@This());
}
