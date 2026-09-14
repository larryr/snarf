//! nsdir.zig — walking and reading DIRECTORIES through the namespace: union
//! walks, union reads, and the synthetic mount-point directories (S-02 §1,
//! R-9P-03, R-9P-16). `mount.zig` keeps the table; this file is what a caller
//! uses to reach a file or list a directory through it.
//!
//! Three kernel behaviours are ported here, from `larryr/plan9@ed1a9c2`:
//!
//!  1. **Union walk** (`9/port/chan.c:965-1050 walk`, esp. :1020-1043). After
//!     stepping through the mount point, the kernel tries the first target;
//!     when that fails it iterates the remaining `Mount`s in order ("try a
//!     union mount, if any") and the first success wins. All fail ⇒ the walk
//!     fails at that component.
//!  2. **Union read** (`9/port/sysfile.c:323-367 unionread`, `:368-380
//!     unionrewind`). One cursor per open directory: member index plus an open
//!     clone of that member. The members' directory streams are CONCATENATED in
//!     bind order; "Error causes component of union to be skipped"; there is no
//!     de-duplication of names anywhere (ruling R-P12d-2). Offset 0 rewinds
//!     (`sysfile.c:660-666`), any other offset must equal the bytes already
//!     returned (`Edirseek`, `sysfile.c:676`; read(5) "seeking other than to
//!     the beginning is illegal in a directory").
//!  3. **The root device** (`9/port/devroot.c`). Plan 9's `#/` synthesizes the
//!     top-level directories that mounts hang from — `rootreset` (devroot.c:96-107)
//!     statically adds `bin dev env fd mnt net net.alt proc root srv`, each
//!     `DMDIR|0555`, and `bind(2)` then requires the mount point to EXIST.
//!     VERIFIED while porting: `/n` is NOT in that list — on a real Plan 9 it
//!     comes from the root file server's own tree, not from devroot. Snarf has
//!     no root filesystem at all, so instead of a static table we synthesize
//!     every directory that exists only as a PREFIX of a mounted entry: `/`,
//!     `/n` (because `/n/origin` is mounted), `/mnt`, and so on. That is
//!     R-9P-16, and it is why `mount.zig` does not require a mount point to
//!     pre-exist.
//!
//! Imports: std + sibling ninep files (S-07 §6). Nothing here touches `core`,
//! `dev` or `shim`.
//!
//! Size note (S-07's ~400-line soft cap): 281 lines of actual code before the
//! test banner; the rest is the cited kernel rationale above and per-function.
//! Walk, the union read and the synthetic directories share `splitComponents`
//! and `syntheticStat` and are one algorithm — splitting them would cut a seam
//! mid-stream.
const std = @import("std");
const Client = @import("client.zig").Client;
const mount = @import("mount.zig");
const msg = @import("msg.zig");
const nspath = @import("nspath.zig");
const Qid = @import("qid.zig");
const Stat = @import("stat.zig");

const Namespace = mount.Namespace;

/// Errors of a namespace walk/read: the client's own set (transport + 9P op
/// errors) plus the namespace-level outcomes.
pub const Error = Client.Error || error{
    /// Nothing in the table is an ancestor of the path, and it is not a
    /// prefix of any mount either.
    NotMounted,
    /// The path is under a mount point, but no union member has it
    /// (chan.c:1044-1050, `Edoesnotexist`).
    NotFound,
    /// Not absolute, or deeper than `max_components`.
    BadPath,
    /// A directory read at an offset that is neither 0 nor "what I have
    /// already returned" (read(5), `Edirseek`).
    BadOffset,
    /// The caller's buffer cannot hold even the next whole stat record.
    ShortBuffer,
};

/// Deepest path `walk` will take, in components. 9P itself chunks a walk at
/// MAXWELEM=16 per Twalk (`Client.walk` does the chunking); this is only the
/// size of our on-stack name array.
pub const max_components: usize = 32;

/// Bytes a `DirReader` buffers from one member read. A stat record can be up
/// to 64 KiB on the wire, but every record Snarf produces or consumes is
/// small; 8 KiB matches the default msize and keeps a reader cheap enough for
/// wasm. A record larger than this is `error.MessageTooBig`.
pub const chunk_size: usize = 8192;

/// A directory that exists only because mounts hang from it (devroot.c's role).
/// Read-only, synthesized on the fly; `path` borrows the caller's path string.
pub const SyntheticDir = struct {
    path: []const u8,
    qid: Qid,
};

/// What `walk` found: either a real fid on some server, or a synthetic
/// mount-point directory that no server knows about.
pub const Handle = union(enum) {
    fid: struct { client: *Client, fid: u32 },
    dir: SyntheticDir,
};

