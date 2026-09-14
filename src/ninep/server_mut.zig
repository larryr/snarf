//! server_mut.zig — the 9P handlers that MUTATE the fid table or the file
//! tree: attach, walk, create, remove and wstat. The rest of the framework
//! (framing, session state, the fid table itself, open/read/write/clunk/
//! flush/stat) stays in `server.zig`; the wait queue is `park.zig`.
//!
//! The split is a size seam (S-07 §2: `server.zig` was 780 pre-test lines
//! before phase 14a). `handleAttach` and `handleWalk` are a PURE MOVE out of
//! `server.zig` — byte-identical apart from `self` becoming an explicit `srv`
//! parameter and the `Outcome` return the generalised parking needs. The
//! create/remove/wstat handlers are new: phase 14a lifts phase-1 ruling R5.
//!
//! Imports: std + sibling ninep files (S-07 §6). Same mutual-import pair as
//! `park.zig`/`server.zig`.
const std = @import("std");
const Qid = @import("qid.zig");
const msg = @import("msg.zig");
const stat = @import("stat.zig");
const errors = @import("errors.zig");
const server = @import("server.zig");
const park = @import("park.zig");

const Server = server.Server;
const Fid = server.Fid;
const Outcome = server.Outcome;
const Error = server.Error;
const OpError = errors.OpError;

/// What `Ops.create` reports: the qid of the file it just made and the iounit
/// to advertise for it (0 ⇒ the framework substitutes msize-IOHDRSZ, exactly as
/// `open` does). [`5/open` Rcreate qid[13] iounit[4]]
pub const CreateResult = struct { qid: Qid, iounit: u32 = 0 };

/// [srv.c:211 sattach]
pub fn handleAttach(srv: *Server, tag: u16, a: anytype) Error!Outcome {
    if (srv.fids.contains(a.fid)) return srv.replied(srv.replyError(tag, error.FidInUse)); // Edupfid
    if (a.afid != msg.NOFID) return srv.replied(srv.replyError(tag, error.AuthNotRequired)); // no auth
    var fid = Fid{ .fid = a.fid, .qid = undefined, .uname = try srv.dupUname(a.uname) };
    const q = srv.ops.attach(srv.ctx, srv, &fid, a.aname) catch |e| {
        srv.allocator.free(fid.uname);
        return srv.replied(srv.replyError(tag, e));
    };
    fid.qid = q;
    try srv.fids.put(srv.allocator, a.fid, fid);
    return srv.replied(srv.reply(.{ .tag = tag, .body = .{ .rattach = .{ .qid = q } } }));
}

/// [srv.c:305 swalk + :133 walkandclone + :339 rwalk]
pub fn handleWalk(srv: *Server, tag: u16, t: msg.Body.Twalk) Error!Outcome {
    const src = srv.fids.get(t.fid) orelse return srv.replied(srv.replyError(tag, error.UnknownFid));
    if (src.omode != null) return srv.replied(srv.replyError(tag, error.FidOpen)); // cannot clone open fid
    if (t.nwname > 0 and !src.qid.qtype.dir) return srv.replied(srv.replyError(tag, error.WalkNoDir));
    const same = (t.fid == t.newfid);
    if (!same and srv.fids.contains(t.newfid)) return srv.replied(srv.replyError(tag, error.FidInUse));

    // Tentative newfid: a private copy that walk1 mutates in place. It is
    // only installed on success; on any failure it is discarded (== C's
    // "removefid" of the tentative newfid, srv.c:341).
    var work = Fid{
        .fid = t.newfid,
        .qid = src.qid,
        .omode = null,
        .ctx = src.ctx,
        .uname = try srv.dupUname(src.uname),
    };
    if (!same) {
        if (srv.ops.clone) |cl| {
            var srccopy = src;
            cl(srv.ctx, srv, &srccopy, &work) catch |e| {
                srv.allocator.free(work.uname);
                return srv.replied(srv.replyError(tag, e));
            };
        }
    }

    var qids: [msg.MAXWELEM]Qid = undefined;
    var i: usize = 0;
    var first_err: OpError = error.FileDoesNotExist;
    while (i < t.nwname) : (i += 1) {
        const q = srv.ops.walk1(srv.ctx, srv, &work, t.wname[i]) catch |e| switch (e) {
            // Blocked: discard the tentative newfid and park the WHOLE Twalk.
            // Re-running from component 0 is safe precisely because nothing was
            // installed — the same "leave no trace" rule a parking `read` obeys.
            error.WouldBlock, error.WouldBlockRead => {
                srv.allocator.free(work.uname);
                return .blocked;
            },
            else => |oe| {
                first_err = oe;
                break;
            },
        };
        work.qid = q;
        qids[i] = q;
    }
    const nwqid = i;

    if (nwqid < t.nwname) {
        // Walk did not complete: discard the tentative newfid.
        srv.allocator.free(work.uname);
        if (nwqid == 0) return srv.replied(srv.replyError(tag, first_err)); // first name failed
        return srv.replied(srv.replyWalk(tag, qids[0..nwqid])); // partial: no error, no newfid
    }

    // Full success (nwname==0 is a bare clone): install the newfid.
    if (same) srv.allocator.free(src.uname); // replace-in-place frees the old name
    try srv.fids.put(srv.allocator, t.newfid, work);
    return srv.replied(srv.replyWalk(tag, qids[0..nwqid]));
}

