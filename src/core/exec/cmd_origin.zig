//! The `Reconnect` builtin (R-P12-7) — the user-visible surface of the origin
//! mount. namespace module (S-07 P-1), sibling of `cmd_edit.zig`/`cmd_window.zig`.
//!
//! Snarf-ONLY: there is no `Reconnect` in `acme/exec.c`'s table. acme's namespace
//! is mounted by the shell before the editor starts and a stale mount is simply
//! an error; Snarf's origin is a WebSocket the browser can drop at any moment
//! (R-P12-6 kills the mount and every fid rather than retrying in the
//! background), so the port needs one explicit "try again" verb. It sits
//! alphabetically between `Paste` and `Redo` in `builtins.exectab`.
//!
//! The command itself is a single indirect call: `core` may not import `shim` or
//! `dev` (R-OV-03, S-07 §6), so the transport is reached only through
//! `Editor.OriginHook`, which the wasm root installs at boot.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");

/// `Reconnect`: close any live origin connection, re-dial, re-attach, re-bind
/// `/mnt/origin` (R-P12-7). Takes no argument and ignores every `execute`
/// parameter — it acts on the session, not on a Text.
///
/// Emits NOTHING on the happy path. The dial is asynchronous (R-P12-5), so the
/// one warning line R-P12-7 asks for is the OUTCOME line the connection's poll
/// writes when version+attach finish or give up — printing "dialing..." here
/// too would make the common case two lines. Windows named `/mnt/origin/...`
/// need no special handling: their fids died when the socket did (R-P12-6).
pub fn reconnect(
    ed: *Editor,
    _: *Text,
    _: ?*Text,
    _: ?*Text,
    _: bool,
    _: bool,
    _: []const u8,
) Text.Error!void {
    const hook = ed.origin orelse {
        // A build with no origin transport at all (every native harness).
        ed.warning("Reconnect: no origin connection\n", .{});
        return;
    };
    hook.redial(hook.ctx);
}

// ==========================================================================
// Tests
// ==========================================================================
const testing = std.testing;

test "Reconnect: with no hook installed it warns and does nothing else" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var t: Text = undefined;

    try reconnect(&ed, &t, null, null, false, false, "");
    try testing.expectEqualStrings("Reconnect: no origin connection\n", ed.warnings.items);
}

test "Reconnect: with a hook installed it re-dials and stays silent" {
    const Spy = struct {
        calls: usize = 0,
        fn redial(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
        }
    };
    var spy = Spy{};

    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.origin = .{ .ctx = &spy, .redial = Spy.redial };
    var t: Text = undefined;

    try reconnect(&ed, &t, null, null, false, false, "");
    try testing.expectEqual(@as(usize, 1), spy.calls);
    // The outcome line comes from the platform's poll, not from the builtin.
    try testing.expectEqual(@as(usize, 0), ed.warnings.items.len);

    // Repeatable: a second Reconnect re-dials again (R-P12-7, no rate limit).
    try reconnect(&ed, &t, null, null, false, false, "");
    try testing.expectEqual(@as(usize, 2), spy.calls);
}