/// Qid path of a synthetic directory (R-P12d-3): FNV-1a 64 of the canonical
/// path with the high bit set, so repeated listings of the same synthetic
/// directory are stable and cannot collide with a server's own qids in the
/// UI's eyes (no server in this project mints paths ≥ 2^63). Deterministic and
/// stateless — nothing has to remember which synthetic directories exist.
pub fn syntheticQidPath(path: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (path) |b| {
        h ^= b;
        h *%= 0x0000_0100_0000_01b3;
    }
    return h | (@as(u64, 1) << 63);
}

/// The stat(5) record a synthetic directory presents: `DMDIR|0555` like
/// devroot's entries (devroot.c:91 `addlist(..., DMDIR|0555)`), length 0,
/// mtime 0. Owner strings are EMPTY: devroot's entries are owned by `eve`, the
/// host's boot user, and the namespace layer has no user model of its own —
/// empty strings are legal 9P and keep a synthesized record small.
pub fn syntheticStat(name: []const u8, full_path: []const u8) Stat {
    return .{
        .qid = .{ .path = syntheticQidPath(full_path), .qtype = .{ .dir = true } },
        .mode = Stat.DMDIR | 0o555,
        .length = 0,
        .name = name,
        .uid = "",
        .gid = "",
        .muid = "",
    };
}

/// Walk `path` through the namespace (chan.c:965-1050).
///
/// The path is resolved to a mount point, then each union member is tried in
/// bind order with `Client.walk` and the FIRST success wins (chan.c:1030-1037,
/// R-P12d-2); the returned fid belongs to that member's client and the caller
/// must `close` it. A path that is only a PREFIX of mounted entries is a
/// synthetic root-device directory and yields `.dir`. All members fail ⇒
/// `error.NotFound`; nothing matches at all ⇒ `error.NotMounted`.
///
/// The synthetic check also runs when every member walk failed: a mount point
/// can be a directory that no server has (`/n` when `/` is served by something
/// that never heard of it), exactly as devroot supplies `/mnt` for the kernel.
pub fn walk(ns: *const Namespace, path_in: []const u8) Error!Handle {
    if (path_in.len == 0 or path_in[0] != '/') return error.BadPath;
    // One trailing '/' is tolerated ("/n/" == "/n"), matching `DirReader.open`'s
    // canonicalization so the two entry points agree on synthetic directories.
    const path = if (path_in.len > 1 and path_in[path_in.len - 1] == '/') path_in[0 .. path_in.len - 1] else path_in;
    const res = ns.resolve(path) catch |e| switch (e) {
        error.BadPath => return error.BadPath,
        error.NotMounted => return syntheticHandle(ns, path) orelse error.NotMounted,
    };

    var names: [max_components][]const u8 = undefined;
    const n = splitComponents(res.remainder, &names) orelse return error.BadPath;

    for (res.entry.targets.items) |t| {
        const info = t.client.walk(t.root_fid, names[0..n]) catch continue;
        return .{ .fid = .{ .client = t.client, .fid = info.fid } };
    }
    return syntheticHandle(ns, path) orelse error.NotFound;
}

/// Release a handle: clunk the fid, nothing to do for a synthetic directory.
/// `ns` is unused today — it is in the signature because a future cached
/// synthetic directory would have to be released back to the table.
pub fn close(ns: *const Namespace, h: Handle) void {
    _ = ns;
    switch (h) {
        .fid => |f| f.client.clunk(f.fid) catch {},
        .dir => {},
    }
}

/// `.dir` if `path` is a strict component-wise ancestor of some mounted
/// prefix, else null.
fn syntheticHandle(ns: *const Namespace, path: []const u8) ?Handle {
    if (!hasChildPrefix(ns, path)) return null;
    return .{ .dir = .{
        .path = path,
        .qid = .{ .path = syntheticQidPath(path), .qtype = .{ .dir = true } },
    } };
}

fn hasChildPrefix(ns: *const Namespace, path: []const u8) bool {
    for (ns.entries.items) |*e| {
        if (e.prefix.len <= path.len) continue;
        const rest = nspath.matchPrefix(path, e.prefix) orelse continue;
        if (rest.len != 0) return true;
    }
    return false;
}

/// Split a resolve remainder into walk components. "" ⇒ 0 components (a pure
/// clone of the mount point's root fid). Null if it is deeper than
/// `max_components`.
fn splitComponents(remainder: []const u8, out: *[max_components][]const u8) ?usize {
    if (remainder.len == 0) return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, remainder, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) continue; // tolerate "//" inside a walked path
        if (n == max_components) return null;
        out[n] = comp;
        n += 1;
    }
    return n;
}

