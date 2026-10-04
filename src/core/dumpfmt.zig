//! The dump file's line codecs — acme's `rowdump1`/`rowload` format
//! (rows.c:317-462, :559-844 at larryr/plan9port@337c6ac), shared by
//! `RowDump.zig` (writing) and `RowLoad.zig` (reading) so the two cannot
//! drift. Namespace module (S-07 P-1). Cite as `rows.c:NN`.
//!
//! The format (R-P17-6: acme's, verbatim, so a Snarf dump reads like an acme
//! one):
//!
//!     <wdir>
//!     <font 0>
//!     <font 1>
//!     <%11.7f column-left percent>{ <…>}            one 12-byte field per column
//!     w <row tag, first line>
//!     c%11d <column tag, first line>                 one per column
//!     f%11d %11d %11d %11d %11.7f <font>             col, id, q0, q1, y-percent
//!     F%11d %11d %11d %11d %11.7f %11d <font>        col, j, q0, q1, y-percent, RUNES
//!     <winctlprint: five %11d fields><tag, '\n' as byte 0xff>
//!     <body: exactly RUNES runes>                    F records only
//!
//! Every numeric field is 11 wide plus one separator, so field `k` of a window
//! record starts at byte `1 + 12k` (rows.c:762-766 `l+1+k*12`); acme reads them
//! with `atoi`/`atof`, which skip leading blanks and stop at the first
//! character they cannot use — so do these.
//!
//! Imports: `std` only.
const std = @import("std");

/// The window-record kinds (rows.c:701-731). `x` (a zerox) and `e` (an
/// external program's window) are never written by Snarf and are skipped with
/// a warning on load (R-P17-6).
pub const Kind = enum { f, F, x, e };

/// One parsed window record line (without its '\n').
pub const WinRec = struct {
    kind: Kind,
    col: usize,
    /// `w->id` for `f`, the window's index in its column for `F` (rows.c:409/:417).
    id: usize,
    q0: usize,
    q1: usize,
    /// Window top as a percent of the column height.
    pct: f64,
    /// `F` only: the body's rune count (rows.c:731 `atoi(l+1+5*12+1)`).
    ndumped: ?usize,
    /// Borrowed from the line; "" for the default font.
    font: []const u8,
};

/// Bytes before the tag text on a ctl+tag line (`winctlprint`'s five `%11d `
/// fields, wind.c:690; rows.c:789 `l+5*12`).
pub const ctl_len: usize = 60;

// --------------------------------------------------------------------------
// Writing
// --------------------------------------------------------------------------

/// `%11d`, unsigned (Zig's `{d:>11}` on a SIGNED int prints a `+`; see
/// `Window.ctlPrint`).
pub fn writeInt(w: *std.Io.Writer, v: usize) std.Io.Writer.Error!void {
    try w.print("{d:>11}", .{v});
}

/// `%11.7f`.
pub fn writePct(w: *std.Io.Writer, p: f64) std.Io.Writer.Error!void {
    try w.print("{d:>11.7}", .{p});
}

/// A window record line (rows.c:406-420), '\n' included.
pub fn writeWinRec(w: *std.Io.Writer, r: WinRec) std.Io.Writer.Error!void {
    try w.writeByte(switch (r.kind) {
        .f => 'f',
        .F => 'F',
        .x => 'x',
        .e => 'e',
    });
    for ([_]usize{ r.col, r.id, r.q0, r.q1 }) |v| {
        try writeInt(w, v);
        try w.writeByte(' ');
    }
    try writePct(w, r.pct);
    try w.writeByte(' ');
    if (r.ndumped) |n| {
        try writeInt(w, n);
        try w.writeByte(' ');
    }
    try w.print("{s}\n", .{r.font});
}

/// Tag text with every '\n' as the byte 0xff ("invalid UTF", rows.c:431-436).
pub fn writeTag(w: *std.Io.Writer, tag: []const u8) std.Io.Writer.Error!void {
    for (tag) |c| try w.writeByte(if (c == '\n') 0xff else c);
}

/// The text before the first '\n' (rows.c:344-347 / :354-357).
pub fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

// --------------------------------------------------------------------------
// Reading
// --------------------------------------------------------------------------