/// [srv.c:361 sopen + :425 ropen]
pub fn handleOpen(srv: *Server, tag: u16, fid: u32, mode: u8) Error!Outcome {
    const fp = srv.fids.getPtr(fid) orelse return srv.replied(srv.replyError(tag, error.UnknownFid));
    const base = mode & 3;
    const norm_base: u8 = if (base == msg.OEXEC) msg.OREAD else base; // OEXEC→OREAD
    const wants_write = norm_base == msg.OWRITE or norm_base == msg.ORDWR or (mode & msg.OTRUNC) != 0;
    if (fp.qid.qtype.dir and wants_write) return srv.replied(srv.replyError(tag, error.FileIsDirectory));
    const q = srv.ops.open(srv.ctx, srv, fp, mode) catch |e| switch (e) {
        error.WouldBlock, error.WouldBlockRead => return .blocked,
        else => |oe| return srv.replied(srv.replyError(tag, oe)),
    };
    fp.omode = (mode & ~@as(u8, 3)) | norm_base;
    return srv.replied(srv.reply(.{ .tag = tag, .body = .{ .ropen = .{ .qid = q, .iounit = 0 } } }));
}

/// [srv.c:554 sclunk] — notify then remove unconditionally.
pub fn handleClunk(srv: *Server, tag: u16, fid: u32) Error!Outcome {
    if (!srv.fids.contains(fid)) return srv.replied(srv.replyError(tag, error.UnknownFid));
    // Before the fid dies, interrupt anything parked on it: Rerror
    // "interrupted" per entry, in park order (R-P6-5).
    try park.sweepFid(srv, fid);
    return srv.replied(clunkFid(srv, tag, fid));
}

/// Drop `fid` (notifying `Ops.clunk`) and answer Rclunk. Shared with the
/// Tremove path: remove is "a clunk with the side effect of removing the file"
/// (`5/remove`), so it ends the same way.
pub fn clunkFid(srv: *Server, tag: u16, fid: u32) Error!void {
    const fp = srv.fids.getPtr(fid) orelse return srv.replyError(tag, error.UnknownFid);
    if (srv.ops.clunk) |c| c(srv.ctx, srv, fp);
    const owned = fp.uname;
    _ = srv.fids.remove(fid);
    srv.allocator.free(owned);
    return srv.reply(.{ .tag = tag, .body = .rclunk });
}

/// Forget `fid` with NO reply: the Tremove path answers Rremove (or Rerror)
/// itself but still owes the unconditional clunk (`5/remove`).
pub fn dropFid(srv: *Server, fid: u32) void {
    const fp = srv.fids.getPtr(fid) orelse return;
    if (srv.ops.clunk) |c| c(srv.ctx, srv, fp);
    const owned = fp.uname;
    _ = srv.fids.remove(fid);
    srv.allocator.free(owned);
}