/// One open directory, reading the union at a path as a single stat(5) stream
/// (`unionread`, sysfile.c:323-367).
///
/// The stream is, in order:
///   1. the SYNTHETIC entries — one `DMDIR` record per child prefix of this
///      path in the mount table (`/n/origin` shows up as `origin` when `/n` is
///      listed), deduplicated by name and in table order;
///   2. then each union member's own directory stream, in bind order, each
///      opened `OREAD` lazily and read to EOF before the next one starts. A
///      member that fails to walk, open or read is SKIPPED (sysfile.c:340
///      "Error causes component of union to be skipped").
/// There is no de-duplication between members (R-P12d-2): Plan 9 does none, so
/// a name present in two members appears twice.
///
/// The union is SNAPSHOT at `open`, like the kernel's refcounted `c->umh`: a
/// later `bind` or `unmount` does not disturb a reader that is already open.
pub const DirReader = struct {
    /// One member of the union, not yet opened.
    const Member = struct {
        client: *Client,
        /// Fid to walk `rem` from (the member's root fid).
        base_fid: u32,
        /// Path remainder from the member's root, "" at an exact mount point.
        rem: []const u8,
    };

    allocator: std.mem.Allocator,
    /// Owned canonical copy of the path; `Member.rem` and `synth` names point
    /// into it or into `synth_buf`.
    path: []u8,
    /// Owned names of the synthetic children, in order.
    synth: std.ArrayList([]u8) = .empty,
    members: std.ArrayList(Member) = .empty,
    /// True when the members came from an entry mounted EXACTLY at this path,
    /// i.e. a real union. False when they were reached by walking through an
    /// ancestor mount, where chan.c's walk takes the first success only.
    union_at_mount: bool,
    /// Bytes handed out so far — the only legal non-zero read offset (read(5)).
    pos: u64 = 0,
    /// Cursor: next synthetic child, then `unionread`'s `uri`/`umc` pair.
    synth_i: usize = 0,
    uri: usize = 0,
    umc: ?u32 = null,
    umc_client: ?*Client = null,
    umc_off: u64 = 0,
    /// Buffered bytes from the current member (or one encoded synthetic stat),
    /// not yet handed to a caller.
    pend: []u8,
    pend_start: usize = 0,
    pend_len: usize = 0,

    /// Open `path` as a directory. Fails the way `walk` does when the path
    /// names nothing; succeeds with zero members for a purely synthetic
    /// directory.
    pub fn open(allocator: std.mem.Allocator, ns: *const Namespace, path: []const u8) Error!DirReader {
        if (path.len == 0 or path[0] != '/') return error.BadPath;
        const owned = try nspath.canonicalize(allocator, path);
        const pend = allocator.alloc(u8, chunk_size) catch |e| {
            allocator.free(owned);
            return e;
        };

        var self = DirReader{
            .allocator = allocator,
            .path = owned,
            .pend = pend,
            .union_at_mount = false,
        };
        errdefer self.close();

        try self.collectSynthetic(ns);
        try self.collectMembers(ns);
        // Neither a mount point nor a prefix of one — the same verdict `walk`
        // reaches for such a path.
        if (self.members.items.len == 0 and self.synth.items.len == 0) return error.NotMounted;
        return self;
    }

    pub fn close(self: *DirReader) void {
        self.closeMember();
        for (self.synth.items) |n| self.allocator.free(n);
        self.synth.deinit(self.allocator);
        self.members.deinit(self.allocator);
        self.allocator.free(self.pend);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Read whole stat records into `buf` (never a partial record).
    ///
    /// `offset` must be 0 — which REWINDS the stream (`unionrewind`,
    /// sysfile.c:368-380) — or exactly the number of bytes returned so far,
    /// else `error.BadOffset` (read(5)). Returns 0 at end of directory.
    /// `error.ShortBuffer` if `buf` is too small for the next record, rather
    /// than a 0 that would masquerade as EOF.
    pub fn read(self: *DirReader, offset: u64, buf: []u8) Error!usize {
        if (offset == 0) {
            self.rewind();
        } else if (offset != self.pos) {
            return error.BadOffset;
        }

        var n: usize = 0;
        while (true) {
            n += self.drain(buf[n..]);
            if (self.pend_len > 0) break; // buf is full of what fits
            if (!try self.produce()) break; // end of the whole union
        }
        if (n == 0 and self.pend_len > 0) {
            // Nothing fit. Tell the caller WHY rather than looking like EOF.
            if (self.pend_len < 2) return error.ProtocolError;
            const rec = 2 + @as(usize, std.mem.readInt(u16, self.pend[self.pend_start..][0..2], .little));
            if (rec > self.pend.len) return error.MessageTooBig; // record > chunk_size
            if (rec > self.pend_len) return error.ProtocolError; // server split a record
            return error.ShortBuffer; // `buf` is smaller than the next record
        }
        self.pos += n;
        return n;
    }

    /// Copy as many WHOLE buffered stat records into `out` as fit.
    fn drain(self: *DirReader, out: []u8) usize {
        var n: usize = 0;
        while (self.pend_len >= 2) {
            const rec = 2 + @as(usize, std.mem.readInt(u16, self.pend[self.pend_start..][0..2], .little));
            if (rec > self.pend_len) break; // truncated tail; produce() refills
            if (rec > out.len - n) break;
            @memcpy(out[n..][0..rec], self.pend[self.pend_start..][0..rec]);
            n += rec;
            self.pend_start += rec;
            self.pend_len -= rec;
        }
        if (self.pend_len == 0) self.pend_start = 0;
        return n;
    }

    /// Refill `pend`. Returns false at the end of the stream.
    fn produce(self: *DirReader) Error!bool {
        std.debug.assert(self.pend_len == 0);
        self.pend_start = 0;

        if (self.synth_i < self.synth.items.len) {
            const name = self.synth.items[self.synth_i];
            self.synth_i += 1;
            var full: [512]u8 = undefined;
            const fp = self.childPath(&full, name) orelse return error.MessageTooBig;
            const st = syntheticStat(name, fp);
            self.pend_len = st.encode(self.pend) catch return error.MessageTooBig;
            return true;
        }

        while (self.uri < self.members.items.len) {
            if (self.umc == null and !self.openMember(self.uri)) {
                // Error causes component of union to be skipped (sysfile.c:340).
                self.uri += 1;
                continue;
            }
            const c = self.umc_client.?;
            const got = c.read(self.umc.?, self.umc_off, self.pend) catch 0;
            if (got == 0) {
                self.closeMember();
                self.uri += 1;
                if (!self.union_at_mount) break; // first success only (chan.c walk)
                continue;
            }
            self.umc_off += got;
            self.pend_len = got;
            return true;
        }
        return false;
    }

    /// Walk+open union member `i`, `OREAD`. False if any step fails — which
    /// includes the member turning out not to be a directory (the kernel would
    /// have refused the open; a union read simply skips that component).
    fn openMember(self: *DirReader, i: usize) bool {
        const m = self.members.items[i];
        var names: [max_components][]const u8 = undefined;
        const n = splitComponents(m.rem, &names) orelse return false;
        const info = m.client.walk(m.base_fid, names[0..n]) catch return false;
        // Only an Rwalk qid is authoritative: a pure clone (`rem` empty)
        // reports the client's cached guess, which a hand-driven attach may
        // never have filled in.
        if (n > 0 and !info.qid.qtype.dir) {
            m.client.clunk(info.fid) catch {};
            return false;
        }
        _ = m.client.open(info.fid, msg.OREAD) catch {
            m.client.clunk(info.fid) catch {};
            return false;
        };
        self.umc = info.fid;
        self.umc_client = m.client;
        self.umc_off = 0;
        return true;
    }

    fn closeMember(self: *DirReader) void {
        if (self.umc) |fid| {
            if (self.umc_client) |c| c.clunk(fid) catch {};
        }
        self.umc = null;
        self.umc_client = null;
        self.umc_off = 0;
    }

    /// `unionrewind` (sysfile.c:368-380) plus our synthetic cursor.
    fn rewind(self: *DirReader) void {
        self.closeMember();
        self.uri = 0;
        self.synth_i = 0;
        self.pend_start = 0;
        self.pend_len = 0;
        self.pos = 0;
    }

    /// `<path>/<name>`, for a synthetic child's qid. Null if it does not fit.
    fn childPath(self: *const DirReader, buf: []u8, name: []const u8) ?[]const u8 {
        const sep: usize = if (self.path.len == 1) 0 else 1; // no "//" under root
        const total = self.path.len + sep + name.len;
        if (total > buf.len) return null;
        @memcpy(buf[0..self.path.len], self.path);
        if (sep == 1) buf[self.path.len] = '/';
        @memcpy(buf[self.path.len + sep ..][0..name.len], name);
        return buf[0..total];
    }

    /// The synthesized children of this path: the next component of every
    /// mounted prefix strictly below it, in table order, each name once.
    /// (devroot.c keeps ONE `Dirlist` per directory, so a name cannot repeat
    /// there either; R-P12d-2's "no de-duplication" is about union MEMBERS.)
    fn collectSynthetic(self: *DirReader, ns: *const Namespace) Error!void {
        for (ns.entries.items) |*e| {
            if (e.prefix.len <= self.path.len) continue;
            const rest = nspath.matchPrefix(self.path, e.prefix) orelse continue;
            const name = nspath.firstComponent(rest);
            if (name.len == 0) continue;
            var seen = false;
            for (self.synth.items) |s| {
                if (std.mem.eql(u8, s, name)) seen = true;
            }
            if (seen) continue;
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try self.synth.append(self.allocator, owned);
        }
    }

    /// The union members to concatenate after the synthetic entries.
    fn collectMembers(self: *DirReader, ns: *const Namespace) Error!void {
        const res = ns.resolve(self.path) catch |e| switch (e) {
            error.BadPath => return error.BadPath,
            error.NotMounted => return, // purely synthetic directory
        };
        self.union_at_mount = res.remainder.len == 0;
        // The remainder aliases `self.path`, which we own, so members can hold
        // it without a copy.
        for (res.entry.targets.items) |t| {
            try self.members.append(self.allocator, .{
                .client = t.client,
                .base_fid = t.root_fid,
                .rem = res.remainder,
            });
        }
    }
};

// ==========================================================================
// Test fixture + smoke tests.
//
// `FakeTree` is the two-fake-servers-on-in-memory-pipes recipe the union
// tests are built from: a read-only 9P tree whose root holds one directory
// per name, each containing a file `ctl` that reports which tree it came
// from. Two of them mounted at one prefix make a union.
// ==========================================================================
const testing = std.testing;
const chan = @import("chan.zig");
const server = @import("server.zig");
const errors = @import("errors.zig");

/// A tiny read-only tree: root (qid 1) ── <names[i]>/ (qid 2+2i) ── ctl (3+2i).
/// `tag` is what every `ctl` file contains, so a union read can be attributed.
pub const FakeTree = struct {
    names: []const []const u8,
    tag: []const u8,

    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 or path % 2 == 0 } };
    }

    fn attach(_: *anyopaque, _: *server.Server, _: *server.Fid, _: []const u8) errors.OpError!Qid {
        return qidOf(1);
    }

    fn walk1(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, name: []const u8) errors.OpError!Qid {
        const self: *FakeTree = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "..")) return qidOf(1);
        if (fid.qid.path == 1) {
            for (self.names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return qidOf(2 + 2 * @as(u64, i));
            }
            return error.FileDoesNotExist;
        }
        if (fid.qid.path % 2 == 0 and std.mem.eql(u8, name, "ctl")) return qidOf(fid.qid.path + 1);
        return error.FileDoesNotExist;
    }

    fn open(_: *anyopaque, _: *server.Server, fid: *server.Fid, mode: u8) errors.OpError!Qid {
        if ((mode & 3) != msg.OREAD) return error.PermissionDenied;
        return fid.qid;
    }

    fn read(ctx: *anyopaque, _: *server.Server, fid: *server.Fid, offset: u64, buf: []u8) server.ReadError!usize {
        const self: *FakeTree = @ptrCast(@alignCast(ctx));
        if (!fid.qid.qtype.dir) {
            if (offset >= self.tag.len) return 0;
            const n = @min(buf.len, self.tag.len - offset);
            @memcpy(buf[0..n], self.tag[@intCast(offset)..][0..n]);
            return n;
        }
        var pos: u64 = 0;
        var n: usize = 0;
        const count: usize = if (fid.qid.path == 1) self.names.len else 1;
        for (0..count) |i| {
            const st: Stat = if (fid.qid.path == 1)
                .{ .qid = qidOf(2 + 2 * @as(u64, i)), .mode = Stat.DMDIR | 0o555, .length = 0, .name = self.names[i], .uid = "", .gid = "", .muid = "" }
            else
                .{ .qid = qidOf(fid.qid.path + 1), .mode = 0o444, .length = self.tag.len, .name = "ctl", .uid = "", .gid = "", .muid = "" };
            var tmp: [256]u8 = undefined;
            const m = st.encode(&tmp) catch return error.IoError;
            if (pos >= offset) {
                if (n + m > buf.len) break;
                @memcpy(buf[n..][0..m], tmp[0..m]);
                n += m;
            }
            pos += m;
        }
        return n;
    }

    fn write(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u64, _: []const u8) errors.OpError!usize {
        return error.PermissionDenied;
    }

    fn statOp(ctx: *anyopaque, _: *server.Server, fid: *server.Fid) errors.OpError!Stat {
        const self: *FakeTree = @ptrCast(@alignCast(ctx));
        return .{
            .qid = fid.qid,
            .mode = if (fid.qid.qtype.dir) Stat.DMDIR | 0o555 else 0o444,
            .length = if (fid.qid.qtype.dir) 0 else self.tag.len,
            .name = if (fid.qid.path == 1) "/" else "x",
        };
    }

    pub const ops = server.Ops{
        .attach = attach,
        .walk1 = walk1,
        .open = open,
        .read = read,
        .write = write,
        .stat = statOp,
    };
};

