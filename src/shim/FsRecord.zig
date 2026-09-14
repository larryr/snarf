//! The `fsOp` operation record — the binary language the module speaks to the
//! browser's Origin Private File System (ABI v6, S-06 §4, R-P14b-6).
//!
//! file-as-struct (S-07 P-1): this file *is* one request record. It carries the
//! codec for both directions — the REQUEST the module encodes and hands to the
//! `fsOp` import, and the small COMPLETION payloads the shim hands back through
//! the `fsPush` export. Everything is little-endian, like 9P itself.
//!
//! Wire layout of a request (`fs_op_version` 2):
//!
//!     op[1] pathlen[2] path[pathlen] arg0[8] arg1[4] payloadlen[4] payload[…]
//!
//! `path` is an absolute path inside the OPFS root, `/`-rooted and never
//! empty: the root itself is `"/"`, a child of the root `"/notes"`, a leaf
//! `"/a/b.txt"`. It is UTF-8, has no `.`/`..` components and no trailing
//! slash, so the JS side can split on `/`, drop the empty leading element and
//! walk `getDirectoryHandle` down the result.
//!
//! Per-op argument meanings:
//!
//!     stat        (1) — no args.               reply: isdir[1] size[8] mtime_ms[8]
//!     list        (2) — no args.               reply: {isdir[1] namelen[2] name[…]}*
//!     read        (3) — arg0=offset arg1=count reply: the bytes (may be short/empty at EOF)
//!     write       (4) — arg0=offset            reply: count[4]
//!                       arg1=flags (bit0 = truncate first; RESERVED, always 0
//!                       in v1 — OTRUNC is its own `truncate` op)
//!                       payload = the data
//!     create_file (5) — arg1=perm (masked per `5/open`; OPFS stores no mode,
//!                       so it is advisory). reply: empty
//!     create_dir  (6) — as create_file.        reply: empty
//!     remove      (7) — no args.               reply: empty
//!     truncate    (8) — arg0=new length.       reply: empty
//!     close       (9) — no args.               reply: empty
//!
//! `close` (version 2) is the counterpart of the browser's `createWritable`.
//! A `FileSystemWritableFileStream` writes to a swap file until it is closed,
//! so the v1 backend had to open and close one PER WRITE — three platform
//! round trips for every 9P Twrite. Since v2 the backend keeps the stream open
//! across a write sequence on one path and closes it when the module says so:
//! `DevOpfs.clunkOp` issues `close` for any fid that wrote. It is a HINT, not
//! a fence — the backend also closes the stream before any op that must see
//! the file's committed contents — so a `close` that never arrives (a session
//! that ends mid-write) costs nothing but a late commit.
//! Every completion also carries a `Status`; a non-`ok` status means the
//! payload is empty and the device turns the code into an Rerror (the mapping
//! lives in `dev/opfs.zig`, which is the only place that may name `ninep`).
//!
//! JS MIRROR (`web/opfs.js`) — these integers must agree, exactly as `WS_KIND`
//! and `EventKind` do:
//!
//!     const FS_OP = { stat:1, list:2, read:3, write:4,
//!                     create_file:5, create_dir:6, remove:7, truncate:8,
//!                     close:9 };
//!     const FS_STATUS = { ok:0, not_found:1, exists:2, not_dir:3, is_dir:4,
//!                         permission:5, quota:6, not_empty:7, io:8 };
//!     const FS_OP_VERSION = 2;
//!
//! Imports: `std` only (S-07 §6) — this file is part of the `shim` module and
//! must stay nameable from a native test root.
const std = @import("std");

const FsRecord = @This();

/// The record format generation. Bumped if the layout above ever changes;
/// re-exported as `abi.fs_op_version` and mirrored in JS as `FS_OP_VERSION`.
/// 2 adds `Op.close` (16b item 4); the byte layout is untouched, so a v1
/// backend still decodes every v1 op — it would simply answer `io` to the new
/// one, which is exactly what the module's fire-and-forget `close` tolerates.
pub const version: u32 = 2;

/// What the module is asking the browser to do.
pub const Op = enum(u8) {
    stat = 1,
    list = 2,
    read = 3,
    write = 4,
    create_file = 5,
    create_dir = 6,
    remove = 7,
    truncate = 8,
    /// Version 2. [see the header: the `createWritable` lifetime]
    close = 9,
};

/// How it went. `ok` alone means the payload is meaningful; every other code
/// is a failure the device maps to a Plan 9 Rerror string.
pub const Status = enum(u8) {
    ok = 0,
    not_found = 1,
    exists = 2,
    not_dir = 3,
    is_dir = 4,
    permission = 5,
    quota = 6,
    not_empty = 7,
    io = 8,
};

/// Fixed part of the record: op[1] pathlen[2] … arg0[8] arg1[4] payloadlen[4].
pub const fixed_len: usize = 1 + 2 + 8 + 4 + 4;

/// `pathlen` is a u16, so this is the hard ceiling on a path.
pub const max_path: usize = std.math.maxInt(u16);