// ===========================================================================
// create / remove / wstat — phase 14a lifts phase-1 ruling R5.
//
// The refusal strings are lib9p's, verbatim, so a Snarf server is
// indistinguishable on the wire from a native 9P server. They are RAW strings,
// not `errors.OpError` members: they are framework-capability refusals and
// protocol botches rather than file errors, so `errors.errorString` stays a
// closed round-trip-stable set (a client sees `error.Other` plus the text via
// `Client.lastErrorString`). [lib9p/srv.c:10-27]
// ===========================================================================

/// [lib9p/srv.c:17]
pub const create_prohibited = "create prohibited";
/// [lib9p/srv.c:20]
pub const remove_prohibited = "remove prohibited";
/// [lib9p/srv.c:23]
pub const wstat_prohibited = "wstat prohibited";
/// The fid is already the product of a successful open or create (`5/open`).
/// [lib9p/srv.c:12 Ebotch, :390 screate]
pub const protocol_botch = "9P protocol botch";
/// [lib9p/srv.c:13 Ecreatenondir, :392 screate]
pub const create_nondir = "create in non-directory";
/// [lib9p/srv.c:27 Ebaddir, :657 swstat]
pub const bad_wstat_dir = "bad directory in wstat";
/// `.`, `..`, an empty name or one containing '/' (`5/open`).
/// [9/port/error.h:15 Efilename]
pub const filename_syntax = "file name syntax";

/// `5/open`: "The names `.` and `..` are special; it is illegal to create files
/// with these names." An empty name and an embedded '/' are excluded for the
/// same reason `nspath.canonicalize` excludes them — they would name something
/// other than one new entry in this directory.
pub fn validCreateName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfScalar(u8, name, '/') == null;
}

/// [`5/open` Tcreate; lib9p/srv.c:383 screate] — the check order is lib9p's:
/// unknown fid, then already-open, then non-directory, then the name, and only
/// then the absent-callback refusal.
pub fn handleCreate(srv: *Server, tag: u16, c: msg.mut.Tcreate) Error!Outcome {
    const fp = srv.fids.getPtr(c.fid) orelse
        return srv.replied(srv.replyError(tag, error.UnknownFid));
    if (fp.omode != null) return srv.replied(srv.replyRaw(tag, protocol_botch));
    if (!fp.qid.qtype.dir) return srv.replied(srv.replyRaw(tag, create_nondir));
    if (!validCreateName(c.name)) return srv.replied(srv.replyRaw(tag, filename_syntax));
    const op = srv.ops.create orelse return srv.replied(srv.replyRaw(tag, create_prohibited));

    const res = op(srv.ctx, srv, fp, c.name, c.perm, c.mode) catch |e| switch (e) {
        error.WouldBlock, error.WouldBlockRead => return .blocked,
        else => |oe| return srv.replied(srv.replyError(tag, oe)),
    };
    // "Finally, the newly created file is opened according to mode, and fid
    // will represent the newly opened file." (`5/open`) — re-point the fid and
    // mark it open, with the same OEXEC→OREAD normalisation `handleOpen` uses.
    // Look the fid up again: the callback may have touched the fid table.
    const np = srv.fids.getPtr(c.fid) orelse
        return srv.replied(srv.replyError(tag, error.UnknownFid));
    np.qid = res.qid;
    const base = c.mode & 3;
    const norm_base: u8 = if (base == msg.OEXEC) msg.OREAD else base;
    np.omode = (c.mode & ~@as(u8, 3)) | norm_base;
    // "The iounit field returned by open and create may be zero." (`5/open`)
    // A server that does not care gets the largest single-message payload.
    const iounit = if (res.iounit != 0) res.iounit else srv.msize - msg.IOHDRSZ;
    return srv.replied(srv.reply(.{ .tag = tag, .body = .{ .rcreate = .{ .qid = res.qid, .iounit = iounit } } }));
}

