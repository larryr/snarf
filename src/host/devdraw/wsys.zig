//! `wsys` — the plan9port `devdraw` window-system protocol (`drawfcall`).
//!
//! Ported from `larryr/plan9port@337c6ac`: the message set is `include/
//! drawfcall.h` (comment block + `enum`), the codec is `src/libdraw/
//! drawfcall.c` (`sizeW2M`/`convW2M`/`convM2W`/`readwsysmsg`). Cite as
//! `drawfcall.c:NN` / `drawfcall.h:NN`.
//!
//! Framing: `size[4] tag[1] type[1] body…`, `size` INCLUDING the header, all
//! integers BIG-endian (`PUT`/`GET`, drawfcall.h:57-70). `MAXWMSG` is 4 MiB.
//!
//! TWO GROUND-TRUTH CORRECTIONS to the phase-15 contract §1, both verified
//! against the pinned source and both replicated here so we stay bug-for-bug
//! compatible with the peer we actually talk to:
//!
//!  1. **Strings are `len[4] bytes`, not `len[2]`.** `_stringsize` is
//!     `4+strlen(s)` and `PUTSTRING` uses `PUT` (4 bytes), not `PUT2`
//!     (drawfcall.c:9-37).
//!  2. **`Tinit` carries only `winsize[s] label[s]`** — the header comment
//!     block advertises a third `font[s]` field that `sizeW2M`/`convW2M` never
//!     encode (drawfcall.c:80-84, :177-181).
//!
//! And one genuine BUG in the reference codec that we must reproduce exactly:
//! `Rrdmouse` writes `msec` at offset 18 and then stamps `resized` at offset
//! **19**, inside `msec`'s own four bytes (drawfcall.c:132-137, :237-242).
//! Encoder and decoder agree, so the wire is self-consistent — but bits 16..23
//! of every `msec` are destroyed, and the byte at offset 22 that the size
//! reserves for `resized` is never written. `Conn` therefore takes its
//! timestamps from the local clock, not from `Rrdmouse.msec` (see `Conn.zig`).
//!
//! This file is the CODEC only (pure, allocation-free, unit-testable);
//! `Conn.zig` is the connection. Both live under `src/host/` — the native
//! host's device layer, a peer of `src/dev/` and equally invisible to `core`
//! (S-07 §6).
const std = @import("std");
const wsys_enc = @import("wsys_enc.zig");

pub const Conn = @import("Conn.zig");
/// The connection's mux half (tags, `rpc`, the long polls, the receive path) —
/// split out of `Conn.zig` in phase 16a; `Conn` aliases every entry point, so
/// nothing calls through this name.
pub const mux = @import("mux.zig");

/// drawfcall.h:110 — `MAXWMSG`.
pub const max_msg: usize = 4 * 1024 * 1024;

/// The fixed header: `size[4] tag[1] type[1]`.
pub const header_len: usize = 6;

/// Message type codes (drawfcall.h:72-108). R-types are the T-type + 1, which
/// is how `replymsg` answers (srv.c:330-332).
pub const Kind = enum(u8) {
    rerror = 1,
    trdmouse = 2,
    rrdmouse = 3,
    tmoveto = 4,
    rmoveto = 5,
    tcursor = 6,
    rcursor = 7,
    tbouncemouse = 8,
    rbouncemouse = 9,
    trdkbd = 10,
    rrdkbd = 11,
    tlabel = 12,
    rlabel = 13,
    tinit = 14,
    rinit = 15,
    trdsnarf = 16,
    rrdsnarf = 17,
    twrsnarf = 18,
    rwrsnarf = 19,
    trddraw = 20,
    rrddraw = 21,
    twrdraw = 22,
    rwrdraw = 23,
    ttop = 24,
    rtop = 25,
    tresize = 26,
    rresize = 27,
    tcursor2 = 28,
    rcursor2 = 29,
    tctxt = 30,
    rctxt = 31,
    trdkbd4 = 32,
    rrdkbd4 = 33,
};

pub const Error = error{ ShortMessage, ShortBuffer, BadMessage };

