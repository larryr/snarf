//! 9P2000 message codec: a tagged-union `Message` plus `decode`/`encode`/
//! `encodedSize`. Namespace module (S-07 P-2). Imports `std`, `qid.zig`, and
//! the internal `wire.zig` cursor (extracted per the §2 overflow rule).
//!
//! Wire framing (convM2S.c / convS2M.c): every message is
//!   size[4] type[1] tag[2] <body>
//! where `size` includes its own 4 bytes and everything is little-endian
//! (fcall.h:65-74). Decode is zero-copy: every returned slice aliases the input
//! `buf`, so a decoded Message is valid only as long as `buf` lives (rule 12).
const std = @import("std");
const Qid = @import("qid.zig");
const wire = @import("wire.zig");
/// The create/remove/wstat halves of the codec (S-07 §2 overflow rule); see
/// `msg_mut.zig`'s header for why they live in their own file.
pub const mut = @import("msg_mut.zig");

pub const version9p = "9P2000"; // [fcall.h:4 VERSION9P]
pub const MAXWELEM = 16; // [fcall.h:6]
pub const NOTAG: u16 = 0xFFFF; // [fcall.h:86]
pub const NOFID: u32 = 0xFFFF_FFFF; // [fcall.h:87]
pub const IOHDRSZ = 24; // [fcall.h:88]
pub const header_size: usize = 7; // size[4] type[1] tag[2]
pub const min_msize: u32 = 8192; // S-01 §1
pub const default_msize: u32 = 65536;

// open modes [libc.h:545-549]
pub const OREAD: u8 = 0;
pub const OWRITE: u8 = 1;
pub const ORDWR: u8 = 2;
pub const OEXEC: u8 = 3;
pub const OTRUNC: u8 = 0x10;

/// 9P2000 message type codes, exhaustive (Tversion=100 … Rwstat=127).
/// [fcall.h:90-121]. No `_` catch-all: decode range-checks the byte before
/// `@enumFromInt`, so every value here is a real, defined code.
pub const Kind = enum(u8) {
    tversion = 100,
    rversion = 101,
    tauth = 102,
    rauth = 103,
    tattach = 104,
    rattach = 105,
    terror = 106, // illegal on the wire [fcall.h:98]
    rerror = 107,
    tflush = 108,
    rflush = 109,
    twalk = 110,
    rwalk = 111,
    topen = 112,
    ropen = 113,
    tcreate = 114,
    rcreate = 115,
    tread = 116,
    rread = 117,
    twrite = 118,
    rwrite = 119,
    tclunk = 120,
    rclunk = 121,
    tremove = 122,
    rremove = 123,
    tstat = 124,
    rstat = 125,
    twstat = 126,
    rwstat = 127,
};

pub const DecodeError = error{ BadMessage, Unsupported };
pub const EncodeError = error{ ShortBuffer, BadMessage };

pub const Message = struct { tag: u16, body: Body };

