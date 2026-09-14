//! devdraw's DRAW-MESSAGE DECODER: the `drawmesg` verb loop
//! (`9/port/devdraw.c:1457-1466`) that walks one `data` write's batch of
//! concatenated draw messages, the little-endian wire readers it parses with
//! (G1/G7) and the single backend-fault table it maps errors through (R-P2-4).
//!
//! Namespace module (S-07 P-1) over `*DevDraw`, split out of `draw.zig`
//! verbatim in phase 16a so that file stays inside the ~400-line cap.
//! `DevDraw` keeps a decl alias for `dispatch`, so `self.dispatch(data)` in
//! `writeOp` is unchanged. Cite as `devdraw.c:NN`.
const std = @import("std");
const ninep = @import("ninep");
const draw_backend = @import("draw_backend.zig");
const draw_font = @import("draw_font.zig");

const OpError = ninep.errors.OpError;
const DevDraw = @import("draw.zig").DevDraw;
const FChar = draw_font.FChar;
const zero_fchar = draw_font.zero_fchar;

/// Walk the batch of concatenated draw messages in one `data` write.
/// Per verb: check the remaining bytes cover the fixed message size (else
/// `ShortDraw`, G5), parse little-endian fields (G1/G7), call the backend.
/// A fault stops the loop; ops already applied stay applied (G6 — no
/// rollback). Backend faults funnel through the single `opError` table.
pub fn dispatch(self: *DevDraw, data: []const u8) OpError!void {
    var i: usize = 0;
    while (i < data.len) {
        const a = data[i..];
        switch (a[0]) {
            // 'b' — alloc: id[4]@1 screenid[4]@5 refresh[1]@9 chan[4]@10
            //   repl[1]@14 r[16]@15 clipr[16]@31 color[4]@47 (devdraw.c:1467).
            'b' => {
                if (a.len < 51) return error.ShortDraw;
                const id = rdU32(a, 1);
                if (rdU32(a, 5) != 0) return error.BadDraw; // no screens in Phase 2
                const ch = rdU32(a, 10);
                const repl = a[14] != 0;
                const r = rdRect(a, 15);
                const clipr = rdRect(a, 31);
                const color = rdU32(a, 47);
                self.backend.allocImage(id, r, ch, repl, clipr, color) catch |e| return opError(e);
                self.allocated.append(self.allocator, id) catch return error.IoError;
                i += 51;
            },
            // 'd' — draw: dstid[4]@1 srcid[4]@5 maskid[4]@9 r[16]@13 sp[8]@29
            //   mp[8]@37; always SoverD in Phase 2 (devdraw.c:1578).
            'd' => {
                if (a.len < 45) return error.ShortDraw;
                const dstid = rdU32(a, 1);
                const srcid = rdU32(a, 5);
                const maskid = rdU32(a, 9);
                const r = rdRect(a, 13);
                const sp = rdPoint(a, 29);
                const mp = rdPoint(a, 37);
                self.backend.draw(dstid, srcid, maskid, r, sp, mp) catch |e| return opError(e);
                i += 45;
            },
            // 'f' — free: id[4]@1 (devdraw.c:1640).
            'f' => {
                if (a.len < 5) return error.ShortDraw;
                const id = rdU32(a, 1);
                self.backend.freeImage(id) catch |e| return opError(e);
                self.forget(id);
                self.freeFont(id); // 'i'-promoted images drop their metrics too
                i += 5;
            },
            // 'y' — load pixels: id[4]@1 r[16]@5 data[..]@21 (devdraw.c:2082-2101).
            //   The fixed check is the 21-byte header only; the backend consumes
            //   `Dy*bytesperline` payload bytes and returns that count so the loop
            //   advances past exactly the payload — more verbs may follow (G17).
            'y' => {
                if (a.len < 21) return error.ShortDraw;
                const id = rdU32(a, 1);
                const r = rdRect(a, 5);
                const consumed = self.backend.loadPixels(id, r, a[21..]) catch |e| return opError(e);
                i += 21 + consumed;
            },
            // 'i' — init font: fontid[4]@1 nchars[4]@5 ascent[1]@9 (devdraw.c:1662-1686).
            //   id 0 (display) ⇒ BadDraw; unknown id ⇒ NoDrawImage; nchars out of
            //   (0,4096] ⇒ BadDraw. Replaces any prior metrics with a zeroed table.
            'i' => {
                if (a.len < 10) return error.ShortDraw;
                const fontid = rdU32(a, 1);
                if (fontid == 0) return error.BadDraw; // "cannot use display as font" ⇒ BadDraw (R-P3-4)
                if (!self.isAllocated(fontid)) return error.NoDrawImage;
                const nchars = rdU32(a, 5);
                if (nchars == 0 or nchars > 4096) return error.BadDraw; // "bad font size" ⇒ BadDraw
                const ascent = a[9];
                const chars = self.allocator.alloc(FChar, nchars) catch return error.IoError;
                @memset(chars, zero_fchar);
                const gop = self.fonts.getOrPut(self.allocator, fontid) catch {
                    self.allocator.free(chars);
                    return error.IoError;
                };
                if (gop.found_existing) self.allocator.free(gop.value_ptr.chars);
                gop.value_ptr.* = .{ .ascent = ascent, .chars = chars };
                i += 10;
            },
            // 'l' — load char: fontid[4]@1 srcid[4]@5 index[2]@9 r[16]@11 sp[8]@27
            //   left[1]@35 (SIGNED) width[1]@36 (devdraw.c:1688-1713). The glyph
            //   bits are stamped into the font image by an op-S copy (:1705); the
            //   metrics record the rect verbatim (miny/maxy TRUNCATED to u8, G18).
            'l' => {
                if (a.len < 37) return error.ShortDraw;
                const fontid = rdU32(a, 1);
                const font = try self.fontLadder(fontid);
                const srcid = rdU32(a, 5);
                const ci = rdU16(a, 9);
                if (ci >= font.chars.len) return error.BadIndex;
                const r = rdRect(a, 11);
                const sp = rdPoint(a, 27);
                self.backend.copy(fontid, srcid, r, sp) catch |e| return opError(e);
                font.chars[ci] = .{
                    .minx = r.min.x,
                    .maxx = r.max.x,
                    .miny = @truncate(@as(u32, @bitCast(r.min.y))),
                    .maxy = @truncate(@as(u32, @bitCast(r.max.y))),
                    .left = @bitCast(a[35]),
                    .width = a[36],
                };
                i += 37;
            },
            // 's' — string: dstid[4]@1 srcid[4]@5 fontid[4]@9 p[8]@13 clipr[16]@21
            //   sp[8]@37 ni[2]@45 indices[2·ni]@47 (devdraw.c:1949-2014). Two-stage
            //   short check: 47 header first, then +2·ni once ni is known. The wire
            //   clipr REPLACES dst.clipr for the op and is restored on every exit
            //   path (incl. BadIndex mid-string and backend faults) (:1976-2011).
            's' => {
                if (a.len < 47) return error.ShortDraw;
                const ni = rdU16(a, 45);
                if (a.len < 47 + 2 * @as(usize, ni)) return error.ShortDraw;
                const dstid = rdU32(a, 1);
                const srcid = rdU32(a, 5);
                const fontid = rdU32(a, 9);
                const p = rdPoint(a, 13); // baseline point (client added ascent)
                const clipr = rdRect(a, 21);
                var sp = rdPoint(a, 37);
                const dst_info = self.backend.imageInfo(dstid) catch |e| return opError(e);
                _ = self.backend.imageInfo(srcid) catch |e| return opError(e);
                const font = try self.fontLadder(fontid);
                const ascent: i32 = font.ascent;
                const old_clipr = dst_info.clipr;
                self.backend.setClipr(dstid, clipr) catch |e| return opError(e);
                var q = p;
                var k: usize = 0;
                while (k < ni) : (k += 1) {
                    const ci = rdU16(a, 47 + 2 * k);
                    if (ci >= font.chars.len) {
                        self.backend.setClipr(dstid, old_clipr) catch {};
                        return error.BadIndex; // prior glyphs stay painted (G5)
                    }
                    const fc = font.chars[ci];
                    const left: i32 = fc.left;
                    const miny: i32 = fc.miny;
                    // drawchar geometry (devdraw.c:894-900, G19): baseline at p.y.
                    const r = draw_backend.Rect{
                        .min = .{ .x = q.x + left, .y = p.y - (ascent - miny) },
                        .max = .{ .x = q.x + left + (fc.maxx - fc.minx), .y = p.y - (ascent - miny) + (@as(i32, fc.maxy) - miny) },
                    };
                    const sp1 = draw_backend.Point{ .x = sp.x + left, .y = sp.y + miny };
                    const mp = draw_backend.Point{ .x = fc.minx, .y = miny };
                    self.backend.draw(dstid, srcid, fontid, r, sp1, mp) catch |e| {
                        self.backend.setClipr(dstid, old_clipr) catch {};
                        return opError(e);
                    };
                    q.x += fc.width; // pen + source advance (devdraw.c:927-928)
                    sp.x += fc.width;
                }
                self.backend.setClipr(dstid, old_clipr) catch {};
                i += 47 + 2 * @as(usize, ni);
            },
            // 'v' — visible/flush: bare byte (devdraw.c:2075).
            'v' => {
                self.backend.flush();
                i += 1;
            },
            else => return error.BadDraw, // unknown verb (devdraw.c:1462 "bad draw command")
        }
    }
}

