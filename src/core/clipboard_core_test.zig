//! Editor-level clipboard tests for issue #12: the snarf buffer must sync
//! with `/dev/snarf` (R-EDIT-14, R-9P-07). Today the buffer is internal
//! (`snarf.zig`: "/dev/snarf + clipboard sync DEFERRED (R-P7-5)"), so these
//! are expected-fail behind `clipboard_sync_landed`. Plan: CB-04, CB-05.
//!
//! Rig: a booted row with a `SnarfSink` 9P server mounted at `/dev` standing
//! in for the host pasteboard (the device side is covered in
//! `host/devdraw/clipboard_test.zig`).
const std = @import("std");
const testing = std.testing;
const ninep = @import("ninep");
const draw = @import("draw");
const boot = @import("boot.zig");
const Editor = @import("Editor.zig");
const builtins = @import("exec/builtins.zig");
const Frame = draw.Frame;
const proto = draw.proto;

/// Flip to true in the PR that lands #12's core sync.
const clipboard_sync_landed = false;

fn xfail(ok: bool) !void {
    if (clipboard_sync_landed) {
        if (!ok) return error.TestUnexpectedResult;
        return;
    }
    if (ok) return error.UnexpectedPassFlipFlag;
    return error.SkipZigTest;
}

const SnarfSink = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    writes: usize = 0,
    reads: usize = 0,

    const ops: ninep.server.Ops = .{ .attach = attach, .walk1 = walk1, .open = open, .read = read, .write = write, .stat = stat };
    fn me(ctx: *anyopaque) *SnarfSink {
        return @ptrCast(@alignCast(ctx));
    }
    fn attach(_: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, _: []const u8) ninep.errors.OpError!ninep.Qid {
        return .{ .path = 0, .qtype = .{ .dir = true } };
    }
    fn walk1(_: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, name: []const u8) ninep.errors.OpError!ninep.Qid {
        if (!std.mem.eql(u8, name, "snarf")) return error.FileDoesNotExist;
        return .{ .path = 4, .qtype = .{} };
    }
    fn open(_: *anyopaque, _: *ninep.server.Server, fid: *ninep.server.Fid, _: u8) ninep.errors.OpError!ninep.Qid {
        return fid.qid;
    }
    fn read(ctx: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, off: u64, out: []u8) ninep.errors.OpError!usize {
        const s = me(ctx);
        s.reads += 1;
        if (off >= s.len) return 0;
        const n = @min(out.len, s.len - off);
        @memcpy(out[0..n], s.buf[off..][0..n]);
        return n;
    }
    fn write(ctx: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, off: u64, data: []const u8) ninep.errors.OpError!usize {
        const s = me(ctx);
        s.writes += 1;
        if (off == 0) s.len = 0;
        @memcpy(s.buf[s.len..][0..data.len], data);
        s.len += data.len;
        return data.len;
    }
    fn stat(_: *anyopaque, _: *ninep.server.Server, fid: *ninep.server.Fid) ninep.errors.OpError!ninep.stat {
        return .{ .qid = fid.qid, .mode = 0o666, .length = 0, .name = "snarf" };
    }
};

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

const Rig = struct {
    fx: Frame.TestFixture,
    ns: ninep.mount.Namespace,
    tree: boot.Tree,
    ed: Editor,
    sink: SnarfSink,
    pipe: *ninep.chan.Pipe,
    srv: ninep.server.Server,
    cl: ninep.Client,

    fn init(h: *Rig, body: []const u8) !void {
        const a = testing.allocator;
        h.fx = try Frame.TestFixture.init();
        h.ns = ninep.mount.Namespace.init(a);
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 640, 480), .{ .ns = &h.ns, .win_name = "scratch", .body = body });
        h.ed = Editor.init(a);
        h.tree.bind(&h.ed);
        h.sink = .{};
        h.pipe = try ninep.chan.Pipe.init(a, 16384);
        h.srv = try ninep.server.Server.init(a, h.pipe.serverEnd(), &SnarfSink.ops, &h.sink, 8192);
        h.cl = try ninep.Client.init(a, h.pipe.clientEnd(), 8192);
        h.cl.pump = .{ .ctx = &h.srv, .run = pump };
        _ = try h.cl.version(8192);
        const root = try h.cl.attach("larry", "");
        try h.ns.mount("/dev", &h.cl, root.fid);
    }
    fn deinit(h: *Rig) void {
        h.ed.deinit();
        h.cl.deinit();
        h.srv.deinit();
        h.pipe.deinit();
        h.tree.deinit();
        h.ns.deinit();
        h.fx.deinit();
    }
    fn exec(h: *Rig, comptime name: []const u8) !void {
        const w = h.tree.row.col.items[0].w.items[0];
        h.ed.seq += 1; // exec.c execute: seq++ before a marking builtin
        for (&builtins.exectab) |*e| if (std.mem.eql(u8, e.name, name)) {
            return e.fn_(&h.ed, &w.tag, &w.body, null, e.flag1, e.flag2, "");
        };
        return error.BuiltinMissing;
    }
};

test "clipboard CB-04: Snarf writes the selection to /dev/snarf (expected-fail until #12)" {
    var h: Rig = undefined;
    try h.init("keepme");
    defer h.deinit();
    const w = h.tree.row.col.items[0].w.items[0];
    try w.body.setSelect(0, 4);
    h.ed.seltext = &w.body;
    try h.exec("Snarf");
    try testing.expectEqualStrings("keep", h.ed.snarf.items); // internal buffer: works today
    try xfail(std.mem.eql(u8, h.sink.buf[0..h.sink.len], "keep"));
}

test "clipboard CB-05: Paste uses the current /dev/snarf contents (expected-fail until #12)" {
    var h: Rig = undefined;
    try h.init("ab");
    defer h.deinit();
    const w = h.tree.row.col.items[0].w.items[0];
    try h.ed.snarf.appendSlice(testing.allocator, "STALE");
    @memcpy(h.sink.buf[0..3], "EXT");
    h.sink.len = 3;
    try w.body.setSelect(2, 2);
    h.ed.seltext = &w.body;
    try h.exec("Paste");
    const n = w.body.file.buffer.len();
    var dest: [256]u8 = undefined;
    const got = w.body.file.buffer.read(0, n, &dest);
    try xfail(std.mem.eql(u8, got, "abEXT"));
}
