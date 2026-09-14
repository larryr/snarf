//! nsio.zig — reading THROUGH the namespace asynchronously: a file, a stat
//! record, a directory listing. The second half of `nsjob.zig` (S-07's ~400-line
//! cap; the seam is "resolve a path" — `nsjob.WalkJob`, `chan.c` — versus "read
//! what it resolved to" — `sysfile.c`). Every job here is re-exported from
//! `nsjob.zig`, which is the name the rest of the tree uses.
//!
//! Each job holds ONE 9P message in flight and advances one state per `step()`,
//! built only on `tickets.begin/check` (R-9P-13, R-P13a-3: `check` never pumps
//! and never blocks). `ListDirJob` is `9/port/sysfile.c:323-367 unionread`
//! ported onto that shape; `Drain`, its per-member spine, is the walk → Topen →
//! Tread loop → Tclunk that `ReadFileJob` also is.
//!
//! POINTER STABILITY and the R-P13a-2 equivalence ruling: see `nsjob.zig`.
//!
//! Size note (S-07's ~400-line soft cap, the `nsdir.zig` convention): ~330 lines
//! of actual code before the test banner; the rest is the cited rationale. The
//! three jobs share `Drain` and splitting further would cut that seam in half.
//!
//! Imports: std + sibling ninep files (S-07 §6). Nothing here touches `core`,
//! `dev` or `shim`.
const std = @import("std");
const Client = @import("client.zig").Client;
const mount = @import("mount.zig");
const msg = @import("msg.zig");
const nsdir = @import("nsdir.zig");
const nspath = @import("nspath.zig");
const nsjob = @import("nsjob.zig");
const Stat = @import("stat.zig");
const tickets = @import("tickets.zig");

const Namespace = mount.Namespace;
const Target = mount.Target;
const Error = nsjob.Error;
const Status = nsjob.Status;
const Step = nsjob.Step;
const WalkJob = nsjob.WalkJob;
const read_chunk = nsjob.read_chunk;

// ==========================================================================
// Drain — walk → Topen(OREAD) → Tread* → Tclunk, the spine of ReadFileJob and
// of ListDirJob's per-member read.
// ==========================================================================

