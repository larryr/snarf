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
        // terror is illegal on the wire (rule 11).
        .terror => return error.BadMessage,
        // Valid 9P codes Snarf does not implement (rule 11).
        .tauth, .rauth, .tcreate, .rcreate, .tremove, .rremove, .twstat, .rwstat => return error.Unsupported,
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
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Tests (§T-msg)
// ---------------------------------------------------------------------------
const testing = std.testing;

/// deep-equal two decoded bodies for the round-trip table.
fn expectBodyEqual(want: Body, got: Body) !void {
    try testing.expectEqual(want.kind(), got.kind());
    switch (want) {
        .tversion, .rversion => |v| {
            const g = if (want == .tversion) got.tversion else got.rversion;
            try testing.expectEqual(v.msize, g.msize);
            try testing.expectEqualStrings(v.version, g.version);
        },
        .tattach => |a| {
            try testing.expectEqual(a.fid, got.tattach.fid);
            try testing.expectEqual(a.afid, got.tattach.afid);
            try testing.expectEqualStrings(a.uname, got.tattach.uname);
            try testing.expectEqualStrings(a.aname, got.tattach.aname);
        },
        .rattach => |a| try expectQid(a.qid, got.rattach.qid),
        .rerror => |e| try testing.expectEqualStrings(e.ename, got.rerror.ename),
        .tflush => |f| try testing.expectEqual(f.oldtag, got.tflush.oldtag),
        .rflush, .rclunk => {},
        .twalk => |t| {
            try testing.expectEqual(t.fid, got.twalk.fid);
            try testing.expectEqual(t.newfid, got.twalk.newfid);
            try testing.expectEqual(t.nwname, got.twalk.nwname);
            for (t.names(), got.twalk.names()) |a, b| try testing.expectEqualStrings(a, b);
        },
        .rwalk => |rw| {
            try testing.expectEqual(rw.nwqid, got.rwalk.nwqid);
            for (rw.qids(), got.rwalk.qids()) |a, b| try expectQid(a, b);
        },
        .topen => |o| {
            try testing.expectEqual(o.fid, got.topen.fid);
            try testing.expectEqual(o.mode, got.topen.mode);
        },
        .ropen => |o| {
            try expectQid(o.qid, got.ropen.qid);
            try testing.expectEqual(o.iounit, got.ropen.iounit);
        },
        .tread => |x| {
            try testing.expectEqual(x.fid, got.tread.fid);
            try testing.expectEqual(x.offset, got.tread.offset);
            try testing.expectEqual(x.count, got.tread.count);
        },
        .rread => |x| try testing.expectEqualSlices(u8, x.data, got.rread.data),
        .twrite => |x| {
            try testing.expectEqual(x.fid, got.twrite.fid);
            try testing.expectEqual(x.offset, got.twrite.offset);
            try testing.expectEqualSlices(u8, x.data, got.twrite.data);
        },
        .rwrite => |x| try testing.expectEqual(x.count, got.rwrite.count),
        .tclunk => |x| try testing.expectEqual(x.fid, got.tclunk.fid),
        .tstat => |x| try testing.expectEqual(x.fid, got.tstat.fid),
        .rstat => |x| try testing.expectEqualSlices(u8, x.stat, got.rstat.stat),
    }
}

fn expectQid(a: Qid, b: Qid) !void {
    try testing.expectEqual(a.path, b.path);
    try testing.expectEqual(a.vers, b.vers);
    try testing.expectEqual(@as(u8, @bitCast(a.qtype)), @as(u8, @bitCast(b.qtype)));
}

