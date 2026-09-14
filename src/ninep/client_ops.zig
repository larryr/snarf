//! The 9P CLIENT's SYNCHRONOUS PROTOCOL OPERATIONS [S-01 §3]: version, attach,
//! walk, open, read, write, clunk, stat, create, remove, wstat, flush. Each is
//! one `Client.rpc` round trip — send a T-message, block the caller until its
//! R-message arrives, decode it.
//!
//! Namespace module (S-07 P-1) over `*Client`, carved out of `client.zig`
//! verbatim in phase 16a so that file stays inside the ~400-line cap. `Client`
//! re-exports every function below as a DECL ALIAS, so `cl.walk(...)` method
//! syntax is unchanged at every call site and no forwarder frame was added.
//! What stayed behind is the struct, its fid/tag bookkeeping and the frame
//! layer (`rpc`/`sendFrame`/`writeFrame`/`readFrame`/`mapRerror`).
//!
//! NOTE (R-9P-13): nothing here may be called from the browser's main thread
//! for a file that can park server-side — that is what the asynchronous ticket
//! API (`beginRead`/`checkRead`, `tickets.zig`) is for.
const std = @import("std");
const msg = @import("msg.zig");
const Qid = @import("qid.zig");
const stat_mod = @import("stat.zig");
const Client = @import("client.zig");

const Error = Client.Error;
const FidInfo = Client.FidInfo;
const NOTAG = msg.NOTAG;
const NOFID = msg.NOFID;
const MAXWELEM = msg.MAXWELEM;
const Body = msg.Body;

// --- protocol operations --------------------------------------------------

/// Negotiate the protocol version and msize. Uses NOTAG, proposes
/// min(want_msize, max_msize), and stores the (possibly smaller) value the
/// server returns. Resets all tag/fid state — a fresh session. A reply that is
/// not Rversion, or whose version is not "9P2000" (the server says "unknown"
/// when it cannot speak our version), is a ProtocolError. [S-01 §3]
pub fn version(self: *Client, want_msize: u32) Error!u32 {
    const proposed = @min(want_msize, self.max_msize);
    const reply = try self.rpc(.{ .tag = NOTAG, .body = .{
        .tversion = .{ .msize = proposed, .version = msg.version9p },
    } });
    switch (reply.body) {
        .rversion => |v| {
            if (!std.mem.eql(u8, v.version, msg.version9p)) return error.ProtocolError;
            self.msize = @min(v.msize, proposed);
            self.next_tag = 0;
            self.next_fid = 0;
            self.free_fids.clearRetainingCapacity();
            self.fids.clearRetainingCapacity();
            // A fresh session: any tickets from the old one are abandoned
            // silently, mirroring the server clearing its parked queue on
            // Tversion (R-P6-5). Their tags belong to the previous session.
            self.pending.clearRetainingCapacity();
            return self.msize;
        },
        else => return error.ProtocolError,
    }
}

/// Attach to the file tree root as `uname` (no auth: afid = NOFID). Returns the
/// root fid and its qid.
pub fn attach(self: *Client, uname: []const u8, aname: []const u8) Error!FidInfo {
    const fid = self.allocFid();
    errdefer self.freeFid(fid);
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tattach = .{ .fid = fid, .afid = NOFID, .uname = uname, .aname = aname },
    } });
    switch (reply.body) {
        .rattach => |a| {
            try self.fids.put(self.allocator, fid, a.qid);
            return .{ .fid = fid, .qid = a.qid };
        },
        else => return error.ProtocolError,
    }
}

