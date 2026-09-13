//! input_pump — the wasm entry point's `/dev/mouse` + `/dev/kbd` drain
//! (R-P6-4, R-P6-12).
//!
//! Split out of `main_wasm.zig` so the entry point stays near the ~400-line cap
//! (S-07, R-P12c-5); the logic is unchanged from the phase-6 adapter. Like
//! `screen.zig` it takes BORROWED pointers rather than the entry point's `App`
//! struct, so it holds no state of its own (no globals) and does not have to see
//! the boot context.
//!
//! This is adapter code, not policy: every gesture decision belongs to
//! `core.Editor` (R-P6-12) and every chord/profile decision to the input device
//! (ADR-0004). All that happens here is "a record completed → hand it over →
//! re-arm the standing read".
const std = @import("std");
const core = @import("core");
const ninep = @import("ninep");

/// The two standing device reads, as borrowed pointers into the entry point's
/// long-lived boot context. `ticket_*` are pointers because a completed read is
/// re-armed IN PLACE — the new ticket has to land back in the caller's storage.
/// `*_buf` are the ticket-backing buffers `beginRead` borrowed and must not move.
pub const Devices = struct {
    srv: *ninep.server.Server,
    cl: *ninep.Client,
    mouse_fid: u32,
    kbd_fid: u32,
    ticket_mouse: *ninep.Client.ReadTicket,
    ticket_kbd: *ninep.Client.ReadTicket,
    mouse_buf: []u8,
    kbd_buf: []u8,
};

/// Drain every mouse record and kbd rune the input device can produce right now,
/// routing each through the Editor and re-arming the standing ticket. Each loop
/// polls the input server first: a poll parks the standing read when the queue is
/// empty (→ checkRead null → done) or serves it immediately when a record is
/// queued (→ checkRead a byte count → handle → re-arm → loop).
pub fn drain(d: Devices, editor: *core.Editor) !void {
    // Mouse: one 49-byte record per completion.
    while (true) {
        _ = try d.srv.poll();
        const n = (try d.cl.checkRead(d.ticket_mouse.*)) orelse break;
        if (parseMouseRec(d.mouse_buf[0..n])) |ev| try editor.handleMouse(ev);
        d.ticket_mouse.* = try d.cl.beginRead(d.mouse_fid, 0, d.mouse_buf);
    }
    // Kbd: a UTF-8 burst; decode whole runes and hand each to the Editor.
    while (true) {
        _ = try d.srv.poll();
        const n = (try d.cl.checkRead(d.ticket_kbd.*)) orelse break;
        var i: usize = 0;
        while (i < n) {
            const seq = std.unicode.utf8ByteSequenceLength(d.kbd_buf[i]) catch {
                i += 1;
                continue;
            };
            if (i + seq > n) break; // never split a rune (device guarantees whole runes)
            const r = std.unicode.utf8Decode(d.kbd_buf[i .. i + seq]) catch {
                i += seq;
                continue;
            };
            try editor.handleKey(@intCast(r));
            i += seq;
        }
        d.ticket_kbd.* = try d.cl.beginRead(d.kbd_fid, 0, d.kbd_buf);
    }
}

/// Parse a `/dev/mouse` record ("m" + four space-padded decimal fields) into an
/// Editor.MouseEvent. Skips the leading 'm', then trim-parses the four ints
/// (devmouse.c:306-309 format). Returns null on any malformation.
fn parseMouseRec(rec: []const u8) ?core.Editor.MouseEvent {
    if (rec.len < 1 or rec[0] != 'm') return null;
    var it = std.mem.tokenizeScalar(u8, rec[1..], ' ');
    const xs = it.next() orelse return null;
    const ys = it.next() orelse return null;
    const bs = it.next() orelse return null;
    const ts = it.next() orelse return null;
    const x = std.fmt.parseInt(i32, xs, 10) catch return null;
    const y = std.fmt.parseInt(i32, ys, 10) catch return null;
    const b = std.fmt.parseInt(u32, bs, 10) catch return null;
    const ms = std.fmt.parseInt(u32, ts, 10) catch return null;
    return .{ .x = x, .y = y, .buttons = @truncate(b), .msec = ms };
}
