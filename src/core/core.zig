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

test {
    std.testing.refAllDecls(@This());
}
