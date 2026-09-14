//! nspath.zig — namespace path helpers shared by `mount.zig` and `nsdir.zig`
//! (S-02 §1). Carved out of `mount.zig` in phase 12d so the union table and the
//! union walker agree, byte for byte, on what "under this prefix" means.
//!
//! Imports: std only (S-07 §6).
const std = @import("std");

pub const Error = error{
    /// The path/prefix is not absolute, or has an empty/"."/".." component.
    BadPath,
    OutOfMemory,
};

/// Does `path` fall under mounted `prefix` at a component boundary? Returns
/// the remainder (leading '/' stripped, "" on exact match) or null. Both
/// arguments are assumed absolute; `prefix` is assumed canonical (no
/// trailing '/' unless it IS "/").
///
/// The component-boundary rule is what keeps `/mnt/host` from swallowing
/// `/mnt/hostx` — a bare `startsWith` would (chan.c walks whole components,
/// never characters).
pub fn matchPrefix(prefix: []const u8, path: []const u8) ?[]const u8 {
    if (prefix.len == 1) return path[1..]; // root "/": matches everything
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len == prefix.len) return path[prefix.len..]; // exact match, ""
    if (path[prefix.len] != '/') return null; // e.g. prefix "/dev", path "/devx"
    return path[prefix.len + 1 ..];
}

/// Canonicalize a mount-table prefix into a freshly owned copy: must be
/// absolute; a single trailing '/' is stripped (except when the whole
/// prefix collapses to root "/"); any empty (e.g. "//"), "." or ".."
/// component is `error.BadPath`.
pub fn canonicalize(allocator: std.mem.Allocator, prefix: []const u8) Error![]u8 {
    if (prefix.len == 0 or prefix[0] != '/') return error.BadPath;
    if (std.mem.eql(u8, prefix, "/")) return allocator.dupe(u8, "/");

    var end = prefix.len;
    while (end > 1 and prefix[end - 1] == '/') end -= 1;
    const trimmed = prefix[0..end];
    if (trimmed.len == 1) return allocator.dupe(u8, "/"); // e.g. "//"

    var it = std.mem.splitScalar(u8, trimmed[1..], '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return error.BadPath;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return error.BadPath;
    }
    return allocator.dupe(u8, trimmed);
}

/// The first path component of `rest` (a remainder as `matchPrefix` returns
/// it): everything up to the next '/', or all of it. "" for an empty
/// remainder. Used to name a synthesized mount-point directory's child
/// (`/n/origin` seen from `/n` is the single entry `origin`).
pub fn firstComponent(rest: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, rest, '/') orelse return rest;
    return rest[0..i];
}

// ==========================================================================
// Tests
// ==========================================================================
const testing = std.testing;

test "nspath: matchPrefix component boundary" {
    try testing.expectEqualStrings("x", matchPrefix("/mnt/host", "/mnt/host/x").?);
    try testing.expectEqualStrings("", matchPrefix("/mnt/host", "/mnt/host").?);
    try testing.expect(matchPrefix("/mnt/host", "/mnt/hostx") == null);
    try testing.expectEqualStrings("a/b", matchPrefix("/", "/a/b").?);
}

test "nspath: firstComponent" {
    try testing.expectEqualStrings("origin", firstComponent("origin"));
    try testing.expectEqualStrings("origin", firstComponent("origin/bin"));
    try testing.expectEqualStrings("", firstComponent(""));
}

test "nspath: canonicalize" {
    const a = testing.allocator;
    const root = try canonicalize(a, "//");
    defer a.free(root);
    try testing.expectEqualStrings("/", root);

    const dev = try canonicalize(a, "/dev/");
    defer a.free(dev);
    try testing.expectEqualStrings("/dev", dev);

    try testing.expectError(error.BadPath, canonicalize(a, "dev"));
    try testing.expectError(error.BadPath, canonicalize(a, "/a/../b"));
}
