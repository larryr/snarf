//! TEST FIXTURE: a flat, writable, in-memory 9P file tree — the server the
//! phase-17 Put/Get/Dump/Load tests write through. file-as-struct (S-07 P-1):
//! this file *is* the MemTree. Test-only: nothing outside a `test` block names
//! it, so lazy analysis keeps it out of the wasm build (the `ninep/testsrv.zig`
//! convention).
//!
//! One root directory (qid path 1) holding plain files (qid path 2+i). Every
//! fid's position is its qid (the server keeps `fid.qid` current), so the ops
//! are stateless. `open` honours OTRUNC, `write` is positional, `create` makes
//! a file (exclusive), and each mutation bumps the file's `vers` — which is
//! also its `mtime`, so a stale-check test can move a file's identity by
//! writing to it (or by bumping `vers` directly).
//!
//! `Harness` wires one onto a `chan.Pipe` + `server.Server` + `Client`, mounts
//! it in a caller's namespace, and exposes `poll` for the step loops.
//!
//! Imports: `std` + `ninep` (S-07 §6).
const std = @import("std");
const ninep = @import("ninep");

const MemTree = @This();
const server = ninep.server;
const msg = ninep.msg;
const Qid = ninep.Qid;
const Stat = ninep.stat;
const OpError = ninep.errors.OpError;

pub const File = struct {
    name: []u8,
    data: std.ArrayList(u8) = .empty,
    vers: u32 = 1,
    /// Fault injection for Put's failure-path tests (T10): when true, `open`
    /// reports this qid QTAPPEND — `WriteFileJob`'s `refuse_append` then
    /// refuses it if the caller also says the file already has bytes.
    qtype_append: bool = false,
    /// One-shot fault: the next `write` on this file acknowledges one byte
    /// fewer than it was asked to — `WriteFileJob` sees that as a short
    /// `Rwrite.count` (`error.ShortWrite`, exec.c:757). Cleared after firing.
    short_once: bool = false,
};

alloc: std.mem.Allocator,
files: std.ArrayList(File) = .empty,
/// Fault injection: every `create` fails (simulates a refused Tcreate — the
/// "can't create file" path, exec.c:729).
fail_create: bool = false,

pub fn init(alloc: std.mem.Allocator) MemTree {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *MemTree) void {
    for (self.files.items) |*f| {
        self.alloc.free(f.name);
        f.data.deinit(self.alloc);
    }
    self.files.deinit(self.alloc);
}

/// Add (or replace the contents of) a file.
pub fn put(self: *MemTree, name: []const u8, data: []const u8) !void {
    const f = self.find(name) orelse blk: {
        try self.files.append(self.alloc, .{ .name = try self.alloc.dupe(u8, name) });
        break :blk &self.files.items[self.files.items.len - 1];
    };
    f.data.clearRetainingCapacity();
    try f.data.appendSlice(self.alloc, data);
    f.vers += 1;
}