// ===========================================================================
// Fault mapping (R-P2-4). ONE table from a backend fault to a 9P Rerror.
// ===========================================================================

pub fn opError(e: draw_backend.Error) OpError {
    return switch (e) {
        error.UnknownImage => error.NoDrawImage, // "unknown id for draw image"
        error.ImageExists, error.BadChan, error.BadRect, error.Unsupported => error.BadDraw,
        error.OutOfMemory => error.IoError,
        // R-P3-9: 3a carries the opError arms for the new backend Error members; the rest of §3 is B1's.
        error.WriteOutside => error.WriteOutside,
        error.ShortData => error.BadWriteImage,
    };
}

// ===========================================================================
// Wire helpers (little-endian, G1). Coordinates are signed i32; ids/chan/color
// are u32 (devdraw.c:871-877, draw.h:508-511).
// ===========================================================================

fn rdU32(a: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, a[off..][0..4], .little);
}

fn rdU16(a: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, a[off..][0..2], .little);
}

fn rdI32(a: []const u8, off: usize) i32 {
    return std.mem.readInt(i32, a[off..][0..4], .little);
}

fn rdRect(a: []const u8, off: usize) draw_backend.Rect {
    return .{
        .min = .{ .x = rdI32(a, off + 0), .y = rdI32(a, off + 4) },
        .max = .{ .x = rdI32(a, off + 8), .y = rdI32(a, off + 12) },
    };
}

fn rdPoint(a: []const u8, off: usize) draw_backend.Point {
    return .{ .x = rdI32(a, off + 0), .y = rdI32(a, off + 4) };
}
