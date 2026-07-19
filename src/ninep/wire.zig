//! wire.zig — little-endian 9P field cursors (ninep-internal, S-07 §6).
//! Extracted from msg.zig per the §2 overflow rule so the message switch stays
//! under the ~400-line soft cap. All integers are little-endian (fcall.h:65-74
//! GBIT/PBIT). Strings are `len[2]` + bytes, no NUL (convM2S.c:6 gstring).
const std = @import("std");
const Qid = @import("qid.zig");

/// Bounded reader over an immutable frame. All `get*` return zero-copy
/// sub-slices that alias the underlying buffer; `error.BadMessage` on overrun.
pub const Reader = struct {
    b: []const u8,
    pos: usize = 0,

    pub fn init(b: []const u8) Reader {
        return .{ .b = b };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.b.len - self.pos;
    }

    fn take(self: *Reader, n: usize) error{BadMessage}![]const u8 {
        if (n > self.remaining()) return error.BadMessage;
        const s = self.b[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn get8(self: *Reader) error{BadMessage}!u8 {
        return (try self.take(1))[0];
    }

    pub fn get16(self: *Reader) error{BadMessage}!u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    pub fn get32(self: *Reader) error{BadMessage}!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    pub fn get64(self: *Reader) error{BadMessage}!u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    /// `len[2]` + `len` bytes, returned as a sub-slice (zero-copy).
    pub fn getString(self: *Reader) error{BadMessage}![]const u8 {
        const n = try self.get16();
        return self.take(n);
    }

    /// Raw `n` bytes, zero-copy.
    pub fn getBytes(self: *Reader, n: usize) error{BadMessage}![]const u8 {
        return self.take(n);
    }

    pub fn getQid(self: *Reader) error{BadMessage}!Qid {
        const s = try self.take(Qid.wire_size);
        return Qid.decode(s[0..Qid.wire_size]);
    }
};

/// Bounded writer over a mutable frame. `error.ShortBuffer` if a put would
/// exceed the buffer. Callers that pre-size the buffer via `encodedSize` never
/// see the error, but the checks keep every put memory-safe.
pub const Writer = struct {
    b: []u8,
    pos: usize = 0,

    pub fn init(b: []u8) Writer {
        return .{ .b = b };
    }

    fn room(self: *Writer, n: usize) error{ShortBuffer}![]u8 {
        if (self.pos + n > self.b.len) return error.ShortBuffer;
        const s = self.b[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn put8(self: *Writer, v: u8) error{ShortBuffer}!void {
        (try self.room(1))[0] = v;
    }

    pub fn put16(self: *Writer, v: u16) error{ShortBuffer}!void {
        std.mem.writeInt(u16, (try self.room(2))[0..2], v, .little);
    }

    pub fn put32(self: *Writer, v: u32) error{ShortBuffer}!void {
        std.mem.writeInt(u32, (try self.room(4))[0..4], v, .little);
    }

    pub fn put64(self: *Writer, v: u64) error{ShortBuffer}!void {
        std.mem.writeInt(u64, (try self.room(8))[0..8], v, .little);
    }

    pub fn putString(self: *Writer, s: []const u8) error{ShortBuffer}!void {
        try self.put16(@intCast(s.len));
        @memcpy(try self.room(s.len), s);
    }

    pub fn putBytes(self: *Writer, s: []const u8) error{ShortBuffer}!void {
        @memcpy(try self.room(s.len), s);
    }

    pub fn putQid(self: *Writer, q: Qid) error{ShortBuffer}!void {
        const s = try self.room(Qid.wire_size);
        q.encode(s[0..Qid.wire_size]);
    }
};

test "wire: reader/writer round-trip primitives" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try w.put8(0xAB);
    try w.put16(0x1234);
    try w.put32(0xDEADBEEF);
    try w.put64(0x0102030405060708);
    try w.putString("hi");
    try w.putQid(.{ .path = 9, .vers = 3, .qtype = .{ .dir = true } });

    var r = Reader.init(buf[0..w.pos]);
    try std.testing.expectEqual(@as(u8, 0xAB), try r.get8());
    try std.testing.expectEqual(@as(u16, 0x1234), try r.get16());
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.get32());
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), try r.get64());
    try std.testing.expectEqualStrings("hi", try r.getString());
    const q = try r.getQid();
    try std.testing.expectEqual(@as(u64, 9), q.path);
    try std.testing.expect(q.qtype.dir);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "wire: reader overrun is BadMessage" {
    var r = Reader.init(&.{ 1, 2 });
    try std.testing.expectError(error.BadMessage, r.get32());
    var r2 = Reader.init(&.{ 5, 0, 1, 2 }); // string len 5, only 2 bytes
    try std.testing.expectError(error.BadMessage, r2.getString());
}

test "wire: writer short buffer" {
    var buf: [2]u8 = undefined;
    var w = Writer.init(&buf);
    try std.testing.expectError(error.ShortBuffer, w.put32(1));
}