/// Walk `names` from `fid` to a freshly allocated newfid (clone + walk). Names
/// are sent in successive Twalks of at most MAXWELEM each (mnt.c chunking). The
/// newfid is established only on FULL success; any short/partial Rwalk yields
/// error.FileDoesNotExist. `names.len == 0` is a pure clone. [S-01 §4, `5/walk`]
///
/// Cleanup on failure (walkCleanup): a partial on the FIRST Twalk leaves newfid
/// untouched server-side, so the number is simply recycled. But once any chunk
/// fully succeeds the server holds newfid at an intermediate node; a later
/// failure must release it with a best-effort Tclunk, and the number is only
/// recycled if that clunk is acknowledged (otherwise it is burned, never handed
/// out again, so a still-live server fid can never collide).
pub fn walk(self: *Client, fid: u32, names: []const []const u8) Error!FidInfo {
    const newfid = self.allocFid();
    var established = false; // has any Twalk chunk fully succeeded?
    errdefer walkCleanup(self, newfid, established);

    var final_qid: Qid = self.fids.get(fid) orelse .{ .path = 0 };
    var clone_from = fid;
    var remaining = names;
    while (remaining.len > 0) {
        const chunk_len = @min(remaining.len, MAXWELEM);
        const chunk = remaining[0..chunk_len];
        const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
            .twalk = Body.Twalk.init(clone_from, newfid, chunk),
        } });
        switch (reply.body) {
            .rwalk => |rw| {
                if (rw.nwqid != chunk_len) return error.FileDoesNotExist; // partial
                final_qid = rw.wqid[chunk_len - 1];
                clone_from = newfid; // later chunks walk newfid in place
                established = true;
                remaining = remaining[chunk_len..];
            },
            else => return error.ProtocolError,
        }
    }
    if (names.len == 0) {
        // Pure clone: reply must be an empty Rwalk; newfid mirrors `fid`.
        const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
            .twalk = Body.Twalk.init(fid, newfid, &.{}),
        } });
        switch (reply.body) {
            .rwalk => |rw| if (rw.nwqid != 0) return error.ProtocolError,
            else => return error.ProtocolError,
        }
    }
    try self.fids.put(self.allocator, newfid, final_qid);
    return .{ .fid = newfid, .qid = final_qid };
}

/// Release the tentative newfid of a failed walk. If it was never established
/// server-side, just recycle the number. Otherwise send a best-effort Tclunk
/// and recycle the number only if the server acknowledges — else burn it.
fn walkCleanup(self: *Client, newfid: u32, established: bool) void {
    if (!established) {
        self.freeFid(newfid);
        return;
    }
    if (clunkQuiet(self, newfid)) self.freeFid(newfid);
    // clunk failed ⇒ the server may still hold newfid: burn the number.
}

/// Send Tclunk(fid) and report whether the server acknowledged it. Never frees
/// the fid number (the caller decides based on the result) and never surfaces
/// an error — used only for best-effort cleanup.
fn clunkQuiet(self: *Client, fid: u32) bool {
    const reply = self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tclunk = .{ .fid = fid },
    } }) catch return false;
    return reply.body == .rclunk;
}

/// Open `fid` for `mode` (an OREAD/OWRITE/... constant). The server tracks the
/// open mode; we just return the qid it reports.
pub fn open(self: *Client, fid: u32, mode: u8) Error!Qid {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .topen = .{ .fid = fid, .mode = mode },
    } });
    switch (reply.body) {
        .ropen => |o| return o.qid,
        else => return error.ProtocolError,
    }
}

/// Read up to `buf.len` bytes at `offset`. The requested count is clamped to
/// msize-IOHDRSZ (the max payload a single Rread can carry). Returns bytes read;
/// 0 means EOF. The caller loops for more.
pub fn read(self: *Client, fid: u32, offset: u64, buf: []u8) Error!usize {
    const count: u32 = @intCast(@min(buf.len, self.ioMax()));
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tread = .{ .fid = fid, .offset = offset, .count = count },
    } });
    switch (reply.body) {
        .rread => |r| {
            if (r.data.len > buf.len) return error.ProtocolError;
            @memcpy(buf[0..r.data.len], r.data);
            return r.data.len;
        },
        else => return error.ProtocolError,
    }
}

