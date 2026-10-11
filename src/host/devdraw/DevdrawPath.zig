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
// Tests — the full §4 T4 matrix is the gate's; these pin the basics.
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

fn expectResolve(env: *const std.process.Environ.Map, dir: ?[]const u8, fs: *FakeFs, path: []const u8, source: Source) !void {
    var r = try resolve(testing.allocator, env, dir, fs.probe());
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(path, r.path);
    try testing.expectEqual(source, r.source);
}

test "bundled beats $PLAN9; $DEVDRAW beats both and is never probed" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("PLAN9", "/p9");
    var fs: FakeFs = .{ .present = &.{ "/opt/snarf/bin/devdraw", "/p9/bin/devdraw" } };
    try expectResolve(&env, "/opt/snarf/bin", &fs, "/opt/snarf/bin/devdraw", .bundled);

    try env.put("DEVDRAW", "/x/devdraw");
    fs.calls = 0;
    try expectResolve(&env, "/opt/snarf/bin", &fs, "/x/devdraw", .env_devdraw);
    try testing.expectEqual(@as(usize, 0), fs.calls);
}

test "missing derived paths fall through to $PATH; empty vars count as unset" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("DEVDRAW", "");
    try env.put("PLAN9", "/p9");
    var fs: FakeFs = .{ .present = &.{"/p9/bin/devdraw"} };
    try expectResolve(&env, "/opt/snarf/bin", &fs, "/p9/bin/devdraw", .plan9);

    fs.present = &.{};
    try expectResolve(&env, "/opt/snarf/bin", &fs, "devdraw", .path);

    var empty: std.process.Environ.Map = .init(testing.allocator);
    defer empty.deinit();
    fs.calls = 0;
    try expectResolve(&empty, null, &fs, "devdraw", .path);
    try testing.expectEqual(@as(usize, 0), fs.calls);
}

test "describe strings are the startup-line interface (R-P18-9)" {
    var p: DevdrawPath = .{ .path = undefined, .source = .env_devdraw };
    try testing.expectEqualStrings("$DEVDRAW", p.describe());
    p.source = .bundled;
    try testing.expectEqualStrings("bundled", p.describe());
    p.source = .plan9;
    try testing.expectEqualStrings("$PLAN9/bin", p.describe());
    p.source = .path;
    try testing.expectEqualStrings("$PATH", p.describe());
}
