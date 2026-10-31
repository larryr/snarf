//! `hostfs` (module root) — the host file system as 9P (phase 20, R-P20-1). Its own build
//! module so BOTH the origin server (`tools/origin`, under `fs/`) and the
//! native host (`main_native.zig`, at `/`) serve the same code. Same layer as
//! `dev`/`host`: it touches the host file system, so `core`, `draw` and
//! `ninep` must never import it (S-07 §6). Imports `ninep` + `std` only.
//!
//!   HostFs.zig    stateless host calls: stat, list, read, write, create
//!   Replace.zig   the atomic Put (temp + rename-on-clunk, PM Q5)
//!   HostTree.zig  a `ninep.server.Ops` with the export dir as the root
//!   dirread.zig   offset-addressed directory reads (`DirReader`)
pub const HostFs = @import("HostFs.zig");
pub const Replace = @import("Replace.zig");
pub const HostTree = @import("HostTree.zig");
pub const Recovery = @import("Recovery.zig");
pub const DirReader = @import("dirread.zig").DirReader;
pub const qid_tag = HostFs.qid_tag;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("dirread.zig");
    _ = @import("recovery_test.zig"); // #58: partial Put kept at shutdown
}
