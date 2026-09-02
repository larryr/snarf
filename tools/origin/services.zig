//! `bin/` — origin command services (S-02 §5, R-EDIT-18). Protocol: a client
//! writes `exec <args>` to `bin/<name>/ctl`, then reads the result from
//! `bin/<name>/output`. The output is per connection, so two browsers never
//! see each other's results.
//!
//! v1 ships BUILT-INS ONLY and never spawns a host process: the origin server
//! runs on the developer's machine, and "exec anything" over a WebSocket would
//! be remote code execution for whoever can reach the port. Real host commands
//! need an allow-list design and an ADR (phase report, open question).
const std = @import("std");
const Io = std.Io;

pub const RunError = error{OutOfMemory};

pub const Service = struct {
    name: []const u8,
    run: *const fn (gpa: std.mem.Allocator, io: Io, args: []const u8) RunError![]u8,
};

/// The comptime service table (S-07 P-7). Index == the service's identity in
/// tree.zig qids, so append only — never reorder.
pub const table = [_]Service{
    .{ .name = "echo", .run = runEcho },
    .{ .name = "date", .run = runDate },
};
pub const count: u8 = table.len;

pub fn indexOf(name: []const u8) ?u8 {
    for (table, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, name)) return @intCast(i);
    }
    return null;
}

/// Parse a ctl write. Only `exec [args]` exists; the trailing newline is
/// optional. Returns the argument string (possibly empty).
pub fn parseExec(ctl: []const u8) ?[]const u8 {
    const line = std.mem.trimEnd(u8, ctl, "\r\n");
    if (std.mem.eql(u8, line, "exec")) return "";
    if (std.mem.startsWith(u8, line, "exec ")) return line["exec ".len..];
    return null;
}

/// Per-connection result buffers, one slot per service.
pub const Outputs = struct {
    slots: [count]?[]u8 = @splat(null),

    pub fn set(self: *Outputs, gpa: std.mem.Allocator, i: u8, out: []u8) void {
        if (self.slots[i]) |old| gpa.free(old);
        self.slots[i] = out;
    }

    pub fn get(self: *const Outputs, i: u8) []const u8 {
        return self.slots[i] orelse "";
    }

    pub fn deinit(self: *Outputs, gpa: std.mem.Allocator) void {
        for (&self.slots) |*s| if (s.*) |old| {
            gpa.free(old);
            s.* = null;
        };
    }
};

fn runEcho(gpa: std.mem.Allocator, io: Io, args: []const u8) RunError![]u8 {
    _ = io;
    return std.fmt.allocPrint(gpa, "{s}\n", .{args});
}

/// Wall-clock seconds since the Unix epoch, UTC. Kept numeric on purpose:
/// no locale, no timezone database, trivially parseable by an Edit script.
fn runDate(gpa: std.mem.Allocator, io: Io, args: []const u8) RunError![]u8 {
    _ = args;
    const now = Io.Timestamp.now(io, .real);
    const secs = @divTrunc(now.nanoseconds, std.time.ns_per_s);
    return std.fmt.allocPrint(gpa, "{d}\n", .{secs});
}

test "services: table lookup and exec parsing" {
    try std.testing.expectEqual(@as(?u8, 0), indexOf("echo"));
    try std.testing.expectEqual(@as(?u8, 1), indexOf("date"));
    try std.testing.expectEqual(@as(?u8, null), indexOf("rm"));
    try std.testing.expectEqualStrings("hi there", parseExec("exec hi there\n").?);
    try std.testing.expectEqualStrings("", parseExec("exec").?);
    try std.testing.expect(parseExec("run x") == null);
}

test "services: echo and outputs lifecycle" {
    const gpa = std.testing.allocator;
    var outs: Outputs = .{};
    defer outs.deinit(gpa);
    outs.set(gpa, 0, try table[0].run(gpa, std.testing.io, "a b"));
    try std.testing.expectEqualStrings("a b\n", outs.get(0));
    outs.set(gpa, 0, try table[0].run(gpa, std.testing.io, "c")); // frees the old slot
    try std.testing.expectEqualStrings("c\n", outs.get(0));
    try std.testing.expectEqualStrings("", outs.get(1));
    const d = try table[1].run(gpa, std.testing.io, "");
    defer gpa.free(d);
    try std.testing.expect(d.len > 5); // "1750000000\n"-ish
}
