//! stat(5) directory-entry codec. file-as-struct (S-07 P-1): this file *is*
//! the Stat. [ref: fcall.h:82-84 STATFIXLEN, convD2M/convM2D field order]
//!
//! Wire layout (all little-endian; a string s = len[2] + len bytes, no NUL):
//!   size[2] type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8]
//!   name[s] uid[s] gid[s] muid[s]
//! `size` counts the bytes AFTER itself, so the whole blob is `2 + size` bytes.
//! With all-empty strings the blob is STATFIXLEN = 49 bytes (size field == 47).
const std = @import("std");
const Qid = @import("qid.zig");

const Stat = @This();

/// Fixed-length portion of a stat blob, empty strings. [fcall.h:84]
/// 2(size)+2(type)+4(dev)+13(qid)+4(mode)+4(atime)+4(mtime)+8(length)+4*2(str lens)
pub const STATFIXLEN: usize = 49;

/// Mode bit for directories, mirrors qid dir bit. [libc.h:580 DMDIR]
pub const DMDIR: u32 = 0x8000_0000;

ktype: u16 = 0, // "for kernel use" (server type)
kdev: u32 = 0, // "for kernel use" (server subtype)
qid: Qid,
mode: u32,
atime: u32 = 0,
mtime: u32 = 0,
length: u64,
name: []const u8,
uid: []const u8 = "snarf",
gid: []const u8 = "snarf",
muid: []const u8 = "snarf",

/// Total bytes this Stat occupies on the wire, including the leading size[2].
pub fn encodedSize(self: *const Stat) usize {
    return STATFIXLEN + self.name.len + self.uid.len + self.gid.len + self.muid.len;
}

/// Encode into `buf`; returns bytes written. `ShortBuffer` if `buf` is too
/// small, `BadMessage` if any string exceeds 0xFFFF bytes.
pub fn encode(self: *const Stat, buf: []u8) error{ ShortBuffer, BadMessage }!usize {
    for ([_][]const u8{ self.name, self.uid, self.gid, self.muid }) |s| {
        if (s.len > 0xFFFF) return error.BadMessage;
    }
    const total = self.encodedSize();
    if (buf.len < total) return error.ShortBuffer;

    // size field counts everything after itself.
    std.mem.writeInt(u16, buf[0..2], @intCast(total - 2), .little);
    std.mem.writeInt(u16, buf[2..4], self.ktype, .little);
    std.mem.writeInt(u32, buf[4..8], self.kdev, .little);
    self.qid.encode(buf[8..21]);
    std.mem.writeInt(u32, buf[21..25], self.mode, .little);
    std.mem.writeInt(u32, buf[25..29], self.atime, .little);
    std.mem.writeInt(u32, buf[29..33], self.mtime, .little);
    std.mem.writeInt(u64, buf[33..41], self.length, .little);

    var pos: usize = 41;
    for ([_][]const u8{ self.name, self.uid, self.gid, self.muid }) |s| {
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(s.len), .little);
        pos += 2;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    std.debug.assert(pos == total);
    return total;
}

/// Decode a stat blob. Strings are zero-copy sub-slices of `buf`; they are
/// valid only as long as `buf` is. `BadMessage` on any truncation or overrun.
pub fn decode(buf: []const u8) error{BadMessage}!Stat {
    if (buf.len < 2) return error.BadMessage;
    const size = std.mem.readInt(u16, buf[0..2], .little);
    const total = 2 + @as(usize, size);
    if (buf.len < total or total < STATFIXLEN) return error.BadMessage;

    var s: Stat = .{
        .ktype = std.mem.readInt(u16, buf[2..4], .little),
        .kdev = std.mem.readInt(u32, buf[4..8], .little),
        .qid = Qid.decode(buf[8..21]),
        .mode = std.mem.readInt(u32, buf[21..25], .little),
        .atime = std.mem.readInt(u32, buf[25..29], .little),
        .mtime = std.mem.readInt(u32, buf[29..33], .little),
        .length = std.mem.readInt(u64, buf[33..41], .little),
        .name = undefined,
        .uid = undefined,
        .gid = undefined,
        .muid = undefined,
    };

    var pos: usize = 41;
    const fields = [_]*[]const u8{ &s.name, &s.uid, &s.gid, &s.muid };
    for (fields) |dst| {
        if (pos + 2 > total) return error.BadMessage;
        const n = std.mem.readInt(u16, buf[pos..][0..2], .little);
        pos += 2;
        if (pos + n > total) return error.BadMessage;
        dst.* = buf[pos..][0..n];
        pos += n;
    }
    return s;
}