/// The message body. Inferred-tag union (NOT `union(Kind)`): only the codes
/// Snarf implements have arms; valid-but-unimplemented codes never construct a
/// Body (decode returns `error.Unsupported`, per rule 11).
pub const Body = union(enum) {
    tversion: Version,
    rversion: Version,
    tattach: struct { fid: u32, afid: u32, uname: []const u8, aname: []const u8 },
    rattach: struct { qid: Qid },
    rerror: struct { ename: []const u8 },
    tflush: struct { oldtag: u16 },
    rflush: void,
    twalk: Twalk,
    rwalk: Rwalk,
    topen: struct { fid: u32, mode: u8 },
    ropen: struct { qid: Qid, iounit: u32 },
    tread: struct { fid: u32, offset: u64, count: u32 },
    rread: struct { data: []const u8 }, // count derived from data.len
    twrite: struct { fid: u32, offset: u64, data: []const u8 },
    rwrite: struct { count: u32 },
    tclunk: struct { fid: u32 },
    rclunk: void,
    tstat: struct { fid: u32 },
    rstat: struct { stat: []const u8 }, // opaque stat(5) blob (R4)
    // The mutating transactions (phase 14a; phase-1 ruling R5 lifted). Field
    // layouts and codec live in `msg_mut.zig` [`5/open`, `5/remove`, `5/stat`].
    tcreate: mut.Tcreate,
    rcreate: mut.Rcreate,
    tremove: mut.Tremove,
    rremove: void,
    twstat: mut.Twstat,
    rwstat: void,

    pub const Version = struct { msize: u32, version: []const u8 };

    pub const Twalk = struct {
        fid: u32,
        newfid: u32,
        nwname: u16 = 0,
        wname: [MAXWELEM][]const u8 = @splat(""),

        /// Convenience builder; `wnames.len` must be ≤ MAXWELEM.
        pub fn init(fid: u32, newfid: u32, wnames: []const []const u8) Twalk {
            var t = Twalk{ .fid = fid, .newfid = newfid, .nwname = @intCast(wnames.len) };
            for (wnames, 0..) |n, i| t.wname[i] = n;
            return t;
        }

        pub fn names(self: *const Twalk) []const []const u8 {
            return self.wname[0..self.nwname];
        }
    };

    pub const Rwalk = struct {
        nwqid: u16 = 0,
        wqid: [MAXWELEM]Qid = @splat(.{ .path = 0 }),

        /// Convenience builder; `qs.len` must be ≤ MAXWELEM.
        pub fn init(qs: []const Qid) Rwalk {
            var r = Rwalk{ .nwqid = @intCast(qs.len) };
            for (qs, 0..) |q, i| r.wqid[i] = q;
            return r;
        }

        pub fn qids(self: *const Rwalk) []const Qid {
            return self.wqid[0..self.nwqid];
        }
    };

    /// The message-type code for this body (exhaustive).
    pub fn kind(self: Body) Kind {
        return switch (self) {
            .tversion => .tversion,
            .rversion => .rversion,
            .tattach => .tattach,
            .rattach => .rattach,
            .rerror => .rerror,
            .tflush => .tflush,
            .rflush => .rflush,
            .twalk => .twalk,
            .rwalk => .rwalk,
            .topen => .topen,
            .ropen => .ropen,
            .tread => .tread,
            .rread => .rread,
            .twrite => .twrite,
            .rwrite => .rwrite,
            .tclunk => .tclunk,
            .rclunk => .rclunk,
            .tstat => .tstat,
            .rstat => .rstat,
            .tcreate => .tcreate,
            .rcreate => .rcreate,
            .tremove => .tremove,
            .rremove => .rremove,
            .twstat => .twstat,
            .rwstat => .rwstat,
        };
    }
};