test "round-trip every mandatory message" {
    const q1 = Qid{ .path = 0xAABB, .vers = 7, .qtype = .{ .dir = true } };
    const q2 = Qid{ .path = 2, .vers = 0 };
    const bodies = [_]Body{
        .{ .tversion = .{ .msize = 65536, .version = version9p } },
        .{ .rversion = .{ .msize = 8192, .version = version9p } },
        .{ .tattach = .{ .fid = 1, .afid = NOFID, .uname = "glenda", .aname = "" } },
        .{ .rattach = .{ .qid = q1 } },
        .{ .rerror = .{ .ename = "file does not exist" } },
        .{ .tflush = .{ .oldtag = 42 } },
        .rflush,
        .{ .twalk = Body.Twalk.init(3, 4, &.{ "dev", "mouse" }) },
        .{ .rwalk = Body.Rwalk.init(&.{ q1, q2 }) },
        .{ .topen = .{ .fid = 5, .mode = 0x12 } },
        .{ .ropen = .{ .qid = q1, .iounit = 8192 } },
        .{ .tread = .{ .fid = 6, .offset = 0xFFFF_FFFF_0000_0001, .count = 4096 } },
        .{ .rread = .{ .data = "hello\x00world" } },
        .{ .twrite = .{ .fid = 7, .offset = 16, .data = &.{ 0, 1, 2, 255 } } },
        .{ .rwrite = .{ .count = 4 } },
        .{ .tclunk = .{ .fid = 8 } },
        .rclunk,
        .{ .tstat = .{ .fid = 9 } },
        .{ .rstat = .{ .stat = &([_]u8{0xAB} ** 49) } },
    };
    var buf: [1024]u8 = undefined;
    var tag: u16 = 0;
    for (bodies) |b| {
        const m = Message{ .tag = tag, .body = b };
        const n = try encode(&m, &buf);
        try testing.expectEqual(encodedSize(&m), n);
        const got = try decode(buf[0..n]);
        try testing.expectEqual(tag, got.tag);
        try expectBodyEqual(b, got.body);
        tag +%= 1;
    }
}

test "zero-copy decode aliases input" {
    var buf: [128]u8 = undefined;
    const rr = Message{ .tag = 1, .body = .{ .rread = .{ .data = "abcdef" } } };
    const n1 = try encode(&rr, &buf);
    const g1 = try decode(buf[0..n1]);
    const base = @intFromPtr(&buf[0]);
    const dptr = @intFromPtr(g1.body.rread.data.ptr);
    try testing.expect(dptr >= base and dptr < base + n1);

    const tw = Message{ .tag = 1, .body = .{ .twalk = Body.Twalk.init(1, 2, &.{"name"}) } };
    const n2 = try encode(&tw, &buf);
    const g2 = try decode(buf[0..n2]);
    const wptr = @intFromPtr(g2.body.twalk.names()[0].ptr);
    try testing.expect(wptr >= base and wptr < base + n2);
}

test "decode: truncated at every offset" {
    var buf: [128]u8 = undefined;
    const m = Message{ .tag = 3, .body = .{ .tattach = .{
        .fid = 1,
        .afid = NOFID,
        .uname = "glenda",
        .aname = "",
    } } };
    const n = try encode(&m, &buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try testing.expectError(error.BadMessage, decode(buf[0..i]));
    }
    _ = try decode(buf[0..n]); // full frame is fine
}

test "decode: size field mismatch" {
    var buf: [128]u8 = undefined;
    const m = Message{ .tag = 3, .body = .{ .tclunk = .{ .fid = 1 } } };
    const n = try encode(&m, &buf);
    // one trailing garbage byte: buf.len == n+1 but size field == n
    buf[n] = 0xEE;
    try testing.expectError(error.BadMessage, decode(buf[0 .. n + 1]));
    // size field says n+1 but buffer is n: rewrite size, feed exact n bytes
    std.mem.writeInt(u32, buf[0..4], @intCast(n + 1), .little);
    try testing.expectError(error.BadMessage, decode(buf[0..n]));
}

test "decode: oversize string length" {
    // Tversion: size[4] type[1] tag[2] msize[4] verlen[2]=0xFFFF + 6 bytes
    var buf = [_]u8{0} ** 19;
    const total: u32 = 19;
    std.mem.writeInt(u32, buf[0..4], total, .little);
    buf[4] = @intFromEnum(Kind.tversion);
    std.mem.writeInt(u16, buf[5..7], 1, .little);
    std.mem.writeInt(u32, buf[7..11], 8192, .little);
    std.mem.writeInt(u16, buf[11..13], 0xFFFF, .little); // absurd string length
    try testing.expectError(error.BadMessage, decode(&buf));

    // Rread count 0xFFFF_FFFF with no data.
    var rb = [_]u8{0} ** 11;
    std.mem.writeInt(u32, rb[0..4], 11, .little);
    rb[4] = @intFromEnum(Kind.rread);
    std.mem.writeInt(u16, rb[5..7], 1, .little);
    std.mem.writeInt(u32, rb[7..11], 0xFFFF_FFFF, .little);
    try testing.expectError(error.BadMessage, decode(&rb));
}

test "walk: zero names" {
    var buf: [64]u8 = undefined;
    const tw = Message{ .tag = 1, .body = .{ .twalk = Body.Twalk.init(1, 2, &.{}) } };
    const n1 = try encode(&tw, &buf);
    const g1 = try decode(buf[0..n1]);
    try testing.expectEqual(@as(u16, 0), g1.body.twalk.nwname);

    const rw = Message{ .tag = 1, .body = .{ .rwalk = Body.Rwalk.init(&.{}) } };
    const n2 = try encode(&rw, &buf);
    const g2 = try decode(buf[0..n2]);
    try testing.expectEqual(@as(u16, 0), g2.body.rwalk.nwqid);
}

