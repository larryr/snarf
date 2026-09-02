//! Static-file half of the origin server (S-06 §3). Serves the assembled
//! `zig-out/www` tree with the two things `file://` and naive servers get
//! wrong for a WASM app:
//!
//!   1. `Content-Type: application/wasm` (WebAssembly.instantiateStreaming
//!      rejects anything else), and
//!   2. the cross-origin isolation headers COOP/COEP (R-BLD-04) that the
//!      SharedArrayBuffer event-ring requires.
//!
//! One request per connection (Connection: close). std-only (ADR-0002).
const std = @import("std");
const Io = std.Io;

const Request = std.http.Server.Request;

/// Answer one already-received GET for a file under `www_dir`.
pub fn serveStatic(io: Io, gpa: std.mem.Allocator, request: *Request, www_dir: []const u8) !void {
    const rel = resolveTarget(request.head.target) orelse
        return plain(request, .bad_request, "400 bad request\n");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ www_dir, rel }) catch
        return plain(request, .uri_too_long, "414 uri too long\n");

    const body = Io.Dir.cwd().readFileAlloc(io, full_path, gpa, .unlimited) catch
        return plain(request, .not_found, "404 not found\n");
    defer gpa.free(body);

    try request.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = contentType(rel) },
            // Cross-origin isolation (R-BLD-04) so the SharedArrayBuffer
            // event-ring is permitted; harmless for the single-thread build.
            .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
            .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
            // Never cache during bring-up; every reload gets the fresh wasm.
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

/// A short text/plain reply (errors and refusals).
pub fn plain(request: *Request, status: std.http.Status, text: []const u8) !void {
    try request.respond(text, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

/// The request path with any query string removed.
pub fn pathOf(target: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
}

/// Map an HTTP request target to a safe relative path under the www root, or
/// null if it is malformed / attempts traversal. Always begins with '/'.
pub fn resolveTarget(target: []const u8) ?[]const u8 {
    const path = pathOf(target);
    if (path.len == 0 or path[0] != '/') return null;
    // Refuse ".." anywhere rather than trying to normalize it.
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    if (std.mem.eql(u8, path, "/")) return "/index.html";
    return path;
}

pub fn contentType(path: []const u8) []const u8 {
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
    };
    inline for (table) |entry| {
        if (std.mem.endsWith(u8, path, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

test "resolveTarget maps and sanitizes" {
    try std.testing.expectEqualStrings("/index.html", resolveTarget("/").?);
    try std.testing.expectEqualStrings("/snarf.wasm", resolveTarget("/snarf.wasm").?);
    try std.testing.expectEqualStrings("/shim.js", resolveTarget("/shim.js?v=1").?);
    try std.testing.expect(resolveTarget("/../etc/passwd") == null);
    try std.testing.expect(resolveTarget("relative") == null);
}

test "contentType by extension" {
    try std.testing.expectEqualStrings("application/wasm", contentType("/snarf.wasm"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", contentType("/index.html"));
    try std.testing.expectEqualStrings("application/octet-stream", contentType("/x.bin"));
}