/// Write up to `data.len` bytes at `offset`. Payload is clamped to
/// msize-IOHDRSZ; if `data` is larger only the clamp is sent and the caller
/// loops. Returns the count the server acknowledges.
pub fn write(self: *Client, fid: u32, offset: u64, data: []const u8) Error!usize {
    const n = @min(data.len, self.ioMax());
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .twrite = .{ .fid = fid, .offset = offset, .data = data[0..n] },
    } });
    switch (reply.body) {
        .rwrite => |w| return w.count,
        else => return error.ProtocolError,
    }
}

/// Clunk (release) `fid`. The fid number is always freed locally, even if the
/// server answers Rerror — the fid is gone either way.
pub fn clunk(self: *Client, fid: u32) Error!void {
    defer self.freeFid(fid);
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tclunk = .{ .fid = fid },
    } });
    switch (reply.body) {
        .rclunk => return,
        else => return error.ProtocolError,
    }
}

/// Fetch the stat(5) record for `fid`. The returned Stat's strings alias `rbuf`
/// (R4): valid only until the next client call.
///
/// `stat.zig` is file-as-struct, so the module handle `stat_mod` *is* the Stat
/// type; `stat_mod.Stat` would name the file's private self-alias (not `pub`) and
/// fails to compile once analyzed — a latent bug uncovered by the first caller
/// (ticket test 12). Reference the type as `stat_mod`.
pub fn stat(self: *Client, fid: u32) Error!stat_mod {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tstat = .{ .fid = fid },
    } });
    switch (reply.body) {
        .rstat => |r| return stat_mod.decode(r.stat) catch return error.ProtocolError,
        else => return error.ProtocolError,
    }
}

/// What `create` reports back: the new file's qid and the server's iounit
/// (0 = no guarantee). [`5/open` Rcreate]
pub const CreateResult = msg.mut.Rcreate;

/// Create `name` in the directory `fid` and open the RESULT as `fid` (`5/open`):
/// on success this client's cached qid for `fid` becomes the new file's. `perm`
/// carries DMDIR for a directory; the server masks it against the parent.
pub fn create(self: *Client, fid: u32, name: []const u8, perm: u32, mode: u8) Error!CreateResult {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tcreate = .{ .fid = fid, .name = name, .perm = perm, .mode = mode },
    } });
    switch (reply.body) {
        .rcreate => |c| {
            self.seedQid(fid, c.qid); // the fid now names the new file
            return c;
        },
        else => return error.ProtocolError,
    }
}

/// Remove the file `fid` names. `5/remove`: the server clunks the fid even when
/// the remove fails, so the number is recycled either way — exactly like
/// `clunk`.
pub fn remove(self: *Client, fid: u32) Error!void {
    defer self.freeFid(fid);
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tremove = .{ .fid = fid },
    } });
    switch (reply.body) {
        .rremove => return,
        else => return error.ProtocolError,
    }
}

/// Change `fid`'s directory entry. Fields `st` leaves at their "don't touch"
/// values (`~0`, empty strings) are not altered (`5/stat`); build one with
/// `stat_mod.dontTouch()`. The blob is encoded into a local scratch buffer, so
/// nothing aliases `wbuf`.
pub fn wstat(self: *Client, fid: u32, st: stat_mod) Error!void {
    // A legal maximum stat is 2 + 39 + 4*(2+255) = 1069 bytes (stat(5)); 1024 would
    // reject a 255-byte name with MessageTooBig (review nit, 14a).
    var blob: [1100]u8 = undefined;
    const n = st.encode(&blob) catch return error.MessageTooBig;
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .twstat = .{ .fid = fid, .stat = blob[0..n] },
    } });
    switch (reply.body) {
        .rwstat => return,
        else => return error.ProtocolError,
    }
}

/// Ask the server to abandon the pending request tagged `oldtag`. In v1 the
/// server is synchronous so this always returns promptly. [`5/flush`]
pub fn flushTag(self: *Client, oldtag: u16) Error!void {
    const reply = try self.rpc(.{ .tag = self.allocTag(), .body = .{
        .tflush = .{ .oldtag = oldtag },
    } });
    switch (reply.body) {
        .rflush => return,
        else => return error.ProtocolError,
    }
}
