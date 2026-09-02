//! Offset-addressed directory reads. A 9P directory `Tread` returns a run of
//! whole stat(5) records; `offset` is the byte position in the virtual
//! concatenation of all records (read(5): "the offset must be zero or the
//! value returned by the previous read"). We regenerate the stream from the
//! start each time and skip records that end before `offset` — O(n²) over a
//! listing, irrelevant at export-directory scale and free of per-fid cursors.
const std = @import("std");
const ninep = @import("ninep");
const Stat = ninep.stat;

pub const DirReader = struct {
    offset: u64,
    buf: []u8,
    /// Stream position of the next record offered to `emit`.
    pos: u64 = 0,
    written: usize = 0,

    pub fn init(offset: u64, buf: []u8) DirReader {
        return .{ .offset = offset, .buf = buf };
    }

    /// Offer the next record in listing order. Returns false once the buffer
    /// cannot take another whole record — the caller may stop iterating.
    pub fn emit(self: *DirReader, st: Stat) bool {
        const n = st.encodedSize();
        const start = self.pos;
        self.pos += n;
        if (start < self.offset) return true; // before the window: skip
        if (self.written + n > self.buf.len) return false;
        _ = st.encode(self.buf[self.written..]) catch return false;
        self.written += n;
        return true;
    }

    /// Bytes produced for this read.
    pub fn len(self: *const DirReader) usize {
        return self.written;
    }
};

test "DirReader resumes at the previous read's offset" {
    const a: Stat = .{ .qid = .{ .path = 1 }, .mode = 0o444, .length = 1, .name = "a" };
    const b: Stat = .{ .qid = .{ .path = 2 }, .mode = 0o444, .length = 2, .name = "bb" };
    var buf: [256]u8 = undefined;

    // First read, buffer sized for exactly one record: gets `a` only.
    var r1 = DirReader.init(0, buf[0..a.encodedSize()]);
    try std.testing.expect(r1.emit(a));
    try std.testing.expect(!r1.emit(b));
    try std.testing.expectEqual(a.encodedSize(), r1.len());

    // Second read from the returned offset: skips `a`, gets `b`.
    var r2 = DirReader.init(a.encodedSize(), &buf);
    try std.testing.expect(r2.emit(a));
    try std.testing.expect(r2.emit(b));
    try std.testing.expectEqual(b.encodedSize(), r2.len());
    const got = try Stat.decode(buf[0..r2.len()]);
    try std.testing.expectEqualStrings("bb", got.name);
}
