//! 9P Qid: the server's unique identity for a file. [ref: 9P2000 §Qid]
//! file-as-struct (S-07 P-1): this file *is* the Qid.
//! Wire order is type byte first, then vers, then path (convM2S.c:26 gqid),
//! which is NOT the C struct declaration order (libc.h:607-612).
const std = @import("std");

const Qid = @This();

/// Fixed on-wire size of a qid: type[1] vers[4] path[8]. [fcall.h:80 QIDSZ]
pub const wire_size: usize = 13;

/// Qid.type bit layout. [libc.h:570-576]
/// Bits 0-1 are unused in 9P2000; QTTMP is bit 2 (0x04).
pub const Type = packed struct(u8) {
    _pad: u2 = 0, // bits 0-1 unused in 9P2000
    tmp: bool = false, // 0x04 QTTMP    [libc.h:575]
    auth: bool = false, // 0x08 QTAUTH   [libc.h:574]
    mount: bool = false, // 0x10 QTMOUNT  [libc.h:573]
    excl: bool = false, // 0x20 QTEXCL   [libc.h:572]
    append: bool = false, // 0x40 QTAPPEND [libc.h:571]
    dir: bool = false, // 0x80 QTDIR    [libc.h:570]
};

path: u64,
vers: u32 = 0,
qtype: Type = .{},

/// Encode into a fixed 13-byte buffer: type[1] vers[4le] path[8le].
/// Infallible; caller (msg.zig) does bounds checks. (convM2S.c gqid order)
pub fn encode(self: Qid, buf: *[wire_size]u8) void {
    buf[0] = @bitCast(self.qtype);
    std.mem.writeInt(u32, buf[1..5], self.vers, .little);
    std.mem.writeInt(u64, buf[5..13], self.path, .little);
}

/// Decode from a fixed 13-byte buffer. Infallible. (convM2S.c:26 gqid)
pub fn decode(buf: *const [wire_size]u8) Qid {
    return .{
        .qtype = @bitCast(buf[0]),
        .vers = std.mem.readInt(u32, buf[1..5], .little),
        .path = std.mem.readInt(u64, buf[5..13], .little),
    };
}

test "qid dir bit" {
    const q = Qid{ .path = 1, .qtype = .{ .dir = true } };
    try std.testing.expect(q.qtype.dir);
    try std.testing.expectEqual(@as(u64, 1), q.path);
}

test "qid type bits match Plan 9" {
    try std.testing.expectEqual(@as(u8, 0x80), @as(u8, @bitCast(Type{ .dir = true })));
    try std.testing.expectEqual(@as(u8, 0x40), @as(u8, @bitCast(Type{ .append = true })));
    try std.testing.expectEqual(@as(u8, 0x20), @as(u8, @bitCast(Type{ .excl = true })));
    try std.testing.expectEqual(@as(u8, 0x10), @as(u8, @bitCast(Type{ .mount = true })));
    try std.testing.expectEqual(@as(u8, 0x08), @as(u8, @bitCast(Type{ .auth = true })));
    try std.testing.expectEqual(@as(u8, 0x04), @as(u8, @bitCast(Type{ .tmp = true })));
    try std.testing.expectEqual(@as(u8, 0x00), @as(u8, @bitCast(Type{})));
}

test "qid wire layout" {
    const q = Qid{
        .path = 0x0102030405060708,
        .vers = 0xAABBCCDD,
        .qtype = .{ .dir = true, .append = true },
    };
    var buf: [wire_size]u8 = undefined;
    q.encode(&buf);
    // type byte first: dir(0x80) | append(0x40) == 0xC0
    try std.testing.expectEqual(@as(u8, 0xC0), buf[0]);
    // vers little-endian
    try std.testing.expectEqualSlices(u8, &.{ 0xDD, 0xCC, 0xBB, 0xAA }, buf[1..5]);
    // path little-endian
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 }, buf[5..13]);
}

test "qid round-trip" {
    const cases = [_]Qid{
        .{ .path = 0x0102030405060708, .vers = 0xAABBCCDD, .qtype = .{ .dir = true, .append = true } },
        .{ .path = 0, .vers = 0, .qtype = .{} },
        .{ .path = std.math.maxInt(u64), .vers = std.math.maxInt(u32), .qtype = .{
            .tmp = true,
            .auth = true,
            .mount = true,
            .excl = true,
            .append = true,
            .dir = true,
        } },
    };
    for (cases) |q| {
        var buf: [wire_size]u8 = undefined;
        q.encode(&buf);
        const got = Qid.decode(&buf);
        try std.testing.expectEqual(q.path, got.path);
        try std.testing.expectEqual(q.vers, got.vers);
        try std.testing.expectEqual(@as(u8, @bitCast(q.qtype)), @as(u8, @bitCast(got.qtype)));
    }
}
