//! The `Dump` and `Load` builtins (exec.c:928-945; exectab rows exec.c:105 and
//! :114, both `dump` with `isdump = flag1`). namespace module (S-07 P-1).
//! Ported from larryr/plan9port@337c6ac; cite as `exec.c:NN`.
//!
//! The work is `Session` → `RowDump`/`RowLoad` (rows.c:317-844): this is only
//! the name choice — the command's argument, else the 2-1 chord argument, else
//! the default `$home/acme.dump` (R-P17-5).
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const exec = @import("exec.zig");

/// `dump` (exec.c:928-945). `isdump` is the exectab's flag1: TRUE for `Dump`,
/// FALSE for `Load`.
pub fn dump(
    ed: *Editor,
    _: *Text,
    _: ?*Text,
    argt: ?*Text,
    isdump: bool,
    _: bool,
    arg: []const u8,
) Text.Error!void {
    // exec.c:937-940: `narg ? arg : getbytearg(argt, …)`.
    const chord = if (arg.len == 0) try exec.getArg(ed, argt) else null;
    defer if (chord) |c| ed.allocator.free(c);
    const name = if (arg.len != 0) arg else (chord orelse "");
    if (isdump) try ed.session.startDump(ed, name) else try ed.session.startLoad(ed, name); // exec.c:941-944
    ed.needs_flush = true;
}