/// One `FakeTree` behind a `chan.Pipe`, versioned and attached, ready to mount.
/// Keep it alive (and `deinit` it) for as long as the namespace names it.
pub const FakeServer = struct {
    pipe: *chan.Pipe,
    srv: *server.Server,
    client: *Client,
    root_fid: u32,
    allocator: std.mem.Allocator,

    fn pump(ctx: *anyopaque) anyerror!void {
        const s: *server.Server = @ptrCast(@alignCast(ctx));
        _ = try s.poll();
    }

    pub fn init(allocator: std.mem.Allocator, tree: *FakeTree) !FakeServer {
        const pipe = try chan.Pipe.init(allocator, 16384);
        const srv = try allocator.create(server.Server);
        srv.* = try server.Server.init(allocator, pipe.serverEnd(), &FakeTree.ops, tree, 8192);
        const cl = try allocator.create(Client);
        cl.* = try Client.init(allocator, pipe.clientEnd(), 8192);
        cl.pump = .{ .ctx = srv, .run = pump };
        _ = try cl.version(8192);
        const root = try cl.attach("larry", "");
        return .{ .pipe = pipe, .srv = srv, .client = cl, .root_fid = root.fid, .allocator = allocator };
    }

    pub fn deinit(self: *FakeServer) void {
        self.client.deinit();
        self.allocator.destroy(self.client);
        self.srv.deinit();
        self.allocator.destroy(self.srv);
        self.pipe.deinit();
    }
};