op: Op,
path: []const u8,
arg0: u64 = 0,
arg1: u32 = 0,
payload: []const u8 = &.{},

/// Bytes this record occupies on the wire.
pub fn encodedSize(self: *const FsRecord) usize {
    return fixed_len + self.path.len + self.payload.len;
}

/// Encode into `buf`; returns the byte count. `BadRecord` if the path or the
/// payload exceeds what its length field can express.
pub fn encode(self: *const FsRecord, buf: []u8) error{ ShortBuffer, BadRecord }!usize {
    if (self.path.len > max_path) return error.BadRecord;
    if (self.payload.len > std.math.maxInt(u32)) return error.BadRecord;
    const total = self.encodedSize();
    if (buf.len < total) return error.ShortBuffer;
    buf[0] = @intFromEnum(self.op);
    std.mem.writeInt(u16, buf[1..3], @intCast(self.path.len), .little);
    var pos: usize = 3;
    @memcpy(buf[pos..][0..self.path.len], self.path);
    pos += self.path.len;
    std.mem.writeInt(u64, buf[pos..][0..8], self.arg0, .little);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], self.arg1, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(self.payload.len), .little);
    pos += 4;
    @memcpy(buf[pos..][0..self.payload.len], self.payload);
    pos += self.payload.len;
    std.debug.assert(pos == total);
    return total;
}

/// Decode a record. `path`/`payload` are zero-copy sub-slices of `buf` and are
/// valid only as long as it is. `BadRecord` on an unknown op or any truncation.
pub fn decode(buf: []const u8) error{BadRecord}!FsRecord {
    if (buf.len < fixed_len) return error.BadRecord;
    const op: Op = switch (buf[0]) {
        1...9 => @enumFromInt(buf[0]), // range-checked (no std.meta.intToEnum in 0.16)
        else => return error.BadRecord,
    };
    const pathlen = std.mem.readInt(u16, buf[1..3], .little);
    if (buf.len < 3 + @as(usize, pathlen) + 16) return error.BadRecord;
    var pos: usize = 3;
    const path = buf[pos..][0..pathlen];
    pos += pathlen;
    const arg0 = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    const arg1 = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    const plen = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    if (buf.len - pos != plen) return error.BadRecord; // exact fit: no trailing slop
    return .{ .op = op, .path = path, .arg0 = arg0, .arg1 = arg1, .payload = buf[pos..] };
}

// ---------------------------------------------------------------------------
// Completion payloads
// ---------------------------------------------------------------------------

/// The `stat` reply: `isdir[1] size[8] mtime_ms[8]`.
pub const StatReply = struct {
    pub const len: usize = 1 + 8 + 8;

    is_dir: bool,
    size: u64 = 0,
    mtime_ms: u64 = 0,

    pub fn encode(self: StatReply, buf: *[len]u8) void {
        buf[0] = @intFromBool(self.is_dir);
        std.mem.writeInt(u64, buf[1..9], self.size, .little);
        std.mem.writeInt(u64, buf[9..17], self.mtime_ms, .little);
    }

    pub fn decode(buf: []const u8) error{BadRecord}!StatReply {
        if (buf.len < len) return error.BadRecord;
        return .{
            .is_dir = buf[0] != 0,
            .size = std.mem.readInt(u64, buf[1..9], .little),
            .mtime_ms = std.mem.readInt(u64, buf[9..17], .little),
        };
    }
};

/// One entry of the `list` reply: `isdir[1] namelen[2] name[…]`.
pub const ListEntry = struct {
    is_dir: bool,
    name: []const u8,

    pub fn encodedSize(self: ListEntry) usize {
        return 3 + self.name.len;
    }

    pub fn encode(self: ListEntry, buf: []u8) error{ ShortBuffer, BadRecord }!usize {
        if (self.name.len > max_path) return error.BadRecord;
        if (buf.len < self.encodedSize()) return error.ShortBuffer;
        buf[0] = @intFromBool(self.is_dir);
        std.mem.writeInt(u16, buf[1..3], @intCast(self.name.len), .little);
        @memcpy(buf[3..][0..self.name.len], self.name);
        return self.encodedSize();
    }
};

/// Walks a `list` reply. A malformed tail ends the iteration rather than
/// trapping: the shim is the one place a bug could produce one, and a short
/// listing is a better failure than a panic in the editor.
pub const ListIter = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *ListIter) ?ListEntry {
        if (self.pos + 3 > self.buf.len) return null;
        const is_dir = self.buf[self.pos] != 0;
        const n = std.mem.readInt(u16, self.buf[self.pos + 1 ..][0..2], .little);
        const start = self.pos + 3;
        if (start + n > self.buf.len) return null;
        self.pos = start + n;
        return .{ .is_dir = is_dir, .name = self.buf[start..][0..n] };
    }
};

/// The `write` reply: `count[4]`. A missing/short payload reads as 0 written.
pub fn decodeWriteCount(payload: []const u8) u32 {
    if (payload.len < 4) return 0;
    return std.mem.readInt(u32, payload[0..4], .little);
}