pub const Point = struct { x: i32 = 0, y: i32 = 0 };
pub const Rect = struct { x0: i32 = 0, y0: i32 = 0, x1: i32 = 0, y1: i32 = 0 };

/// `Mouse` (mouse.h): position, button bitmap, timestamp.
pub const Mouse = struct { x: i32 = 0, y: i32 = 0, buttons: u32 = 0, msec: u32 = 0 };

/// The 1× cursor (draw.h `Cursor`): `offset[2*4] clr[2*16] set[2*16]` — the
/// same 72-byte blob Plan 9's `/dev/cursor` takes (devmouse.c:381-393).
pub const Cursor = struct {
    off: Point = .{},
    clr: [32]u8 = @splat(0),
    set: [32]u8 = @splat(0),
};

/// The 2× cursor (draw.h `Cursor2`): `offset[2*4] clr[4*32] set[4*32]`.
pub const Cursor2 = struct {
    off: Point = .{},
    clr: [128]u8 = @splat(0),
    set: [128]u8 = @splat(0),
};

/// One `Wsysmsg` (drawfcall.h:113-133) as a tagged union. Slice payloads
/// BORROW the frame they were decoded from.
pub const Msg = union(Kind) {
    rerror: []const u8,
    trdmouse,
    rrdmouse: struct { mouse: Mouse, resized: bool },
    tmoveto: Point,
    rmoveto,
    tcursor: struct { cursor: Cursor, arrow: bool },
    rcursor,
    tbouncemouse: Mouse,
    rbouncemouse,
    trdkbd,
    rrdkbd: u16,
    tlabel: []const u8,
    rlabel,
    tinit: struct { winsize: []const u8, label: []const u8 },
    rinit,
    trdsnarf,
    rrdsnarf: []const u8,
    twrsnarf: []const u8,
    rwrsnarf,
    trddraw: u32,
    rrddraw: []const u8,
    twrdraw: []const u8,
    rwrdraw: u32,
    ttop,
    rtop,
    tresize: Rect,
    rresize,
    tcursor2: struct { cursor: Cursor, cursor2: Cursor2, arrow: bool },
    rcursor2,
    tctxt: []const u8,
    rctxt,
    trdkbd4,
    rrdkbd4: u32,
};

/// `sizeW2M` (drawfcall.c:39-96) and `convW2M` (drawfcall.c:98-195) — bodies in
/// `wsys_enc.zig` since phase 16a. Decl aliases, so every call site is
/// unchanged.
pub const sizeOf = wsys_enc.sizeOf;
pub const encode = wsys_enc.encode;

fn get(buf: []const u8, off: usize) i32 {
    return @bitCast(std.mem.readInt(u32, buf[off..][0..4], .big));
}

fn getU(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .big);
}

/// `GETSTRING` (drawfcall.c:28-37), minus the in-place shift + NUL the C needs:
/// we return a borrowed slice. Errors when the length runs past the frame.
fn getString(frame: []const u8, off: usize) Error!struct { s: []const u8, next: usize } {
    if (off + 4 > frame.len) return error.ShortMessage;
    const n = getU(frame, off);
    if (off + 4 + n > frame.len) return error.ShortMessage;
    return .{ .s = frame[off + 4 ..][0..n], .next = off + 4 + n };
}

/// The declared frame length of `buf` (at least 4 bytes), for the framer.
pub fn frameLen(buf: []const u8) Error!usize {
    if (buf.len < 4) return error.ShortMessage;
    const n = getU(buf, 0);
    if (n < header_len or n > max_msg) return error.BadMessage;
    return n;
}

