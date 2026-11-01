//! Exclusive listening socket for snarf-origin (issue #47).
//!
//! Zig 0.16's `IpAddress.listen(.{ .reuse_address = true })` sets SO_REUSEADDR
//! **and** SO_REUSEPORT (std/Io/Threaded.zig `netListenIpPosix`). SO_REUSEPORT
//! lets a second snarf-origin bind the same busy port, after which the kernel
//! splits connections between the two processes — a stale server silently
//! answers instead of the new one failing to start.
//!
//! `listenExclusive` is the ONE bind path: `Origin.listen` (main.zig) uses it,
//! so the regression tests (port_test.zig OP-01..03, OP-05 below) bind exactly
//! the way the real server does. On POSIX it opens the socket itself and sets
//! SO_REUSEADDR only, then binds and listens:
//!   * SO_REUSEADDR keeps a restart working while the previous run's
//!     connections sit in TIME_WAIT;
//!   * without SO_REUSEPORT a second live listener on the same address gets
//!     EADDRINUSE → `error.AddressInUse`, and `main` exits non-zero with
//!     "cannot listen on …".
//! On Windows SO_REUSEADDR itself permits port hijacking, so there we ask std
//! for a plain (non-reuse) listener; TIME_WAIT does not block rebinding there.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const IpAddress = Io.net.IpAddress;
const Threaded = Io.Threaded;

pub const Error = error{
    AddressInUse,
    AddressUnavailable,
    AddressFamilyUnsupported,
    AccessDenied,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NetworkDown,
    Unexpected,
} || IpAddress.ListenError;

/// Listen on `address` with SO_REUSEADDR but never SO_REUSEPORT.
pub fn listenExclusive(io: Io, address: IpAddress) Error!Io.net.Server {
    if (builtin.os.tag == .windows) return address.listen(io, .{});

    const family = Threaded.posixAddressFamily(&address);
    const want_cloexec = @hasDecl(posix.SOCK, "CLOEXEC") and !Threaded.socket_flags_unsupported;
    const flags: u32 = posix.SOCK.STREAM | if (want_cloexec) posix.SOCK.CLOEXEC else 0;
    const rc = posix.system.socket(family, flags, posix.IPPROTO.TCP);
    const fd: posix.socket_t = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        else => |e| return posix.unexpectedErrno(e),
    };
    errdefer _ = posix.system.close(fd);
    if (!want_cloexec) {
        switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)))) {
            .SUCCESS => {},
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    // SO_REUSEADDR only — the whole point of #47. Do NOT add SO_REUSEPORT.
    const one: c_int = 1;
    switch (posix.errno(posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int)))) {
        .SUCCESS => {},
        .NOMEM, .NOBUFS => return error.SystemResources,
        else => |e| return posix.unexpectedErrno(e),
    }

    var storage: Threaded.PosixAddress = undefined;
    var len = Threaded.addressToPosix(&address, &storage);
    switch (posix.errno(posix.system.bind(fd, &storage.any, len))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .ACCES, .PERM => return error.AccessDenied,
        .NOMEM, .NOBUFS => return error.SystemResources,
        else => |e| return posix.unexpectedErrno(e),
    }
    switch (posix.errno(posix.system.listen(fd, Io.net.default_kernel_backlog))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => |e| return posix.unexpectedErrno(e),
    }
    switch (posix.errno(posix.system.getsockname(fd, &storage.any, &len))) {
        .SUCCESS => {},
        .NOBUFS => return error.SystemResources,
        else => |e| return posix.unexpectedErrno(e),
    }
    return .{
        .socket = .{ .handle = fd, .address = Threaded.addressFromPosix(&storage) },
        .options = if (Io.net.Server.AcceptOptions != void) .{ .mode = .stream, .protocol = .tcp } else {},
    };
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

fn portOf(s: *const Io.net.Server) u16 {
    return switch (s.socket.address) {
        inline else => |a| a.port,
    };
}

test "listenExclusive: binds an ephemeral port and accepts a connection" {
    const io = testing.io;
    var srv = try listenExclusive(io, try IpAddress.parse("127.0.0.1", 0));
    defer srv.deinit(io);
    try testing.expect(portOf(&srv) != 0);
    var c = try (try IpAddress.parse("127.0.0.1", portOf(&srv))).connect(io, .{ .mode = .stream });
    defer c.close(io);
    var s = try srv.accept(io);
    s.close(io);
}

test "listenExclusive: a second exclusive listener on the same busy port is AddressInUse" {
    const io = testing.io;
    var a = try listenExclusive(io, try IpAddress.parse("127.0.0.1", 0));
    defer a.deinit(io);
    try testing.expectError(error.AddressInUse, listenExclusive(io, try IpAddress.parse("127.0.0.1", portOf(&a))));
}

test "listenExclusive: a std reuse_address (SO_REUSEPORT) listener cannot join a port we hold" {
    // The pre-#47 bind (REUSEADDR+REUSEPORT) must not be able to share our port:
    // SO_REUSEPORT sharing requires every socket on the port to have it set.
    const io = testing.io;
    var a = try listenExclusive(io, try IpAddress.parse("127.0.0.1", 0));
    defer a.deinit(io);
    const addr = try IpAddress.parse("127.0.0.1", portOf(&a));
    if (addr.listen(io, .{ .reuse_address = true })) |ok| {
        var s = ok;
        s.deinit(io);
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.AddressInUse, err);
}

test "origin port OP-05: restart while a previous connection is in TIME_WAIT still binds (SO_REUSEADDR kept)" {
    const io = testing.io;
    const origin = @import("main.zig");
    const cfg: origin.Config = .{ .www_dir = ".", .export_dir = "." };

    var first = try origin.Origin.listen(io, testing.allocator, cfg, "127.0.0.1", 0);
    const p = first.port();
    const addr = try IpAddress.parse("127.0.0.1", p);
    {
        var client = try addr.connect(io, .{ .mode = .stream });
        var served = try first.listener.accept(io);
        // The SERVER closes first (active close), so the server-side
        // 127.0.0.1:p endpoint is the one that enters TIME_WAIT.
        served.close(io);
        var buf: [1]u8 = undefined;
        var r = client.reader(io, &buf);
        _ = r.interface.takeByte() catch {}; // wait for the FIN
        client.close(io);
    }
    first.deinit();

    // Precondition (Linux, where it is deterministic): the port really is held
    // by TIME_WAIT — a plain, non-reuse bind is refused. Proves this test
    // exercises SO_REUSEADDR rather than passing vacuously.
    if (builtin.os.tag == .linux) {
        if (addr.listen(io, .{})) |ok| {
            var plain = ok;
            plain.deinit(io);
            std.debug.print("OP-05: no TIME_WAIT on port {d}; precondition not met\n", .{p});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.AddressInUse, err);
    }

    var again = try origin.Origin.listen(io, testing.allocator, cfg, "127.0.0.1", p);
    defer again.deinit();
    try testing.expectEqual(p, again.port());
}