test "stat round-trip" {
    const dir = Stat{
        .qid = .{ .path = 42, .vers = 1, .qtype = .{ .dir = true } },
        .mode = DMDIR | 0o755,
        .atime = 100,
        .mtime = 200,
        .length = 0,
        .name = "sub",
    };
    const file = Stat{
        .ktype = 7,
        .kdev = 9,
        .qid = .{ .path = 43, .vers = 2 },
        .mode = 0o644,
        .atime = 111,
        .mtime = 222,
        .length = 13,
        .name = "index",
        .uid = "glenda",
        .gid = "users",
        .muid = "glenda",
    };
    for ([_]Stat{ dir, file }) |st| {
        var buf: [256]u8 = undefined;
        const n = try st.encode(&buf);
        try std.testing.expectEqual(st.encodedSize(), n);
        const got = try Stat.decode(buf[0..n]);
        try std.testing.expectEqual(st.ktype, got.ktype);
        try std.testing.expectEqual(st.kdev, got.kdev);
        try std.testing.expectEqual(st.qid.path, got.qid.path);
        try std.testing.expectEqual(st.qid.vers, got.qid.vers);
        try std.testing.expectEqual(@as(u8, @bitCast(st.qid.qtype)), @as(u8, @bitCast(got.qid.qtype)));
        try std.testing.expectEqual(st.mode, got.mode);
        try std.testing.expectEqual(st.atime, got.atime);
        try std.testing.expectEqual(st.mtime, got.mtime);
        try std.testing.expectEqual(st.length, got.length);
        try std.testing.expectEqualStrings(st.name, got.name);
        try std.testing.expectEqualStrings(st.uid, got.uid);
        try std.testing.expectEqualStrings(st.gid, got.gid);
        try std.testing.expectEqualStrings(st.muid, got.muid);
    }
}

test "stat size field" {
    const st = Stat{
        .qid = .{ .path = 1 },
        .mode = 0,
        .length = 0,
        .name = "",
        .uid = "",
        .gid = "",
        .muid = "",
    };
    var buf: [64]u8 = undefined;
    const n = try st.encode(&buf);
    try std.testing.expectEqual(@as(usize, 49), n);
    try std.testing.expectEqual(@as(u16, 47), std.mem.readInt(u16, buf[0..2], .little));
}

test "stat truncated" {
    const st = Stat{
        .qid = .{ .path = 5, .qtype = .{ .dir = true } },
        .mode = DMDIR,
        .length = 0,
        .name = "notes",
    };
    var buf: [128]u8 = undefined;
    const n = try st.encode(&buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try std.testing.expectError(error.BadMessage, Stat.decode(buf[0..i]));
    }
    // Full buffer decodes fine.
    _ = try Stat.decode(buf[0..n]);
}

test "stat mode dir bit" {
    // The codec passes mode verbatim; DMDIR<->qid.dir consistency is caller
    // policy, not enforced here.
    const st = Stat{
        .qid = .{ .path = 1 }, // qid says plain file...
        .mode = DMDIR, // ...but mode says dir; codec must not object.
        .length = 0,
        .name = "x",
    };
    var buf: [128]u8 = undefined;
    const n = try st.encode(&buf);
    const got = try Stat.decode(buf[0..n]);
    try std.testing.expectEqual(DMDIR, got.mode);
    try std.testing.expect(!got.qid.qtype.dir);
}