/// `convM2W` (drawfcall.c:197-297): decode one COMPLETE frame. Slice payloads
/// borrow `frame`. The tag is `frame[4]`.
pub fn decode(frame: []const u8) Error!Msg {
    if (frame.len < header_len) return error.ShortMessage;
    const n = try frameLen(frame);
    if (n > frame.len) return error.ShortMessage;
    const body = frame[0..n];
    // `std.meta.intToEnum` is gone in Zig 0.16; range-check by hand.
    if (body[5] < 1 or body[5] > @intFromEnum(Kind.rrdkbd4)) return error.BadMessage;
    const kind: Kind = @enumFromInt(body[5]);
    const p = 6;
    // Every fixed-size arm needs `n >= sizeOf`; the string/data arms bound-check
    // in `getString` / below.
    switch (kind) {
        .trdmouse => return .trdmouse,
        .rbouncemouse => return .rbouncemouse,
        .rmoveto => return .rmoveto,
        .rcursor => return .rcursor,
        .rcursor2 => return .rcursor2,
        .trdkbd => return .trdkbd,
        .trdkbd4 => return .trdkbd4,
        .rlabel => return .rlabel,
        .rctxt => return .rctxt,
        .rinit => return .rinit,
        .trdsnarf => return .trdsnarf,
        .rwrsnarf => return .rwrsnarf,
        .ttop => return .ttop,
        .rtop => return .rtop,
        .rresize => return .rresize,
        .rerror => return .{ .rerror = (try getString(body, p)).s },
        .tlabel => return .{ .tlabel = (try getString(body, p)).s },
        .tctxt => return .{ .tctxt = (try getString(body, p)).s },
        .rrdsnarf => return .{ .rrdsnarf = (try getString(body, p)).s },
        .twrsnarf => return .{ .twrsnarf = (try getString(body, p)).s },
        .rrdmouse => {
            if (n < p + 17) return error.ShortMessage;
            return .{
                .rrdmouse = .{
                    .mouse = .{
                        .x = get(body, p + 0),
                        .y = get(body, p + 4),
                        .buttons = getU(body, p + 8),
                        .msec = getU(body, p + 12), // see the header: byte 1 is `resized`
                    },
                    // drawfcall.c:242 `m->resized = p[19]`.
                    .resized = body[p + 13] != 0,
                },
            };
        },
        .tbouncemouse => {
            if (n < p + 12) return error.ShortMessage;
            return .{ .tbouncemouse = .{
                .x = get(body, p + 0),
                .y = get(body, p + 4),
                .buttons = getU(body, p + 8),
            } };
        },
        .tmoveto => {
            if (n < p + 8) return error.ShortMessage;
            return .{ .tmoveto = .{ .x = get(body, p + 0), .y = get(body, p + 4) } };
        },
        .tcursor => {
            if (n < p + 73) return error.ShortMessage;
            var c: Cursor = .{ .off = .{ .x = get(body, p), .y = get(body, p + 4) } };
            @memcpy(&c.clr, body[p + 8 ..][0..32]);
            @memcpy(&c.set, body[p + 40 ..][0..32]);
            return .{ .tcursor = .{ .cursor = c, .arrow = body[p + 72] != 0 } };
        },
        .tcursor2 => {
            if (n < p + 337) return error.ShortMessage;
            var c: Cursor = .{ .off = .{ .x = get(body, p), .y = get(body, p + 4) } };
            @memcpy(&c.clr, body[p + 8 ..][0..32]);
            @memcpy(&c.set, body[p + 40 ..][0..32]);
            var c2: Cursor2 = .{ .off = .{ .x = get(body, p + 72), .y = get(body, p + 76) } };
            @memcpy(&c2.clr, body[p + 80 ..][0..128]);
            @memcpy(&c2.set, body[p + 208 ..][0..128]);
            return .{ .tcursor2 = .{ .cursor = c, .cursor2 = c2, .arrow = body[p + 336] != 0 } };
        },
        .rrdkbd => {
            if (n < p + 2) return error.ShortMessage;
            return .{ .rrdkbd = std.mem.readInt(u16, body[p..][0..2], .big) };
        },
        .rrdkbd4 => {
            if (n < p + 4) return error.ShortMessage;
            return .{ .rrdkbd4 = getU(body, p) };
        },
        .tinit => {
            const ws = try getString(body, p);
            const lb = try getString(body, ws.next);
            return .{ .tinit = .{ .winsize = ws.s, .label = lb.s } };
        },
        .rrddraw, .twrdraw => {
            if (n < p + 4) return error.ShortMessage;
            const count = getU(body, p);
            if (p + 4 + count > n) return error.ShortMessage;
            const data = body[p + 4 ..][0..count];
            return if (kind == .rrddraw) .{ .rrddraw = data } else .{ .twrdraw = data };
        },
        .trddraw => {
            if (n < p + 4) return error.ShortMessage;
            return .{ .trddraw = getU(body, p) };
        },
        .rwrdraw => {
            if (n < p + 4) return error.ShortMessage;
            return .{ .rwrdraw = getU(body, p) };
        },
        .tresize => {
            if (n < p + 16) return error.ShortMessage;
            return .{ .tresize = .{
                .x0 = get(body, p + 0),
                .y0 = get(body, p + 4),
                .x1 = get(body, p + 8),
                .y1 = get(body, p + 12),
            } };
        },
    }
}

