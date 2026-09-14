//! msg_mut.zig — the wire codec for the three MUTATING 9P2000 transactions:
//! create (`5/open`), remove (`5/remove`) and wstat (`5/stat`). Namespace
//! module (S-07 P-2); imports `std`, `qid.zig` and the internal `wire.zig`
//! cursor only, so it carries no dependency on `msg.zig` and the two files
//! can import each other freely.
//!
//! Carved out of `msg.zig` under the phase-14a contract §3a overflow rule:
//! `msg.zig` was already at 425 pre-test lines (over the S-07 ~400 soft cap)
//! before phase 14a lifted phase-1 ruling R5 ("no create/remove/wstat"), so the
//! per-field cursor code for the six new bodies lives here and `msg.zig` keeps
//! only the union arms and the one-line dispatch into these helpers.
//!
//! Wire layouts (`5/open`, `5/remove`, `5/stat`; all little-endian, a string
//! s = len[2] + len bytes):
//!   Tcreate  fid[4] name[s] perm[4] mode[1]
//!   Rcreate  qid[13] iounit[4]
//!   Tremove  fid[4]
//!   Rremove  —
//!   Twstat   fid[4] stat[n]      (n[2] then the stat(5) blob, which itself
//!                                 opens with its own size[2] — the documented
//!                                 double length of `5/stat`, exactly as Rstat)
//!   Rwstat   —
//!
//! Decode is zero-copy like the rest of the codec: `name`/`stat` alias the
//! caller's frame buffer and are valid only as long as it is (msg.zig rule 12).
const std = @import("std");
const Qid = @import("qid.zig");
const wire = @import("wire.zig");

pub const DecodeError = error{BadMessage};
pub const EncodeError = error{ ShortBuffer, BadMessage };

/// Tcreate body. `perm` carries DMDIR (0x80000000) for directories; the server
/// ANDs it with the parent's permissions (`5/open`) — the framework does not,
/// since only the file server knows `dir.perm`.
pub const Tcreate = struct { fid: u32, name: []const u8, perm: u32, mode: u8 };

/// Rcreate body. `iounit` may be 0, meaning "no guarantee" (`5/open`).
pub const Rcreate = struct { qid: Qid, iounit: u32 };

/// Tremove body. The fid is clunked by the server even when the remove itself
/// fails (`5/remove`).
pub const Tremove = struct { fid: u32 };

/// Twstat body. `stat` is the opaque stat(5) blob (decoded by `stat.zig` when
/// a server cares); "don't touch" fields are `~0` / empty strings (`5/stat`).
pub const Twstat = struct { fid: u32, stat: []const u8 };

// --- decode ---------------------------------------------------------------

pub fn getTcreate(r: *wire.Reader) DecodeError!Tcreate {
    const fid = try r.get32();
    const name = try r.getString();
    const perm = try r.get32();
    return .{ .fid = fid, .name = name, .perm = perm, .mode = try r.get8() };
}

pub fn getRcreate(r: *wire.Reader) DecodeError!Rcreate {
    const qid = try r.getQid();
    return .{ .qid = qid, .iounit = try r.get32() };
}

pub fn getTremove(r: *wire.Reader) DecodeError!Tremove {
    return .{ .fid = try r.get32() };
}

pub fn getTwstat(r: *wire.Reader) DecodeError!Twstat {
    const fid = try r.get32();
    const nstat = try r.get16(); // bounds-checked before slicing (msg.zig rule 7)
    return .{ .fid = fid, .stat = try r.getBytes(nstat) };
}

// --- encode ---------------------------------------------------------------

pub fn putTcreate(w: *wire.Writer, t: Tcreate) EncodeError!void {
    try w.put32(t.fid);
    try w.putString(t.name);
    try w.put32(t.perm);
    try w.put8(t.mode);
}

pub fn putRcreate(w: *wire.Writer, r: Rcreate) EncodeError!void {
    try w.putQid(r.qid);
    try w.put32(r.iounit);
}

pub fn putTremove(w: *wire.Writer, t: Tremove) EncodeError!void {
    try w.put32(t.fid);
}

pub fn putTwstat(w: *wire.Writer, t: Twstat) EncodeError!void {
    try w.put32(t.fid);
    try w.put16(@intCast(t.stat.len)); // n[2], then the blob (`5/stat`)
    try w.putBytes(t.stat);
}

// --- encoded sizes --------------------------------------------------------

pub fn sizeTcreate(t: Tcreate) usize {
    return 4 + (2 + t.name.len) + 4 + 1;
}

pub fn sizeRcreate() usize {
    return Qid.wire_size + 4;
}

pub fn sizeTremove() usize {
    return 4;
}

pub fn sizeTwstat(t: Twstat) usize {
    return 4 + (2 + t.stat.len);
}

// --- validation (msg.zig rule 13: reject fields that cannot fit their count) --

pub fn validateTcreate(t: Tcreate) EncodeError!void {
    if (t.name.len > 0xFFFF) return error.BadMessage;
}

pub fn validateTwstat(t: Twstat) EncodeError!void {
    if (t.stat.len > 0xFFFF) return error.BadMessage;
}
