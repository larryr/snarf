//! `warp` — acme's `moveto` (mouse.c:9-12), re-expressed as a WRITE to
//! `/dev/mouse` (R-EDIT-25 as amended, ruling R-P15-3). Namespace module
//! (S-07 P-1, lowercase). Ported from larryr/plan9port@337c6ac.
//!
//! WHY THIS IS A 9P WRITE AND NOT A HOOK. Plan 9's `/dev/mouse` is read-write:
//! "writing the mouse file, in the same format, causes the mouse cursor to
//! move to the position specified by the x and y coordinates of the message"
//! (mouse(3):41-48). The kernel's `mousewrite` `case Qmouse` skips the leading
//! `m`, reads two integers with `strtoul`, and warps if the point is on screen
//! (9/port/devmouse.c:458-476). libdraw's `moveto` is exactly that write
//! (mouse.c:9-12 via `_displaymoveto`, which on plan9port becomes `Tmoveto`).
//!
//! So the core does not need to know what a host can do. It issues the SAME
//! write on every host and the namespace answers:
//!
//!   * NATIVE host — `host/devdraw/dev_input.zig` turns the write into
//!     `Tmoveto` and the pointer really moves (ADR-0005 §2).
//!   * BROWSER host — `dev/input.zig` refuses writes to `mouse` with
//!     `Rerror "permission denied"`, because no page may move the pointer
//!     (R-EDIT-25's founding divergence). The write fails, `warp` swallows the
//!     failure, and the editor behaves exactly as it did before this file
//!     existed.
//!   * ANY host with no `/dev/mouse` at all (every headless test harness,
//!     where `ed.ns` is null) — nothing happens, silently.
//!
//! EVERY failure here is swallowed by design: a warp is a courtesy, never a
//! precondition. Nothing above returns an error and nothing logs a warning —
//! a browser session would otherwise fill `+Errors` with one line per B3.
//!
//! Imports: std + `draw` + `ninep` + sibling core files. This is the one place
//! in `core` that names a device file, and it names it by PATH through the
//! session's mount table (R-OV-03) — it sees no host, no device, no shim.
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");

/// Where `/dev/mouse` lives in the session namespace (S-02 §1.3). The device
/// is mounted at `/dev` by the host's boot glue, which `core` cannot see — so,
/// like `openfile.self_mtpt`, the path is repeated here and this file is its
/// only reader.
pub const mouse_path = "/dev/mouse";

/// `moveto(mousectl, addpt(frptofchar(&t->fr, t->fr.p0), Pt(4, font->height-4)))`
/// — the shape BOTH surviving warp sites use (look.c:219 on a search hit,
/// look.c:897 after `openfile`). The point is the top-left corner of the first
/// selected character, nudged 4 px right and to just above the baseline, so the
/// pointer lands inside the highlighted run rather than on its corner.
pub fn toSelection(ed: *Editor, t: *Text) void {
    const pt = t.fr.ptOfChar(t.fr.p0);
    const h: i32 = t.fr.font.height;
    to(ed, .{ .x = pt.x + 4, .y = pt.y + h - 4 });
}

/// Ask the namespace to move the pointer to `pt`. Best effort; see the header.
pub fn to(ed: *Editor, pt: draw.proto.Point) void {
    const ns = ed.ns orelse return;
    const h = ninep.nsdir.walk(ns, mouse_path) catch return;
    defer ninep.nsdir.close(ns, h);
    const f = switch (h) {
        .fid => |x| x,
        .dir => return, // a synthesized directory is not the mouse
    };
    _ = f.client.open(f.fid, ninep.msg.OWRITE) catch return;
    var rec: [rec_len]u8 = undefined;
    format(pt.x, pt.y, &rec);
    _ = f.client.write(f.fid, 0, &rec) catch return;
}

/// A `/dev/mouse` record: `m` plus four `%11d `-padded fields
/// (devmouse.c:306-309). mouse(3) says a warp write is "in the same format",
/// and the kernel reads only the first two fields, so `buttons` and `msec` go
/// out as 0.
pub const rec_len: usize = 49;