/// A tree that mounts fine (root walk/clone succeeds) but whose directory can
/// never be OPENED — T11 needs a union member that fails partway through
/// `unionread`'s per-member open, not one that is missing outright (sysfile.c:
/// 340 "Error causes component of union to be skipped").
pub const FailOpenTree = struct {
    fn attach(_: *anyopaque, _: *server.Server, _: *server.Fid, _: []const u8) errors.OpError!Qid {
        return .{ .path = 1, .qtype = .{ .dir = true } };
    }
    fn walk1(_: *anyopaque, _: *server.Server, _: *server.Fid, _: []const u8) errors.OpError!Qid {
        return error.FileDoesNotExist;
    }
    fn open(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u8) errors.OpError!Qid {
        return error.PermissionDenied;
    }
    fn read(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u64, _: []u8) server.ReadError!usize {
        return error.IoError;
    }
    fn write(_: *anyopaque, _: *server.Server, _: *server.Fid, _: u64, _: []const u8) errors.OpError!usize {
        return error.PermissionDenied;
    }
    fn statOp(_: *anyopaque, _: *server.Server, fid: *server.Fid) errors.OpError!Stat {
        return .{ .qid = fid.qid, .mode = Stat.DMDIR | 0o555, .length = 0, .name = "/", .uid = "", .gid = "", .muid = "" };
    }
    pub const ops = server.Ops{
        .attach = attach,
        .walk1 = walk1,
        .open = open,
        .read = read,
        .write = write,
        .stat = statOp,
    };
};