/// C `atoi`: leading blanks, optional sign, digits; 0 when there are none.
/// Negative values clamp to 0 (every field here is a count or a position).
pub fn atoi(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var v: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v *| 10 +| (s[i] - '0');
    }
    return if (neg) 0 else v;
}

/// C `atof`: leading blanks, then the longest numeric prefix; 0 when none.
pub fn atof(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var j = i;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (!((c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E')) break;
    }
    return std.fmt.parseFloat(f64, s[i..j]) catch 0;
}

/// The column-percent line (rows.c:607-615): `linelen/12` fields (the '\n'
/// counted, as `Blinelen` does), `1..10` of them, each `0 <= p < 100`. Null
/// when malformed.
pub fn parsePcts(line: []const u8, out: *[10]f64) ?[]f64 {
    const j = (line.len + 1) / 12;
    if (j == 0 or j > 10) return null;
    for (0..j) |i| {
        const off = i * 12;
        if (off >= line.len) return null;
        const p = atof(line[off..]);
        if (p < 0 or p >= 100) return null;
        out[i] = p;
    }
    return out[0..j];
}

/// A window record line (rows.c:686-760), without its '\n'. Null when it is
/// not one or is too short (`Blinelen(b) < 1+5*12+1`, `< 1+6*12+1` for `F`).
pub fn parseWinRec(line: []const u8) ?WinRec {
    if (line.len == 0) return null;
    const kind: Kind = switch (line[0]) {
        'f' => .f,
        'F' => .F,
        'x' => .x,
        'e' => .e,
        else => return null,
    };
    const nfields: usize = if (kind == .F) 6 else 5;
    if (line.len + 1 < 1 + nfields * 12 + 1) return null;
    const field = struct {
        fn at(l: []const u8, k: usize) []const u8 {
            return l[1 + k * 12 ..];
        }
    }.at;
    return .{
        .kind = kind,
        .col = atoi(field(line, 0)),
        .id = atoi(field(line, 1)),
        .q0 = atoi(field(line, 2)),
        .q1 = atoi(field(line, 3)),
        .pct = atof(field(line, 4)),
        .ndumped = if (kind == .F) atoi(field(line, 5)) else null,
        .font = line[@min(line.len, 1 + nfields * 12)..],
    };
}

/// The tag half of a ctl+tag line with 0xff turned back into '\n'
/// (rows.c:785-788). Owned. Empty when the line is shorter than the ctl.
pub fn tagOf(a: std.mem.Allocator, line: []const u8) error{OutOfMemory}![]u8 {
    if (line.len <= ctl_len) return a.alloc(u8, 0);
    const out = try a.dupe(u8, line[ctl_len..]);
    for (out) |*c| {
        if (c.* == 0xff) c.* = '\n';
    }
    return out;
}

/// Byte length of the first `n` runes of `bytes`, counted exactly as
/// `Buffer` counts them (an invalid byte is one rune — Buffer.zig `runeStep`),
/// so an `F` body written as `writeRaw` bytes and `buffer.len()` runes reads
/// back to the same text. Null when `bytes` holds fewer than `n` runes
/// (rows.c:812-818 `Beof` ⇒ bad load file).
pub fn runeBytes(bytes: []const u8, n: usize) ?usize {
    var i: usize = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (i >= bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        const ok = i + len <= bytes.len and if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| true else |_| false;
        i += if (ok) len else 1;
    }
    return i;
}

// ==========================================================================
// Smoke test. The named battery (T15) is the test writer's.
// ==========================================================================
const testing = std.testing;

test "dumpfmt: a window record round-trips through its codec" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeWinRec(&w, .{ .kind = .F, .col = 1, .id = 2, .q0 = 3, .q1 = 4, .pct = 12.5, .ndumped = 7, .font = "" });
    const line = w.buffered();
    try testing.expectEqualStrings("F          1           2           3           4  12.5000000           7 \n", line);
    const r = parseWinRec(line[0 .. line.len - 1]).?;
    try testing.expectEqual(Kind.F, r.kind);
    try testing.expectEqual(@as(usize, 7), r.ndumped.?);
    try testing.expectEqual(@as(f64, 12.5), r.pct);
    try testing.expectEqual(@as(?usize, 3), runeBytes("a\xffb", 3));
}
