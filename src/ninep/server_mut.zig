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