/// One `FailOpenTree` behind a `chan.Pipe`, ready to mount (T11).
pub const FailServer = struct {
    pipe: *chan.Pipe,
    srv: *server.Server,
    client: *Client,
    root_fid: u32,
    dummy: *u8,
    allocator: std.mem.Allocator,

    fn pump(ctx: *anyopaque) anyerror!void {
        const s: *server.Server = @ptrCast(@alignCast(ctx));
        _ = try s.poll();
    }

    pub fn init(allocator: std.mem.Allocator) !FailServer {
        const pipe = try chan.Pipe.init(allocator, 16384);
        const dummy = try allocator.create(u8);
        dummy.* = 0;
        const srv = try allocator.create(server.Server);
        srv.* = try server.Server.init(allocator, pipe.serverEnd(), &FailOpenTree.ops, dummy, 8192);
        const cl = try allocator.create(Client);
        cl.* = try Client.init(allocator, pipe.clientEnd(), 8192);
        cl.pump = .{ .ctx = srv, .run = pump };
        _ = try cl.version(8192);
        const root = try cl.attach("larry", "");
        return .{ .pipe = pipe, .srv = srv, .client = cl, .root_fid = root.fid, .dummy = dummy, .allocator = allocator };
    }

    pub fn deinit(self: *FailServer) void {
        self.client.deinit();
        self.allocator.destroy(self.client);
        self.srv.deinit();
        self.allocator.destroy(self.srv);
        self.pipe.deinit();
        self.allocator.destroy(self.dummy);
    }
};

test "nsdir: union walk takes the first member that has the name (T6, T7, T8)" {
    const a = testing.allocator;
    var t1 = FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var t2 = FakeTree{ .names = &.{ "rc", "date" }, .tag = "two\n" };
    var s1 = try FakeServer.init(a, &t1);
    defer s1.deinit();
    var s2 = try FakeServer.init(a, &t2);
    defer s2.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.bind("/bin", s1.client, s1.root_fid, .after);
    try ns.bind("/bin", s2.client, s2.root_fid, .after);

    // Only the second member has `date` (chan.c:1030-1037).
    const h = try walk(&ns, "/bin/date/ctl");
    try testing.expectEqual(s2.client, h.fid.client);
    defer close(&ns, h);

    // Both have `rc`: the first wins.
    const h2 = try walk(&ns, "/bin/rc");
    defer close(&ns, h2);
    try testing.expectEqual(s1.client, h2.fid.client);

    try testing.expectError(error.NotFound, walk(&ns, "/bin/nope"));
    try testing.expectError(error.NotMounted, walk(&ns, "/dev/mouse"));
}

