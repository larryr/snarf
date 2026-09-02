//! Origin-server acceptance tests: a real listener on an ephemeral loopback
//! port, a real WebSocket client, and the real `ninep.Client` — the browser's
//! view of `/mnt/origin` without a browser (S-02 §5, S-01 §3.2). Also the
//! test root that pulls in every tools/origin unit test.
const std = @import("std");
const ninep = @import("ninep");
const origin = @import("main.zig");
const tree = @import("tree.zig");
const services = @import("services.zig");
const WsClient = @import("ws_client.zig").WsClient;

const msg = ninep.msg;
const Stat = ninep.stat;
const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = @import("http.zig");
    _ = @import("ws_transport.zig");
    _ = @import("dirread.zig");
    _ = @import("hostfs.zig");
    _ = services;
    _ = tree;
}

/// A running origin over a temp www dir and a temp export dir.
const Harness = struct {
    tmp: testing.TmpDir,
    www: [:0]u8,
    export_dir: [:0]u8,
    server: *origin.Origin,
    thread: std.Thread,

    fn start(gpa: std.mem.Allocator) !Harness {
        const io = testing.io;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "www");
        try tmp.dir.writeFile(io, .{ .sub_path = "www/index.html", .data = "<canvas id=screen></canvas>" });
        try tmp.dir.createDirPath(io, "export/sub");
        try tmp.dir.writeFile(io, .{ .sub_path = "export/hello.txt", .data = "hello, origin\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "export/notes.txt", .data = "" });
        try tmp.dir.writeFile(io, .{ .sub_path = "export/sub/leaf", .data = "leaf\n" });
        const www = try tmp.dir.realPathFileAlloc(io, "www", gpa);
        errdefer gpa.free(www);
        const export_dir = try tmp.dir.realPathFileAlloc(io, "export", gpa);
        errdefer gpa.free(export_dir);

        const server = try gpa.create(origin.Origin);
        errdefer gpa.destroy(server);
        server.* = try origin.Origin.listen(io, gpa, .{ .www_dir = www, .export_dir = export_dir }, "127.0.0.1", 0);
        const thread = try std.Thread.spawn(.{}, origin.Origin.serveForever, .{server});
        return .{ .tmp = tmp, .www = www, .export_dir = export_dir, .server = server, .thread = thread };
    }

    fn stop(self: *Harness, gpa: std.mem.Allocator) void {
        self.server.shutdown();
        self.thread.join();
        self.server.deinit();
        gpa.destroy(self.server);
        gpa.free(self.www);
        gpa.free(self.export_dir);
        self.tmp.cleanup();
    }
};

fn readAll(cl: *ninep.Client, fid: u32, buf: []u8) !usize {
    var total: usize = 0;
    while (true) {
        const n = try cl.read(fid, total, buf[total..]);
        if (n == 0) return total;
        total += n;
    }
}

/// Decode a directory read into its entry names (comma-joined, in order).
fn dirNames(buf: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        const st = try Stat.decode(buf[pos..]);
        if (out.items.len > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, st.name);
        pos += st.encodedSize();
    }
}