/// Decode a single frame. `buf.len` must equal the size field exactly; trailing
/// bytes ⇒ BadMessage (rule 9). Zero-copy: slices alias `buf` (rule 12).
pub fn decode(buf: []const u8) DecodeError!Message {
    if (buf.len < header_size) return error.BadMessage;
    const size = std.mem.readInt(u32, buf[0..4], .little);
    if (size != buf.len) return error.BadMessage; // covers min-7 and trailing bytes
    const type_byte = buf[4];
    const tag = std.mem.readInt(u16, buf[5..7], .little);
    if (type_byte < 100 or type_byte > 127) return error.BadMessage;
    const k: Kind = @enumFromInt(type_byte);

    var r = wire.Reader.init(buf[header_size..]);
    const body: Body = switch (k) {
        .tversion => .{ .tversion = try decodeVersion(&r) },
        .rversion => .{ .rversion = try decodeVersion(&r) },
        .tattach => .{ .tattach = .{
            .fid = try r.get32(),
            .afid = try r.get32(),
            .uname = try r.getString(),
            .aname = try r.getString(),
        } },
        .rattach => .{ .rattach = .{ .qid = try r.getQid() } },
        .rerror => .{ .rerror = .{ .ename = try r.getString() } },
        .tflush => .{ .tflush = .{ .oldtag = try r.get16() } },
        .rflush => .rflush,
        .twalk => blk: {
            var t = Body.Twalk{ .fid = try r.get32(), .newfid = try r.get32() };
            t.nwname = try r.get16();
            if (t.nwname > MAXWELEM) return error.BadMessage; // rule 5
            var i: usize = 0;
            while (i < t.nwname) : (i += 1) t.wname[i] = try r.getString();
            break :blk .{ .twalk = t };
        },
        .rwalk => blk: {
            var rw = Body.Rwalk{ .nwqid = try r.get16() };
            if (rw.nwqid > MAXWELEM) return error.BadMessage; // rule 6
            var i: usize = 0;
            while (i < rw.nwqid) : (i += 1) rw.wqid[i] = try r.getQid();
            break :blk .{ .rwalk = rw };
        },
        .topen => .{ .topen = .{ .fid = try r.get32(), .mode = try r.get8() } },
        .ropen => .{ .ropen = .{ .qid = try r.getQid(), .iounit = try r.get32() } },
        .tread => .{ .tread = .{
            .fid = try r.get32(),
            .offset = try r.get64(),
            .count = try r.get32(),
        } },
        .rread => blk: {
            const count = try r.get32(); // rule 7: bounds-check before slicing
            break :blk .{ .rread = .{ .data = try r.getBytes(count) } };
        },
        .twrite => blk: {
            const fid = try r.get32();
            const offset = try r.get64();
            const count = try r.get32();
            break :blk .{ .twrite = .{ .fid = fid, .offset = offset, .data = try r.getBytes(count) } };
        },
        .rwrite => .{ .rwrite = .{ .count = try r.get32() } },
        .tclunk => .{ .tclunk = .{ .fid = try r.get32() } },
        .rclunk => .rclunk,
        .tstat => .{ .tstat = .{ .fid = try r.get32() } },
        .rstat => blk: {
            const nstat = try r.get16();
            break :blk .{ .rstat = .{ .stat = try r.getBytes(nstat) } };
        },
        .tcreate => .{ .tcreate = try mut.getTcreate(&r) },
        .rcreate => .{ .rcreate = try mut.getRcreate(&r) },
        .tremove => .{ .tremove = try mut.getTremove(&r) },
        .rremove => .rremove,
        .twstat => .{ .twstat = try mut.getTwstat(&r) },
        .rwstat => .rwstat,
        // terror is illegal on the wire (rule 11).
        .terror => return error.BadMessage,
        // The only pair Snarf still does not implement (rule 11); `5/attach`
        // auth is OQ-9P-3, S-01 §2.
        .tauth, .rauth => return error.Unsupported,
    };
    if (r.remaining() != 0) return error.BadMessage; // no trailing body bytes
    return .{ .tag = tag, .body = body };
}

fn decodeVersion(r: *wire.Reader) DecodeError!Body.Version {
    const msize = try r.get32();
    return .{ .msize = msize, .version = try r.getString() };
}

/// Total encoded byte length of `m`. Requires a valid message (see `encode`'s
/// validation); calling with nwname/nwqid > MAXWELEM is illegal.
pub fn encodedSize(m: *const Message) usize {
    return header_size + bodySize(m.body);
}

fn bodySize(b: Body) usize {
    return switch (b) {
        .tversion, .rversion => |v| 4 + 2 + v.version.len,
        .tattach => |a| 4 + 4 + (2 + a.uname.len) + (2 + a.aname.len),
        .rattach => Qid.wire_size,
        .rerror => |e| 2 + e.ename.len,
        .tflush => 2,
        .rflush => 0,
        .twalk => |t| blk: {
            var n: usize = 4 + 4 + 2;
            for (t.wname[0..t.nwname]) |name| n += 2 + name.len;
            break :blk n;
        },
        .rwalk => |rw| 2 + @as(usize, rw.nwqid) * Qid.wire_size,
        .topen => 4 + 1,
        .ropen => Qid.wire_size + 4,
        .tread => 4 + 8 + 4,
        .rread => |x| 4 + x.data.len,
        .twrite => |x| 4 + 8 + 4 + x.data.len,
        .rwrite => 4,
        .tclunk => 4,
        .rclunk => 0,
        .tstat => 4,
        .rstat => |x| 2 + x.stat.len,
        .tcreate => |x| mut.sizeTcreate(x),
        .rcreate => mut.sizeRcreate(),
        .tremove => mut.sizeTremove(),
        .twstat => |x| mut.sizeTwstat(x),
        .rremove, .rwstat => 0,
    };
}

