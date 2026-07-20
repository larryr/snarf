//! The Edit-language loop commands — `s` (substitute) and `x`/`y`/`g`/`v`
//! (match/gap/guard loops), plus the bare-`x` linelooper (acme/ecmd.c:447-534,
//! 852-935, 370-385). Ported from larryr/plan9port@337c6ac; cite as `ecmd.c:NN`.
//!
//! WAVE(10d): this file is a STUB left by wave 10c so the dispatch table in
//! `cmd.zig` is COMPLETE (every v1 command row points at a real function) and
//! parse -> dispatch works for `s x y g v` end to end. The three public entry
//! points below carry the FROZEN signatures (side contract §2.5); wave 10d
//! replaces their bodies with the real looper/linelooper/loopcmd machinery
//! (tests 18-31). Until then each returns a diagnostic `error.Edit` so a user
//! `Edit ,x/b/d` fails cleanly with "Edit: x not yet implemented" rather than
//! silently doing nothing.
const std = @import("std");
const ast = @import("ast.zig");
const cmd = @import("cmd.zig");
const Text = @import("../text/Text.zig");

/// `s_cmd` (ecmd.c:447-534). WAVE(10d).
pub fn sCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    _ = t;
    return notYet(x, cp);
}

/// `x_cmd`/`y_cmd` (ecmd.c:852-935); `re == null` ⇒ the bare-`x` linelooper.
/// WAVE(10d).
pub fn xCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    _ = t;
    return notYet(x, cp);
}

/// `g_cmd`/`v_cmd` (ecmd.c:370-385). WAVE(10d).
pub fn gCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool {
    _ = t;
    return notYet(x, cp);
}

fn notYet(x: *cmd.Ctx, cp: *ast.Cmd) ast.Error!bool {
    return x.diag.set("{u} not yet implemented", .{@as(u21, @intCast(cp.cmdc & 0xff))});
}