/// The tag byte of a complete frame (drawclient.c:212-220 `drawgettag`).
pub fn tagOf(frame: []const u8) u8 {
    return frame[4];
}

// ==========================================================================
// Tests — codec only (the connection's tests live in `Conn.zig`).
// ==========================================================================
const testing = std.testing;

fn roundTrip(m: Msg, buf: []u8) !Msg {
    const n = try encode(m, 7, buf);
    try testing.expectEqual(sizeOf(m), n);
    try testing.expectEqual(@as(u8, 7), tagOf(buf[0..n]));
    return decode(buf[0..n]);
}

test "wsys: every message type round-trips" {
    var buf: [1024]u8 = undefined;
    // The 15 empty-bodied types.
    const empties = [_]Msg{ .trdmouse, .rbouncemouse, .rmoveto, .rcursor, .rcursor2, .trdkbd, .trdkbd4, .rlabel, .rctxt, .rinit, .trdsnarf, .rwrsnarf, .ttop, .rtop, .rresize };
    for (empties) |m| {
        const got = try roundTrip(m, &buf);
        try testing.expectEqual(std.meta.activeTag(m), std.meta.activeTag(got));
        try testing.expectEqual(header_len, sizeOf(m));
    }
    // Mouse: note msec's byte 1 is claimed by `resized` (the reference bug).
    const rm = try roundTrip(.{ .rrdmouse = .{
        .mouse = .{ .x = -3, .y = 400, .buttons = 4, .msec = 0x11_00_33_44 },
        .resized = true,
    } }, &buf);
    try testing.expectEqual(@as(i32, -3), rm.rrdmouse.mouse.x);
    try testing.expectEqual(@as(i32, 400), rm.rrdmouse.mouse.y);
    try testing.expectEqual(@as(u32, 4), rm.rrdmouse.mouse.buttons);
    try testing.expectEqual(true, rm.rrdmouse.resized);
    try testing.expectEqual(@as(u32, 0x11_01_33_44), rm.rrdmouse.mouse.msec); // byte 1 == resized

    try testing.expectEqual(@as(i32, 12), (try roundTrip(.{ .tmoveto = .{ .x = 12, .y = -9 } }, &buf)).tmoveto.x);
    try testing.expectEqual(@as(u32, 3), (try roundTrip(.{ .tbouncemouse = .{ .x = 1, .y = 2, .buttons = 3 } }, &buf)).tbouncemouse.buttons);
    try testing.expectEqual(@as(u16, 0x263a), (try roundTrip(.{ .rrdkbd = 0x263a }, &buf)).rrdkbd);
    try testing.expectEqual(@as(u32, 0x1F600), (try roundTrip(.{ .rrdkbd4 = 0x1F600 }, &buf)).rrdkbd4);
    try testing.expectEqual(@as(u32, 144), (try roundTrip(.{ .trddraw = 144 }, &buf)).trddraw);
    try testing.expectEqual(@as(u32, 17), (try roundTrip(.{ .rwrdraw = 17 }, &buf)).rwrdraw);
    try testing.expectEqualStrings("boom", (try roundTrip(.{ .rerror = "boom" }, &buf)).rerror);
    try testing.expectEqualStrings("snarf", (try roundTrip(.{ .tlabel = "snarf" }, &buf)).tlabel);
    try testing.expectEqualStrings("id/7", (try roundTrip(.{ .tctxt = "id/7" }, &buf)).tctxt);
    try testing.expectEqualStrings("hi", (try roundTrip(.{ .rrdsnarf = "hi" }, &buf)).rrdsnarf);
    try testing.expectEqualStrings("hi", (try roundTrip(.{ .twrsnarf = "hi" }, &buf)).twrsnarf);
    try testing.expectEqualStrings("JI", (try roundTrip(.{ .twrdraw = "JI" }, &buf)).twrdraw);
    try testing.expectEqualStrings("xy", (try roundTrip(.{ .rrddraw = "xy" }, &buf)).rrddraw);
    const ti = try roundTrip(.{ .tinit = .{ .winsize = "1024x768", .label = "snarf" } }, &buf);
    try testing.expectEqualStrings("1024x768", ti.tinit.winsize);
    try testing.expectEqualStrings("snarf", ti.tinit.label);
    const tr = try roundTrip(.{ .tresize = .{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 } }, &buf);
    try testing.expectEqual(Rect{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, tr.tresize);
    var cur: Cursor = .{ .off = .{ .x = -1, .y = -1 } };
    cur.set[3] = 0xAB;
    const tc = try roundTrip(.{ .tcursor = .{ .cursor = cur, .arrow = false } }, &buf);
    try testing.expectEqual(@as(u8, 0xAB), tc.tcursor.cursor.set[3]);
    try testing.expectEqual(false, tc.tcursor.arrow);
    var c2: Cursor2 = .{};
    c2.clr[127] = 0xCD;
    const tc2 = try roundTrip(.{ .tcursor2 = .{ .cursor = cur, .cursor2 = c2, .arrow = true } }, &buf);
    try testing.expectEqual(@as(u8, 0xCD), tc2.tcursor2.cursor2.clr[127]);
    try testing.expectEqual(true, tc2.tcursor2.arrow);
}

test "wsys: framing is big-endian and size includes the header" {
    var buf: [64]u8 = undefined;
    const n = try encode(.{ .tmoveto = .{ .x = 1, .y = 2 } }, 3, &buf);
    try testing.expectEqual(@as(usize, 14), n);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 14, 3, 4, 0, 0, 0, 1, 0, 0, 0, 2 }, buf[0..n]);
    try testing.expectEqual(@as(usize, 14), try frameLen(buf[0..n]));
}

