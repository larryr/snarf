//! nsjob.zig — ASYNCHRONOUS namespace operations: walk, stat, read-a-file and
//! list-a-directory as step-driven state machines over `tickets.zig`
//! (R-9P-13 extended to every 9P operation the editor issues).
//!
//! `nsdir.zig` does the same four things SYNCHRONOUSLY, on top of
//! `Client.walk/open/read/clunk` — correct against a pumped in-process server
//! and unusable against `/n/origin`, whose frames only arrive on a later tick
//! (`wsPush`). Plan 9 never needed this split: `sysfile.c`'s syscalls are
//! synchronous over a kernel that simply blocks the proc, and acme itself blocks
//! in `textload`/`dirread`. The browser main thread cannot block, so the loop is
//! turned inside out — each job holds ONE 9P message in flight and advances one
//! state per `step()`.
//!
//! Ported behaviour (`larryr/plan9@ed1a9c2`), and the reason `nsdir.zig` stays:
//!
//!  * `WalkJob` is `chan.c:1020-1043`'s union walk — members tried in bind
//!    order, first success wins, all fail ⇒ the path does not exist unless it is
//!    a synthetic mount-point prefix (R-9P-16).
//!  * `ListDirJob` is `sysfile.c:323-380`'s `unionread` — synthetic children
//!    first, then each member's own stream concatenated in bind order, "error
//!    causes component of union to be skipped" (sysfile.c:340), no
//!    de-duplication (R-P12d-2).
//!
//! RULING R-P13a-2 (pinned by tests): over the same fixtures, `runSync(WalkJob)`
//! lands on the same member as `nsdir.walk` and `runSync(ListDirJob)` yields the
//! same names in the same order as `nsdir.DirReader`. The two implementations
//! SHARE `syntheticChildren`, `syntheticStat`, `syntheticHandle` and
//! `splitComponents` so the halves cannot drift.
//!
//! POINTER STABILITY: a job borrows the caller's `path` (and, through the mount
//! table, the members it resolved) and hands its own inline reply buffer to a
//! live ticket. A job therefore must NOT be moved once `step` has been called,
//! and the namespace must not be re-bound under it — the same rule the rest of
//! Snarf's heap-pinned state follows.
//!
//! Imports: std + sibling ninep files (S-07 §6). Nothing here touches `core`,
//! `dev` or `shim`.
const std = @import("std");
const Client = @import("client.zig").Client;
const mount = @import("mount.zig");
const msg = @import("msg.zig");
const nsdir = @import("nsdir.zig");
const nspath = @import("nspath.zig");
const Qid = @import("qid.zig");
const Stat = @import("stat.zig");
const tickets = @import("tickets.zig");

const Message = msg.Message;
const Namespace = mount.Namespace;
const Target = mount.Target;

/// Job errors: everything a namespace walk/read can already fail with, plus the
/// `max_bytes` cap.
pub const Error = nsdir.Error || error{
    /// `ReadFileJob` hit its `max_bytes` ceiling before end of file.
    TooBig,
};

/// What one `step()` accomplished. `done` means the result fields are final;
/// calling `step` again is a no-op that returns `done`.
pub const Status = enum { pending, done };

/// Bytes a job buffers from one `Tread` (the `nsdir.DirReader` chunk), plus the
/// Rread frame header the `.frame` ticket mode also lands in the buffer.
pub const read_chunk: usize = nsdir.chunk_size;

/// Reply-buffer size for the small fixed-shape replies a job waits on: Rwalk is
/// at most `7 + 2 + 16·13` = 217 bytes, Ropen/Rclunk/Rflush are tiny, and every
/// stat record Snarf produces or consumes is well under this. A larger reply is
/// `error.ProtocolError` (the slot cannot hold it).
pub const small_reply: usize = 512;

/// `ReadFileJob`'s default ceiling — acme's own file-size limit (R-EDIT-10).
pub const max_file_bytes: usize = 64 << 20;