test "nsdir: synthetic mount-point directories and union reads" {
    const a = testing.allocator;
    var t1 = FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var t2 = FakeTree{ .names = &.{"date"}, .tag = "two\n" };
    var s1 = try FakeServer.init(a, &t1);
    defer s1.deinit();
    var s2 = try FakeServer.init(a, &t2);
    defer s2.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/n/origin", s1.client, s1.root_fid);
    try ns.bind("/bin", s1.client, s1.root_fid, .after);
    try ns.bind("/bin", s2.client, s2.root_fid, .after);

    // `/n` is nobody's mount point; it exists because `/n/origin` does
    // (devroot.c's role, R-9P-16).
    const h = try walk(&ns, "/n");
    try testing.expect(h == .dir);
    try testing.expect(h.dir.qid.qtype.dir);
    close(&ns, h);

    var names = std.ArrayList([]const u8).empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var dr = try DirReader.open(a, &ns, "/n");
    defer dr.close();
    var buf: [512]u8 = undefined;
    const n = try dr.read(0, &buf);
    const st = try Stat.decode(buf[0..n]);
    try testing.expectEqualStrings("origin", st.name);
    try testing.expect(st.mode & Stat.DMDIR != 0);
    try testing.expectEqual(@as(usize, st.encodedSize()), n);
    try testing.expectEqual(@as(usize, 0), try dr.read(n, &buf));

    // The union at `/bin` concatenates both members, in bind order.
    var db = try DirReader.open(a, &ns, "/bin");
    defer db.close();
    const bn = try db.read(0, &buf);
    const first = try Stat.decode(buf[0..bn]);
    try testing.expectEqualStrings("rc", first.name);
    const second = try Stat.decode(buf[first.encodedSize()..bn]);
    try testing.expectEqualStrings("date", second.name);
    try testing.expectEqual(first.encodedSize() + second.encodedSize(), bn);
    try testing.expectError(error.BadOffset, db.read(bn + 1, &buf));
}

test "nsdir: the synthetic root lists exactly its mounted children (T9)" {
    const a = testing.allocator;
    var t1 = FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var s1 = try FakeServer.init(a, &t1);
    defer s1.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/dev", s1.client, s1.root_fid);
    try ns.mount("/n/origin", s1.client, s1.root_fid);
    try ns.mount("/mnt/snarf-self", s1.client, s1.root_fid);

    // "/" is nobody's mount point; it exists only because things mount below
    // it (devroot.c's role, R-9P-16).
    const h = try walk(&ns, "/");
    try testing.expect(h == .dir);
    close(&ns, h);

    var buf: [512]u8 = undefined;
    var dr = try DirReader.open(a, &ns, "/");
    defer dr.close();
    const n = try dr.read(0, &buf);
    const dev = try Stat.decode(buf[0..n]);
    try testing.expectEqualStrings("dev", dev.name);
    const nn = try Stat.decode(buf[dev.encodedSize()..n]);
    try testing.expectEqualStrings("n", nn.name);
    const mnt = try Stat.decode(buf[dev.encodedSize() + nn.encodedSize() .. n]);
    try testing.expectEqualStrings("mnt", mnt.name);
    try testing.expectEqual(dev.encodedSize() + nn.encodedSize() + mnt.encodedSize(), n);
    try testing.expectEqual(@as(usize, 0), try dr.read(n, &buf));

    // "/n" itself lists exactly its one child, "origin".
    const hn = try walk(&ns, "/n");
    try testing.expect(hn == .dir);
    close(&ns, hn);
    var drn = try DirReader.open(a, &ns, "/n");
    defer drn.close();
    const nn2 = try drn.read(0, &buf);
    const origin = try Stat.decode(buf[0..nn2]);
    try testing.expectEqualStrings("origin", origin.name);
    try testing.expectEqual(origin.encodedSize(), nn2);
    try testing.expectEqual(@as(usize, 0), try drn.read(nn2, &buf));
}

test "nsdir: union directory reads never de-duplicate across members (T10)" {
    const a = testing.allocator;
    var t1 = FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var t2 = FakeTree{ .names = &.{"rc"}, .tag = "two\n" }; // same name, other tree
    var s1 = try FakeServer.init(a, &t1);
    defer s1.deinit();
    var s2 = try FakeServer.init(a, &t2);
    defer s2.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.bind("/bin", s1.client, s1.root_fid, .after);
    try ns.bind("/bin", s2.client, s2.root_fid, .after);

    var dr = try DirReader.open(a, &ns, "/bin");
    defer dr.close();
    var buf: [512]u8 = undefined;
    const n = try dr.read(0, &buf);
    const first = try Stat.decode(buf[0..n]);
    try testing.expectEqualStrings("rc", first.name);
    const second = try Stat.decode(buf[first.encodedSize()..n]);
    try testing.expectEqualStrings("rc", second.name); // R-P12d-2: no dedup
    try testing.expectEqual(first.encodedSize() + second.encodedSize(), n);
    try testing.expectEqual(@as(usize, 0), try dr.read(n, &buf));
}