test "wsys: string fields carry a 4-byte length (NOT 2)" {
    var buf: [64]u8 = undefined;
    const n = try encode(.{ .tlabel = "ab" }, 1, &buf);
    try testing.expectEqual(@as(usize, 6 + 4 + 2), n);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 'a', 'b' }, buf[6..n]);
}

test "wsys: truncated and malformed frames are rejected" {
    var buf: [64]u8 = undefined;
    const n = try encode(.{ .tmoveto = .{ .x = 1, .y = 2 } }, 3, &buf);
    try testing.expectError(error.ShortMessage, decode(buf[0 .. n - 1]));
    try testing.expectError(error.ShortMessage, decode(buf[0..3]));
    // Unknown type byte.
    buf[5] = 99;
    try testing.expectError(error.BadMessage, decode(buf[0..n]));
    // Declared size below the header.
    var tiny = [_]u8{ 0, 0, 0, 2, 0, 0 };
    try testing.expectError(error.BadMessage, decode(&tiny));
    // A string that runs past the frame.
    var s = [_]u8{ 0, 0, 0, 12, 1, @intFromEnum(Kind.tlabel), 0, 0, 0, 99, 'a', 'b' };
    try testing.expectError(error.ShortMessage, decode(&s));
}

test "wsys: encode refuses a buffer that is too small" {
    var small: [8]u8 = undefined;
    try testing.expectError(error.ShortBuffer, encode(.{ .tmoveto = .{ .x = 1, .y = 2 } }, 1, &small));
}