/// Drive `job` (a POINTER to one) to completion, pumping between steps. For
/// tests and for pumped in-process transports only: with no pump and no frames
/// this spins forever, which is exactly why the browser calls `step` from its
/// own tick instead.
pub fn runSync(job: anytype, pump: ?Client.Pump) Error!void {
    while (true) {
        if (try job.step() == .done) return;
        if (pump) |p| p.run(p.ctx) catch return error.IoError;
    }
}

/// One in-flight 9P message. `send` issues a T-message on a generic ticket;
/// `poll` reports its reply exactly once and then forgets the ticket (including
/// on an error, which `tickets.check` has already consumed the slot for).
pub const Step = struct {
    ticket: ?tickets.Ticket = null,

    pub fn send(self: *Step, c: *Client, m: Message, buf: []u8) Error!void {
        self.ticket = try tickets.begin(c, m, buf);
    }

    pub fn poll(self: *Step, c: *Client) Error!?Message {
        const t = self.ticket orelse return error.ProtocolError;
        const m = tickets.check(c, t) catch |e| {
            self.ticket = null;
            return e;
        };
        if (m == null) return null;
        self.ticket = null;
        return m;
    }

    /// Tflush an in-flight ticket. Best effort: a transport with no pump cannot
    /// complete the flush RPC, and the slot is dropped either way.
    pub fn abort(self: *Step, c: *Client) void {
        if (self.ticket) |t| {
            tickets.cancel(c, t) catch {};
            self.ticket = null;
        }
    }
};

// ==========================================================================
// WalkJob — chan.c:1020-1043 over tickets.
// ==========================================================================

