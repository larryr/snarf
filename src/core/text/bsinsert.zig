//! `textbsinsert` (text.c:307-364) — insert a run of runes with BACKSPACE
//! PROCESSING: a `\b` in the run erases the rune before it, and a `\b` with
//! nothing left to erase in the run eats a rune already in the file.
//!
//! Namespace module (S-07 P-1) over `*Text`, its own file so `Text.zig` stays
//! inside the ~400-line cap; `Text` keeps a decl alias, so `t.bsInsert(…)`
//! reads as a method.
//!
//! WHY IT EXISTS. Command output arrives as a byte stream that has already been
//! through a terminal-ish pipeline, so it carries the backspaces a program used
//! to overstrike or to rub out a character — `flushwarnings` (util.c:243) is
//! the writer this port has today, `xfid`'s body write (xfid.c:597) is the
//! other one in the C. Without this, an error message containing `\b` puts a
//! literal control character in an `+Errors` window.
//!
//! Ported from larryr/plan9port@337c6ac; cite as `text.c:NN`.
//!
//! Imports: `std` + sibling core files only (S-07 §6).
const std = @import("std");
const Text = @import("Text.zig");

/// Insert `bytes` at rune offset `q0`, processing `\b`. Returns the rune offset
/// the inserted run actually STARTS at — the C's return value, which differs
/// from `q0` when leading backspaces ate text already in the file (the caller
/// needs it to `show` the appended run: util.c:241-245).
///
/// `bytes` must be valid UTF-8, like every other `Text` insertion. `\b` is
/// U+0008, a single byte that can only ever stand for itself in UTF-8, so the
/// no-backspace fast path is a byte search.
pub fn bsInsert(t: *Text, q0: usize, bytes: []const u8, tofile: bool) Text.Error!usize {
    // "can't happen but safety first: mustn't backspace over file name"
    // (text.c:325-330) — a tag never gets backspace processing.
    if (t.what == .tag) {
        try t.insertAt(q0, bytes, tofile);
        return q0;
    }
    // No backspace ⇒ the C's `goto Err`, a plain insert (text.c:363).
    if (std.mem.indexOfScalar(u8, bytes, '\x08') == null) {
        try t.insertAt(q0, bytes, tofile);
        return q0;
    }

    const a = t.fr.allocator;
    // The processed run (`tp`), plus where each of its runes begins, which is
    // how `--up` becomes "drop the last rune" over UTF-8 instead of over
    // fixed-width Runes (text.c:337-345).
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(a);

    // Backspaces with nothing left to erase in the run (`up == tp` ⇒
    // `initial++`, text.c:341-342). The C copies the prefix before the first
    // `\b` and then runs this loop from there; running it from rune 0 is the
    // same function, because a later `\b` may walk `up` back into that prefix.
    var initial: usize = 0;

    const view = std.unicode.Utf8View.init(bytes) catch {
        try t.insertAt(q0, bytes, tofile); // not our contract; insert verbatim
        return q0;
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |s| {
        if (s.len == 1 and s[0] == '\x08') {
            if (starts.pop()) |at| out.items.len = at else initial += 1;
            continue;
        }
        try starts.append(a, out.items.len);
        try out.appendSlice(a, s);
    }

    // Leading backspaces eat what is already in the file, clamped at the start
    // of the text (text.c:347-352).
    var at = q0;
    if (initial > 0) {
        const del = @min(initial, at);
        at -= del;
        try t.deleteRange(at, at + del, tofile);
    }
    try t.insertAt(at, out.items, tofile); // text.c:354
    return at;
}

// ===========================================================================
// Tests — SMOKE ONLY (the named battery is the test writer's).
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");

const Fixture = struct {
    fx: draw.Frame.TestFixture,
    file: File,
    t: Text,

    fn init(seed: []const u8) !*Fixture {
        const a = testing.allocator;
        const h = try a.create(Fixture);
        errdefer a.destroy(h);
        h.fx = try draw.Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.t = try Text.init(&h.file, a, draw.proto.Rect.make(4, 20, 200, 470), h.fx.font, &h.fx.disp.image, h.fx.cols());
        try h.t.fill();
        return h;
    }
    fn deinit(h: *Fixture) void {
        h.t.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    /// The whole buffer as UTF-8, caller-owned.
    fn text(h: *Fixture, a: std.mem.Allocator) ![]u8 {
        const n = h.file.buffer.len();
        const dst = try a.alloc(u8, n * Buffer.max_bytes_per_rune + 1);
        defer a.free(dst);
        return a.dupe(u8, h.file.buffer.read(0, n, dst));
    }
};

test "bsinsert: a backspace erases the rune before it (text.c:307-364)" {
    const a = testing.allocator;
    const h = try Fixture.init("abc");
    defer h.deinit();

    // No backspace: a plain insert, q0 unchanged.
    try testing.expectEqual(@as(usize, 3), try h.t.bsInsert(3, "de", true));

    // Inside the run: "xy\bz" is "xz".
    try testing.expectEqual(@as(usize, 5), try h.t.bsInsert(5, "xy\x08z", true));
    {
        const got = try h.text(a);
        defer a.free(got);
        try testing.expectEqualStrings("abcdexz", got);
    }

    // Leading backspaces eat what is already there, and the return value is
    // where the run actually landed (text.c:347-352).
    const at = try h.t.bsInsert(h.file.buffer.len(), "\x08\x08Q", true);
    try testing.expectEqual(@as(usize, 5), at);
    {
        const got = try h.text(a);
        defer a.free(got);
        try testing.expectEqualStrings("abcdeQ", got);
    }
}

test "bsinsert: backspaces are clamped at the start, and multi-byte runes go whole" {
    const a = testing.allocator;
    const h = try Fixture.init("ab");
    defer h.deinit();

    // Four backspaces with two runes in front of them: clamped, not underflow.
    try testing.expectEqual(@as(usize, 0), try h.t.bsInsert(2, "\x08\x08\x08\x08z", true));
    {
        const got = try h.text(a);
        defer a.free(got);
        try testing.expectEqualStrings("z", got);
    }

    // A backspace erases a RUNE, not a byte.
    _ = try h.t.bsInsert(1, "caf\u{e9}\x08\u{e8}", true);
    const got = try h.text(a);
    defer a.free(got);
    try testing.expectEqualStrings("zcaf\u{e8}", got);
}
