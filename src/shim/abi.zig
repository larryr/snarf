//! The WASM env ABI: extern imports/exports + a version hash that both this
//! file and `web/shim.js` must agree on (S-06 §4). Drift becomes a build error
//! once the JS mirror + generated checksum land (OQ-BLD-2). Stub for now.
const std = @import("std");

/// Bumped whenever the import/export surface changes. `web/shim.js` carries the
/// mirror of this value; the two must match.
pub const version: u32 = 1;

test "abi version is present" {
    try std.testing.expect(version >= 1);
}