/// Walk a namespace path, one Twalk at a time, trying each union member in bind
/// order until one succeeds (`nsdir.walk`'s contract, asynchronously).
///
/// On success `result` is an `nsdir.Handle` and its fid belongs to the CALLER —
/// release it with `nsdir.close`, exactly as after `nsdir.walk`. `deinit` only
/// cleans up an INCOMPLETE walk (cancel the in-flight ticket, clunk the
/// tentative newfid).
pub const WalkJob = struct {
    ns: *const Namespace,
    /// Borrowed, trailing '/' trimmed (so "/n/" and "/n" agree, as in `nsdir`).
    path: []const u8,
    names: [nsdir.max_components][]const u8 = undefined,
    n: usize = 0,
    /// The union at the resolved mount point, in bind order. Borrowed from the
    /// mount table.
    targets: []const Target = &.{},
    /// Did anything in the table match at all? Decides NotFound vs NotMounted.
    resolved: bool = false,
    /// False for `ListDirJob`'s per-member walks: `unionread` opens each member
    /// separately and must not fall back to a synthetic mount-point directory.
    synthetic_ok: bool = true,
    /// Index of the member currently being tried.
    i: usize = 0,
    client: ?*Client = null,
    newfid: u32 = 0,
    /// Names already walked (Twalk chunks at most MAXWELEM, as `Client.walk`).
    sent: usize = 0,
    chunk: usize = 0,
    /// Has any Twalk chunk fully succeeded? (`Client.walk`'s `established`:
    /// decides whether a failed walk owes the server a Tclunk.)
    established: bool = false,
    /// The qid the walk has reached — the caller's "is this a directory?".
    qid: Qid = .{ .path = 0 },
    st: Step = .{},
    phase: Phase = .next_member,
    buf: [small_reply]u8 = undefined,
    result: nsdir.Handle = undefined,

    const Phase = enum { next_member, walking, cleanup, done };

    /// Resolve `path` against the table. Errors that `nsdir.walk` reports up
    /// front (BadPath) are reported here; NotFound/NotMounted are verdicts the
    /// walk only reaches once every member has failed, so they come out of
    /// `step`.
    pub fn init(ns: *const Namespace, path_in: []const u8) Error!WalkJob {
        if (path_in.len == 0 or path_in[0] != '/') return error.BadPath;
        var self = WalkJob{ .ns = ns, .path = trimSlash(path_in) };
        const res = ns.resolve(self.path) catch |e| switch (e) {
            error.BadPath => return error.BadPath,
            error.NotMounted => return self, // may still be a synthetic prefix
        };
        self.resolved = true;
        self.targets = res.entry.targets.items;
        self.n = nsdir.splitComponents(res.remainder, &self.names) orelse return error.BadPath;
        return self;
    }

    /// A walk restricted to ONE already-resolved member (`ListDirJob`). `one`
    /// must be a length-1 slice of the mount table's own target array.
    pub fn initOne(ns: *const Namespace, path: []const u8, one: []const Target, rem: []const u8) Error!WalkJob {
        var self = WalkJob{
            .ns = ns,
            .path = path,
            .resolved = true,
            .synthetic_ok = false,
            .targets = one,
        };
        self.n = nsdir.splitComponents(rem, &self.names) orelse return error.BadPath;
        return self;
    }

    pub fn step(self: *WalkJob) Error!Status {
        switch (self.phase) {
            .done => return .done,
            .next_member => {
                if (self.i >= self.targets.len) {
                    // Every member failed (or there were none): a path that is
                    // only a PREFIX of mounted entries is a synthetic
                    // root-device directory (devroot.c's role, R-9P-16).
                    self.phase = .done;
                    if (self.synthetic_ok) {
                        if (nsdir.syntheticHandle(self.ns, self.path)) |h| {
                            self.result = h;
                            return .done;
                        }
                    }
                    return if (self.resolved) error.NotFound else error.NotMounted;
                }
                const t = self.targets[self.i];
                self.client = t.client;
                self.newfid = t.client.allocFid();
                self.established = false;
                self.sent = 0;
                // A pure clone reports the source fid's cached qid, exactly as
                // `Client.walk` does when the Rwalk carries none.
                self.qid = t.client.fids.get(t.root_fid) orelse .{ .path = 0 };
                try self.issue(t.root_fid);
                self.phase = .walking;
                return .pending;
            },
            .walking => {
                const c = self.client.?;
                const m = (self.st.poll(c) catch return self.memberFailed()) orelse return .pending;
                const rw = switch (m.body) {
                    .rwalk => |rw| rw,
                    else => return self.memberFailed(),
                };
                if (rw.nwqid != self.chunk) return self.memberFailed(); // partial
                if (self.chunk > 0) {
                    self.qid = rw.wqid[self.chunk - 1];
                    self.established = true;
                }
                self.sent += self.chunk;
                if (self.sent < self.n) {
                    try self.issue(self.newfid); // later chunks walk newfid in place
                    return .pending;
                }
                c.seedQid(self.newfid, self.qid);
                self.result = .{ .fid = .{ .client = c, .fid = self.newfid } };
                self.phase = .done;
                return .done;
            },
            .cleanup => {
                // Releasing the tentative newfid of a failed multi-chunk walk
                // (`Client.walkCleanup`): recycle the number only if the server
                // acknowledged the Tclunk, else burn it.
                const c = self.client.?;
                const m = self.st.poll(c) catch null;
                if (m) |reply| {
                    if (reply.body == .rclunk) c.freeFid(self.newfid);
                } else if (self.st.ticket != null) {
                    return .pending; // still waiting
                }
                self.i += 1;
                self.phase = .next_member;
                return .pending;
            },
        }
    }

    /// This member cannot supply the path: release its fid and move on
    /// (chan.c:1030-1037 "try a union mount, if any").
    fn memberFailed(self: *WalkJob) Error!Status {
        const c = self.client.?;
        if (self.established) {
            // The server holds newfid at an intermediate node; ask for it back
            // before trying the next member.
            try self.st.send(c, .{ .tag = 0, .body = .{ .tclunk = .{ .fid = self.newfid } } }, &self.buf);
            self.phase = .cleanup;
            return .pending;
        }
        c.freeFid(self.newfid);
        self.i += 1;
        self.phase = .next_member;
        return .pending;
    }

    /// Send the next Twalk chunk (at most MAXWELEM names; `names.len == 0` is a
    /// pure clone and still costs exactly one Twalk).
    fn issue(self: *WalkJob, from: u32) Error!void {
        self.chunk = @min(self.n - self.sent, msg.MAXWELEM);
        try self.st.send(self.client.?, .{ .tag = 0, .body = .{
            .twalk = msg.Body.Twalk.init(from, self.newfid, self.names[self.sent..][0..self.chunk]),
        } }, &self.buf);
    }

    pub fn deinit(self: *WalkJob) void {
        if (self.client) |c| {
            self.st.abort(c);
            switch (self.phase) {
                .walking => c.clunk(self.newfid) catch {},
                .cleanup => c.freeFid(self.newfid),
                else => {},
            }
        }
        self.* = undefined;
    }
};
/// One tolerated trailing '/' ("/n/" == "/n"), matching `nsdir.walk`.
fn trimSlash(p: []const u8) []const u8 {
    return if (p.len > 1 and p[p.len - 1] == '/') p[0 .. p.len - 1] else p;
}