test "origin: 9P over WebSocket — version, fs read/write, bin/echo, listings" {
    const gpa = testing.allocator;
    var h = try Harness.start(gpa);
    defer h.stop(gpa);

    const wc = try WsClient.connect(gpa, testing.io, h.server.port(), origin.ws_path, origin.msize + 4096);
    defer wc.deinit();
    var cl = try ninep.Client.init(gpa, wc.transport(), origin.msize);
    defer cl.deinit();

    try testing.expectEqual(origin.msize, try cl.version(origin.msize));
    const root = try cl.attach("larry", "");
    var buf: [4096]u8 = undefined;

    // version
    const v = try cl.walk(root.fid, &.{"version"});
    _ = try cl.open(v.fid, msg.OREAD);
    try testing.expectEqualStrings(tree.version_text, buf[0..try readAll(&cl, v.fid, &buf)]);
    try testing.expectError(error.PermissionDenied, cl.open(v.fid, msg.OWRITE));
    try cl.clunk(v.fid);

    // root listing — on a clone, since an open fid cannot be walked from (walk(5))
    const rootdir = try cl.walk(root.fid, &.{});
    _ = try cl.open(rootdir.fid, msg.OREAD);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    try dirNames(buf[0..try readAll(&cl, rootdir.fid, &buf)], &names, gpa);
    try testing.expectEqualStrings("version,bin,fs", names.items);
    try cl.clunk(rootdir.fid);

    // fs/hello.txt via a multi-element walk
    const hello = try cl.walk(root.fid, &.{ "fs", "hello.txt" });
    try testing.expect(!hello.qid.qtype.dir);
    _ = try cl.open(hello.fid, msg.OREAD);
    try testing.expectEqualStrings("hello, origin\n", buf[0..try readAll(&cl, hello.fid, &buf)]);
    const hst = try cl.stat(hello.fid);
    try testing.expectEqualStrings("hello.txt", hst.name);
    try testing.expectEqual(@as(u64, 14), hst.length);
    try cl.clunk(hello.fid);

    // fs/notes.txt: write, then read back through a fresh fid
    const notes = try cl.walk(root.fid, &.{ "fs", "notes.txt" });
    _ = try cl.open(notes.fid, msg.OWRITE);
    try testing.expectEqual(@as(usize, 9), try cl.write(notes.fid, 0, "remember\n"));
    try cl.clunk(notes.fid);
    const notes2 = try cl.walk(root.fid, &.{ "fs", "notes.txt" });
    _ = try cl.open(notes2.fid, msg.OREAD);
    try testing.expectEqualStrings("remember\n", buf[0..try readAll(&cl, notes2.fid, &buf)]);
    try cl.clunk(notes2.fid);

    // fs/ listing and `..` back to the root
    const fs = try cl.walk(root.fid, &.{"fs"});
    try testing.expect(fs.qid.qtype.dir);
    _ = try cl.open(fs.fid, msg.OREAD);
    names.clearRetainingCapacity();
    try dirNames(buf[0..try readAll(&cl, fs.fid, &buf)], &names, gpa);
    try testing.expect(std.mem.indexOf(u8, names.items, "hello.txt") != null);
    try testing.expect(std.mem.indexOf(u8, names.items, "sub") != null);
    try cl.clunk(fs.fid);
    const back = try cl.walk(root.fid, &.{ "fs", "sub", "..", ".." });
    try testing.expectEqual(root.qid.path, back.qid.path);
    try cl.clunk(back.fid);

    // walk errors: a partial multi-element walk is a short Rwalk (walk(5)),
    // which the client reports as FileDoesNotExist; only a failing FIRST
    // element carries the specific Rerror.
    try testing.expectError(error.FileDoesNotExist, cl.walk(root.fid, &.{ "fs", "nope" }));
    try testing.expectError(error.FileDoesNotExist, cl.walk(root.fid, &.{ "fs", "hello.txt", "x" }));
    try testing.expectError(error.FileDoesNotExist, cl.walk(root.fid, &.{ "bin", "rm" }));
    const hf = try cl.walk(root.fid, &.{ "fs", "hello.txt" });
    try testing.expectError(error.WalkNoDir, cl.walk(hf.fid, &.{"x"}));
    try cl.clunk(hf.fid);

    // bin/echo: exec via ctl, result via output; a bad verb is refused
    const ctl = try cl.walk(root.fid, &.{ "bin", "echo", "ctl" });
    _ = try cl.open(ctl.fid, msg.OWRITE);
    try testing.expectError(error.BadCtl, cl.write(ctl.fid, 0, "launch missiles\n"));
    _ = try cl.write(ctl.fid, 0, "exec hi there\n");
    try cl.clunk(ctl.fid);
    const out = try cl.walk(root.fid, &.{ "bin", "echo", "output" });
    _ = try cl.open(out.fid, msg.OREAD);
    try testing.expectEqualStrings("hi there\n", buf[0..try readAll(&cl, out.fid, &buf)]);
    try cl.clunk(out.fid);

    // bin/ listing
    const bin = try cl.walk(root.fid, &.{"bin"});
    _ = try cl.open(bin.fid, msg.OREAD);
    names.clearRetainingCapacity();
    try dirNames(buf[0..try readAll(&cl, bin.fid, &buf)], &names, gpa);
    try testing.expectEqualStrings("echo,date", names.items);
    try cl.clunk(bin.fid);

    try cl.clunk(root.fid);
    wc.transport().close();
}

test "origin: static HTTP serves www with the wasm-friendly headers" {
    const gpa = testing.allocator;
    const io = testing.io;
    var h = try Harness.start(gpa);
    defer h.stop(gpa);

    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(h.server.port()) };
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var rbuf: [8192]u8 = undefined;
    var wbuf: [512]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(gpa);
    while (true) {
        const chunk = reader.interface.peek(1) catch break;
        if (chunk.len == 0) break;
        try response.append(gpa, chunk[0]);
        reader.interface.toss(1);
    }
    const text = response.items;
    try testing.expect(std.mem.startsWith(u8, text, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, text, "content-type: text/html; charset=utf-8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cross-origin-opener-policy: same-origin") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cross-origin-embedder-policy: require-corp") != null);
    try testing.expect(std.mem.endsWith(u8, text, "<canvas id=screen></canvas>"));
}

const Io = std.Io;