/// [`5/remove`; lib9p/srv.c:573 sremove] — "It is correct to consider remove to
/// be a clunk with the side effect of removing the file if permissions allow":
/// the fid is dropped whether the remove succeeds, fails, or is prohibited
/// (R-P14a-3). lib9p pulls the fid out of the pool BEFORE calling `srv->remove`;
/// we drop it after, because `Ops.remove` is handed the `*Fid` — the wire is
/// identical either way. A PARKED remove has not clunked yet: the retry
/// re-dispatches the whole Tremove, which is why the drop is on the reply paths
/// and not before the callback.
pub fn handleRemove(srv: *Server, tag: u16, fid: u32) Error!Outcome {
    const fp = srv.fids.getPtr(fid) orelse
        return srv.replied(srv.replyError(tag, error.UnknownFid));
    const op = srv.ops.remove orelse {
        dropFid(srv, fid); // clunked even when the remove is refused
        return srv.replied(srv.replyRaw(tag, remove_prohibited));
    };
    op(srv.ctx, srv, fp) catch |e| switch (e) {
        error.WouldBlock, error.WouldBlockRead => return .blocked, // fid survives for the retry
        else => |oe| {
            dropFid(srv, fid); // ...and even when it fails (`5/remove`)
            return srv.replied(srv.replyError(tag, oe));
        },
    };
    dropFid(srv, fid);
    return srv.replied(srv.reply(.{ .tag = tag, .body = .rremove }));
}

/// [`5/stat` Twstat; lib9p/srv.c:644 swstat] — decode the directory entry,
/// reject every attempt to change something a wstat may not change, then hand
/// the decoded `Stat` to the callback. "Don't touch" is `~0` for the integer
/// fields and an empty string for the text ones; lib9p's checks are reproduced
/// field for field, including the order (the prohibited refusal comes BEFORE
/// the decode here, unlike create).
pub fn handleWstat(srv: *Server, tag: u16, w: msg.mut.Twstat) Error!Outcome {
    const fp = srv.fids.getPtr(w.fid) orelse
        return srv.replied(srv.replyError(tag, error.UnknownFid));
    const op = srv.ops.wstat orelse return srv.replied(srv.replyRaw(tag, wstat_prohibited));

    const st = stat.decode(w.stat) catch
        return srv.replied(srv.replyRaw(tag, bad_wstat_dir));
    // convM2D must consume the WHOLE stat field, nothing less (:657).
    if (st.encodedSize() != w.stat.len) return srv.replied(srv.replyRaw(tag, bad_wstat_dir));

    if (st.ktype != 0xFFFF) return srv.replied(srv.replyRaw(tag, "wstat -- attempt to change type"));
    if (st.kdev != 0xFFFF_FFFF) return srv.replied(srv.replyRaw(tag, "wstat -- attempt to change dev"));
    const qtype_bits: u8 = @bitCast(st.qid.qtype);
    if (qtype_bits != 0xFF or st.qid.vers != 0xFFFF_FFFF or st.qid.path != std.math.maxInt(u64)) {
        return srv.replied(srv.replyRaw(tag, "wstat -- attempt to change qid"));
    }
    if (st.muid.len != 0) return srv.replied(srv.replyRaw(tag, "wstat -- attempt to change muid"));
    // The directory bit cannot be changed by a wstat (`5/stat`).
    if (st.mode != 0xFFFF_FFFF and ((st.mode & stat.DMDIR) != 0) != fp.qid.qtype.dir) {
        return srv.replied(srv.replyRaw(tag, "wstat -- attempt to change DMDIR bit"));
    }

    op(srv.ctx, srv, fp, st) catch |e| switch (e) {
        error.WouldBlock, error.WouldBlockRead => return .blocked,
        else => |oe| return srv.replied(srv.replyError(tag, oe)),
    };
    return srv.replied(srv.reply(.{ .tag = tag, .body = .rwstat }));
}

// ===========================================================================
// Tests — SMOKE ONLY. The named battery (T2/T3: every refusal, every check
// order, the re-pointed fid, the iounit default) is the test author's, per the
// phase-14a contract §4. `testsrv.zig` carries the shared harness.
// ===========================================================================
const testsrv = @import("testsrv.zig");
const testing = std.testing;

