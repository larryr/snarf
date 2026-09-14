//! The `wsys` ENCODE half: `sizeW2M` + `convW2M` (drawfcall.c:39-96, :98-195)
//! and the two write helpers they use. Namespace module (S-07 P-1) split out of
//! `wsys.zig` verbatim in phase 16a so that file stays inside the ~400-line
//! cap; `wsys` re-exports `sizeOf` and `encode` as decl aliases, so every call
//! site (`Conn.encodeAlloc`, `mux.send`, the codec tests) is unchanged.
//!
//! Ported from `larryr/plan9port@337c6ac` `src/libdraw/drawfcall.c`; cite as
//! `drawfcall.c:NN`. Strings are `len[4] bytes` — NOT 9P's `len[2]`.
const std = @import("std");
const wsys = @import("wsys.zig");

const Msg = wsys.Msg;
const Error = wsys.Error;
const Kind = wsys.Kind;
const header_len = wsys.header_len;
const max_msg = wsys.max_msg;

/// `sizeW2M` (drawfcall.c:39-96): the whole frame length, header included.
pub fn sizeOf(m: Msg) usize {
    return switch (m) {
        .trdmouse, .rbouncemouse, .rmoveto, .rcursor, .rcursor2, .trdkbd, .trdkbd4, .rlabel, .rctxt, .rinit, .trdsnarf, .rwrsnarf, .ttop, .rtop, .rresize => header_len,
        .rrdmouse => header_len + 4 + 4 + 4 + 4 + 1,
        .tbouncemouse => header_len + 4 + 4 + 4,
        .tmoveto => header_len + 4 + 4,
        .tcursor => header_len + 4 + 4 + 32 + 32 + 1,
        .tcursor2 => header_len + 4 + 4 + 32 + 32 + 4 + 4 + 128 + 128 + 1,
        .rerror => |s| header_len + 4 + s.len,
        .rrdkbd => header_len + 2,
        .rrdkbd4 => header_len + 4,
        .tlabel => |s| header_len + 4 + s.len,
        .tctxt => |s| header_len + 4 + s.len,
        .tinit => |i| header_len + 4 + i.winsize.len + 4 + i.label.len,
        .rrdsnarf, .twrsnarf => |s| header_len + 4 + s.len,
        .rrddraw, .twrdraw => |d| header_len + 4 + d.len,
        .trddraw, .rwrdraw => header_len + 4,
        .tresize => header_len + 4 * 4,
    };
}

fn put(buf: []u8, off: usize, v: i64) void {
    const u: u32 = @bitCast(@as(i32, @truncate(v)));
    std.mem.writeInt(u32, buf[off..][0..4], u, .big);
}

/// `PUTSTRING` (drawfcall.c:16-26): `len[4] bytes`. Returns bytes written.
fn putString(buf: []u8, off: usize, s: []const u8) usize {
    put(buf, off, @intCast(s.len));
    @memcpy(buf[off + 4 ..][0..s.len], s);
    return 4 + s.len;
}

/// `convW2M` (drawfcall.c:98-195): encode `m` with `tag` into `buf`, returning
/// the frame length. `error.ShortBuffer` when `buf` cannot hold it.
pub fn encode(m: Msg, tag: u8, buf: []u8) Error!usize {
    const n = sizeOf(m);
    if (buf.len < n) return error.ShortBuffer;
    if (n > max_msg) return error.BadMessage;
    put(buf, 0, @intCast(n));
    buf[4] = tag;
    buf[5] = @intFromEnum(std.meta.activeTag(m));
    const p = 6;
    switch (m) {
        .trdmouse, .rbouncemouse, .rmoveto, .rcursor, .rcursor2, .trdkbd, .trdkbd4, .rlabel, .rctxt, .rinit, .trdsnarf, .rwrsnarf, .ttop, .rtop, .rresize => {},
        .rerror, .tlabel, .tctxt, .rrdsnarf, .twrsnarf => |s| _ = putString(buf, p, s),
        .rrdmouse => |r| {
            put(buf, p + 0, r.mouse.x);
            put(buf, p + 4, r.mouse.y);
            put(buf, p + 8, r.mouse.buttons);
            put(buf, p + 12, r.mouse.msec);
            // drawfcall.c:137 `p[19] = m->resized` — offset 19 is INSIDE msec
            // (which starts at 18). Reproduced verbatim: see the file header.
            buf[p + 13] = @intFromBool(r.resized);
        },
        .tbouncemouse => |mo| {
            put(buf, p + 0, mo.x);
            put(buf, p + 4, mo.y);
            put(buf, p + 8, mo.buttons);
        },
        .tmoveto => |pt| {
            put(buf, p + 0, pt.x);
            put(buf, p + 4, pt.y);
        },
        .tcursor => |c| {
            put(buf, p + 0, c.cursor.off.x);
            put(buf, p + 4, c.cursor.off.y);
            @memcpy(buf[p + 8 ..][0..32], &c.cursor.clr);
            @memcpy(buf[p + 40 ..][0..32], &c.cursor.set);
            buf[p + 72] = @intFromBool(c.arrow);
        },
        .tcursor2 => |c| {
            put(buf, p + 0, c.cursor.off.x);
            put(buf, p + 4, c.cursor.off.y);
            @memcpy(buf[p + 8 ..][0..32], &c.cursor.clr);
            @memcpy(buf[p + 40 ..][0..32], &c.cursor.set);
            put(buf, p + 72, c.cursor2.off.x);
            put(buf, p + 76, c.cursor2.off.y);
            @memcpy(buf[p + 80 ..][0..128], &c.cursor2.clr);
            @memcpy(buf[p + 208 ..][0..128], &c.cursor2.set);
            buf[p + 336] = @intFromBool(c.arrow);
        },
        .rrdkbd => |r| std.mem.writeInt(u16, buf[p..][0..2], r, .big),
        .rrdkbd4 => |r| put(buf, p, r),
        .tinit => |i| {
            var off: usize = p;
            off += putString(buf, off, i.winsize);
            _ = putString(buf, off, i.label);
        },
        .rrddraw, .twrdraw => |d| {
            put(buf, p, @intCast(d.len));
            @memcpy(buf[p + 4 ..][0..d.len], d);
        },
        .trddraw, .rwrdraw => |c| put(buf, p, c),
        .tresize => |r| {
            put(buf, p + 0, r.x0);
            put(buf, p + 4, r.y0);
            put(buf, p + 8, r.x1);
            put(buf, p + 12, r.y1);
        },
    }
    return n;
}
