//! Browser-free editor core. Imports: `draw`, `ninep` (client|mount|msg), `std`
//! (S-07 §6). MUST NOT import `dev` or `shim` — the module graph in build.zig
//! withholds them, so a violating import is a compile error (R-CON-02).
const std = @import("std");

pub const Editor = @import("Editor.zig");
pub const Buffer = @import("Buffer.zig");
pub const File = @import("File.zig");
pub const Text = @import("text/Text.zig");
pub const Window = @import("Window.zig");
pub const Chrome = @import("Chrome.zig");
pub const Column = @import("Column.zig");
pub const Row = @import("Row.zig");
pub const boot = @import("boot.zig");
pub const look = @import("look.zig");
pub const exec = @import("exec/exec.zig");

/// The `/mnt/snarf-self` served tree (S-07 §4). `fsys` is the directory server
/// half (wave 10a-A3); `xfid` (the per-file read/write half) joins in wave 10b-B3.
pub const served = struct {
    pub const fsys = @import("served/fsys.zig");
};

test {
    std.testing.refAllDecls(@This());
    // Pull the served-tree test blocks into this module's test binary (the
    // exec.zig / Text.zig convention — refAllDecls does not recurse into the
    // `served` namespace struct's imports).
    _ = @import("served/fsys.zig");
}