test "nsdir: a union member that fails to open is skipped (T11)" {
    const a = testing.allocator;
    var t = FakeTree{ .names = &.{"rc"}, .tag = "ok\n" };
    var good = try FakeServer.init(a, &t);
    defer good.deinit();
    var bad = try FailServer.init(a);
    defer bad.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    // The failing member goes FIRST: if it were not skipped, its error would
    // surface instead of the good member's entry (sysfile.c:340).
    try ns.bind("/bin", bad.client, bad.root_fid, .after);
    try ns.bind("/bin", good.client, good.root_fid, .after);

    var dr = try DirReader.open(a, &ns, "/bin");
    defer dr.close();
    var buf: [512]u8 = undefined;
    const n = try dr.read(0, &buf);
    const st = try Stat.decode(buf[0..n]);
    try testing.expectEqualStrings("rc", st.name);
    try testing.expectEqual(st.encodedSize(), n);
    try testing.expectEqual(@as(usize, 0), try dr.read(n, &buf));

    // Walking through the failing member is skipped too: the good member's
    // file is still reachable (chan.c:1030-1037 tries the union in order).
    const h = try walk(&ns, "/bin/rc");
    defer close(&ns, h);
    try testing.expectEqual(good.client, h.fid.client);
}

test "nsdir: offset continuation matches a byte-identical single read (T12)" {
    const a = testing.allocator;
    var t1 = FakeTree{ .names = &.{ "aa", "bb", "cc", "dd" }, .tag = "x\n" };
    var s1 = try FakeServer.init(a, &t1);
    defer s1.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/bin", s1.client, s1.root_fid);

    // One big read of the whole stream.
    var big = try DirReader.open(a, &ns, "/bin");
    defer big.close();
    var big_buf: [4096]u8 = undefined;
    const big_n = try big.read(0, &big_buf);

    // The same stream, read piecemeal through a buffer that holds only one
    // record at a time (each record here is 49 + 2-byte name = 51 bytes).
    var small = try DirReader.open(a, &ns, "/bin");
    defer small.close();
    var acc = std.ArrayList(u8).empty;
    defer acc.deinit(a);
    var small_buf: [60]u8 = undefined;
    var off: u64 = 0;
    var first_len: usize = 0;
    while (true) {
        const n = try small.read(off, &small_buf);
        if (n == 0) break;
        if (off == 0) first_len = n;
        try acc.appendSlice(a, small_buf[0..n]);
        off += n;
    }
    try testing.expectEqualSlices(u8, big_buf[0..big_n], acc.items);

    // Offset 0 rewinds the stream (unionrewind, sysfile.c:368-380)...
    const rn = try small.read(0, &small_buf);
    try testing.expectEqual(first_len, rn);

    // ...and any other offset must equal what has been returned so far.
    try testing.expectError(error.BadOffset, small.read(rn + 999, &small_buf));
}

test "nsdir: an exact mount point also lists deeper synthetic children (T13)" {
    const a = testing.allocator;
    var t1 = FakeTree{ .names = &.{"mouse"}, .tag = "m\n" };
    var s1 = try FakeServer.init(a, &t1);
    defer s1.deinit();
    var t2 = FakeTree{ .names = &.{"new"}, .tag = "d\n" };
    var s2 = try FakeServer.init(a, &t2);
    defer s2.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/dev", s1.client, s1.root_fid);
    try ns.mount("/dev/draw", s2.client, s2.root_fid);

    var dr = try DirReader.open(a, &ns, "/dev");
    defer dr.close();
    var buf: [512]u8 = undefined;
    const n = try dr.read(0, &buf);
    // Synthetic children come first, then the device's own listing.
    const first = try Stat.decode(buf[0..n]);
    try testing.expectEqualStrings("draw", first.name);
    try testing.expect(first.mode & Stat.DMDIR != 0);
    const second = try Stat.decode(buf[first.encodedSize()..n]);
    try testing.expectEqualStrings("mouse", second.name);
    try testing.expectEqual(first.encodedSize() + second.encodedSize(), n);

    // `/dev` itself resolves to the device's own root, not a synthetic dir.
    const h = try walk(&ns, "/dev");
    try testing.expect(h == .fid);
    try testing.expectEqual(s1.client, h.fid.client);
    close(&ns, h);
}
