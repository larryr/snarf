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

/// The Edit command language (phase 10, `src/core/edit/`). Seeded here so the
/// module's colocated tests are collected by `zig build test`. Wave 10a-A2 lands
/// `ast` + `parse`; wave 10a-A1 (Regx) and later waves (addr/cmd/loop/Elog) extend
/// this namespace — the concurrent seeds are orchestrator-merged (like the Editor
/// field merge, R-P10-5). FLAG: A1 and A2 both introduce `pub const edit`.
pub const edit = struct {
    pub const ast = @import("edit/ast.zig");
    pub const parse = @import("edit/parse.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

test {
    std.testing.refAllDecls(@This());
}
