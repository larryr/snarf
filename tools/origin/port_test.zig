//! Regression tests for issue #47: `Origin.listen` passes
//! `.reuse_address = true`, which on POSIX sets SO_REUSEADDR **and**
//! SO_REUSEPORT (std/Io/net.zig). Two snarf-origin instances can then bind the
//! same busy port and the kernel splits connections between them, so a stale
//! server silently answers instead of the new one failing to start. A second
//! bind must fail, so that `main` logs "cannot listen on …" and exits non-zero.
//! Plan: `notes/snarfdev2/test-plans/M0-47-origin-port.md`.
//!
//! LANDED-FLAG PATTERN (as in clipboard_test.zig): with
//! `origin_port_exclusive_fixed = false`, a second bind that succeeds SKIPs,
//! and one that fails FAILs with UnexpectedPassFlipFlag, so the fixing PR
//! (#47) must flip the flag.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const origin = @import("main.zig");

/// Flip when a second bind to a busy port fails (issue #47, SnarfDev1).
const origin_port_exclusive_fixed = false;

const cfg: origin.Config = .{ .www_dir = ".", .export_dir = "." };
const bind = "127.0.0.1";

test "origin port OP-01: a second Origin.listen on a port another snarf-origin holds fails loudly (no SO_REUSEPORT sharing)" {
    const io = testing.io;
    var first = try origin.Origin.listen(io, testing.allocator, cfg, bind, 0);
    defer first.deinit();
    const p = first.port();
    try testing.expect(p != 0);

    if (origin.Origin.listen(io, testing.allocator, cfg, bind, p)) |second_ok| {
        var second = second_ok;
        second.deinit();
        if (!origin_port_exclusive_fixed) return error.SkipZigTest; // #47 still open
        std.debug.print("origin port OP-01: second listen on busy port {d} succeeded\n", .{p});
        return error.TestUnexpectedResult;
    } else |err| {
        if (!origin_port_exclusive_fixed) return error.UnexpectedPassFlipFlag;
        try testing.expectEqual(error.AddressInUse, err);
    }
}

test "origin port OP-02 (control): Origin.listen refuses a port held by a plain (non-reuse) listener" {
    const io = testing.io;
    const addr = try Io.net.IpAddress.parse(bind, 0);
    var plain = try addr.listen(io, .{});
    defer plain.deinit(io);
    const p = switch (plain.socket.address) {
        inline else => |a| a.port,
    };
    try testing.expectError(error.AddressInUse, origin.Origin.listen(io, testing.allocator, cfg, bind, p));
}

test "origin port OP-03 (control): after a clean shutdown the same port can be bound again" {
    const io = testing.io;
    var first = try origin.Origin.listen(io, testing.allocator, cfg, bind, 0);
    const p = first.port();
    first.deinit();
    var again = try origin.Origin.listen(io, testing.allocator, cfg, bind, p);
    defer again.deinit();
    try testing.expectEqual(p, again.port());
}
