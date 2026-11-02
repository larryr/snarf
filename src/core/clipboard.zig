//! `clipboard` — acme's `acmeputsnarf`/`acmegetsnarf` (acme.c:1088-1138 @337c6ac):
//! the snarf buffer synced with `/dev/snarf` (#12, R-EDIT-14, R-9P-07).
//! Namespace module (S-07 P-1, lowercase).
//!
//! Like `warp`, this is a file in the session namespace, not a host hook. The
//! core names `/dev/snarf` by PATH and the namespace answers:
//!
//!   * NATIVE host — `host/devdraw/dev_input.zig` serves it: a read is
//!     `Trdsnarf` (the macOS pasteboard), and a write is buffered until the
//!     Tclunk and then sent as ONE `Twrsnarf` (S-02 §3, #31).
//!   * BROWSER host (frozen) — its `/dev` has no `snarf`, the walk fails, and
//!     the internal buffer behaves exactly as before (CB-09).
//!   * No namespace (headless harnesses) — nothing happens.
//!
//! Every failure is swallowed, as in acme (`putsnarf`/`getsnarf` return
//! nothing): the internal buffer is always the fallback, so Snarf/Paste keep
//! working inside snarf when the host clipboard does not.
//!
//! Imports: std + `ninep` + sibling core files (S-07 §6).
const std = @import("std");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");

/// Where the clipboard lives in the session namespace (S-02 §1.3 table).
pub const snarf_path = "/dev/snarf";

/// The most `get` reads (acme's file ceiling, R-EDIT-10).
pub const max_bytes: usize = 64 << 20;

/// `acmeputsnarf` (acme.c:1094-1116): the snarf buffer becomes the host
/// clipboard. An empty buffer, like acme's `s[0]==0` guard, writes nothing.
/// One OTRUNC open, a Twrite loop at increasing offsets, one clunk — the
/// device replaces the clipboard at the clunk.
pub fn put(ed: *Editor) void {
    if (ed.snarf.items.len == 0) return;
    const ns = ed.ns orelse return;
    // A NUL ends the C string `putsnarf` sends (acme.c:1113-1114).
    const data = if (std.mem.indexOfScalar(u8, ed.snarf.items, 0)) |z| ed.snarf.items[0..z] else ed.snarf.items;
    if (data.len == 0) return;
    const h = ninep.nsdir.walk(ns, snarf_path) catch return;
    defer ninep.nsdir.close(ns, h);
    const f = switch (h) {
        .fid => |x| x,
        .dir => return,
    };
    _ = f.client.open(f.fid, ninep.msg.OWRITE | ninep.msg.OTRUNC) catch return;
    const chunk = @max(f.client.ioMax(), 1);
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(chunk, data.len - off);
        const w = f.client.write(f.fid, off, data[off..][0..n]) catch return;
        if (w == 0) return;
        off += w;
    }
}

/// `acmegetsnarf` (acme.c:1119-1138): if the host clipboard holds text, it
/// replaces the snarf buffer. An empty or unreadable clipboard leaves the
/// buffer as it was (acme's `s == nil || s[0]==0` return), so text snarfed
/// inside snarf still pastes when the host has nothing.
///
/// The bytes are taken as acme's `cvttorunes` would (util.c:39-69): reading
/// stops at the first NUL (`getsnarf` returns a C string), and each byte that
/// is not part of valid UTF-8 becomes U+FFFD, so the buffer stays valid UTF-8
/// (`snarf.snarfInsert` counts its runes).
pub fn get(ed: *Editor) void {
    const ns = ed.ns orelse return;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(ed.allocator);
    readAll(ed.allocator, ns, &raw) catch return;
    const text = if (std.mem.indexOfScalar(u8, raw.items, 0)) |z| raw.items[0..z] else raw.items;
    if (text.len == 0) return;
    var clean: std.ArrayList(u8) = .empty;
    errdefer clean.deinit(ed.allocator);
    sanitize(ed.allocator, text, &clean) catch {
        clean.deinit(ed.allocator);
        return;
    };
    ed.snarf.deinit(ed.allocator);
    ed.snarf = clean;
}

fn readAll(gpa: std.mem.Allocator, ns: *const ninep.mount.Namespace, out: *std.ArrayList(u8)) !void {
    const h = try ninep.nsdir.walk(ns, snarf_path);
    defer ninep.nsdir.close(ns, h);
    const f = switch (h) {
        .fid => |x| x,
        .dir => return error.IsDir,
    };
    _ = try f.client.open(f.fid, ninep.msg.OREAD);
    var buf: [8192]u8 = undefined;
    const want = @min(buf.len, @max(f.client.ioMax(), 1));
    while (true) {
        const n = try f.client.read(f.fid, out.items.len, buf[0..want]);
        if (n == 0) return;
        if (out.items.len + n > max_bytes) return error.TooBig;
        try out.appendSlice(gpa, buf[0..n]);
    }
}

/// Copy `in` to `out`, one U+FFFD per byte that does not start a valid UTF-8
/// sequence (chartorune's Runeerror, one byte consumed).
pub fn sanitize(gpa: std.mem.Allocator, in: []const u8, out: *std.ArrayList(u8)) !void {
    try out.ensureTotalCapacity(gpa, in.len);
    var i: usize = 0;
    while (i < in.len) {
        const len = std.unicode.utf8ByteSequenceLength(in[i]) catch 0;
        if (len != 0 and i + len <= in.len) {
            if (std.unicode.utf8Decode(in[i..][0..len])) |_| {
                try out.appendSlice(gpa, in[i..][0..len]);
                i += len;
                continue;
            } else |_| {}
        }
        try out.appendSlice(gpa, "\u{FFFD}");
        i += 1;
    }
}

test "clipboard: sanitize keeps valid UTF-8 and replaces each bad byte" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try sanitize(a, "caf\xc3\xa9 \xf0\x9f\x98\x80 \xff\xc3", &out);
    try std.testing.expectEqualStrings("caf\xc3\xa9 \xf0\x9f\x98\x80 \u{FFFD}\u{FFFD}", out.items);
}

test "clipboard: no namespace means no sync and no failure" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.snarf.appendSlice(std.testing.allocator, "x");
    put(&ed);
    get(&ed);
    try std.testing.expectEqualStrings("x", ed.snarf.items);
}
