//! devdraw: image state + verb dispatch, served over 9P; blits reach the canvas
//! only via the shim backend. [ref: 9/port/devdraw.c, S-03]. Stub.
const std = @import("std");
const ninep = @import("ninep");
const shim = @import("shim");

/// Device ABI generation this server speaks (must match the shim mirror).
pub const abi_version = shim.abi.version;

comptime {
    // devdraw is served over 9P — prove the server-side import resolves.
    std.debug.assert(@hasDecl(ninep, "msg"));
}

test "devdraw tracks shim abi version" {
    try std.testing.expectEqual(shim.abi.version, abi_version);
}
