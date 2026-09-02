//! The origin's exported tree (S-02 §5) as a `ninep.server.Ops`:
//!
//!   /
//!   ├── version          "snarf-origin <ver>\n"
//!   ├── bin/             services.zig — <name>/{ctl,output}
//!   └── fs/              hostfs.zig — the export directory, read/write
//!
//! One `Tree` per connection. Each fid carries a heap `Node` (`fid.ctx`); the
//! synthetic nodes have fixed qid paths, host nodes carry their relative path
//! and take qids from the host inode (hostfs.qid_tag range).
const std = @import("std");
const ninep = @import("ninep");
const server = ninep.server;
const msg = ninep.msg;
const Qid = ninep.Qid;
const Stat = ninep.stat;
const OpError = ninep.errors.OpError;
const HostFs = @import("hostfs.zig").HostFs;
const services = @import("services.zig");
const DirReader = @import("dirread.zig").DirReader;

pub const version_text = "snarf-origin 0.1\n";

const q_root: u64 = 1;
const q_version: u64 = 2;
const q_bin: u64 = 3;
const q_svc: u64 = 0x100; // + service index: bin/<name>/
const q_ctl: u64 = 0x200; // + service index: bin/<name>/ctl
const q_out: u64 = 0x300; // + service index: bin/<name>/output

pub const Node = union(enum) {
    root,
    version,
    bin,
    svc: u8,
    svc_ctl: u8,
    svc_output: u8,
    /// Owned path relative to the export root; "" is `fs/` itself.
    host: []u8,
};