/// Format the warp record. `{d}` with hand-rolled padding, NOT `{d:>11}`,
/// which prints a leading `+` for positive signed ints in Zig 0.16 where the
/// kernel's `%11d` never does — the same trap `dev/input.zig formatMouseRec`
/// documents. (The two formatters are deliberately independent: `core` cannot
/// import `dev`, S-07 §6.)
pub fn format(x: i32, y: i32, out: *[rec_len]u8) void {
    out[0] = 'm';
    var pos: usize = 1;
    field(out, &pos, x);
    field(out, &pos, y);
    field(out, &pos, 0);
    field(out, &pos, 0);
    std.debug.assert(pos == rec_len);
}

fn field(out: *[rec_len]u8, pos: *usize, v: i32) void {
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    var pad: usize = 11 - @min(@as(usize, 11), s.len);
    while (pad > 0) : (pad -= 1) {
        out[pos.*] = ' ';
        pos.* += 1;
    }
    @memcpy(out[pos.*..][0..s.len], s);
    pos.* += s.len;
    out[pos.*] = ' ';
    pos.* += 1;
}

// ==========================================================================
// Tests
// ==========================================================================
const testing = std.testing;

test "warp: the record is the kernel's mouse format" {
    var rec: [rec_len]u8 = undefined;
    format(100, 200, &rec);
    try testing.expectEqualStrings("m        100         200           0           0 ", &rec);
    format(-4, 0, &rec);
    try testing.expectEqualStrings("m         -4           0           0           0 ", &rec);
}

test "warp: no namespace means no warp and no failure" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try testing.expectEqual(@as(?*ninep.mount.Namespace, null), ed.ns);
    to(&ed, .{ .x = 1, .y = 2 }); // must not crash, must not error
}

// --------------------------------------------------------------------------
// A stand-in `/dev` whose `mouse` file records what was written to it. This is
// the seam a headless warp test works through: mount it at `/dev`, drive the
// editor, read `MouseSink.last`. (A test block may name `ninep.server` —
// R-P2-3; nothing outside a test does.)
// --------------------------------------------------------------------------
pub const MouseSink = struct {
    last: [rec_len]u8 = @splat(0),
    writes: usize = 0,

    pub const ops: ninep.server.Ops = .{
        .attach = attach,
        .walk1 = walk1,
        .open = open,
        .read = read,
        .write = write,
        .stat = stat,
    };

    fn self_(ctx: *anyopaque) *MouseSink {
        return @ptrCast(@alignCast(ctx));
    }
    fn attach(_: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, _: []const u8) ninep.errors.OpError!ninep.Qid {
        return .{ .path = 0, .qtype = .{ .dir = true } };
    }
    fn walk1(_: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, name: []const u8) ninep.errors.OpError!ninep.Qid {
        if (!std.mem.eql(u8, name, "mouse")) return error.FileDoesNotExist;
        return .{ .path = 1, .qtype = .{} };
    }
    fn open(_: *anyopaque, _: *ninep.server.Server, fid: *ninep.server.Fid, _: u8) ninep.errors.OpError!ninep.Qid {
        return fid.qid;
    }
    fn read(_: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, _: u64, _: []u8) ninep.errors.OpError!usize {
        return 0;
    }
    fn write(ctx: *anyopaque, _: *ninep.server.Server, _: *ninep.server.Fid, _: u64, data: []const u8) ninep.errors.OpError!usize {
        const s = self_(ctx);
        const n = @min(data.len, rec_len);
        @memcpy(s.last[0..n], data[0..n]);
        s.writes += 1;
        return data.len;
    }
    fn stat(_: *anyopaque, _: *ninep.server.Server, fid: *ninep.server.Fid) ninep.errors.OpError!ninep.stat {
        return .{ .qid = fid.qid, .mode = 0o666, .length = 0, .name = "mouse" };
    }
};

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "warp: the request reaches /dev/mouse through the namespace" {
    const a = testing.allocator;
    var sink: MouseSink = .{};
    const pipe = try ninep.chan.Pipe.init(a, 16384);
    defer pipe.deinit();
    var srv = try ninep.server.Server.init(a, pipe.serverEnd(), &MouseSink.ops, &sink, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(a, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pump };
    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");

    var ns = ninep.mount.Namespace.init(a);
    defer ns.deinit();
    try ns.mount("/dev", &cl, root.fid);

    var ed = Editor.init(a);
    defer ed.deinit();
    ed.ns = &ns;

    to(&ed, .{ .x = 100, .y = 200 });
    try testing.expectEqual(@as(usize, 1), sink.writes);
    try testing.expectEqualStrings("m        100         200           0           0 ", &sink.last);
}