test "walk: MAXWELEM ok, 17 rejected" {
    var buf: [1024]u8 = undefined;
    var names: [MAXWELEM][]const u8 = @splat("n");
    const tw = Message{ .tag = 1, .body = .{ .twalk = Body.Twalk.init(1, 2, &names) } };
    const n = try encode(&tw, &buf);
    const g = try decode(buf[0..n]);
    try testing.expectEqual(@as(u16, 16), g.body.twalk.nwname);
    _ = &names;

    // encode with nwname = 17 ⇒ BadMessage
    var bad = Body.Twalk{ .fid = 1, .newfid = 2, .nwname = 17 };
    for (&bad.wname) |*w| w.* = "x";
    try testing.expectError(error.BadMessage, encode(&.{ .tag = 1, .body = .{ .twalk = bad } }, &buf));

    // hand-crafted wire with nwname = 17 ⇒ decode BadMessage
    var wb = [_]u8{0} ** 64;
    std.mem.writeInt(u32, wb[0..4], 17, .little); // size (bogus but > header)
    wb[4] = @intFromEnum(Kind.twalk);
    std.mem.writeInt(u16, wb[5..7], 1, .little);
    std.mem.writeInt(u32, wb[7..11], 1, .little); // fid
    std.mem.writeInt(u32, wb[11..15], 2, .little); // newfid
    std.mem.writeInt(u16, wb[15..17], 17, .little); // nwname = 17
    std.mem.writeInt(u32, wb[0..4], 17, .little);
    try testing.expectError(error.BadMessage, decode(wb[0..17]));

    // Rwalk nwqid = 17 ⇒ encode BadMessage
    var badr = Body.Rwalk{ .nwqid = 17 };
    _ = &badr;
    try testing.expectError(error.BadMessage, encode(&.{ .tag = 1, .body = .{ .rwalk = badr } }, &buf));
    // hand-crafted rwalk nwqid = 17 ⇒ decode BadMessage
    var rb = [_]u8{0} ** 9;
    std.mem.writeInt(u32, rb[0..4], 9, .little);
    rb[4] = @intFromEnum(Kind.rwalk);
    std.mem.writeInt(u16, rb[5..7], 1, .little);
    std.mem.writeInt(u16, rb[7..9], 17, .little);
    try testing.expectError(error.BadMessage, decode(&rb));
}

test "decode: unknown and unsupported codes" {
    var buf = [_]u8{0} ** 7;
    std.mem.writeInt(u32, buf[0..4], 7, .little);
    std.mem.writeInt(u16, buf[5..7], 1, .little);
    for ([_]u8{ 99, 128 }) |code| {
        buf[4] = code;
        try testing.expectError(error.BadMessage, decode(&buf));
    }
    buf[4] = 106; // terror
    try testing.expectError(error.BadMessage, decode(&buf));
    for ([_]u8{ 102, 114, 122, 126 }) |code| {
        buf[4] = code;
        try testing.expectError(error.Unsupported, decode(&buf));
    }
}

test "rerror: UTF-8 ename" {
    var buf: [128]u8 = undefined;
    const ename = "fichier inexistant — файл";
    const m = Message{ .tag = 9, .body = .{ .rerror = .{ .ename = ename } } };
    const n = try encode(&m, &buf);
    const g = try decode(buf[0..n]);
    try testing.expectEqualStrings(ename, g.body.rerror.ename);
}

test "tags: NOTAG and boundaries" {
    var buf: [64]u8 = undefined;
    for ([_]u16{ NOTAG, 0, 0xFFFE }) |t| {
        const m = Message{ .tag = t, .body = .{ .tclunk = .{ .fid = 1 } } };
        const n = try encode(&m, &buf);
        const g = try decode(buf[0..n]);
        try testing.expectEqual(t, g.tag);
    }
}

test "encode: ShortBuffer" {
    const m = Message{ .tag = 1, .body = .{ .tversion = .{ .msize = 8192, .version = version9p } } };
    const need = encodedSize(&m);
    var buf: [64]u8 = undefined;
    try testing.expectError(error.ShortBuffer, encode(&m, buf[0 .. need - 1]));
    try testing.expectError(error.ShortBuffer, encode(&m, buf[0..0]));
    try testing.expectError(error.ShortBuffer, encode(&m, buf[0..6]));
}
