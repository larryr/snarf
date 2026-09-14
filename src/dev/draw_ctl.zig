//! devdraw's CONNECTION LINE (G8): the 144-byte line a read of the ctl file
//! yields — 12 fields, each right-justified in 11 columns followed by one
//! space, no newline (`9/port/devdraw.c:1197-1204`). Namespace module (S-07
//! P-1) over `*DevDraw`, split out of `draw.zig` verbatim in phase 16a so that
//! file stays inside the ~400-line cap. `DevDraw` keeps a decl alias for
//! `connLine`, so `self.connLine(&line)` in `readOp` is unchanged.
const std = @import("std");
const draw_backend = @import("draw_backend.zig");
const DevDraw = @import("draw.zig").DevDraw;
const conn_line_len = @import("draw.zig").conn_line_len;

/// Format the 144-byte connection line: 12 fields, each a value
/// right-justified in 11 columns followed by one space, no newline
/// (devdraw.c:1197-1204). Field order: clientid, infoid(0), chan string,
/// repl(0), r×4, clipr×4. Values come from `backend.displayInfo()`.
pub fn connLine(self: *DevDraw, out: *[conn_line_len]u8) void {
    const di = self.backend.displayInfo();
    var pos: usize = 0;
    var tmp: [16]u8 = undefined;
    putIntField(out, &pos, &tmp, 1); // clientid = N = 1 (G3)
    putIntField(out, &pos, &tmp, 0); // infoid
    putStrField(out, &pos, chanToStr(di.chan)); // display chan
    putIntField(out, &pos, &tmp, 0); // repl
    putIntField(out, &pos, &tmp, di.r.min.x);
    putIntField(out, &pos, &tmp, di.r.min.y);
    putIntField(out, &pos, &tmp, di.r.max.x);
    putIntField(out, &pos, &tmp, di.r.max.y);
    putIntField(out, &pos, &tmp, di.clipr.min.x);
    putIntField(out, &pos, &tmp, di.clipr.min.y);
    putIntField(out, &pos, &tmp, di.clipr.max.x);
    putIntField(out, &pos, &tmp, di.clipr.max.y);
    std.debug.assert(pos == conn_line_len);
}

/// Chan-code → its canonical string (chantostr, chan.c). Phase 2 only ever
/// emits the display chan (XRGB32); the rest round out the known set (G9).
pub fn chanToStr(ch: u32) []const u8 {
    return switch (ch) {
        draw_backend.XRGB32 => "x8r8g8b8",
        draw_backend.RGBA32 => "r8g8b8a8",
        draw_backend.RGB24 => "r8g8b8",
        draw_backend.GREY8 => "k8",
        draw_backend.GREY1 => "k1",
        else => "x8r8g8b8",
    };
}

/// Right-justify `s` in an 11-column field followed by one space (`%11s `).
fn putStrField(out: *[conn_line_len]u8, pos: *usize, s: []const u8) void {
    std.debug.assert(s.len <= 11);
    var pad: usize = 11 - s.len;
    while (pad > 0) : (pad -= 1) {
        out[pos.*] = ' ';
        pos.* += 1;
    }
    @memcpy(out[pos.*..][0..s.len], s);
    pos.* += s.len;
    out[pos.*] = ' ';
    pos.* += 1;
}

/// Right-justify a decimal integer in an 11-column field + space (`%11d `).
/// Formatted via plain `{d}` (no sign padding) into `tmp`, then justified —
/// Zig 0.16's `{d:>11}` prints a `+` for positive signed ints, which the
/// kernel's `snprint("%11d")` never does.
fn putIntField(out: *[conn_line_len]u8, pos: *usize, tmp: *[16]u8, v: i64) void {
    const s = std.fmt.bufPrint(tmp, "{d}", .{v}) catch unreachable;
    putStrField(out, pos, s);
}
