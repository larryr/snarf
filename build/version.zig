//! `snarf --version`'s string, from what git says about the checkout (#77,
//! SnarfProdd PR #74 Q8). BUILD-TIME ONLY: imported by `build.zig`, imports
//! only `std`, part of no S-07 module graph.
//!
//! The format:
//!
//!     v1.0                     a release tag, built exactly at the tag, clean
//!     v0.M0-dev.3 (2d686d1)    a dev tag (its name has `-dev`), at the tag
//!     v0.M0-dev.3 (4b79757)    any commit after the latest tag
//!     v0.M0-dev.3 (4b79757-dirty)  ... with uncommitted changes
//!     untagged (4b79757)       a checkout with no tag behind it
//!
//! i.e. the latest tag reachable from HEAD, then the short commit hash in
//! parentheses unless this is a clean build of a release tag. The tag says
//! which release the build is (or follows); the hash says exactly which
//! commit, which a dev tag alone does not pin once later commits share it.
const std = @import("std");

pub const Git = struct {
    /// `git describe --tags --abbrev=0`: the latest tag behind HEAD.
    tag: ?[]const u8,
    /// HEAD is exactly at `tag` (`git describe --tags --exact-match`).
    exact: bool,
    /// `git rev-parse --short HEAD`.
    hash: []const u8,
    /// The work tree differs from HEAD.
    dirty: bool,
};

pub fn format(gpa: std.mem.Allocator, g: Git) ![]const u8 {
    const tag = g.tag orelse "untagged";
    const release = g.tag != null and g.exact and !g.dirty and std.mem.indexOf(u8, tag, "-dev") == null;
    if (release) return gpa.dupe(u8, tag);
    return std.fmt.allocPrint(gpa, "{s} ({s}{s})", .{ tag, g.hash, if (g.dirty) "-dirty" else "" });
}

const testing = std.testing;

fn expectFormat(want: []const u8, g: Git) !void {
    const got = try format(testing.allocator, g);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "version: a clean release tag prints alone; a dev tag or later commit adds the hash (PR #74 Q8)" {
    try expectFormat("v1.0", .{ .tag = "v1.0", .exact = true, .hash = "abc1234", .dirty = false });
    try expectFormat("v0.M0-dev.3 (2d686d1)", .{ .tag = "v0.M0-dev.3", .exact = true, .hash = "2d686d1", .dirty = false });
    try expectFormat("v0.M0-dev.3 (4b79757)", .{ .tag = "v0.M0-dev.3", .exact = false, .hash = "4b79757", .dirty = false });
    try expectFormat("v1.0 (abc1234)", .{ .tag = "v1.0", .exact = false, .hash = "abc1234", .dirty = false });
    try expectFormat("v1.0 (abc1234-dirty)", .{ .tag = "v1.0", .exact = true, .hash = "abc1234", .dirty = true });
    try expectFormat("untagged (4b79757)", .{ .tag = null, .exact = false, .hash = "4b79757", .dirty = false });
}
