//! `DevdrawPath` — which `devdraw` binary the native host spawns, and why;
//! file-as-struct (S-07 P-1). ADR-0006 §4, phase 18 contract §3d.
//!
//! Resolution order (binding):
//!   1. `$DEVDRAW`, non-empty — taken as given, never probed: it names one
//!      binary deliberately, and a wrong value fails loudly at spawn, exactly
//!      as libdraw's `getenv("DEVDRAW")` does (drawclient.c:101).
//!   2. bundled — `<dir of the running executable>/devdraw`, if it exists.
//!      `zig build native` puts one beside `zig-out/bin/snarf-native`.
//!   3. `$PLAN9/bin/devdraw`, non-empty `$PLAN9`, if it exists. A derived path
//!      that does not exist must not shadow `$PATH` (R-P18-5).
//!   4. bare `devdraw`, for the OS's `PATH` search at spawn (drawclient.c:124).
//!
//! Pure policy: the caller supplies the environment, the executable's
//! directory, and a `Probe` for existence, so every ordering is testable with
//! no file system. The directory comes from `std.process.executablePathAlloc`
//! (symlinks followed), never from the working directory.
const std = @import("std");

const DevdrawPath = @This();

/// Owned by the allocator passed to `resolve`; free with `deinit`.
path: []u8,
source: Source,

pub const Source = enum { env_devdraw, bundled, plan9, path };

/// The existence check, one indirection so tests can script it (same shape
/// as `Conn.Sink`). Only derived candidates (bundled, `$PLAN9`) are probed.
pub const Probe = struct {
    ctx: *anyopaque,
    exists: *const fn (ctx: *anyopaque, path: []const u8) bool,
};

pub fn resolve(
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    self_exe_dir: ?[]const u8,
    probe: Probe,
) !DevdrawPath {
    if (nonEmpty(env.get("DEVDRAW"))) |p|
        return .{ .path = try gpa.dupe(u8, p), .source = .env_devdraw };

    if (self_exe_dir) |dir| {
        const cand = try std.fs.path.join(gpa, &.{ dir, "devdraw" });
        if (probe.exists(probe.ctx, cand)) return .{ .path = cand, .source = .bundled };
        gpa.free(cand);
    }

    if (nonEmpty(env.get("PLAN9"))) |p9| {
        const cand = try std.fs.path.join(gpa, &.{ p9, "bin", "devdraw" });
        if (probe.exists(probe.ctx, cand)) return .{ .path = cand, .source = .plan9 };
        gpa.free(cand);
    }

    return .{ .path = try gpa.dupe(u8, "devdraw"), .source = .path };
}

pub fn deinit(self: *DevdrawPath, gpa: std.mem.Allocator) void {
    gpa.free(self.path);
    self.* = undefined;
}