/// Encode `m` into `buf`. Returns bytes written. `BadMessage` if a field is
/// out of wire range (rule 13); `ShortBuffer` if `buf` cannot hold the frame.
pub fn encode(m: *const Message, buf: []u8) EncodeError!usize {
    try validate(m.body);
    const total = encodedSize(m);
    if (buf.len < header_size) return error.ShortBuffer;
    if (buf.len < total) return error.ShortBuffer;

    std.mem.writeInt(u32, buf[0..4], @intCast(total), .little);
    buf[4] = @intFromEnum(m.body.kind());
    std.mem.writeInt(u16, buf[5..7], m.tag, .little);

    var w = wire.Writer.init(buf[header_size..total]);
    switch (m.body) {
        .tversion, .rversion => |v| {
            try w.put32(v.msize);
            try w.putString(v.version);
        },
        .tattach => |a| {
            try w.put32(a.fid);
            try w.put32(a.afid);
            try w.putString(a.uname);
            try w.putString(a.aname);
        },
        .rattach => |a| try w.putQid(a.qid),
        .rerror => |e| try w.putString(e.ename),
        .tflush => |f| try w.put16(f.oldtag),
        .rflush => {},
        .twalk => |t| {
            try w.put32(t.fid);
            try w.put32(t.newfid);
            try w.put16(t.nwname);
            for (t.wname[0..t.nwname]) |name| try w.putString(name);
        },
        .rwalk => |rw| {
            try w.put16(rw.nwqid);
            for (rw.wqid[0..rw.nwqid]) |q| try w.putQid(q);
        },
        .topen => |o| {
            try w.put32(o.fid);
            try w.put8(o.mode);
        },
        .ropen => |o| {
            try w.putQid(o.qid);
            try w.put32(o.iounit);
        },
        .tread => |x| {
            try w.put32(x.fid);
            try w.put64(x.offset);
            try w.put32(x.count);
        },
        .rread => |x| {
            try w.put32(@intCast(x.data.len));
            try w.putBytes(x.data);
        },
        .twrite => |x| {
            try w.put32(x.fid);
            try w.put64(x.offset);
            try w.put32(@intCast(x.data.len));
            try w.putBytes(x.data);
        },
        .rwrite => |x| try w.put32(x.count),
        .tclunk => |x| try w.put32(x.fid),
        .rclunk => {},
        .tstat => |x| try w.put32(x.fid),
        .rstat => |x| {
            try w.put16(@intCast(x.stat.len));
            try w.putBytes(x.stat);
        },
        .tcreate => |x| try mut.putTcreate(&w, x),
        .rcreate => |x| try mut.putRcreate(&w, x),
        .tremove => |x| try mut.putTremove(&w, x),
        .twstat => |x| try mut.putTwstat(&w, x),
        .rremove, .rwstat => {},
    }
    return total;
}

/// Reject fields that cannot fit their wire counts (rule 13).
fn validate(b: Body) EncodeError!void {
    const max_str = 0xFFFF;
    switch (b) {
        .tversion, .rversion => |v| if (v.version.len > max_str) return error.BadMessage,
        .tattach => |a| if (a.uname.len > max_str or a.aname.len > max_str) return error.BadMessage,
        .rerror => |e| if (e.ename.len > max_str) return error.BadMessage,
        .twalk => |t| {
            if (t.nwname > MAXWELEM) return error.BadMessage;
            for (t.wname[0..t.nwname]) |name| if (name.len > max_str) return error.BadMessage;
        },
        .rwalk => |rw| if (rw.nwqid > MAXWELEM) return error.BadMessage,
        .rread => |x| if (x.data.len > std.math.maxInt(u32)) return error.BadMessage,
        .twrite => |x| if (x.data.len > std.math.maxInt(u32)) return error.BadMessage,
        .rstat => |x| if (x.stat.len > max_str) return error.BadMessage,
        .tcreate => |x| try mut.validateTcreate(x),
        .twstat => |x| try mut.validateTwstat(x),
        else => {},
    }
}