const Drain = struct {
    walk: WalkJob,
    allocator: std.mem.Allocator,
    /// Caller-owned sink; every byte read is appended to it.
    out: *std.ArrayList(u8),
    max_bytes: usize,
    /// Refuse a non-directory (the union-read case: the kernel's open would
    /// have refused it and the component is skipped, sysfile.c:340).
    require_dir: bool,
    /// Heap so it survives a move of the enclosing job before the first `step`.
    buf: []u8,
    client: ?*Client = null,
    fid: u32 = 0,
    off: u64 = 0,
    /// True once Topen succeeded — `unionread` treats "never opened" and
    /// "opened then ended" differently.
    opened: bool = false,
    got: usize = 0,
    st: Step = .{},
    phase: Phase = .walking,

    const Phase = enum { walking, opening, reading, clunking, done };

    fn init(
        allocator: std.mem.Allocator,
        walk: WalkJob,
        out: *std.ArrayList(u8),
        max_bytes: usize,
        require_dir: bool,
    ) Error!Drain {
        return .{
            .walk = walk,
            .allocator = allocator,
            .out = out,
            .max_bytes = max_bytes,
            .require_dir = require_dir,
            .buf = try allocator.alloc(u8, read_chunk + tickets.rread_overhead),
        };
    }

    fn step(self: *Drain) Error!Status {
        switch (self.phase) {
            .done => return .done,
            .walking => {
                if (try self.walk.step() == .pending) return .pending;
                const f = switch (self.walk.result) {
                    .dir => return error.FileIsDirectory, // synthetic: nothing to open
                    .fid => |f| f,
                };
                self.client = f.client;
                self.fid = f.fid;
                // Only an Rwalk qid is authoritative; a pure clone reports the
                // client's cached guess (nsdir.DirReader.openMember).
                if (self.require_dir and self.walk.n > 0 and !self.walk.qid.qtype.dir) return error.WalkNoDir;
                try self.st.send(f.client, .{ .tag = 0, .body = .{
                    .topen = .{ .fid = f.fid, .mode = msg.OREAD },
                } }, self.buf);
                self.phase = .opening;
                return .pending;
            },
            .opening => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                if (m.body != .ropen) return error.ProtocolError;
                self.opened = true;
                try self.sendRead();
                self.phase = .reading;
                return .pending;
            },
            .reading => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                const data = switch (m.body) {
                    .rread => |r| r.data,
                    else => return error.ProtocolError,
                };
                if (data.len == 0) {
                    try self.sendClunk();
                    self.phase = .clunking;
                    return .pending;
                }
                if (self.got + data.len > self.max_bytes) return error.TooBig;
                try self.out.appendSlice(self.allocator, data);
                self.got += data.len;
                self.off += data.len;
                try self.sendRead();
                return .pending;
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

    fn sendRead(self: *Drain) Error!void {
        const c = self.client.?;
        const cap = self.buf.len - tickets.rread_overhead;
        const count: u32 = @intCast(@min(cap, c.ioMax()));
        try self.st.send(c, .{ .tag = 0, .body = .{
            .tread = .{ .fid = self.fid, .offset = self.off, .count = count },
        } }, self.buf);
    }

    fn sendClunk(self: *Drain) Error!void {
        try self.st.send(self.client.?, .{ .tag = 0, .body = .{
            .tclunk = .{ .fid = self.fid },
        } }, self.buf);
    }

    /// Abandon an in-flight drain. Fire-and-forget throughout — a job may be
    /// deinit'd on a client with no pump, where waiting for a reply is both
    /// impossible and poisonous (`tickets`' tombstone note).
    fn deinit(self: *Drain) void {
        if (self.client) |c| {
            self.st.abort(c);
            // In `.clunking` the Tclunk is already on the wire.
            if (self.phase == .clunking) c.freeFid(self.fid) else tickets.discardClunk(c, self.fid);
        }
        self.walk.deinit();
        self.allocator.free(self.buf);
        self.* = undefined;
    }
};

// ==========================================================================
// ReadFileJob / StatJob / ListDirJob
// ==========================================================================

/// Read a whole file through the namespace into a caller-owned `ArrayList(u8)`:
/// union walk, Topen(OREAD), a Tread loop at advancing offsets until a 0-length
/// Rread, then Tclunk. Stops with `error.TooBig` past `max_bytes` (R-EDIT-10);
/// `deinit` clunks the open fid on every path.
pub const ReadFileJob = struct {
    d: Drain,

    pub fn init(
        allocator: std.mem.Allocator,
        ns: *const Namespace,
        path: []const u8,
        out: *std.ArrayList(u8),
        max_bytes: usize,
    ) Error!ReadFileJob {
        return .{ .d = try Drain.init(allocator, try WalkJob.init(ns, path), out, max_bytes, false) };
    }

    pub fn step(self: *ReadFileJob) Error!Status {
        return self.d.step();
    }

    /// Bytes appended so far (final once `step` reports `done`).
    pub fn bytesRead(self: *const ReadFileJob) usize {
        return self.d.got;
    }

    pub fn deinit(self: *ReadFileJob) void {
        self.d.deinit();
    }
};

/// Stat one namespace path: union walk, Tstat, Tclunk. A synthetic mount-point
/// directory answers from the table with no server op at all. `result`'s strings
/// alias the job — valid until `deinit`.
pub const StatJob = struct {
    walk: WalkJob,
    st: Step = .{},
    /// The Rstat slot (and then the Rclunk one). `read_chunk`, not
    /// `small_reply`: an Rstat carries a variable-length record, and a
    /// worst-case stat(5) — four 255-byte strings, `2 + 39 + 4·(2+255)` = 1069
    /// bytes, plus the `7 + 2` byte Rstat frame — does NOT fit in 512. A slot
    /// too small is `error.ProtocolError`, i.e. a legal long-named file would
    /// fail to stat, so the slot is sized like every other variable-length one
    /// in this file.
    buf: [read_chunk]u8 = undefined,
    /// Owned copy of the stat(5) blob: the Tclunk that follows reuses `buf`.
    sbuf: [read_chunk]u8 = undefined,
    client: ?*Client = null,
    fid: u32 = 0,
    result: Stat = undefined,
    phase: Phase = .walking,

    const Phase = enum { walking, statting, clunking, done };

    pub fn init(ns: *const Namespace, path: []const u8) Error!StatJob {
        return .{ .walk = try WalkJob.init(ns, path) };
    }

    pub fn step(self: *StatJob) Error!Status {
        switch (self.phase) {
            .done => return .done,
            .walking => {
                if (try self.walk.step() == .pending) return .pending;
                switch (self.walk.result) {
                    .dir => |d| {
                        self.result = nsdir.syntheticStat(baseName(d.path), d.path);
                        self.phase = .done;
                        return .done;
                    },
                    .fid => |f| {
                        self.client = f.client;
                        self.fid = f.fid;
                        try self.st.send(f.client, .{ .tag = 0, .body = .{
                            .tstat = .{ .fid = f.fid },
                        } }, &self.buf);
                        self.phase = .statting;
                        return .pending;
                    },
                }
            },
            .statting => {
                const m = (try self.st.poll(self.client.?)) orelse return .pending;
                const blob = switch (m.body) {
                    .rstat => |r| r.stat,
                    else => return error.ProtocolError,
                };
                if (blob.len > self.sbuf.len) return error.MessageTooBig;
                @memcpy(self.sbuf[0..blob.len], blob);
                self.result = Stat.decode(self.sbuf[0..blob.len]) catch return error.ProtocolError;
                try self.st.send(self.client.?, .{ .tag = 0, .body = .{
                    .tclunk = .{ .fid = self.fid },
                } }, &self.buf);
                self.phase = .clunking;
                return .pending;
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

    /// Abandon an in-flight stat. Fire-and-forget, for the same reason as
    /// `Drain.deinit`.
    pub fn deinit(self: *StatJob) void {
        if (self.client) |c| {
            self.st.abort(c);
            if (self.phase == .clunking) c.freeFid(self.fid) else tickets.discardClunk(c, self.fid);
        }
        self.walk.deinit();
        self.* = undefined;
    }
};

/// List a directory through the namespace as `unionread` does
/// (sysfile.c:323-367): the synthetic children of this path first, then each
/// union member's own stream concatenated in bind order. A member that fails to
/// walk, open or read is SKIPPED (sysfile.c:340); when the path is NOT an exact
/// mount point only the first member that opens is read (chan.c's walk takes the
/// first success). No de-duplication anywhere (R-P12d-2).
///
/// `data` accumulates the raw stat(5) byte stream — byte-identical to what
/// `nsdir.DirReader` hands out — and `entries` is that stream decoded once at
/// the end, its strings aliasing `data`.
pub const ListDirJob = struct {
    allocator: std.mem.Allocator,
    ns: *const Namespace,
    /// Owned canonical copy; `rem` and the synthetic child paths point into it.
    path: []u8,
    synth: std.ArrayList([]u8) = .empty,
    synth_i: usize = 0,
    members: []const Target = &.{},
    rem: []const u8 = "",
    union_at_mount: bool = false,
    i: usize = 0,
    drain: ?Drain = null,
    data: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Stat) = .empty,
    phase: Phase = .synthetic,

    const Phase = enum { synthetic, member, decode, done };

    pub fn init(allocator: std.mem.Allocator, ns: *const Namespace, path: []const u8) Error!ListDirJob {
        if (path.len == 0 or path[0] != '/') return error.BadPath;
        var self = ListDirJob{ .allocator = allocator, .ns = ns, .path = try nspath.canonicalize(allocator, path) };
        errdefer self.deinit();
        try nsdir.syntheticChildren(allocator, ns, self.path, &self.synth);
        if (ns.resolve(self.path)) |res| {
            self.union_at_mount = res.remainder.len == 0;
            self.members = res.entry.targets.items;
            self.rem = res.remainder;
        } else |e| switch (e) {
            error.BadPath => return error.BadPath,
            error.NotMounted => {}, // purely synthetic directory
        }
        // Neither a mount point nor a prefix of one — `DirReader.open`'s verdict.
        if (self.members.len == 0 and self.synth.items.len == 0) return error.NotMounted;
        return self;
    }

    pub fn step(self: *ListDirJob) Error!Status {
        switch (self.phase) {
            .done => return .done,
            .synthetic => {
                if (self.synth_i == self.synth.items.len) {
                    self.phase = .member;
                    return .pending;
                }
                const name = self.synth.items[self.synth_i];
                self.synth_i += 1;
                var full: [512]u8 = undefined;
                const fp = childPath(self.path, &full, name) orelse return error.MessageTooBig;
                var rec: [512]u8 = undefined;
                const n = nsdir.syntheticStat(name, fp).encode(&rec) catch return error.MessageTooBig;
                try self.data.appendSlice(self.allocator, rec[0..n]);
                return .pending;
            },
            .member => return self.stepMember(),
            .decode => {
                try self.decodeAll();
                self.phase = .done;
                return .done;
            },
        }
    }

    fn stepMember(self: *ListDirJob) Error!Status {
        if (self.drain == null) {
            if (self.i >= self.members.len) {
                self.phase = .decode;
                return .pending;
            }
            const w = try WalkJob.initOne(self.ns, self.path, self.members[self.i..][0..1], self.rem);
            self.drain = try Drain.init(self.allocator, w, &self.data, std.math.maxInt(usize), true);
            return .pending;
        }
        const d = &self.drain.?;
        // "Error causes component of union to be skipped" (sysfile.c:340): a
        // member that never opened is simply passed over; one that opened and
        // then ended (or failed mid-read) also ends a NON-union listing, where
        // chan.c's walk takes the first success only.
        const opened = d.opened;
        const finished = if (d.step()) |s| s == .done else |_| true;
        if (!finished) return .pending;
        self.closeMember();
        if (opened and !self.union_at_mount) self.phase = .decode;
        return .pending;
    }

    fn closeMember(self: *ListDirJob) void {
        if (self.drain) |*d| d.deinit();
        self.drain = null;
        self.i += 1;
    }

    fn decodeAll(self: *ListDirJob) Error!void {
        var off: usize = 0;
        while (off + 2 <= self.data.items.len) {
            const size = std.mem.readInt(u16, self.data.items[off..][0..2], .little);
            const total = 2 + @as(usize, size);
            if (off + total > self.data.items.len) return error.ProtocolError;
            const st = Stat.decode(self.data.items[off..][0..total]) catch return error.ProtocolError;
            try self.entries.append(self.allocator, st);
            off += total;
        }
    }

    pub fn deinit(self: *ListDirJob) void {
        if (self.drain) |*d| d.deinit();
        for (self.synth.items) |n| self.allocator.free(n);
        self.synth.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

// --- helpers ---------------------------------------------------------------

/// `<path>/<name>`, for a synthetic child's qid. Null if it does not fit.
fn childPath(path: []const u8, buf: []u8, name: []const u8) ?[]const u8 {
    const sep: usize = if (path.len == 1) 0 else 1; // no "//" under root
    const total = path.len + sep + name.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    if (sep == 1) buf[path.len] = '/';
    @memcpy(buf[path.len + sep ..][0..name.len], name);
    return buf[0..total];
}

/// The last component of a canonical path ("/" stays "/").
fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i + 1 < path.len) return path[i + 1 ..];
    }
    return path;
}

// ==========================================================================
// Smoke tests (§T-nsio). The named battery T5-T9 is the test writer's; these
// only pin that the decls are reachable and that the R-P13a-2 equivalence
// (same names, same order as `nsdir.DirReader`) holds on the simplest shapes,
// over the 12d `nsdir` fixtures.
// ==========================================================================
const testing = std.testing;
const Pumps = nsjob.Pumps;
const runSync = nsjob.runSync;
const max_file_bytes = nsjob.max_file_bytes;

test "nsio: ListDirJob yields DirReader's names in DirReader's order (T6)" {
    const a = testing.allocator;
    var t1 = nsdir.FakeTree{ .names = &.{"mouse"}, .tag = "m\n" };
    var s1 = try nsdir.FakeServer.init(a, &t1);
    defer s1.deinit();
    var t2 = nsdir.FakeTree{ .names = &.{"new"}, .tag = "d\n" };
    var s2 = try nsdir.FakeServer.init(a, &t2);
    defer s2.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/dev", s1.client, s1.root_fid);
    try ns.mount("/dev/draw", s2.client, s2.root_fid);
    var pumps = Pumps{ .srvs = &.{ s1.srv, s2.srv } };

    // The synchronous reference stream for `/dev` (T13's shape: a synthesized
    // `draw` child, then the device's own listing).
    var dr = try nsdir.DirReader.open(a, &ns, "/dev");
    defer dr.close();
    var buf: [1024]u8 = undefined;
    const want = buf[0..try dr.read(0, &buf)];

    var j = try ListDirJob.init(a, &ns, "/dev");
    defer j.deinit();
    try runSync(&j, pumps.pump());
    try testing.expectEqualSlices(u8, want, j.data.items);
    try testing.expectEqual(@as(usize, 2), j.entries.items.len);
    try testing.expectEqualStrings("draw", j.entries.items[0].name);
    try testing.expectEqualStrings("mouse", j.entries.items[1].name);
}

test "nsio: StatJob and ReadFileJob reach a file through the namespace (T9)" {
    const a = testing.allocator;
    var t1 = nsdir.FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var s1 = try nsdir.FakeServer.init(a, &t1);
    defer s1.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/bin", s1.client, s1.root_fid);
    var pumps = Pumps{ .srvs = &.{s1.srv} };

    var sj = try StatJob.init(&ns, "/bin/rc/ctl");
    defer sj.deinit();
    try runSync(&sj, pumps.pump());
    try testing.expect(sj.result.mode & Stat.DMDIR == 0);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var rj = try ReadFileJob.init(a, &ns, "/bin/rc/ctl", &out, max_file_bytes);
    defer rj.deinit();
    try runSync(&rj, pumps.pump());
    try testing.expectEqualStrings("one\n", out.items);

    var nf = try StatJob.init(&ns, "/bin/nope");
    defer nf.deinit();
    try testing.expectError(error.NotFound, runSync(&nf, pumps.pump()));
}

test "nsio: ListDirJob matches DirReader at '/', '/n' and a union at '/bin' (T6)" {
    const a = testing.allocator;
    var t1 = nsdir.FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var s1 = try nsdir.FakeServer.init(a, &t1);
    defer s1.deinit();
    var t2 = nsdir.FakeTree{ .names = &.{"date"}, .tag = "two\n" };
    var s2 = try nsdir.FakeServer.init(a, &t2);
    defer s2.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/n/origin", s1.client, s1.root_fid);
    try ns.mount("/dev", s1.client, s1.root_fid);
    try ns.bind("/bin", s1.client, s1.root_fid, .after);
    try ns.bind("/bin", s2.client, s2.root_fid, .after);
    var pumps = Pumps{ .srvs = &.{ s1.srv, s2.srv } };

    const paths = [_][]const u8{ "/", "/n", "/bin" };
    for (paths) |path| {
        var dr = try nsdir.DirReader.open(a, &ns, path);
        defer dr.close();
        var want_buf: [1024]u8 = undefined;
        const want = want_buf[0..try dr.read(0, &want_buf)];

        var j = try ListDirJob.init(a, &ns, path);
        defer j.deinit();
        try runSync(&j, pumps.pump());
        try testing.expectEqualSlices(u8, want, j.data.items);
    }
}

test "nsio: ListDirJob skips a union member that fails to open or read (T6)" {
    const a = testing.allocator;
    var good = nsdir.FakeTree{ .names = &.{"rc"}, .tag = "ok\n" };
    var s_good = try nsdir.FakeServer.init(a, &good);
    defer s_good.deinit();
    var s_bad_open = try nsdir.FailServer.init(a);
    defer s_bad_open.deinit();
    var s_bad_read = try nsdir.FailReadServer.init(a);
    defer s_bad_read.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    // The failing members go FIRST: if they were not skipped, their error
    // would surface instead of the good member's entry (sysfile.c:340).
    try ns.bind("/bin", s_bad_open.client, s_bad_open.root_fid, .after);
    try ns.bind("/bin", s_bad_read.client, s_bad_read.root_fid, .after);
    try ns.bind("/bin", s_good.client, s_good.root_fid, .after);
    var pumps = Pumps{ .srvs = &.{ s_bad_open.srv, s_bad_read.srv, s_good.srv } };

    var dr = try nsdir.DirReader.open(a, &ns, "/bin");
    defer dr.close();
    var want_buf: [512]u8 = undefined;
    const want = want_buf[0..try dr.read(0, &want_buf)];

    var j = try ListDirJob.init(a, &ns, "/bin");
    defer j.deinit();
    try runSync(&j, pumps.pump());
    try testing.expectEqualSlices(u8, want, j.data.items);
    try testing.expectEqual(@as(usize, 1), j.entries.items.len);
    try testing.expectEqualStrings("rc", j.entries.items[0].name);
}

test "nsio: ReadFileJob reads a multi-chunk file byte-exactly; max_bytes stops early with TooBig (T7)" {
    const a = testing.allocator;
    // A body far larger than one Tread's payload (msize 8192, minus header
    // slack): forces several Tread round-trips, pinning the offset advance
    // across `step()` calls (contract §T7). `FakeTree.tag` is served
    // verbatim as the file body, so no fixture beyond a long string is
    // needed — no implementation code changes.
    const big = try a.alloc(u8, 20_000);
    defer a.free(big);
    for (big, 0..) |*b, i| b.* = @intCast('a' + (i % 26));

    var t = nsdir.FakeTree{ .names = &.{"rc"}, .tag = big };
    var s = try nsdir.FakeServer.init(a, &t);
    defer s.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/bin", s.client, s.root_fid);
    var pumps = Pumps{ .srvs = &.{s.srv} };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var rj = try ReadFileJob.init(a, &ns, "/bin/rc/ctl", &out, max_file_bytes);
    defer rj.deinit();
    try runSync(&rj, pumps.pump());
    try testing.expectEqualSlices(u8, big, out.items);
    try testing.expectEqual(big.len, rj.bytesRead());

    // A cap smaller than the file stops early with error.TooBig; `deinit`
    // still clunks the open fid (no hang, no trap).
    var out2 = std.ArrayList(u8).empty;
    defer out2.deinit(a);
    var rj2 = try ReadFileJob.init(a, &ns, "/bin/rc/ctl", &out2, 100);
    defer rj2.deinit();
    try testing.expectError(error.TooBig, runSync(&rj2, pumps.pump()));
}

test "nsio: StatJob reports DMDIR for a real directory and a synthetic one (T9)" {
    const a = testing.allocator;
    var t1 = nsdir.FakeTree{ .names = &.{"rc"}, .tag = "one\n" };
    var s1 = try nsdir.FakeServer.init(a, &t1);
    defer s1.deinit();

    var ns = Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/bin", s1.client, s1.root_fid);
    var pumps = Pumps{ .srvs = &.{s1.srv} };

    // A real server-side directory ("/bin/rc", FakeTree's per-name dir).
    var sj = try StatJob.init(&ns, "/bin/rc");
    defer sj.deinit();
    try runSync(&sj, pumps.pump());
    try testing.expect(sj.result.mode & Stat.DMDIR != 0);

    // A purely synthetic mount-point directory ("/", nobody's exact mount —
    // it exists only because "/bin" hangs from it): no server op at all, so
    // a nil pump is fine.
    var sd = try StatJob.init(&ns, "/");
    defer sd.deinit();
    try runSync(&sd, null);
    try testing.expect(sd.result.mode & Stat.DMDIR != 0);
}
