//! One in-flight `putfile` (exec.c:697-836) — the asynchronous Put.
//! file-as-struct (S-07 P-1): this file *is* the Put. Ported from
//! larryr/plan9port@337c6ac; cite as `exec.c:NN` / `wind.c:NN`.
//!
//! WHY IT IS A STRUCT (the `Load.zig` shape). acme's `putfile` is a run of
//! blocking syscalls — `dirstat`, maybe a re-read for `checksha1`, `create`,
//! the write loop, `close`, a re-`dirfstat` — and the kernel blocks the proc
//! in between. Snarf writes through the 9P namespace and may not block the
//! browser's main thread (R-9P-13), so each syscall is a `ninep.nsjob` job and
//! a Put advances one state per frame from `Editor.frameEnd`:
//!
//!     stat ──exists, samename, identity moved──> verify (re-read + sha1)
//!       │                                           │ hash differs ⇒ warn, abort
//!       └──────────────────────────────────────────> write ──samename──> restat ──> tail
//!
//! R-P17-1 (asynchronous Put). The bytes are SNAPSHOT when the Put is issued
//! (`Buffer.writeRaw`: raw bytes, so an untouched invalid sequence survives,
//! S-05 §1) together with the file's `seq`. The window is marked clean at the
//! end only if nothing was typed meanwhile (`file.seq == seq_at`); otherwise
//! `seq != putseq` keeps ` Put` in the tag, exactly wind.c:514's rule. One Put
//! per window at a time; Puts on different windows run concurrently. A Put
//! OUTLIVES its window: `dropWindow` only cuts the back-pointer and the write
//! finishes (a half-written file is worse than a finished one, and acme's
//! synchronous `putfile` cannot be interrupted either) — the completion
//! bookkeeping is skipped.
//!
//! R-P17-2 (OPFS write discipline). The Twrites go back to back on ONE fid and
//! are followed by the Tclunk, and only THEN the restat — `web/opfs.js` keeps
//! one writable stream per path and commits it before any non-write op on that
//! path, so the identity recorded is the committed file's.
//!
//! Every failure is a warning into `+Errors` (R-EDIT-21) in acme's own words.
//!
//! POINTER STABILITY (nsjob.zig's rule): jobs borrow `name` and `bytes` and
//! hand inline reply buffers to live tickets, so every Put is heap-pinned and
//! `Editor.puts` is a list of POINTERS.
//!
//! Imports: `std` + `ninep` + sibling core files (S-07 §6 — never dev/shim).
const std = @import("std");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");
const File = @import("File.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const wintag = @import("wintag.zig");

const Put = @This();
const nsjob = ninep.nsjob;
const Stat = ninep.stat;

/// The jobs a Put runs, in `putfile`'s order.
pub const Job = union(enum) {
    /// Between two jobs (the previous one already deinit'd).
    none,
    stat: nsjob.StatJob,
    verify: nsjob.ReadFileJob,
    write: nsjob.WriteFileJob,
    restat: nsjob.StatJob,
};

/// What a stat said, copied out of the job (its strings alias it).
const Seen = struct { qid: ninep.Qid, mtime: u32, length: u64 };

allocator: std.mem.Allocator,
/// The window being written; null once it died (`dropWindow`).
w: ?*Window,
/// Absolute name being written. OWNED; borrowed by every job.
name: []u8,
/// The body's raw bytes when the Put was issued. OWNED; borrowed by the write.
bytes: []u8,
/// The body file's `seq` when the Put was issued (becomes `putseq`).
seq_at: u32,
/// `name` is the window's own name (exec.c:711): only then is the file's
/// identity checked and recorded.
samename: bool,
/// Putall's asynchronous `access()` (R-P17-3): never create.
must_exist: bool,
/// The file's `disk`/`unread` when the Put was issued — the stale check runs
/// on these, so it does not depend on the window surviving.
disk_at: ?File.Disk,
unread_at: bool,
/// The pre-write stat (null: the file did not exist).
seen: ?Seen = null,
/// `d->muid` of the pre-write stat, for the "modified by" warning.
muid: [64]u8 = undefined,
muid_len: usize = 0,
/// `ReadFileJob`'s sink for the sha1 arm.
verify_buf: std.ArrayList(u8) = .empty,
job: Job,
finished: bool = false,

// ==========================================================================
// Starting, stepping, dropping
// ==========================================================================

/// `put`'s call into `putfile(f, 0, f->b.nc, name)` (exec.c:924). `name` is
/// copied. Every outcome but OOM arrives later as a warning.
pub fn start(ed: *Editor, w: *Window, name: []const u8, must_exist: bool) Text.Error!void {
    const a = ed.allocator;
    const ns = ed.ns orelse {
        ed.warning("can't create file {s}: no namespace\n", .{name});
        return;
    };
    for (ed.puts.items) |p| {
        if (p.w == w) { // R-P17-1: one Put per window
            ed.warning("{s}: Put already in progress\n", .{name});
            return;
        }
    }
    const f = w.body.file;
    const self = try a.create(Put);
    errdefer a.destroy(self);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    f.buffer.writeRaw(&aw.writer) catch return error.OutOfMemory;
    self.* = .{
        .allocator = a,
        .w = w,
        .name = try a.dupe(u8, name),
        .bytes = undefined,
        .seq_at = f.seq,
        .samename = std.mem.eql(u8, name, f.name.items),
        .must_exist = must_exist,
        .disk_at = f.disk,
        .unread_at = f.unread,
        .job = undefined,
    };
    errdefer a.free(self.name);
    self.bytes = try aw.toOwnedSlice();
    errdefer a.free(self.bytes);
    self.job = .{ .stat = nsjob.StatJob.init(ns, self.name) catch |e| {
        ed.warning("can't create file {s}: {s}\n", .{ name, @errorName(e) });
        a.free(self.bytes);
        a.free(self.name);
        a.destroy(self);
        return;
    } };
    try ed.puts.append(a, self);
}

pub fn deinit(self: *Put) void {
    switch (self.job) {
        .none => {},
        .stat, .restat => |*j| j.deinit(),
        .verify => |*j| j.deinit(),
        .write => |*j| j.deinit(),
    }
    self.verify_buf.deinit(self.allocator);
    self.allocator.free(self.bytes);
    self.allocator.free(self.name);
    self.* = undefined;
}

/// Advance every live Put by one state; reap the finished ones. Called once
/// per frame from `Editor.frameEnd`, right after `Load.stepAll` (so before the
/// warnings flush and the tag sweep).
pub fn stepAll(ed: *Editor) Text.Error!void {
    var i: usize = 0;
    while (i < ed.puts.items.len) {
        const p = ed.puts.items[i];
        try p.step(ed);
        if (p.finished) {
            _ = ed.puts.orderedRemove(i);
            p.deinit();
            ed.allocator.destroy(p);
        } else i += 1;
    }
}

/// The window is dying (`Editor.dropTextRefs`): cut the back-pointer and let
/// the write finish (R-P17-1).
pub fn dropWindow(ed: *Editor, w: *Window) void {
    for (ed.puts.items) |p| {
        if (p.w == w) p.w = null;
    }
}

/// Editor teardown: abandon every Put (each job's deinit is fire-and-forget).
pub fn deinitAll(ed: *Editor) void {
    for (ed.puts.items) |p| {
        p.deinit();
        ed.allocator.destroy(p);
    }
    ed.puts.deinit(ed.allocator);
}

// ==========================================================================
// One state
// ==========================================================================

/// One state of this Put. Never blocks, never pumps (R-P13a-3).
pub fn step(self: *Put, ed: *Editor) Text.Error!void {
    if (self.finished) return;
    switch (self.job) {
        .none => self.finished = true, // unreachable in practice: every arm leaves a job
        .stat => |*j| {
            const st = j.step() catch |e| switch (e) {
                error.NotFound => {
                    if (self.must_exist) return self.finish(ed, "no auto-Put of {s}: file does not exist\n", .{self.name}); // exec.c:1186
                    return self.startWrite(ed); // a new file
                },
                else => return self.finish(ed, "can't create file {s}: {s}\n", .{ self.name, @errorName(e) }),
            };
            if (st == .pending) return;
            const r = j.result;
            self.seen = .{ .qid = r.qid, .mtime = r.mtime, .length = r.length };
            self.muid_len = @min(r.muid.len, self.muid.len);
            @memcpy(self.muid[0..self.muid_len], r.muid[0..self.muid_len]);
            j.deinit();
            self.job = .none;
            if (!self.samename or !self.moved()) return self.startWrite(ed); // exec.c:711-713
            if (self.disk_at == null) return self.stale(ed); // nothing to hash against
            // exec.c:713 `checksha1`: the identity moved — maybe only the
            // metadata. Re-read the file and compare hashes.
            const ns = ed.ns.?;
            self.job = .{ .verify = nsjob.ReadFileJob.init(self.allocator, ns, self.name, &self.verify_buf, nsjob.max_file_bytes) catch
                return self.stale(ed) };
        },
        .verify => |*j| {
            const st = j.step() catch return self.stale(ed); // exec.c:679-680 open fails ⇒ no update
            if (st == .pending) return;
            var h: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(self.verify_buf.items, &h, .{});
            if (!std.mem.eql(u8, &h, &self.disk_at.?.sha1)) return self.stale(ed);
            // exec.c:689-693: same bytes — adopt the new identity and write.
            const s = self.seen.?;
            self.disk_at.?.qid = s.qid;
            self.disk_at.?.mtime = s.mtime;
            if (self.liveFile()) |f| {
                if (f.disk) |*d| {
                    d.qid = s.qid;
                    d.mtime = s.mtime;
                }
            }
            return self.startWrite(ed);
        },
        .write => |*j| {
            const st = j.step() catch |e| {
                if (e == error.AppendOnly) return self.finish(ed, "{s} not written; file is append only\n", .{self.name}); // exec.c:745
                if (e == error.NotFound and self.must_exist) return self.finish(ed, "no auto-Put of {s}: file does not exist\n", .{self.name});
                if (j.pastOpen()) return self.finish(ed, "can't write file {s}: {s}\n", .{ self.name, @errorName(e) }); // exec.c:758/:764/:770
                return self.finish(ed, "can't create file {s}: {s}\n", .{ self.name, @errorName(e) }); // exec.c:729
            };
            if (st == .pending) return;
            const fallback = Seen{ .qid = j.qid, .mtime = 0, .length = self.bytes.len };
            j.deinit();
            self.job = .none;
            if (!self.samename) { // exec.c:774: a `Put other` writes a copy and changes nothing
                self.finished = true;
                return;
            }
            // exec.c:790-799: the fresh identity. AFTER the clunk (R-P17-2).
            self.seen = fallback;
            self.job = .{ .restat = nsjob.StatJob.init(ed.ns.?, self.name) catch
                return self.tail(ed) };
        },
        .restat => |*j| {
            // A failed restat keeps the pre-restat identity (exec.c:796-799).
            const st = j.step() catch return self.tail(ed);
            if (st == .pending) return;
            self.seen = .{ .qid = j.result.qid, .mtime = j.result.mtime, .length = j.result.length };
            return self.tail(ed);
        },
    }
}

/// The write itself (exec.c:727): open-truncate or create, Twrite loop, clunk.
/// `refuse_append` is exec.c:744's `d->length>0 && QTAPPEND` with the length
/// from the pre-write stat.
fn startWrite(self: *Put, ed: *Editor) Text.Error!void {
    const ns = ed.ns.?;
    const refuse_append = if (self.seen) |s| s.length > 0 else false;
    self.job = .{ .write = nsjob.WriteFileJob.init(ns, self.name, self.bytes, .{
        .must_exist = self.must_exist,
        .refuse_append = refuse_append,
    }) catch |e| return self.finish(ed, "can't create file {s}: {s}\n", .{ self.name, @errorName(e) }) };
}

/// exec.c:712: did the file's identity move since it was last read or written?
fn moved(self: *const Put) bool {
    const d = self.disk_at orelse return true;
    const s = self.seen.?;
    return d.qid.path != s.qid.path or d.qid.vers != s.qid.vers or d.mtime != s.mtime;
}

/// exec.c:714-724: the file changed under us — say so, remember its new
/// identity (so a second Put goes through, as in acme), write nothing.
fn stale(self: *Put, ed: *Editor) Text.Error!void {
    const s = self.seen.?;
    if (self.unread_at) {
        ed.warning("{s} not written; file already exists\n", .{self.name}); // exec.c:717
    } else {
        var was: [24]u8 = undefined;
        var now: [24]u8 = undefined;
        const muid = self.muid[0..self.muid_len];
        ed.warning("{s} modified{s}{s} since last read\n\twas {s}; now {s}\n", .{ // exec.c:719
            self.name,
            if (muid.len != 0) " by " else "",
            muid,
            fmtTime(&was, if (self.disk_at) |d| d.mtime else 0),
            fmtTime(&now, s.mtime),
        });
    }
    if (self.liveFile()) |f| { // exec.c:720-722
        if (f.disk) |*d| {
            d.qid = s.qid;
            d.mtime = s.mtime;
            d.length = s.length;
        } else f.disk = .{ .qid = s.qid, .mtime = s.mtime, .length = s.length, .sha1 = @splat(0) };
    }
    self.finished = true;
}

/// exec.c:774-818, the successful whole-file write of the window's own name:
/// record the identity, `putseq = seq` (exec.c:807), and clean the window only
/// if nothing was typed since the snapshot (R-P17-1).
fn tail(self: *Put, ed: *Editor) Text.Error!void {
    self.finished = true;
    const w = self.w orelse return;
    const f = self.liveFile() orelse return;
    const s = self.seen.?;
    var h: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(self.bytes, &h, .{});
    f.disk = .{ .qid = s.qid, .mtime = s.mtime, .length = s.length, .sha1 = h }; // exec.c:800-803
    w.putseq = self.seq_at; // exec.c:807
    if (f.seq == self.seq_at) {
        f.mod = false; // exec.c:804
        w.dirty = false; // exec.c:805, :808
    }
    f.unread = false; // exec.c:806
    try wintag.setTagCommit(ed, w); // exec.c:818 winsettag
    ed.needs_flush = true;
}

/// The window's file, if the window lives and is still named what we wrote —
/// a window renamed mid-Put must not be marked clean for another file.
fn liveFile(self: *const Put) ?*File {
    const w = self.w orelse return null;
    if (!std.mem.eql(u8, w.body.file.name.items, self.name)) return null;
    return w.body.file;
}

/// Warn and stop.
fn finish(self: *Put, ed: *Editor, comptime fmt: []const u8, args: anytype) void {
    ed.warning(fmt, args);
    self.finished = true;
}

/// acme's `%t` (acme.c:132 `timefmt`) as UTC `YYYY-MM-DD HH:MM:SS`.
fn fmtTime(buf: *[24]u8, t: u32) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = t };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,                 md.month.numeric(),       md.day_index + 1,
        ds.getHoursIntoDay(),    ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

// ==========================================================================
// Smoke tests. The named battery (T7-T10) is the test writer's.
// ==========================================================================
const testing = std.testing;

test "Put: fmtTime renders UTC" {
    var b: [24]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01 00:00:00", fmtTime(&b, 0));
    try testing.expectEqualStrings("2001-09-09 01:46:40", fmtTime(&b, 1_000_000_000));
}

test "Put: with no namespace a Put warns instead of trapping" {
    const draw = @import("draw");
    const boot = @import("boot.zig");
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(testing.allocator, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "/a/file",
        .body = "x\n",
    });
    defer tree.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    const w = tree.row.col.items[0].w.items[0];
    try start(&ed, w, "/a/file", false);
    try testing.expectEqual(@as(usize, 0), ed.puts.items.len);
    try testing.expectEqualStrings("can't create file /a/file: no namespace\n", ed.warningText());
}
