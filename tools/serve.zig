//! `zig build serve` — a tiny std-only static file server for the assembled
//! `zig-out/www` tree (S-06 §3). It is a DEV TOOL, not part of the editor's
//! module graph; it exists so the WASM build can be loaded in a browser with
//! the two things `file://` and naive servers get wrong:
//!
//!   1. `Content-Type: application/wasm` (WebAssembly.instantiateStreaming
//!      rejects anything else), and
//!   2. the cross-origin isolation headers COOP/COEP (R-BLD-04) that a future
//!      SharedArrayBuffer event-ring will require.
//!
//! Single-threaded, one request per connection (Connection: close). Good enough
//! for local bring-up; not a production server. std-only (ADR-0002).
const std = @import("std");
const build_options = @import("build_options");

const Io = std.Io;

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const www_dir = build_options.www_dir;
    const port = build_options.port;

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("snarf serve: cannot listen on 127.0.0.1:{d}: {s}\n", .{ port, @errorName(err) });
        return err;
    };
    defer server.deinit(io);

    std.debug.print(
        \\snarf serve: http://127.0.0.1:{d}/   (Ctrl-C to stop)
        \\  root : {s}
        \\  headers: application/wasm + COOP/COEP (cross-origin isolated)
        \\
    , .{ port, www_dir });

    while (true) {
        var stream = server.accept(io) catch |err| {
            std.debug.print("snarf serve: accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        defer stream.close(io);
        serveConnection(io, &stream, gpa, www_dir) catch |err| {
            // A dropped connection (browser preconnect, reload) is routine.
            if (err != error.ReadFailed and err != error.EndOfStream)
                std.debug.print("snarf serve: {s}\n", .{@errorName(err)});
        };
    }
}

fn serveConnection(io: Io, stream: *Io.net.Stream, gpa: std.mem.Allocator, www_dir: []const u8) !void {
    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);

    var request = try http.receiveHead();

    const rel = resolveTarget(request.head.target) orelse {
        try request.respond("400 bad request\n", .{
            .status = .bad_request,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
        return;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ www_dir, rel }) catch {
        try request.respond("414 uri too long\n", .{
            .status = .uri_too_long,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
        return;
    };

    const body = Io.Dir.cwd().readFileAlloc(io, full_path, gpa, .unlimited) catch {
        try request.respond("404 not found\n", .{
            .status = .not_found,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
        return;
    };
    defer gpa.free(body);

    try request.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = contentType(rel) },
            // Cross-origin isolation (R-BLD-04) so a future SharedArrayBuffer
            // event-ring is permitted; harmless for the current single-thread build.
            .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
            .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
            // Never cache during bring-up; every reload gets the fresh wasm.
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

/// Map an HTTP request target to a safe relative path under the www root, or
/// null if it is malformed / attempts traversal. Always begins with '/'.
fn resolveTarget(target: []const u8) ?[]const u8 {
    // Strip any query string.
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    if (path.len == 0 or path[0] != '/') return null;
    // Refuse ".." anywhere rather than trying to normalize it.
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    if (std.mem.eql(u8, path, "/")) return "/index.html";
    return path;
}

fn contentType(path: []const u8) []const u8 {
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
