//! `zig build serve` — the Snarf ORIGIN SERVER (S-02 §5, S-01 §3.2, S-06 §3).
//!
//! One listening socket, two protocols:
//!   * plain HTTP GET  → static files from `zig-out/www` (http.zig), with the
//!     `application/wasm` + COOP/COEP headers the browser needs;
//!   * GET /9p + Upgrade: websocket → a 9P2000 session over binary WebSocket
//!     messages (ws_transport.zig) serving the tree in tree.zig: `version`,
//!     `bin/` services, and `fs/` — the export directory (`-Dexport`).
//!
//! Thread per connection; the 9P side is a blocking pump over the existing
//! `ninep.server.Server`. A host DEV TOOL outside the editor's module graph;
//! std-only (ADR-0002). Loopback by default — `fs/` is read/write.
const std = @import("std");
const Io = std.Io;
const ninep = @import("ninep");
const build_options = @import("build_options");
const http = @import("http.zig");
const WsTransport = @import("ws_transport.zig").WsTransport;
const HostFs = @import("hostfs.zig").HostFs;
const Tree = @import("tree.zig").Tree;

/// Negotiated message ceiling (S-01 §1).
pub const msize: u32 = 65536;
/// The 9P endpoint path (S-01 §3.2).
pub const ws_path = "/9p";

pub const Config = struct {
    www_dir: []const u8,
    export_dir: []const u8,
};

pub const Origin = struct {
    io: Io,
    gpa: std.mem.Allocator,
    cfg: Config,
    listener: Io.net.Server,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Live connection threads, so a controlled shutdown can wait for them.
    conns: std.atomic.Value(u32) = .init(0),

    pub fn listen(io: Io, gpa: std.mem.Allocator, cfg: Config, bind: []const u8, port_num: u16) !Origin {
        const address = try Io.net.IpAddress.parse(bind, port_num);
        const listener = try address.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .gpa = gpa, .cfg = cfg, .listener = listener };
    }

    /// The bound port (resolved when `port` 0 requested an ephemeral one).
    pub fn port(self: *const Origin) u16 {
        return switch (self.listener.socket.address) {
            inline else => |a| a.port,
        };
    }

    /// Accept loop: one detached thread per connection. Returns after
    /// `shutdown` (a closed listener also ends it).
    pub fn serveForever(self: *Origin) void {
        while (!self.stopping.load(.acquire)) {
            var stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return,
            };
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            _ = self.conns.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, handleConnection, .{ self, stream }) catch {
                handleConnection(self, stream);
                continue;
            };
            t.detach();
        }
    }

    /// Stop accepting: flag, then poke the port so a blocked `accept` returns.
    /// Waits for in-flight connection threads before closing the listener.
    pub fn shutdown(self: *Origin) void {
        self.stopping.store(true, .release);
        const poke: Io.net.IpAddress = .{ .ip4 = .loopback(self.port()) };
        if (poke.connect(self.io, .{ .mode = .stream })) |s| {
            var stream = s;
            stream.close(self.io);
        } else |_| {}
        while (self.conns.load(.acquire) != 0) {
            Io.sleep(self.io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
        }
    }

    pub fn deinit(self: *Origin) void {
        self.listener.deinit(self.io);
    }
};

fn handleConnection(o: *Origin, stream_in: Io.net.Stream) void {
    var stream = stream_in;
    defer _ = o.conns.fetchSub(1, .acq_rel);
    defer stream.close(o.io);
    serveConnection(o, &stream) catch |err| {
        // Dropped connections (browser preconnect, reload) are routine.
        const routine = err == error.ReadFailed or err == error.EndOfStream or
            err == error.WriteFailed or err == error.HttpConnectionClosing;
        if (!routine) std.debug.print("snarf-origin: {s}\n", .{@errorName(err)});
    };
}

fn serveConnection(o: *Origin, stream: *Io.net.Stream) !void {
    // Room for one full 9P frame plus WebSocket framing on each side.
    const recv_buf = try o.gpa.alloc(u8, msize + 4096);
    defer o.gpa.free(recv_buf);
    const send_buf = try o.gpa.alloc(u8, msize + 4096);
    defer o.gpa.free(send_buf);
    var reader = stream.reader(o.io, recv_buf);
    var writer = stream.writer(o.io, send_buf);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();

    if (std.mem.eql(u8, http.pathOf(request.head.target), ws_path)) {
        switch (request.upgradeRequested()) {
            .websocket => |key_opt| {
                const key = key_opt orelse return http.plain(&request, .bad_request, "400 missing sec-websocket-key\n");
                var ws = try request.respondWebSocket(.{ .key = key });
                try ws.flush();
                return serveNineP(o, &ws);
            },
            else => return http.plain(&request, .upgrade_required, "426 upgrade required: /9p speaks 9P2000 over WebSocket\n"),
        }
    }
    try http.serveStatic(o.io, o.gpa, &request, o.cfg.www_dir);
}

/// One 9P session: its own tree, host export handle, and server state, all
/// released when the peer goes away. Fid nodes live in a per-session arena:
/// a peer that vanishes without clunking must not leak. The transport blocks,
/// so `step` never reports idle; the loop ends on `Closed`.
fn serveNineP(o: *Origin, ws: *std.http.Server.WebSocket) !void {
    var arena = std.heap.ArenaAllocator.init(o.gpa);
    defer arena.deinit();
    var host = try HostFs.open(o.io, o.cfg.export_dir);
    defer host.close();
    var tree = Tree.init(arena.allocator(), &host);
    defer tree.deinit();
    var tport: WsTransport = .{ .ws = ws };
    var srv = try ninep.server.Server.init(o.gpa, tport.transport(), &Tree.ops, &tree, msize);
    defer srv.deinit();
    while (true) {
        _ = srv.step() catch |err| switch (err) {
            error.Closed => return,
            else => return err,
        };
    }
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg: Config = .{ .www_dir = build_options.www_dir, .export_dir = build_options.export_dir };
    var origin = Origin.listen(io, gpa, cfg, build_options.bind, build_options.port) catch |err| {
        std.debug.print("snarf-origin: cannot listen on {s}:{d}: {s}\n", .{ build_options.bind, build_options.port, @errorName(err) });
        return err;
    };
    defer origin.deinit();

    std.debug.print(
        \\snarf-origin: http://{s}:{d}/   (Ctrl-C to stop)
        \\  www    : {s}
        \\  9p     : ws://{s}:{d}{s}  →  version, bin/{{echo,date}}, fs/
        \\  fs/    : {s}  (read/write)
        \\  headers: application/wasm + COOP/COEP (cross-origin isolated)
        \\
    , .{ build_options.bind, origin.port(), cfg.www_dir, build_options.bind, origin.port(), ws_path, cfg.export_dir });

    origin.serveForever();
}
