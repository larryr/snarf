//! `DevOpfs`'s two CACHES — the per-path `stat` memo (16b item 3) and the
//! write-sequence bookkeeping behind the record-v2 `close` op (16b item 4).
//! Namespace module (S-07 P-1) over `*DevOpfs`, its own file so `opfs.zig`
//! stays inside the ~400-line cap; `DevOpfs` keeps decl aliases, so
//! `self.statOf(…)` and friends resolve exactly as methods.
//!
//! WHY THE MEMO. Opening one file used to cost SIX `stat` round trips: walk1 stats
//! the component, `open` stats it again to confirm it is not a directory,
//! and every Tstat the client sends — the namespace walker sends several
//! while resolving `/mnt/opfs/x` — stats it once more, each through a
//! DIFFERENT fid and so a different `(fid, op, key)` slot. The slot table
//! is per-fid by design (it exists so two concurrent reads on one fid do
//! not collide); the TRUTH it caches is per-PATH.
//!
//! THE RULE. `stat_memo` holds the last `StatReply` seen for a path hash.
//! It is dropped whenever this device changes what that answer would be —
//! `write`, `truncate`, `create_file`/`create_dir`, `remove` — for the path
//! itself AND for its parent directory, and a `list` of a directory drops
//! every child memo under it (a fresh listing is fresh truth, so nothing
//! older may outlive it). An external writer (another tab) is NOT seen:
//! the same staleness a 9P client's own qid.vers caching already accepts,
//! and the reason the memo never outlives an editing operation on the file.
//!
//! Like `PathTable`, it grows with the set of paths VISITED and is freed
//! whole at `deinit`.
//!
//! THE WRITE SEQUENCE. `writers` holds the fids with a browser
//! `FileSystemWritableFileStream` open for their path; `Ops.clunk` closes it
//! (see `DevOpfs.clunkOp`). Two fids writing one path means two `close`s, the
//! second a no-op in the shim — correct, just not maximally lazy.
//!
//! Imports: std + `shim` + sibling dev files (S-07 §6) — the same budget
//! `opfs.zig` has.
const std = @import("std");
const shim = @import("shim");
const tree = @import("opfs_tree.zig");
const opfs = @import("opfs.zig");

const DevOpfs = opfs.DevOpfs;
const FsRecord = shim.abi.FsRecord;
const Self = DevOpfs;
const OpBlockError = @import("ninep").server.OpBlockError;

/// `stat` this path, from the memo if it is there and from the browser
/// (one parked round trip) if it is not.
pub fn statOf(self: *Self, fid: u32, path: []const u8, key: u64) OpBlockError!FsRecord.StatReply {
    if (self.stat_memo.get(key)) |sr| return sr;
    const c = try self.request(fid, .{ .op = .stat, .path = path }, key);
    if (c.status != .ok) return tree.statusError(c.status);
    const sr = FsRecord.StatReply.decode(c.payload) catch return error.IoError;
    // The memo is an optimisation: an OOM here costs a round trip, not
    // correctness, so the failure is swallowed.
    self.stat_memo.put(self.allocator, key, sr) catch {};
    return sr;
}

/// Forget `path` and its parent directory — what a completed `write`,
/// `truncate`, `create_*` or `remove` through this device invalidates.
pub fn forgetStat(self: *Self, path: []const u8) void {
    _ = self.stat_memo.remove(tree.hashPath(path));
    const parent = tree.parentPath(path);
    if (parent.ptr != path.ptr or parent.len != path.len) {
        _ = self.stat_memo.remove(tree.hashPath(parent));
    }
}

/// Forget every memo for a child of `dir`: a fresh `list` supersedes them.
/// Keys are collected first — removing while iterating a hash map is not
/// allowed — and an allocation failure falls back to dropping the WHOLE
/// memo, which is conservative in the safe direction.
pub fn forgetChildren(self: *Self, dir: []const u8) void {
    var doomed: std.ArrayList(u64) = .empty;
    defer doomed.deinit(self.allocator);
    var it = self.stat_memo.keyIterator();
    while (it.next()) |k| {
        const p = self.paths.get(k.*) orelse continue;
        // The root is its OWN parent (`5/walk`), so `dir` itself would
        // otherwise match when `dir` is "/" — and a listing says nothing
        // new about the directory being listed.
        if (std.mem.eql(u8, p, dir)) continue;
        if (!std.mem.eql(u8, tree.parentPath(p), dir)) continue;
        doomed.append(self.allocator, k.*) catch {
            self.stat_memo.clearRetainingCapacity();
            return;
        };
    }
    for (doomed.items) |k| _ = self.stat_memo.remove(k);
}

/// Note that `fid` has written: the browser is now holding a writable
/// stream open for its path (record version 2; 16b item 4). A failure to
/// record it costs a stream that is closed by the backend's own guard
/// rather than by us, so it is swallowed.
pub fn markWriter(self: *Self, fid: u32) void {
    self.writers.put(self.allocator, fid, {}) catch {};
}

/// Send one record with no slot and no ticket anybody waits on. Silent on
/// an encoding failure: the caller has no way to report one and no reply to
/// lose.
pub fn issueUnwatched(self: *Self, rec: FsRecord) void {
    const n = rec.encodedSize();
    self.rec_buf.resize(self.allocator, n) catch return;
    _ = rec.encode(self.rec_buf.items) catch return;
    self.req.issue(self.req.ctx, 0, self.rec_buf.items);
}
