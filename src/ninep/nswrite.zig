//! nswrite.zig — WRITING through the namespace asynchronously: `WriteFileJob`,
//! the third leg of `nsjob.zig` (walk) / `nsio.zig` (read). Re-exported from
//! `nsjob.zig`, which is the name the rest of the tree uses.
//!
//! What it is: Plan 9's `create(name, OWRITE, 0666)` + `write` loop + `close`
//! (acme `putfile`, exec.c:727-773 at `larryr/plan9port@337c6ac`) turned inside
//! out, one 9P message in flight per `step()` on `tickets.begin/check` exactly
//! like `nsio.Drain` (R-9P-13, R-P13a-3: `check` never pumps, never blocks).
//!
//!     walking ──ok──> opening (Topen OWRITE|OTRUNC) ──> writing (Twrite*) ──> clunking ──> done
//!        └─NotFound && create && !must_exist──> parent_walking ──> creating (Tcreate) ──> writing …
//!
//! Plan 9's `create` on an EXISTING file truncates it (`5/open`); 9P's Tcreate
//! on an existing name fails instead, which is why the existing-file arm is a
//! Topen(OTRUNC) and only a NotFound walk falls through to Tcreate. The kernel
//! picks the union member carrying MCREATE for a create (`9/port/chan.c` namec
//! `Acreate`); Snarf's mount table has no MCREATE flag, so the parent walk's
//! own first-success union rule decides — bind order (only `/bin` is a union).
//!
//! DROPPED: the partial-range arm of `putfile` (exec.c:775 `q0!=0 ||
//! q1!=f->b.nc`) — Snarf's Put always writes the whole buffer.
//!
//! POINTER STABILITY (nsjob.zig's rule): the job borrows `path` and `data`, and
//! hands its inline reply buffer to a live ticket; it must not move once `step`
//! has run, and `path`/`data` must outlive it.
//!
//! Imports: std + sibling ninep files (S-07 §6). Nothing here touches `core`,
//! `dev` or `shim`.
const std = @import("std");
const Client = @import("client.zig").Client;
const mount = @import("mount.zig");
const msg = @import("msg.zig");
const nsjob = @import("nsjob.zig");
const Qid = @import("qid.zig");
const tickets = @import("tickets.zig");

const Namespace = mount.Namespace;
const Status = nsjob.Status;
const Step = nsjob.Step;
const WalkJob = nsjob.WalkJob;

/// Everything a namespace job can fail with, plus the two write-only verdicts.
pub const Error = nsjob.Error || error{
    /// An `Rwrite.count` short of the chunk sent (`Bwrite(b, s, m) != m`,
    /// exec.c:757).
    ShortWrite,
    /// The opened file carries QTAPPEND and the caller said it already holds
    /// data (exec.c:744-748 `isapp`).
    AppendOnly,
};

/// `WriteFileJob` policy. `refuse_append` is the caller's half of acme's
/// `isapp` test (exec.c:744): the job only sees the Ropen/Rcreate qid, the
/// caller knows the pre-write length, so it says "refuse an append-only file".
pub const Options = struct {
    /// Topen with OTRUNC (Plan 9 `create` semantics on an existing file).
    truncate: bool = true,
    /// A missing file is Tcreate'd in its parent.
    create: bool = true,
    perm: u32 = 0o666,
    /// A missing file is `error.NotFound`, never created (Putall's `access()`
    /// check, R-P17-3).
    must_exist: bool = false,
    /// Fail with `error.AppendOnly` (before any Twrite) if the opened qid has
    /// QTAPPEND.
    refuse_append: bool = false,
};

/// Bytes a Twrite frame costs besides its payload: size[4] type[1] tag[2]
/// fid[4] offset[8] count[4] — the `- msg.header_size - 23` of the contract's
/// chunk formula (the extra margin keeps a chunk well inside msize).
const twrite_overhead: usize = 23;

