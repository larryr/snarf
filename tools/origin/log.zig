//! Origin-server logging: info lines to STDOUT, error lines to STDERR, one
//! `HH:MM:SS`-stamped (UTC) line per call, mutex-serialized across the
//! per-connection threads. A host DEV TOOL concern only — the acceptance
//! tests run the server with no `Log` attached and stay silent
//! (see `Origin.log`).
const std = @import("std");
const Io = std.Io;

pub const Log = struct {
    io: Io,
    mutex: Io.Mutex = .init,

    pub fn info(self: *Log, comptime fmt: []const u8, args: anytype) void {
        self.emit(Io.File.stdout(), fmt, args);
    }

    pub fn err(self: *Log, comptime fmt: []const u8, args: anytype) void {
        self.emit(Io.File.stderr(), fmt, args);
    }

    fn emit(self: *Log, file: Io.File, comptime fmt: []const u8, args: anytype) void {
        var buf: [768]u8 = undefined;
        const ns = Io.Timestamp.now(self.io, .real).nanoseconds;
        const secs: u64 = @intCast(@max(0, @divTrunc(ns, std.time.ns_per_s)));
        const line = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2} " ++ fmt ++ "\n", .{
            secs / 3600 % 24,
            secs / 60 % 60,
            secs % 60,
        } ++ args) catch blk: {
            buf[buf.len - 1] = '\n'; // over-long line: emit the truncated prefix
            break :blk buf[0..];
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        file.writeStreamingAll(self.io, line) catch {};
    }
};

const testing = std.testing;

test "log line stamp math" {
    // 2026-09-05T17:03:09Z = 1788973389 s; check the H/M/S decomposition used
    // by emit (the format call itself needs no Io, so exercise the arithmetic).
    const secs: u64 = 1788973389;
    try testing.expectEqual(@as(u64, 17), secs / 3600 % 24);
    try testing.expectEqual(@as(u64, 3), secs / 60 % 60);
    try testing.expectEqual(@as(u64, 9), secs % 60);
}