pub fn find(self: *MemTree, name: []const u8) ?*File {
    for (self.files.items) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn fileOf(self: *MemTree, fid: *server.Fid) ?*File {
    if (fid.qid.path < 2) return null;
    const i: usize = @intCast(fid.qid.path - 2);
    return if (i < self.files.items.len) &self.files.items[i] else null;
}

fn qidOf(self: *MemTree, i: usize) Qid {
    return .{ .path = 2 + i, .vers = self.files.items[i].vers };
}

fn attach(_: *anyopaque, _: *server.Server, _: *server.Fid, _: []const u8) OpError!Qid {
    return .{ .path = 1, .qtype = .{ .dir = true } };
}

fn walk1(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) OpError!Qid {
    const self: *MemTree = @ptrCast(@alignCast(ctx));
    if (fid.qid.path != 1) return error.WalkNoDir;
    if (std.mem.eql(u8, name, "..")) return .{ .path = 1, .qtype = .{ .dir = true } };
    for (self.files.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return self.qidOf(i);
    }
    return error.FileDoesNotExist;
}

fn open(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, mode: u8) OpError!Qid {
    const self: *MemTree = @ptrCast(@alignCast(ctx));
    const f = self.fileOf(fid) orelse return fid.qid;
    if (mode & msg.OTRUNC != 0) {
        f.data.clearRetainingCapacity();
        f.vers += 1;
    }
    return .{ .path = fid.qid.path, .vers = f.vers, .qtype = .{ .append = f.qtype_append } };
}

fn read(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, buf: []u8) server.ReadError!usize {
    const self: *MemTree = @ptrCast(@alignCast(ctx));
    if (fid.qid.path == 1) {
        if (offset != 0) return 0;
        var n: usize = 0;
        for (self.files.items, 0..) |f, i| {
            const st = Stat{ .qid = self.qidOf(i), .mode = 0o644, .length = f.data.items.len, .name = f.name };
            n += st.encode(buf[n..]) catch break;
        }
        return n;
    }
    const f = self.fileOf(fid) orelse return error.FileDoesNotExist;
    if (offset >= f.data.items.len) return 0;
    const k = @min(buf.len, f.data.items.len - offset);
    @memcpy(buf[0..k], f.data.items[@intCast(offset)..][0..k]);
    return k;
}

fn write(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, data: []const u8) OpError!usize {
    const self: *MemTree = @ptrCast(@alignCast(ctx));
    const f = self.fileOf(fid) orelse return error.PermissionDenied;
    const off: usize = @intCast(offset);
    if (off + data.len > f.data.items.len) f.data.resize(self.alloc, off + data.len) catch return error.IoError;
    @memcpy(f.data.items[off..][0..data.len], data);
    f.vers += 1;
    if (f.short_once and data.len > 0) {
        f.short_once = false;
        return data.len - 1;
    }
    return data.len;
}

fn statOp(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) OpError!Stat {
    const self: *MemTree = @ptrCast(@alignCast(ctx));
    if (fid.qid.path == 1) return .{ .qid = fid.qid, .mode = Stat.DMDIR | 0o755, .length = 0, .name = "/" };
    const f = self.fileOf(fid) orelse return error.FileDoesNotExist;
    const i: usize = @intCast(fid.qid.path - 2);
    return .{ .qid = self.qidOf(i), .mode = 0o644, .length = f.data.items.len, .mtime = f.vers, .name = f.name };
}

fn create(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8, perm: u32, _: u8) server.OpBlockError!server.CreateResult {
    const self: *MemTree = @ptrCast(@alignCast(ctx));
    if (self.fail_create) return error.PermissionDenied;
    if (fid.qid.path != 1 or perm & Stat.DMDIR != 0) return error.PermissionDenied;
    if (self.find(name) != null) return error.FileExists;
    const copy = self.alloc.dupe(u8, name) catch return error.IoError;
    self.files.append(self.alloc, .{ .name = copy }) catch {
        self.alloc.free(copy);
        return error.IoError;
    };
    return .{ .qid = self.qidOf(self.files.items.len - 1) };
}

pub const ops = server.Ops{
    .attach = attach,
    .walk1 = walk1,
    .open = open,
    .read = read,
    .write = write,
    .stat = statOp,
    .create = create,
};

/// A MemTree served over a pipe and mounted at `prefix` in `ns`. Heap-pinned
/// (the client's pump and the server's ctx point into it).
pub const Harness = struct {
    tree: MemTree,
    pipe: *ninep.chan.Pipe,
    srv: server.Server,
    client: ninep.Client,

    pub fn create(alloc: std.mem.Allocator, ns: *ninep.mount.Namespace, prefix: []const u8) !*Harness {
        const h = try alloc.create(Harness);
        errdefer alloc.destroy(h);
        h.tree = MemTree.init(alloc);
        h.pipe = try ninep.chan.Pipe.init(alloc, 65536);
        h.srv = try server.Server.init(alloc, h.pipe.serverEnd(), &ops, &h.tree, 8192);
        h.client = try ninep.Client.init(alloc, h.pipe.clientEnd(), 8192);
        h.client.pump = .{ .ctx = &h.srv, .run = pumpFn };
        _ = try h.client.version(8192);
        const root = try h.client.attach("larry", "");
        try ns.mount(prefix, &h.client, root.fid);
        return h;
    }

    pub fn destroy(h: *Harness, alloc: std.mem.Allocator) void {
        h.client.deinit();
        h.srv.deinit();
        h.pipe.deinit();
        h.tree.deinit();
        alloc.destroy(h);
    }

    /// Let the server answer whatever is queued (a step loop calls this).
    pub fn poll(h: *Harness) !void {
        _ = try h.srv.poll();
    }

    fn pumpFn(ctx: *anyopaque) anyerror!void {
        const s: *server.Server = @ptrCast(@alignCast(ctx));
        _ = try s.poll();
    }
};
