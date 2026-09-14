//! Browser-free editor core. Imports: `draw`, `ninep` (client|mount|msg), `std`
//! (S-07 §6). MUST NOT import `dev` or `shim` — the module graph in build.zig
//! withholds them, so a violating import is a compile error (R-CON-02).
const std = @import("std");

pub const Editor = @import("Editor.zig");
/// The mouse gesture machine (`mousethread`, acme.c:576-672) — carved out of
/// `Editor.zig` in phase 12e; `Editor` forwards `handleMouse`/`hitTest` to it.
pub const Gesture = @import("Gesture.zig");
/// `textselect` + its chord loop (text.c:1001-1384), the half of the gesture
/// machine that runs against one Text. Entered only via `Gesture.handleMouse`.
pub const textselect = @import("textselect.zig");
/// The snarf buffer's single-Text `cut`/`paste` cores (exec.c:947-1073).
pub const snarf = @import("snarf.zig");
pub const Buffer = @import("Buffer.zig");
pub const File = @import("File.zig");
pub const Text = @import("text/Text.zig");
pub const Window = @import("Window.zig");
pub const Chrome = @import("Chrome.zig");
pub const Column = @import("Column.zig");
pub const Row = @import("Row.zig");
pub const boot = @import("boot.zig");
pub const look = @import("look.zig");
/// Directory windows — `textload`'s QTDIR arm and `textcolumnate`
/// (text.c:121-275), phase 13b, R-EDIT-03.
pub const dirwin = @import("dirwin.zig");
/// One in-flight window load — the asynchronous `textload` (text.c:192-317).
pub const Load = @import("Load.zig");
/// Window placement (`makenewwindow`, util.c:449-495) + the shared window mint
/// helper — phase 12b, R-EDIT-23.
pub const place = @import("place.zig");
/// The `+Errors` window and the warning flush (util.c:79-258) — phase 12b,
/// R-EDIT-21. Named for the C's concept, not for `ninep.errors`.
pub const errors = @import("errors.zig");
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
    pub const cmd = @import("edit/cmd.zig");
    pub const loop = @import("edit/loop.zig");
    // The entry point (edit.c's `editcmd`/`edit` builtin, wave 10c). Named `entry`
    // so it doesn't collide with the enclosing `edit` namespace.
    pub const entry = @import("edit/edit.zig");
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