/// The §10 fixture tree plus a `create` that mints path 99 and a `remove`/
/// `wstat` that merely record the call — enough to pin the success paths.
const MutOps = struct {
    var created: [16]u8 = undefined;
    var created_len: usize = 0;
    var removed: u64 = 0;
    var wstat_name: [16]u8 = undefined;
    var wstat_len: usize = 0;

    fn create(_: *anyopaque, _: *Server, _: *server.Fid, name: []const u8, _: u32, _: u8) server.OpBlockError!CreateResult {
        @memcpy(created[0..name.len], name);
        created_len = name.len;
        return .{ .qid = .{ .path = 99 } };
    }
    fn remove(_: *anyopaque, _: *Server, fid: *server.Fid) server.OpBlockError!void {
        removed = fid.qid.path;
    }
    fn wstat(_: *anyopaque, _: *Server, _: *server.Fid, st: stat) server.OpBlockError!void {
        @memcpy(wstat_name[0..st.name.len], st.name);
        wstat_len = st.name.len;
    }
};

/// A stat blob with every field "don't touch" except `name` (`5/stat`).
fn renameBlob(buf: []u8, name: []const u8) ![]u8 {
    const st = stat{
        .ktype = 0xFFFF,
        .kdev = 0xFFFF_FFFF,
        .qid = .{ .path = ~@as(u64, 0), .vers = 0xFFFF_FFFF, .qtype = @bitCast(@as(u8, 0xFF)) },
        .mode = 0xFFFF_FFFF,
        .atime = 0xFFFF_FFFF,
        .mtime = 0xFFFF_FFFF,
        .length = ~@as(u64, 0),
        .name = name,
        .uid = "",
        .gid = "",
        .muid = "",
    };
    return buf[0..try st.encode(buf)];
}

test "server_mut: create re-points the fid, remove clunks it, wstat applies" {
    const f = try testsrv.Fixture.create(testing.allocator);
    defer f.destroy();
    f.srv.ops = &.{
        .attach = testsrv.tree_ops.attach,
        .walk1 = testsrv.tree_ops.walk1,
        .open = testsrv.tree_ops.open,
        .read = testsrv.tree_ops.read,
        .write = testsrv.tree_ops.write,
        .stat = testsrv.tree_ops.stat,
        .create = MutOps.create,
        .remove = MutOps.remove,
        .wstat = MutOps.wstat,
    };
    try f.doVersion();
    _ = try f.doAttach(0);

    // create on the root (a dir, unopened): Rcreate, new qid, iounit default.
    const rc = try f.transact(.{ .tag = 1, .body = .{ .tcreate = .{ .fid = 0, .name = "made", .perm = 0o644, .mode = msg.OWRITE } } });
    try testing.expect(rc.body == .rcreate);
    try testing.expectEqual(@as(u64, 99), rc.body.rcreate.qid.path);
    try testing.expectEqual(@as(u32, 8192 - msg.IOHDRSZ), rc.body.rcreate.iounit);
    try testing.expectEqualStrings("made", MutOps.created[0..MutOps.created_len]);
    // The fid now IS the new file and is open, so a second create is a botch.
    const again = try f.transact(.{ .tag = 2, .body = .{ .tcreate = .{ .fid = 0, .name = "z", .perm = 0, .mode = 0 } } });
    try f.expectRerror(again, protocol_botch);

    // wstat: a rename with every other field "don't touch".
    var blob: [96]u8 = undefined;
    const rw = try f.transact(.{ .tag = 3, .body = .{ .twstat = .{ .fid = 0, .stat = try renameBlob(&blob, "renamed") } } });
    try testing.expect(rw.body == .rwstat);
    try testing.expectEqualStrings("renamed", MutOps.wstat_name[0..MutOps.wstat_len]);

    // remove: Rremove, and the fid is gone (`5/remove`).
    const rr = try f.transact(.{ .tag = 4, .body = .{ .tremove = .{ .fid = 0 } } });
    try testing.expect(rr.body == .rremove);
    try testing.expectEqual(@as(u64, 99), MutOps.removed);
    const after = try f.transact(.{ .tag = 5, .body = .{ .tstat = .{ .fid = 0 } } });
    try f.expectRerror(after, "unknown fid");
}

test "server_mut: create name syntax" {
    try testing.expect(validCreateName("x"));
    try testing.expect(!validCreateName(""));
    try testing.expect(!validCreateName("."));
    try testing.expect(!validCreateName(".."));
    try testing.expect(!validCreateName("a/b"));
}