pub const Tree = struct {
    gpa: std.mem.Allocator,
    host: *HostFs,
    outputs: services.Outputs = .{},

    pub fn init(gpa: std.mem.Allocator, host: *HostFs) Tree {
        return .{ .gpa = gpa, .host = host };
    }

    pub fn deinit(self: *Tree) void {
        self.outputs.deinit(self.gpa);
    }

    pub const ops: server.Ops = .{
        .attach = attach,
        .walk1 = walk1,
        .clone = clone,
        .open = open,
        .read = read,
        .write = write,
        .clunk = clunk,
        .stat = statOp,
    };

    // -- fid ↔ node -----------------------------------------------------------

    fn nodeOf(fid: *server.Fid) *Node {
        return @ptrCast(@alignCast(fid.ctx.?));
    }

    fn setNode(self: *Tree, fid: *server.Fid, node: Node) OpError!void {
        const p = self.gpa.create(Node) catch return error.IoError;
        p.* = node;
        fid.ctx = p;
    }

    fn freeNode(self: *Tree, fid: *server.Fid) void {
        const p: *Node = @ptrCast(@alignCast(fid.ctx orelse return));
        if (p.* == .host) self.gpa.free(p.host);
        self.gpa.destroy(p);
        fid.ctx = null;
    }

    fn dupNode(self: *Tree, node: Node) OpError!Node {
        return switch (node) {
            .host => |rel| .{ .host = self.gpa.dupe(u8, rel) catch return error.IoError },
            else => node,
        };
    }

    // -- identity -------------------------------------------------------------

    fn qidOf(self: *Tree, node: Node) OpError!Qid {
        return switch (node) {
            .root => .{ .path = q_root, .qtype = .{ .dir = true } },
            .version => .{ .path = q_version },
            .bin => .{ .path = q_bin, .qtype = .{ .dir = true } },
            .svc => |i| .{ .path = q_svc + i, .qtype = .{ .dir = true } },
            .svc_ctl => |i| .{ .path = q_ctl + i },
            .svc_output => |i| .{ .path = q_out + i },
            .host => |rel| self.host.qidOf(rel),
        };
    }

    fn statOfNode(self: *Tree, node: Node, name: []const u8) OpError!Stat {
        const dir_mode = Stat.DMDIR | 0o555;
        return switch (node) {
            .root, .bin, .svc => .{ .qid = try self.qidOf(node), .mode = dir_mode, .length = 0, .name = name },
            .version => .{ .qid = try self.qidOf(node), .mode = 0o444, .length = version_text.len, .name = name },
            .svc_ctl => .{ .qid = try self.qidOf(node), .mode = 0o222, .length = 0, .name = name },
            .svc_output => |i| .{ .qid = try self.qidOf(node), .mode = 0o444, .length = self.outputs.get(i).len, .name = name },
            .host => |rel| self.host.statOf(rel, name),
        };
    }

    fn nameOf(node: Node) []const u8 {
        return switch (node) {
            .root => "/",
            .version => "version",
            .bin => "bin",
            .svc => |i| services.table[i].name,
            .svc_ctl => "ctl",
            .svc_output => "output",
            .host => |rel| if (rel.len == 0) "fs" else basename(rel),
        };
    }

    // -- Ops ------------------------------------------------------------------

    fn attach(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, _: []const u8) OpError!Qid {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        try self.setNode(fid, .root);
        return self.qidOf(.root);
    }

    fn walk1(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) OpError!Qid {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        const eq = std.mem.eql;
        const cur = nodeOf(fid);
        const up = eq(u8, name, "..");
        const next: Node = switch (cur.*) {
            .root => if (up) .root else if (eq(u8, name, "version")) .version else if (eq(u8, name, "bin")) .bin else if (eq(u8, name, "fs")) .{ .host = try self.hostPath("", "") } else return error.FileDoesNotExist,
            .version, .svc_ctl, .svc_output => return error.WalkNoDir,
            .bin => if (up) .root else if (services.indexOf(name)) |i| .{ .svc = i } else return error.FileDoesNotExist,
            .svc => |i| if (up) .bin else if (eq(u8, name, "ctl")) .{ .svc_ctl = i } else if (eq(u8, name, "output")) .{ .svc_output = i } else return error.FileDoesNotExist,
            .host => |rel| try self.walkHost(rel, name, up),
        };
        const qid = self.qidOf(next) catch |e| {
            if (next == .host) self.gpa.free(next.host);
            return e;
        };
        if (cur.* == .host) self.gpa.free(cur.host);
        cur.* = next;
        return qid;
    }

    /// One step inside `fs/`. Names never contain '/' on the wire, so a child
    /// path is rel ++ "/" ++ name; ".." pops a component (or leaves `fs/` for
    /// the root). Walking through a plain file is `WalkNoDir` (walk(5)).
    fn walkHost(self: *Tree, rel: []const u8, name: []const u8, up: bool) OpError!Node {
        if (up) {
            if (rel.len == 0) return .root;
            const cut = std.mem.lastIndexOfScalar(u8, rel, '/') orelse 0;
            return .{ .host = try self.hostPath(rel[0..cut], "") };
        }
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.indexOfScalar(u8, name, '/') != null)
            return error.FileDoesNotExist;
        if (!(try self.host.qidOf(rel)).qtype.dir) return error.WalkNoDir;
        return .{ .host = try self.hostPath(rel, name) };
    }

    fn hostPath(self: *Tree, rel: []const u8, name: []const u8) OpError![]u8 {
        if (name.len == 0) return self.gpa.dupe(u8, rel) catch return error.IoError;
        if (rel.len == 0) return self.gpa.dupe(u8, name) catch return error.IoError;
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ rel, name }) catch return error.IoError;
    }

    fn clone(ctx: *anyopaque, _: *server.Server, old: *server.Fid, new: *server.Fid) OpError!void {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        try self.setNode(new, try self.dupNode(nodeOf(old).*));
    }

    fn open(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, mode: u8) OpError!Qid {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        const node = nodeOf(fid).*;
        const acc = mode & 3;
        const wants_write = acc == msg.OWRITE or acc == msg.ORDWR or (mode & msg.OTRUNC) != 0;
        const qid = try self.qidOf(node);
        switch (node) {
            .root, .bin, .svc, .version, .svc_output => if (wants_write) return error.PermissionDenied,
            .svc_ctl => {},
            .host => |rel| {
                if (qid.qtype.dir) {
                    if (wants_write) return error.PermissionDenied;
                } else if ((mode & msg.OTRUNC) != 0) {
                    try self.host.truncate(rel);
                }
            },
        }
        return qid;
    }

    fn read(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, buf: []u8) server.ReadError!usize {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        const node = nodeOf(fid).*;
        switch (node) {
            .root => {
                var dr = DirReader.init(offset, buf);
                _ = dr.emit(try self.statOfNode(.version, "version")) and
                    dr.emit(try self.statOfNode(.bin, "bin")) and
                    dr.emit(try self.host.statOf("", "fs"));
                return dr.len();
            },
            .bin => {
                var dr = DirReader.init(offset, buf);
                for (0..services.count) |i| {
                    const idx: u8 = @intCast(i);
                    if (!dr.emit(try self.statOfNode(.{ .svc = idx }, services.table[i].name))) break;
                }
                return dr.len();
            },
            .svc => |i| {
                var dr = DirReader.init(offset, buf);
                _ = dr.emit(try self.statOfNode(.{ .svc_ctl = i }, "ctl")) and
                    dr.emit(try self.statOfNode(.{ .svc_output = i }, "output"));
                return dr.len();
            },
            .version => return sliceRead(version_text, offset, buf),
            .svc_ctl => return 0,
            .svc_output => |i| return sliceRead(self.outputs.get(i), offset, buf),
            .host => |rel| {
                if ((try self.host.qidOf(rel)).qtype.dir) return self.host.readDir(rel, offset, buf);
                return self.host.readFile(rel, offset, buf);
            },
        }
    }

    fn write(ctx: *anyopaque, srv: *server.Server, fid: *server.Fid, offset: u64, data: []const u8) OpError!usize {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        _ = srv;
        switch (nodeOf(fid).*) {
            .svc_ctl => |i| {
                const args = services.parseExec(data) orelse return error.BadCtl;
                const out = services.table[i].run(self.gpa, self.host.io, args) catch return error.IoError;
                self.outputs.set(self.gpa, i, out);
                return data.len;
            },
            .host => |rel| return self.host.writeFile(rel, offset, data),
            else => return error.PermissionDenied,
        }
    }

    fn clunk(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) void {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        self.freeNode(fid);
    }

    fn statOp(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) OpError!Stat {
        const self: *Tree = @ptrCast(@alignCast(ctx));
        const node = nodeOf(fid).*;
        return self.statOfNode(node, nameOf(node));
    }
};

fn sliceRead(content: []const u8, offset: u64, buf: []u8) usize {
    if (offset >= content.len) return 0;
    const n = @min(buf.len, content.len - offset);
    @memcpy(buf[0..n], content[@intCast(offset)..][0..n]);
    return n;
}

fn basename(rel: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return rel;
    return rel[cut + 1 ..];
}

test "tree: basename and sliceRead" {
    try std.testing.expectEqualStrings("leaf", basename("sub/leaf"));
    try std.testing.expectEqualStrings("top", basename("top"));
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), sliceRead("abcdef", 0, &buf));
    try std.testing.expectEqualStrings("ef", buf[0..sliceRead("abcdef", 4, &buf)]);
    try std.testing.expectEqual(@as(usize, 0), sliceRead("abc", 3, &buf));
}