pub const WriteFileJob = struct {
    ns: *const Namespace,
    /// Borrowed, absolute.
    path: []const u8,
    /// Borrowed; must outlive the job.
    data: []const u8,
    opts: Options,
    walk: WalkJob,
    client: ?*Client = null,
    fid: u32 = 0,
    /// Bytes acknowledged so far (final once `step` reports `done`).
    written: usize = 0,
    /// The chunk in flight.
    chunk: usize = 0,
    /// The qid of the opened (or created) file — carries `qtype.append`.
    qid: Qid = .{ .path = 0 },
    /// True when the file did not exist and was Tcreate'd.
    created: bool = false,
    st: Step = .{},
    buf: [nsjob.small_reply]u8 = undefined,
    phase: Phase = .walking,

    /// `pub` so a caller can tell a failure to OPEN/CREATE (`walking`,
    /// `opening`, `parent_walking`, `creating`) from a failure to WRITE
    /// (`writing`, `clunking`) — acme's two different warnings.
    pub const Phase = enum { walking, opening, parent_walking, creating, writing, clunking, done };

    pub fn init(ns: *const Namespace, path: []const u8, data: []const u8, opts: Options) Error!WriteFileJob {
        return .{ .ns = ns, .path = path, .data = data, .opts = opts, .walk = try WalkJob.init(ns, path) };
    }

    /// True once the job has an open fid and is (or was) pushing bytes — an
    /// error from this point on is "can't write", not "can't create".
    pub fn pastOpen(self: *const WriteFileJob) bool {
        return self.phase == .writing or self.phase == .clunking or self.phase == .done;
    }

    pub fn step(self: *WriteFileJob) Error!Status {
        switch (self.phase) {
            .done => return .done,
            .walking => {
                const st = self.walk.step() catch |e| {
                    if (e != error.NotFound or !self.opts.create or self.opts.must_exist) return e;
                    return self.startParentWalk();
                };
                if (st == .pending) return .pending;
                const f = switch (self.walk.result) {
                    .dir => return error.FileIsDirectory, // a synthetic mount-point directory
                    .fid => |f| f,
                };
                self.client = f.client;
                self.fid = f.fid;
                const mode: u8 = msg.OWRITE | (if (self.opts.truncate) msg.OTRUNC else 0);
                try self.st.send(f.client, .{ .tag = 0, .body = .{
                    .topen = .{ .fid = f.fid, .mode = mode },
                } }, &self.buf);
                self.phase = .opening;
                return .pending;
            },
            .opening => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                const o = switch (m.body) {
                    .ropen => |o| o,
                    else => return error.ProtocolError,
                };
                return self.opened(o.qid);
            },
            .parent_walking => {
                if (try self.walk.step() == .pending) return .pending;
                const f = switch (self.walk.result) {
                    // Nothing can be created in the synthetic root device.
                    .dir => return error.PermissionDenied,
                    .fid => |f| f,
                };
                self.client = f.client;
                self.fid = f.fid;
                // Tcreate: "the fid now IS the new file" (`5/open`).
                try self.st.send(f.client, .{ .tag = 0, .body = .{ .tcreate = .{
                    .fid = f.fid,
                    .name = baseName(self.path),
                    .perm = self.opts.perm,
                    .mode = msg.OWRITE,
                } } }, &self.buf);
                self.phase = .creating;
                return .pending;
            },
            .creating => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                const cr = switch (m.body) {
                    .rcreate => |cr| cr,
                    else => return error.ProtocolError,
                };
                self.client.?.seedQid(self.fid, cr.qid);
                self.created = true;
                return self.opened(cr.qid);
            },
            .writing => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                const count = switch (m.body) {
                    .rwrite => |r| r.count,
                    else => return error.ProtocolError,
                };
                if (count != self.chunk) return error.ShortWrite; // exec.c:757
                self.written += self.chunk;
                return self.sendNext();
            },
            .clunking => {
                const c = self.client.?;
                const finished = if (self.st.poll(c)) |m| m != null else |_| true;
                if (!finished) return .pending;
                c.freeFid(self.fid);
                self.client = null;
                self.phase = .done;
                return .done;
            },
        }
    }

    /// The walk said "no such file": walk to the parent instead, then Tcreate.
    fn startParentWalk(self: *WriteFileJob) Error!Status {
        self.walk.deinit();
        self.walk = try WalkJob.init(self.ns, dirName(self.path));
        self.phase = .parent_walking;
        return .pending;
    }

    /// Ropen/Rcreate landed: the append-only refusal, then the first Twrite.
    fn opened(self: *WriteFileJob, qid: Qid) Error!Status {
        self.qid = qid;
        self.phase = .writing;
        if (self.opts.refuse_append and qid.qtype.append) return error.AppendOnly; // exec.c:744-748
        return self.sendNext();
    }

    /// The next Twrite, or the Tclunk once every byte is acknowledged. The
    /// writes go back to back on ONE fid with nothing else on the path in
    /// between (R-P17-2: `/mnt/opfs` keeps one writable stream per path).
    fn sendNext(self: *WriteFileJob) Error!Status {
        const c = self.client.?;
        if (self.written >= self.data.len) {
            try self.st.send(c, .{ .tag = 0, .body = .{ .tclunk = .{ .fid = self.fid } } }, &self.buf);
            self.phase = .clunking;
            return .pending;
        }
        const room = c.ioMax() -| (msg.header_size + twrite_overhead);
        self.chunk = @min(self.data.len - self.written, @max(room, 1));
        try self.st.send(c, .{ .tag = 0, .body = .{ .twrite = .{
            .fid = self.fid,
            .offset = self.written,
            .data = self.data[self.written..][0..self.chunk],
        } } }, &self.buf);
        return .pending;
    }

    /// Abandon the job. Fire-and-forget on every path (the `nsio.Drain.deinit`
    /// rule): a job may be torn down on a client with no pump, so it must never
    /// wait for a reply — `tickets.discardClunk` releases the fid on a tombstone.
    pub fn deinit(self: *WriteFileJob) void {
        if (self.client) |c| {
            self.st.abort(c);
            // In `.clunking` the Tclunk is already on the wire.
            if (self.phase == .clunking) c.freeFid(self.fid) else tickets.discardClunk(c, self.fid);
        }
        self.walk.deinit();
        self.* = undefined;
    }
};