/// The `<source>` half of the startup line (R-P18-9):
/// `snarf-native: devdraw: <path> (<source>)`.
pub fn describe(self: DevdrawPath) []const u8 {
    return switch (self.source) {
        .env_devdraw => "$DEVDRAW",
        .bundled => "bundled",
        .plan9 => "$PLAN9/bin",
        .path => "$PATH",
    };
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ==========================================================================
// Tests
// ==========================================================================

const testing = std.testing;

/// A probe that answers from a fixed list and counts its calls.
const FakeFs = struct {
    present: []const []const u8,
    calls: usize = 0,

    fn probe(self: *FakeFs) Probe {
        return .{ .ctx = self, .exists = exists };
    }

    fn exists(ctx: *anyopaque, path: []const u8) bool {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        for (self.present) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
};

/// One row of the contract §4 T4 table. `devdraw`/`plan9` null means the env
/// var is unset (not put at all — distinct from `""`, case (f)'s point).
const Case = struct {
    label: []const u8,
    devdraw: ?[]const u8 = null,
    plan9: ?[]const u8 = null,
    self_exe_dir: ?[]const u8 = null,
    present: []const []const u8 = &.{},
    want_path: []const u8,
    want_source: Source,
    /// How many times `probe.exists` must have been called — pins that
    /// `$DEVDRAW` and bare `"devdraw"` are never probed (R-P18-5) and that a
    /// hit short-circuits the rest of the chain.
    want_calls: usize,
};

/// Contract §4 T4, cases (a)-(f) verbatim ((g) is `describe()`, tested below).
const t4_cases = [_]Case{
    .{
        .label = "(a) $DEVDRAW wins over bundled and $PLAN9, and neither is probed",
        .devdraw = "/x/devdraw",
        .plan9 = "/p9",
        .self_exe_dir = "/opt/snarf/bin",
        .present = &.{ "/opt/snarf/bin/devdraw", "/p9/bin/devdraw" },
        .want_path = "/x/devdraw",
        .want_source = .env_devdraw,
        .want_calls = 0,
    },
    .{
        .label = "(b) bundled beats $PLAN9 when both exist — the ADR's whole point",
        .plan9 = "/p9",
        .self_exe_dir = "/opt/snarf/bin",
        .present = &.{ "/opt/snarf/bin/devdraw", "/p9/bin/devdraw" },
        .want_path = "/opt/snarf/bin/devdraw",
        .want_source = .bundled,
        .want_calls = 1,
    },
    .{
        .label = "(c) bundled absent -> $PLAN9/bin/devdraw",
        .plan9 = "/p9",
        .self_exe_dir = "/opt/snarf/bin",
        .present = &.{"/p9/bin/devdraw"},
        .want_path = "/p9/bin/devdraw",
        .want_source = .plan9,
        .want_calls = 2,
    },
    .{
        .label = "(d) bundled and $PLAN9/bin/devdraw both absent -> bare \"devdraw\" on $PATH",
        .plan9 = "/p9",
        .self_exe_dir = "/opt/snarf/bin",
        .present = &.{},
        .want_path = "devdraw",
        .want_source = .path,
        .want_calls = 2,
    },
    .{
        .label = "(e) nothing set, no self_exe_dir -> $PATH, probe never called",
        .want_path = "devdraw",
        .want_source = .path,
        .want_calls = 0,
    },
    .{
        .label = "(f) empty $DEVDRAW is treated as unset, falls through to bundled",
        .devdraw = "",
        .self_exe_dir = "/opt/snarf/bin",
        .present = &.{"/opt/snarf/bin/devdraw"},
        .want_path = "/opt/snarf/bin/devdraw",
        .want_source = .bundled,
        .want_calls = 1,
    },
};

test "DevdrawPath.resolve — contract §4 T4 table (a)-(f)" {
    for (t4_cases) |c| {
        var env: std.process.Environ.Map = .init(testing.allocator);
        defer env.deinit();
        if (c.devdraw) |v| try env.put("DEVDRAW", v);
        if (c.plan9) |v| try env.put("PLAN9", v);
        var fs: FakeFs = .{ .present = c.present };

        var r = resolve(testing.allocator, &env, c.self_exe_dir, fs.probe()) catch |e| {
            std.debug.print("T4 case {s}: resolve failed: {t}\n", .{ c.label, e });
            return e;
        };
        defer r.deinit(testing.allocator);

        testing.expectEqualStrings(c.want_path, r.path) catch |e| {
            std.debug.print("T4 case {s}: path mismatch\n", .{c.label});
            return e;
        };
        testing.expectEqual(c.want_source, r.source) catch |e| {
            std.debug.print("T4 case {s}: source mismatch\n", .{c.label});
            return e;
        };
        testing.expectEqual(c.want_calls, fs.calls) catch |e| {
            std.debug.print("T4 case {s}: probe call count mismatch\n", .{c.label});
            return e;
        };
    }
}

test "(g) describe strings are the startup-line interface (R-P18-9)" {
    var p: DevdrawPath = .{ .path = undefined, .source = .env_devdraw };
    try testing.expectEqualStrings("$DEVDRAW", p.describe());
    p.source = .bundled;
    try testing.expectEqualStrings("bundled", p.describe());
    p.source = .plan9;
    try testing.expectEqualStrings("$PLAN9/bin", p.describe());
    p.source = .path;
    try testing.expectEqualStrings("$PATH", p.describe());
}
