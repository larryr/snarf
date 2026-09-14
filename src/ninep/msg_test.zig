//! Tests for the 9P2000 message codec (§T-msg). Split out of `msg.zig` in phase
//! 16a (pure move — every test keeps its name) so the codec file itself stays
//! well inside the ~400-line cap; this is where the round-trip table and its
//! `expectBodyEqual`/`expectQid` deep-equal helpers live. Reached from
//! `ninep.zig`'s test block, the `core/core.zig` precedent.
const std = @import("std");
const msg = @import("msg.zig");
const Qid = @import("qid.zig");

const mut = msg.mut;
const Body = msg.Body;
const Message = msg.Message;
const Kind = msg.Kind;
const MAXWELEM = msg.MAXWELEM;
const NOTAG = msg.NOTAG;
const NOFID = msg.NOFID;
const header_size = msg.header_size;
const version9p = msg.version9p;
const OWRITE = msg.OWRITE;
const decode = msg.decode;
const encode = msg.encode;
const encodedSize = msg.encodedSize;

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
        .rflush, .rclunk, .rremove, .rwstat => {},
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
        .tcreate => |x| {
            try testing.expectEqual(x.fid, got.tcreate.fid);
            try testing.expectEqualStrings(x.name, got.tcreate.name);
            try testing.expectEqual(x.perm, got.tcreate.perm);
            try testing.expectEqual(x.mode, got.tcreate.mode);
        },
        .rcreate => |x| {
            try expectQid(x.qid, got.rcreate.qid);
            try testing.expectEqual(x.iounit, got.rcreate.iounit);
        },
        .tremove => |x| try testing.expectEqual(x.fid, got.tremove.fid),
        .twstat => |x| {
            try testing.expectEqual(x.fid, got.twstat.fid);
            try testing.expectEqualSlices(u8, x.stat, got.twstat.stat);
        },
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
    // Tauth/Rauth are the only pair still Unsupported (S-01 §2, OQ-9P-3).
    for ([_]u8{ 102, 103 }) |code| {
        buf[4] = code;
        try testing.expectError(error.Unsupported, decode(&buf));
    }
    // Phase 14a: 114/122/126 (Tcreate/Tremove/Twstat) are IMPLEMENTED, so a
    // body-less 7-byte frame is now a truncation, not an unsupported type.
    // [phase-1 ruling R5 lifted; agents/contracts/phase14a-... §3a]
    for ([_]u8{ 114, 122, 126 }) |code| {
        buf[4] = code;
        try testing.expectError(error.BadMessage, decode(&buf));
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

test "round-trip create/remove/wstat (phase 14a)" {
    // Smoke only — the full table (max-length name, empty wstat, truncation)
    // is T1 in the phase-14a contract §4.
    const q = Qid{ .path = 0x1234, .vers = 2, .qtype = .{ .dir = false } };
    const bodies = [_]Body{
        .{ .tcreate = .{ .fid = 3, .name = "newfile", .perm = 0o644, .mode = OWRITE } },
        .{ .rcreate = .{ .qid = q, .iounit = 8168 } },
        .{ .tremove = .{ .fid = 4 } },
        .rremove,
        .{ .twstat = .{ .fid = 5, .stat = &([_]u8{0x5A} ** 49) } },
        .rwstat,
    };
    var buf: [512]u8 = undefined;
    for (bodies, 0..) |b, i| {
        const m = Message{ .tag = @intCast(i), .body = b };
        const n = try encode(&m, &buf);
        try testing.expectEqual(encodedSize(&m), n);
        const got = try decode(buf[0..n]);
        try testing.expectEqual(@as(u16, @intCast(i)), got.tag);
        try expectBodyEqual(b, got.body);
    }
}

test "msg: create/remove/wstat — max-length name, empty-string wstat, truncated Tcreate (T1)" {
    const alloc = testing.allocator;

    // Max-length name: `mut.validateTcreate` accepts up to 0xFFFF bytes (a
    // string's u16 length prefix), so this pins the boundary the codec
    // itself enforces, not an arbitrary "long" name.
    const max_name = try alloc.alloc(u8, 0xFFFF);
    defer alloc.free(max_name);
    @memset(max_name, 'n');
    const buf = try alloc.alloc(u8, 0xFFFF + 64);
    defer alloc.free(buf);

    const tc = Message{ .tag = 1, .body = .{ .tcreate = .{ .fid = 9, .name = max_name, .perm = 0o644, .mode = OWRITE } } };
    {
        const n = try encode(&tc, buf);
        try testing.expectEqual(encodedSize(&tc), n);
        const got = try decode(buf[0..n]);
        try testing.expectEqualStrings(max_name, got.body.tcreate.name);
    }

    // Empty-string wstat: the codec treats `stat` as an opaque blob (its
    // validity as a stat(5) record is a different layer, checked in
    // server_mut.zig's T2/T3), so a zero-length one round-trips fine.
    const tw = Message{ .tag = 2, .body = .{ .twstat = .{ .fid = 9, .stat = &.{} } } };
    {
        const n = try encode(&tw, buf);
        const got = try decode(buf[0..n]);
        try testing.expectEqual(@as(usize, 0), got.body.twstat.stat.len);
    }

    // The rest of the mandatory set, at ordinary sizes (the phase-14a smoke
    // test above already covers Tcreate/Rcreate/Tremove/Twstat generally).
    const q = Qid{ .path = 0x99, .vers = 3, .qtype = .{ .dir = false } };
    const bodies = [_]Body{
        .{ .rcreate = .{ .qid = q, .iounit = 8168 } },
        .{ .tremove = .{ .fid = 4 } },
        .rremove,
        .rwstat,
    };
    for (bodies) |b| {
        const m = Message{ .tag = 3, .body = b };
        const n = try encode(&m, buf);
        try testing.expectEqual(encodedSize(&m), n);
        const got = try decode(buf[0..n]);
        try expectBodyEqual(b, got.body);
    }

    // A Tcreate truncated at every offset short of the full frame ⇒
    // BadMessage (mirrors "decode: truncated at every offset" above, for the
    // new body).
    const full = Message{ .tag = 5, .body = .{ .tcreate = .{ .fid = 1, .name = "abc", .perm = 0o644, .mode = OWRITE } } };
    const full_n = try encode(&full, buf);
    var i: usize = 0;
    while (i < full_n) : (i += 1) {
        try testing.expectError(error.BadMessage, decode(buf[0..i]));
    }
    _ = try decode(buf[0..full_n]); // the full frame decodes fine
}