// ==========================================================================
// The READING half lives in `nsio.zig` (split out under S-07's ~400-line cap;
// the seam is "resolve a path" above — chan.c — versus "read what it resolved
// to" — sysfile.c). Re-exported here so every caller says `nsjob.ListDirJob`.
// ==========================================================================

/// Read a whole file through the namespace into a caller-owned buffer.
pub const ReadFileJob = @import("nsio.zig").ReadFileJob;
/// Stat one namespace path (a synthetic mount-point directory answers from the
/// table, with no server op at all).
pub const StatJob = @import("nsio.zig").StatJob;
/// List a directory the way `unionread` does (sysfile.c:323-367).
pub const ListDirJob = @import("nsio.zig").ListDirJob;

// ==========================================================================
// Smoke tests (§T-nsjob). The named battery T5-T9 is the test writer's; these
// only pin that the decls are reachable and that the R-P13a-2 equivalence holds
// on the simplest shape of each job, over the 12d `nsdir` fixtures.
// ==========================================================================
const testing = std.testing;
const server = @import("server.zig");

/// `runSync`'s pump must drive EVERY server the job may talk to: a job's
/// `check` deliberately never pumps (R-P13a-3), so a union spread over two
/// servers wedges if only one of them is polled.
pub const Pumps = struct {
    srvs: []const *server.Server,

    fn run(ctx: *anyopaque) anyerror!void {
        const self: *Pumps = @ptrCast(@alignCast(ctx));
        for (self.srvs) |s| _ = try s.poll();
    }

    pub fn pump(self: *Pumps) Client.Pump {
        return .{ .ctx = self, .run = run };
    }
};

test "nsjob: WalkJob lands on the same member as nsdir.walk" {
    const a = testing.allocator;
    var t1 = nsdir.FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var t2 = nsdir.FakeTree{ .names = &.{ "rc", "date" }, .tag = "two\n" };
    var s1 = try nsdir.FakeServer.init(a, &t1);
    defer s1.deinit();
    var s2 = try nsdir.FakeServer.init(a, &t2);
    defer s2.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.bind("/bin", s1.client, s1.root_fid, .after);
    try ns.bind("/bin", s2.client, s2.root_fid, .after);
    var pumps = Pumps{ .srvs = &.{ s1.srv, s2.srv } };

    // Only the second member has `date` (chan.c:1030-1037) — same verdict the
    // synchronous walk reaches.
    var j = try WalkJob.init(&ns, "/bin/date/ctl");
    defer j.deinit();
    try runSync(&j, pumps.pump());
    try testing.expectEqual(s2.client, j.result.fid.client);
    nsdir.close(&ns, j.result);

    // A path that is only a prefix of a mount is the synthetic root device.
    var jd = try WalkJob.init(&ns, "/");
    defer jd.deinit();
    try runSync(&jd, null);
    try testing.expect(jd.result == .dir);

    var jm = try WalkJob.init(&ns, "/dev/mouse");
    defer jm.deinit();
    try testing.expectError(error.NotMounted, runSync(&jm, null));
}