/// The parent of an absolute path ("/a/b" ⇒ "/a", "/a" ⇒ "/").
fn dirName(path: []const u8) []const u8 {
    const p = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return "/";
    return if (i == 0) "/" else p[0..i];
}

/// The last component of an absolute path.
fn baseName(path: []const u8) []const u8 {
    const p = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
    return p[i + 1 ..];
}

// ==========================================================================
// Smoke tests. The named battery (T1-T3) is the test writer's; these only pin
// the path helpers and that a missing-file write refuses cleanly under
// `must_exist` over the 12d `nsdir` fixtures.
// ==========================================================================
const testing = std.testing;
const nsdir = @import("nsdir.zig");

test "nswrite: dirName / baseName" {
    try testing.expectEqualStrings("/a", dirName("/a/b"));
    try testing.expectEqualStrings("/", dirName("/a"));
    try testing.expectEqualStrings("b", baseName("/a/b"));
    try testing.expectEqualStrings("a", baseName("/a"));
}

test "nswrite: must_exist turns a missing file into NotFound, no create" {
    const a = testing.allocator;
    var t = nsdir.FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var s = try nsdir.FakeServer.init(a, &t);
    defer s.deinit();
    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/x", s.client, s.root_fid);
    var pumps = nsjob.Pumps{ .srvs = &.{s.srv} };

    var j = try WriteFileJob.init(&ns, "/x/nope", "data", .{ .must_exist = true });
    defer j.deinit();
    try testing.expectError(error.NotFound, nsjob.runSync(&j, pumps.pump()));
    try testing.expect(!j.created);
}