// ===========================================================================
// Tests — round trips (contract §4 T1's home).
// ===========================================================================
const testing = std.testing;

test "FsRecord: round-trips every op (T1)" {
    var buf: [256]u8 = undefined;
    const cases = [_]FsRecord{
        .{ .op = .stat, .path = "/" },
        .{ .op = .list, .path = "/a/b" },
        .{ .op = .read, .path = "/f", .arg0 = 1 << 40, .arg1 = 8192 },
        .{ .op = .write, .path = "/f", .arg0 = 7, .arg1 = 1, .payload = "hello" },
        .{ .op = .create_file, .path = "/d/new", .arg1 = 0o644 },
        .{ .op = .create_dir, .path = "/d/sub", .arg1 = 0o755 },
        .{ .op = .remove, .path = "/d/sub" },
        .{ .op = .truncate, .path = "/f", .arg0 = 0 },
        .{ .op = .close, .path = "/f" }, // version 2
    };
    for (cases) |c| {
        const n = try c.encode(&buf);
        try testing.expectEqual(c.encodedSize(), n);
        const got = try decode(buf[0..n]);
        try testing.expectEqual(c.op, got.op);
        try testing.expectEqualStrings(c.path, got.path);
        try testing.expectEqual(c.arg0, got.arg0);
        try testing.expectEqual(c.arg1, got.arg1);
        try testing.expectEqualStrings(c.payload, got.payload);
    }
}

test "FsRecord: empty payload, long path, short buffer, bad op (T1)" {
    var path: [max_path]u8 = undefined;
    @memset(&path, 'x');
    path[0] = '/';
    const rec: FsRecord = .{ .op = .stat, .path = &path };
    const big = try testing.allocator.alloc(u8, rec.encodedSize());
    defer testing.allocator.free(big);
    const n = try rec.encode(big);
    const got = try decode(big[0..n]);
    try testing.expectEqual(@as(usize, max_path), got.path.len);
    try testing.expectEqual(@as(usize, 0), got.payload.len);

    var small: [4]u8 = undefined;
    try testing.expectError(error.ShortBuffer, rec.encode(&small));

    // Unknown op byte, truncation, and trailing slop are all BadRecord.
    var buf: [64]u8 = undefined;
    const m = try (FsRecord{ .op = .stat, .path = "/a" }).encode(&buf);
    buf[0] = 10; // one past `close`, the highest op in version 2
    try testing.expectError(error.BadRecord, decode(buf[0..m]));
    buf[0] = 0;
    try testing.expectError(error.BadRecord, decode(buf[0..m]));
    buf[0] = 1;
    try testing.expectError(error.BadRecord, decode(buf[0 .. m - 1]));
    try testing.expectError(error.BadRecord, decode(buf[0 .. m + 1]));
    try testing.expectError(error.BadRecord, decode(buf[0..3]));
}

test "FsRecord: stat/list/write reply payloads" {
    var sb: [StatReply.len]u8 = undefined;
    (StatReply{ .is_dir = true, .size = 0, .mtime_ms = 1_700_000_000_123 }).encode(&sb);
    const sr = try StatReply.decode(&sb);
    try testing.expect(sr.is_dir);
    try testing.expectEqual(@as(u64, 1_700_000_000_123), sr.mtime_ms);
    try testing.expectError(error.BadRecord, StatReply.decode(sb[0..3]));

    var lb: [64]u8 = undefined;
    var pos: usize = 0;
    pos += try (ListEntry{ .is_dir = true, .name = "sub" }).encode(lb[pos..]);
    pos += try (ListEntry{ .is_dir = false, .name = "f.txt" }).encode(lb[pos..]);
    var it = ListIter{ .buf = lb[0..pos] };
    const a = it.next().?;
    try testing.expect(a.is_dir);
    try testing.expectEqualStrings("sub", a.name);
    const b = it.next().?;
    try testing.expect(!b.is_dir);
    try testing.expectEqualStrings("f.txt", b.name);
    try testing.expectEqual(@as(?ListEntry, null), it.next());

    var wb: [4]u8 = undefined;
    std.mem.writeInt(u32, &wb, 4096, .little);
    try testing.expectEqual(@as(u32, 4096), decodeWriteCount(&wb));
    try testing.expectEqual(@as(u32, 0), decodeWriteCount(&.{}));
}

test "FsRecord: op and status integers match the JS mirror (T1)" {
    try testing.expectEqual(@as(u32, 2), version);
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Op.stat));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Op.list));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Op.read));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Op.write));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(Op.create_file));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(Op.create_dir));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(Op.remove));
    try testing.expectEqual(@as(u8, 8), @intFromEnum(Op.truncate));
    try testing.expectEqual(@as(u8, 9), @intFromEnum(Op.close)); // version 2
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Status.ok));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Status.not_found));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Status.exists));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Status.not_dir));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Status.is_dir));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(Status.permission));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(Status.quota));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(Status.not_empty));
    try testing.expectEqual(@as(u8, 8), @intFromEnum(Status.io));
}
