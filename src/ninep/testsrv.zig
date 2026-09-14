//! testsrv.zig — the shared 9P server TEST HARNESS: an in-memory duplex
//! transport plus the contract §10 fixture tree, lifted verbatim out of
//! `server.zig`'s test section in phase 14a so that `server.zig`, `park.zig`
//! and `server_mut.zig` all drive the SAME fixture (and so `server.zig` fits
//! its S-07 size cap — the block was 234 of its 780 pre-test lines).
//!
//! PURE MOVE: every declaration below is byte-identical to the phase-13b
//! `server.zig` original apart from `pub` qualifiers and this header, so the
//! existing test bodies that use it are unchanged (ruling R-P14a-1).
//!
//! Test-only: nothing outside a `test` block references it, so Zig's lazy
//! analysis keeps it out of the wasm build. Imports std + sibling ninep files
//! only (S-07 §6).
const std = @import("std");
const Qid = @import("qid.zig");
const msg = @import("msg.zig");
const stat = @import("stat.zig");
const errors = @import("errors.zig");
const transport = @import("transport.zig");
const server = @import("server.zig");

const OpError = errors.OpError;
const Server = server.Server;
const Fid = server.Fid;
const Ops = server.Ops;
const testing = std.testing;

/// In-memory duplex transport: `requests` are frames the test enqueues for the
/// server to read; `replies` are frames the server writes back.
pub const TestTransport = struct {
    alloc: std.mem.Allocator,
    requests: std.ArrayList([]u8) = .empty,
    replies: std.ArrayList([]u8) = .empty,
    closed: bool = false,

    pub fn deinit(self: *TestTransport) void {
        for (self.requests.items) |fr| self.alloc.free(fr);
        for (self.replies.items) |fr| self.alloc.free(fr);
        self.requests.deinit(self.alloc);
        self.replies.deinit(self.alloc);
    }

    pub fn pushReq(self: *TestTransport, frame: []const u8) !void {
        try self.requests.append(self.alloc, try self.alloc.dupe(u8, frame));
    }

    pub fn popReply(self: *TestTransport) ?[]u8 {
        if (self.replies.items.len == 0) return null;
        return self.replies.orderedRemove(0);
    }

    pub fn vWrite(ctx: *anyopaque, frame: []const u8) transport.Error!void {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        if (frame.len < msg.header_size) return error.BadFrame;
        if (std.mem.readInt(u32, frame[0..4], .little) != frame.len) return error.BadFrame;
        const copy = self.alloc.dupe(u8, frame) catch unreachable;
        self.replies.append(self.alloc, copy) catch unreachable;
    }

    pub fn vRead(ctx: *anyopaque, buf: []u8) transport.Error![]u8 {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        if (self.requests.items.len == 0) return if (self.closed) error.Closed else error.WouldBlock;
        const front = self.requests.items[0];
        if (front.len > buf.len) return error.FrameTooBig;
        @memcpy(buf[0..front.len], front);
        _ = self.requests.orderedRemove(0);
        self.alloc.free(front);
        return buf[0..front.len];
    }

    pub fn vClose(ctx: *anyopaque) void {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }

    const vtable = transport.Transport.VTable{ .writeMsg = vWrite, .readMsg = vRead, .close = vClose };

    pub fn asTransport(self: *TestTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// A tree node addressed by qid path. Directories list child paths by number.
pub const Node = struct {
    path: u64 = 0,
    name: []const u8 = "",
    is_dir: bool = false,
    content: []const u8 = "",
    writable: bool = false,
    children: []const u64 = &.{},
};

/// Contract §10 fixture: root(1) dir → {index(2) "hello, snarf\n" ro,
/// notes(3) writable, sub(4) dir → leaf(5) "leaf\n"}.
pub const TestTree = struct {
    nodes: [6]Node,
    notes: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TestTree {
        return .{
            .alloc = alloc,
            .notes = .empty,
            .nodes = .{
                .{}, // path 0 — unused
                .{ .path = 1, .name = "", .is_dir = true, .children = &.{ 2, 3, 4 } },
                .{ .path = 2, .name = "index", .content = "hello, snarf\n" },
                .{ .path = 3, .name = "notes", .writable = true },
                .{ .path = 4, .name = "sub", .is_dir = true, .children = &.{5} },
                .{ .path = 5, .name = "leaf", .content = "leaf\n" },
            },
        };
    }

    pub fn deinit(self: *TestTree) void {
        self.notes.deinit(self.alloc);
    }
};

pub fn qidOf(n: *const Node) Qid {
    return .{ .path = n.path, .qtype = .{ .dir = n.is_dir } };
}

pub fn nodeOf(fid: *Fid) *Node {
    return @ptrCast(@alignCast(fid.ctx.?));
}

pub fn treeAttach(ctx: *anyopaque, srv: *Server, fid: *Fid, aname: []const u8) OpError!Qid {
    _ = srv;
    _ = aname;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    fid.ctx = &tree.nodes[1];
    return qidOf(&tree.nodes[1]);
}

pub fn treeWalk1(ctx: *anyopaque, srv: *Server, fid: *Fid, name: []const u8) OpError!Qid {
    _ = srv;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    const cur = nodeOf(fid);
    for (cur.children) |cp| {
        const child = &tree.nodes[cp];
        if (std.mem.eql(u8, child.name, name)) {
            fid.ctx = child;
            return qidOf(child);
        }
    }
    return error.FileDoesNotExist;
}

pub fn treeOpen(ctx: *anyopaque, srv: *Server, fid: *Fid, mode: u8) OpError!Qid {
    _ = ctx;
    _ = srv;
    _ = mode;
    return fid.qid;
}

pub fn treeRead(ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, buf: []u8) OpError!usize {
    _ = srv;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    const node = nodeOf(fid);
    if (node.is_dir) return 0; // fixtures return 0 for dir reads (R7)
    const data = if (node.writable) tree.notes.items else node.content;
    if (offset >= data.len) return 0;
    const avail = data[@intCast(offset)..];
    const n = @min(avail.len, buf.len);
    @memcpy(buf[0..n], avail[0..n]);
    return n;
}

pub fn treeWrite(ctx: *anyopaque, srv: *Server, fid: *Fid, offset: u64, data: []const u8) OpError!usize {
    _ = srv;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    const node = nodeOf(fid);
    if (!node.writable) return error.PermissionDenied;
    const off: usize = @intCast(offset);
    const end = off + data.len;
    if (end > tree.notes.items.len) tree.notes.resize(tree.alloc, end) catch return error.IoError;
    @memcpy(tree.notes.items[off..end], data);
    return data.len;
}

pub fn treeStat(ctx: *anyopaque, srv: *Server, fid: *Fid) OpError!stat {
    _ = srv;
    const tree: *TestTree = @ptrCast(@alignCast(ctx));
    const node = nodeOf(fid);
    const len: u64 = if (node.is_dir) 0 else if (node.writable) tree.notes.items.len else node.content.len;
    return .{
        .qid = qidOf(node),
        .mode = if (node.is_dir) (stat.DMDIR | 0o555) else 0o644,
        .length = len,
        .name = node.name,
    };
}

pub const tree_ops = Ops{
    .attach = treeAttach,
    .walk1 = treeWalk1,
    .open = treeOpen,
    .read = treeRead,
    .write = treeWrite,
    .stat = treeStat,
};

/// Heap-pinned harness so the transport/tree pointers held by `Server` stay
/// stable across the whole test.
pub const Fixture = struct {
    alloc: std.mem.Allocator,
    tt: TestTransport,
    tree: TestTree,
    srv: Server,
    rbuf: [8192]u8 = undefined,

    pub fn create(alloc: std.mem.Allocator) !*Fixture {
        const self = try alloc.create(Fixture);
        self.alloc = alloc;
        self.tt = .{ .alloc = alloc };
        self.tree = TestTree.init(alloc);
        self.srv = try Server.init(alloc, self.tt.asTransport(), &tree_ops, &self.tree, 8192);
        return self;
    }

    pub fn destroy(self: *Fixture) void {
        self.srv.deinit();
        self.tree.deinit();
        self.tt.deinit();
        self.alloc.destroy(self);
    }

    /// Encode `m`, feed it to the server, decode the single reply. The reply
    /// bytes are copied into `self.rbuf` so the decoded slices stay valid.
    pub fn transact(self: *Fixture, m: msg.Message) !msg.Message {
        var enc: [8192]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        return self.transactRaw(enc[0..n]);
    }

    pub fn transactRaw(self: *Fixture, frame: []const u8) !msg.Message {
        try self.tt.pushReq(frame);
        _ = try self.srv.step();
        const reply = self.tt.popReply() orelse return error.NoReply;
        defer self.alloc.free(reply);
        @memcpy(self.rbuf[0..reply.len], reply);
        return try msg.decode(self.rbuf[0..reply.len]);
    }

    pub fn doVersion(self: *Fixture) !void {
        const r = try self.transact(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect(r.body == .rversion);
    }

    pub fn doAttach(self: *Fixture, fid: u32) !Qid {
        const r = try self.transact(.{ .tag = 1, .body = .{ .tattach = .{ .fid = fid, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
        try testing.expect(r.body == .rattach);
        return r.body.rattach.qid;
    }

    pub fn expectRerror(_: *Fixture, r: msg.Message, want: []const u8) !void {
        try testing.expect(r.body == .rerror);
        try testing.expectEqualStrings(want, r.body.rerror.ename);
    }
};
