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
// Edit language (phase 10). One public type per line, matching the flat style
// above; later 10x waves add ast/parse/addr/Elog/cmd here.
pub const Regx = @import("edit/Regx.zig");

/// The `/mnt/snarf-self` served tree (S-07 §4). `fsys` is the directory server
/// half (wave 10a-A3); `xfid` (the per-file read/write half) joins in wave 10b-B3.
pub const served = struct {
    pub const fsys = @import("served/fsys.zig");
};

/// The Edit command language (phase 10, `src/core/edit/`). Seeded here so the
/// module's colocated tests are collected by `zig build test`. Wave 10a-A2 lands
/// `ast` + `parse`; wave 10a-A1 (Regx) and later waves (addr/cmd/loop/Elog) extend
/// this namespace — the concurrent seeds are orchestrator-merged (like the Editor
/// field merge, R-P10-5). FLAG: A1 and A2 both introduce `pub const edit`.
pub const edit = struct {
    pub const ast = @import("edit/ast.zig");
    pub const parse = @import("edit/parse.zig");
    pub const addr = @import("edit/addr.zig");
    pub const Elog = @import("edit/Elog.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

test {
    std.testing.refAllDecls(@This());
    // Pull the served-tree test blocks into this module's test binary (the
    // exec.zig / Text.zig convention — refAllDecls does not recurse into the
    // `served` namespace struct's imports).
    _ = @import("served/fsys.zig");
}
