//! devinput — the Plan 9 `/dev/mouse` + `/dev/kbd` + ctl device, served over 9P.
//!
//! A single pre-namespace server (the `dev/draw.zig` precedent) exposing a tiny
//! tree — `input/{mouse,kbd,ctl}` — that turns raw shim events into the kernel's
//! logical mouse record and UTF-8 rune streams. All chord/modifier synthesis
//! lives in `profiles.zig` (wave 6a): this file owns the served tree, the mouse
//! coalescing queue, the kbd rune queue, the ctl profile/map verbs, exclusivity,
//! and the R-P6-2 park integration (a read on an empty queue returns
//! `error.WouldBlockRead` and the framework parks it; the ADAPTER re-runs it via
//! `Server.completeReads(mousePath()/kbdPath())` after a push batch — R-P6-3).
//!
//! Ground truth (cited per site):
//!   - mouse record `"m%11d %11d %11d %11lud "`, 49 bytes = 1+4*12, count clamp:
//!     `9/port/devmouse.c:306-309` (format) and `:311-312` (clamp).
//!   - blocking read semantics: `9/port/devmouse.c:272-273` — here realized as
//!     the framework park (R-P6-2), never an in-device spin.
//!   - button bits B1=1/B2=2/B3=4, wheel 8/16; kbd = whole-rune UTF-8 stream;
//!     writes to mouse/kbd => permission denied: S-04 §1/§3/§5 (ADR-0004).
//!   - keyboard.h rune constants (Kup/Kdown/…): via `profiles.zig` (4e tree,
//!     `larryr/plan9@ed1a9c2 sys/include/keyboard.h`, R-P6-7).
//!   - the `{d:>11}` +-sign trap: format `{d}` then right-pad — the `putIntField`
//!     idiom duplicated from `dev/draw.zig:522-542`.
//!
//! Imports: std, ninep (the 9P framework), and the file-local `profiles`. No
//! shim, no `src/core` (S-07 §6, R-P6-6). `RawEvent`/`Mod`/`Mods`/`LogicalMouse`
//! are DEFINED in `profiles.zig` (A3's placement ruling) and only ALIASED here.
const std = @import("std");
const ninep = @import("ninep");
const profiles = @import("profiles.zig");

const Server = ninep.server.Server;
const Fid = ninep.server.Fid;
const ReadError = ninep.server.ReadError;
const Qid = ninep.Qid;
const OpError = ninep.errors.OpError;
const Stat = ninep.stat;
const msg = ninep.msg;

// Types homed in profiles.zig (placement ruling) — alias, never redefine.
pub const RawEvent = profiles.RawEvent;
pub const Mod = profiles.Mod;
pub const Mods = profiles.Mods;
/// The kernel mouse record shape. Byte-for-byte the same as `profiles.LogicalMouse`;
/// aliased directly so the machine's output and the device's records never drift.
pub const MouseRec = profiles.LogicalMouse;

// ===========================================================================
// Mouse record wire format (devmouse.c:306-309). 49 bytes: 'm' then four
// 11-column right-justified decimal fields, each followed by one space.
// ===========================================================================

/// Fixed size of one `/dev/mouse` record (devmouse.c:311 `1+4*12`).
pub const mouse_rec_len: usize = 49;

/// Format `rec` into the 49-byte record. `x`/`y` are signed, `buttons`/`msec`
/// unsigned; all widen to `i64` and print via plain `{d}` (NO `{d:>11}`, which
/// prints a leading `+` for positive signed ints in Zig 0.16 — the kernel's
/// `snprint("%11d")` never does). This is the `putIntField` idiom from
/// `dev/draw.zig:522-542`, duplicated locally.
pub fn formatMouseRec(rec: MouseRec, out: *[mouse_rec_len]u8) void {
    out[0] = 'm';
    var pos: usize = 1;
    var tmp: [16]u8 = undefined;
    putIntField(out, &pos, &tmp, rec.x);
    putIntField(out, &pos, &tmp, rec.y);
    putIntField(out, &pos, &tmp, rec.buttons);
    putIntField(out, &pos, &tmp, rec.msec);
    std.debug.assert(pos == mouse_rec_len);
}

/// Right-justify a decimal integer in an 11-column field + one trailing space
/// (`%11d `), formatted via plain `{d}` to dodge the `+`-sign trap.
fn putIntField(out: *[mouse_rec_len]u8, pos: *usize, tmp: *[16]u8, v: i64) void {
    const s = std.fmt.bufPrint(tmp, "{d}", .{v}) catch unreachable;
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

// ===========================================================================
// MouseQueue — an ArrayList-as-deque with S-04 §5 coalescing. A "move" (a
// record whose buttons equal the previously enqueued record's buttons)
// overwrites a tail that is itself a move; a "transition" (buttons changed)
// always appends and is never dropped. This diverges from the kernel's
// qfull-discard (devmouse.c:598-604) — Snarf keeps transitions unconditionally
// (S-04 §5 / R-IN-02).
// ===========================================================================

pub const MouseQueue = struct {
    items: std.ArrayListUnmanaged(MouseRec) = .empty,
    /// Buttons of the most recently enqueued record — the "is this a move?" key.
    last_buttons: u32 = 0,
    /// Is the current tail record a coalescible move (vs a transition)?
    tail_is_move: bool = false,

    pub fn deinit(self: *MouseQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn isEmpty(self: *const MouseQueue) bool {
        return self.items.items.len == 0;
    }

    /// Enqueue `rec`, coalescing a move onto a move tail. Void (per the DevInput
    /// contract): under OOM the record is dropped — a degradation acceptable
    /// only because it implies the whole task is already failing.
    pub fn push(self: *MouseQueue, allocator: std.mem.Allocator, rec: MouseRec) void {
        const is_move = rec.buttons == self.last_buttons;
        if (is_move and self.tail_is_move and self.items.items.len > 0) {
            self.items.items[self.items.items.len - 1] = rec; // overwrite (coalesce)
        } else {
            self.items.append(allocator, rec) catch return;
            self.tail_is_move = is_move;
        }
        self.last_buttons = rec.buttons;
    }

    /// Pop the front record (FIFO), or null if empty.
    pub fn pop(self: *MouseQueue) ?MouseRec {
        if (self.items.items.len == 0) return null;
        const rec = self.items.items[0];
        _ = self.items.orderedRemove(0);
        return rec;
    }
};

// ===========================================================================
// Tree nodes, addressed by qid.path (single server, pre-namespace — no
// connection multiplexing, so the path IS the node value).
// ===========================================================================

const Node = enum(u4) {
    root = 0,
    mouse = 1,
    kbd = 2,
    ctl = 3,
};

fn qidFor(node: Node) Qid {
    return .{ .path = @intFromEnum(node), .qtype = .{ .dir = node == .root } };
}

fn nodeOf(path: u64) Node {
    return @enumFromInt(@as(u4, @intCast(path & 0xF)));
}

// ===========================================================================
// DevInput — the served device.
// ===========================================================================

pub const DevInput = struct {
    allocator: std.mem.Allocator,
    /// The active (reported) profile; always equals `machine.profile` except
    /// while a switch is deferred (then `pending_profile` holds the new one).
    profile: profiles.Profile = .native,
    machine: profiles.Machine,
    mouse_q: MouseQueue = .{},
    kbd_q: std.ArrayListUnmanaged(u8) = .empty,
    /// Single-reader exclusivity (S-04): a second concurrent open refuses.
    mouse_open: bool = false,
    kbd_open: bool = false,
    /// A profile switch requested mid-gesture, applied when the Machine idles.
    pending_profile: ?profiles.Profile = null,
    // NO parked fields, NO Server pointer (R-P6-2/3): the framework owns the
    // wait queue; the adapter drives completion via completeReads.

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .machine = profiles.Machine.init(.native) };
    }

    pub fn deinit(self: *Self) void {
        self.mouse_q.deinit(self.allocator);
        self.kbd_q.deinit(self.allocator);
        self.* = undefined;
    }

    /// The qid paths the adapter passes to `srv.completeReads` after a push
    /// batch (R-P6-3). Static — the tree is fixed.
    pub fn mousePath() u64 {
        return @intFromEnum(Node.mouse);
    }
    pub fn kbdPath() u64 {
        return @intFromEnum(Node.kbd);
    }

    // -- event intake -------------------------------------------------------

    /// THE single intake point: run `ev` through the chord machine, enqueue the
    /// synthesized mouse record(s) and/or the delivered rune, then apply any
    /// profile switch that was waiting for the Machine to idle.
    pub fn push(self: *Self, ev: RawEvent) void {
        switch (ev) {
            // Wheel fan-out is OUR job (R-P6-2 note in profiles.zig): profiles
            // treats one wheel event as ONE notch (a set/clear pulse pair), so
            // |n| notches become |n| step calls => |n| pairs in the queue.
            .wheel => |w| {
                const notches: u32 = @abs(w.notches);
                var i: u32 = 0;
                while (i < notches) : (i += 1) {
                    const one = RawEvent{ .wheel = .{ .notches = w.notches, .x = w.x, .y = w.y, .msec = w.msec } };
                    self.queueEvents(self.machine.step(one));
                }
            },
            .key => |k| {
                const r = self.machine.step(ev);
                self.queueEvents(r);
                if (r.kbd_deliver) self.enqueueRune(k.rune);
            },
            else => self.queueEvents(self.machine.step(ev)),
        }
        self.applyPendingIfIdle();
    }

    fn queueEvents(self: *Self, r: profiles.StepResult) void {
        for (r.events) |maybe| {
            if (maybe) |rec| self.mouse_q.push(self.allocator, rec);
        }
    }

    fn enqueueRune(self: *Self, rune: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(rune, &buf) catch return; // drop unencodable
        self.kbd_q.appendSlice(self.allocator, buf[0..len]) catch {};
    }

    // -- scalar push wrappers (used by the adapter / tests) -----------------

    pub fn pushPointer(self: *Self, kind: anytype, x: i32, y: i32, button: u8, msec: u32) void {
        self.push(.{ .pointer = .{ .kind = kind, .x = x, .y = y, .button = button, .msec = msec } });
    }
    pub fn pushWheel(self: *Self, notches: i32, x: i32, y: i32, msec: u32) void {
        self.push(.{ .wheel = .{ .notches = notches, .x = x, .y = y, .msec = msec } });
    }
    pub fn pushKey(self: *Self, rune: u21, mods: Mods, msec: u32) void {
        self.push(.{ .key = .{ .rune = rune, .mods = mods, .msec = msec } });
    }
    pub fn pushMod(self: *Self, kind: anytype, which: Mod, msec: u32) void {
        self.push(.{ .mod = .{ .kind = kind, .which = which, .msec = msec } });
    }

    // -- profile switching (deferred until the Machine idles) ---------------

    /// The Machine is between gestures: no sweep in progress and no buttons
    /// held, so resetting it loses nothing.
    fn machineIdle(self: *const Self) bool {
        return !self.machine.pointer_down and self.machine.buttons == 0;
    }

    fn setProfile(self: *Self, p: profiles.Profile) void {
        const mm = self.machine.mod_map; // preserve any `map` verb customization
        self.machine = profiles.Machine.init(p);
        self.machine.mod_map = mm;
        self.profile = p;
    }

    fn applyPendingIfIdle(self: *Self) void {
        if (self.pending_profile) |p| {
            if (self.machineIdle()) {
                self.setProfile(p);
                self.pending_profile = null;
            }
        }
    }

    // -- ctl file -----------------------------------------------------------

    /// Format the ctl status text. Idempotent snapshot of the active profile and
    /// modifier map (`map <slot> <2|3>` — the value is the BUTTON number, so
    /// B2=>'2', B3=>'3'), plus a fixed `uncapturable` line (browsers cannot see
    /// some chords; the concrete list is the shim's concern).
    fn ctlText(self: *const Self, out: []u8) usize {
        const an: u8 = if (self.machine.mod_map.alt == profiles.B2) '2' else '3';
        const mn: u8 = if (self.machine.mod_map.meta_or_ctrl == profiles.B2) '2' else '3';
        const s = std.fmt.bufPrint(out, "profile {s}\nmap alt {c}\nmap meta {c}\nuncapturable\n", .{
            @tagName(self.profile), an, mn,
        }) catch return 0;
        return s.len;
    }

    /// Apply one ctl write verb (R-P6-11: any malformed verb => BadMessage,
    /// reusing the error rather than minting a new OpError member).
    fn ctlWrite(self: *Self, data: []const u8) OpError!usize {
        var it = std.mem.tokenizeAny(u8, data, " \t\r\n");
        const verb = it.next() orelse return error.BadMessage;
        const eq = std.mem.eql;
        if (eq(u8, verb, "profile")) {
            const name = it.next() orelse return error.BadMessage;
            const p: profiles.Profile = if (eq(u8, name, "native"))
                .native
            else if (eq(u8, name, "modifier"))
                .modifier
            else
                return error.BadMessage; // touch/chordbar (and junk) => BadMessage until built
            if (self.machineIdle()) self.setProfile(p) else self.pending_profile = p;
        } else if (eq(u8, verb, "map")) {
            const which = it.next() orelse return error.BadMessage;
            const val = it.next() orelse return error.BadMessage;
            const bit: u32 = if (eq(u8, val, "2"))
                profiles.B2
            else if (eq(u8, val, "3"))
                profiles.B3
            else
                return error.BadMessage;
            if (eq(u8, which, "alt"))
                self.machine.mod_map.alt = bit
            else if (eq(u8, which, "meta") or eq(u8, which, "ctrl"))
                self.machine.mod_map.meta_or_ctrl = bit
            else
                return error.BadMessage;
        } else {
            return error.BadMessage;
        }
        return data.len;
    }

    // -- Ops vtable ---------------------------------------------------------

    pub const ops: ninep.server.Ops = .{
        .attach = attachOp,
        .walk1 = walk1Op,
        .open = openOp,
        .read = readOp,
        .write = writeOp,
        .clunk = clunkOp,
        .stat = statOp,
    };

    fn devOf(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    fn attachOp(_: *anyopaque, _: *Server, _: *Fid, _: []const u8) OpError!Qid {
        return qidFor(.root);
    }

    fn walk1Op(_: *anyopaque, _: *Server, fid: *Fid, name: []const u8) OpError!Qid {
        const eq = std.mem.eql;
        if (eq(u8, name, "..")) return qidFor(.root);
        return switch (nodeOf(fid.qid.path)) {
            .root => if (eq(u8, name, "mouse"))
                qidFor(.mouse)
            else if (eq(u8, name, "kbd"))
                qidFor(.kbd)
            else if (eq(u8, name, "ctl"))
                qidFor(.ctl)
            else
                error.FileDoesNotExist,
            else => error.FileDoesNotExist,
        };
    }

    fn openOp(ctx: *anyopaque, _: *Server, fid: *Fid, _: u8) OpError!Qid {
        const self = devOf(ctx);
        switch (nodeOf(fid.qid.path)) {
            // mouse/kbd are exclusive single-reader (a second open => Einuse).
            .mouse => {
                if (self.mouse_open) return error.PermissionDenied;
                self.mouse_open = true;
            },
            .kbd => {
                if (self.kbd_open) return error.PermissionDenied;
                self.kbd_open = true;
            },
            .ctl, .root => {},
        }
        return fid.qid;
    }

    fn readOp(ctx: *anyopaque, _: *Server, fid: *Fid, offset: u64, buf: []u8) ReadError!usize {
        const self = devOf(ctx);
        return switch (nodeOf(fid.qid.path)) {
            .mouse => self.readMouse(buf),
            .kbd => self.readKbd(buf),
            .ctl => self.readCtl(offset, buf),
            .root => 0, // directory read
        };
    }

    /// One record per Tread (devmouse.c: reads never straddle records). Empty
    /// queue => park (R-P6-2). A buffer shorter than 49 gets the first `count`
    /// bytes and the record is still consumed (devmouse.c:311-312 clamp).
    fn readMouse(self: *Self, buf: []u8) ReadError!usize {
        const rec = self.mouse_q.pop() orelse return error.WouldBlockRead;
        var tmp: [mouse_rec_len]u8 = undefined;
        formatMouseRec(rec, &tmp);
        const n = @min(mouse_rec_len, buf.len);
        @memcpy(buf[0..n], tmp[0..n]);
        return n;
    }

    /// As many WHOLE UTF-8 runes as fit `buf.len`, FIFO; never split a rune.
    /// Empty queue => park (R-P6-2).
    fn readKbd(self: *Self, buf: []u8) ReadError!usize {
        if (self.kbd_q.items.len == 0) return error.WouldBlockRead;
        var n: usize = 0;
        while (n < self.kbd_q.items.len) {
            const seq = std.unicode.utf8ByteSequenceLength(self.kbd_q.items[n]) catch 1;
            if (n + seq > self.kbd_q.items.len) break; // incomplete tail (shouldn't happen)
            if (n + seq > buf.len) break; // would overflow the caller's buffer
            n += seq;
        }
        if (n == 0) return 0; // buffer too small for even one rune
        @memcpy(buf[0..n], self.kbd_q.items[0..n]);
        std.mem.copyForwards(u8, self.kbd_q.items[0 .. self.kbd_q.items.len - n], self.kbd_q.items[n..]);
        self.kbd_q.shrinkRetainingCapacity(self.kbd_q.items.len - n);
        return n;
    }

    fn readCtl(self: *Self, offset: u64, buf: []u8) ReadError!usize {
        var tmp: [128]u8 = undefined;
        const len = self.ctlText(&tmp);
        if (offset >= len) return 0;
        const avail = tmp[@intCast(offset)..len];
        const n = @min(avail.len, buf.len);
        @memcpy(buf[0..n], avail[0..n]);
        return n;
    }

    fn writeOp(ctx: *anyopaque, _: *Server, fid: *Fid, _: u64, data: []const u8) OpError!usize {
        const self = devOf(ctx);
        return switch (nodeOf(fid.qid.path)) {
            .ctl => self.ctlWrite(data),
            // Writes to mouse/kbd are refused (S-04 §1 overrides the kernel's
            // cursor-warp write); the root is not writable.
            else => error.PermissionDenied,
        };
    }

    fn clunkOp(ctx: *anyopaque, _: *Server, fid: *Fid) void {
        const self = devOf(ctx);
        if (fid.omode == null) return; // never opened => no exclusivity to release
        switch (nodeOf(fid.qid.path)) {
            .mouse => self.mouse_open = false,
            .kbd => self.kbd_open = false,
            .ctl, .root => {},
        }
    }

    fn statOp(_: *anyopaque, _: *Server, fid: *Fid) OpError!Stat {
        const info: struct { name: []const u8, mode: u32 } = switch (nodeOf(fid.qid.path)) {
            .root => .{ .name = "input", .mode = Stat.DMDIR | 0o555 },
            .mouse => .{ .name = "mouse", .mode = 0o444 },
            .kbd => .{ .name = "kbd", .mode = 0o444 },
            .ctl => .{ .name = "ctl", .mode = 0o666 },
        };
        return .{ .qid = fid.qid, .mode = info.mode, .length = 0, .name = info.name };
    }
};

// ===========================================================================
// Tests — the 11 named "devinput:" cases (contract "Named tests"). A Pipe +
// Server(DevInput.ops) harness per dev/draw.zig; the park cases drive
// srv.completeReads(mousePath()/kbdPath()) after direct pushes (R-P6-3).
// ===========================================================================

const testing = std.testing;
const chan = ninep.chan;

const B1 = profiles.B1;
const B2 = profiles.B2;
const B3 = profiles.B3;

/// Heap-pinned harness: the Server holds a pointer to `dev`, so neither may move.
const Harness = struct {
    alloc: std.mem.Allocator,
    pipe: *chan.Pipe,
    dev: DevInput,
    srv: Server,
    rbuf: [1024]u8 = undefined,
    tag: u16 = 0,

    fn create(alloc: std.mem.Allocator) !*Harness {
        const self = try alloc.create(Harness);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.tag = 0;
        self.pipe = try chan.Pipe.init(alloc, 16384);
        self.dev = DevInput.init(alloc);
        self.srv = try Server.init(alloc, self.pipe.serverEnd(), &DevInput.ops, &self.dev, 8192);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.srv.deinit();
        self.dev.deinit();
        self.pipe.deinit();
        self.alloc.destroy(self);
    }

    fn nextTag(self: *Harness) u16 {
        self.tag += 1;
        return self.tag;
    }

    /// Encode `m` and let the server handle it; a parked read yields no reply.
    fn send(self: *Harness, m: msg.Message) !void {
        var enc: [2048]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        try self.pipe.clientEnd().writeMsg(enc[0..n]);
        _ = try self.srv.step();
    }

    /// Pop one decoded reply, or null when the server sent nothing (parked).
    fn recv(self: *Harness) !?msg.Message {
        const frame = self.pipe.clientEnd().readMsg(&self.rbuf) catch |e| switch (e) {
            error.WouldBlock => return null,
            else => return e,
        };
        return try msg.decode(frame);
    }

    fn transact(self: *Harness, m: msg.Message) !msg.Message {
        try self.send(m);
        return (try self.recv()) orelse error.NoReply;
    }

    fn connect(self: *Harness) !void {
        const rv = try self.transact(.{ .tag = msg.NOTAG, .body = .{ .tversion = .{ .msize = 8192, .version = msg.version9p } } });
        try testing.expect(rv.body == .rversion);
        const ra = try self.transact(.{ .tag = self.nextTag(), .body = .{ .tattach = .{ .fid = 0, .afid = msg.NOFID, .uname = "glenda", .aname = "" } } });
        try testing.expect(ra.body == .rattach);
    }

    fn walk(self: *Harness, fid: u32, newfid: u32, names: []const []const u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .twalk = msg.Body.Twalk.init(fid, newfid, names) } });
    }

    fn open(self: *Harness, fid: u32, mode: u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .topen = .{ .fid = fid, .mode = mode } } });
    }

    /// Walk root(0) → `newfid` by `name`, then open it. Asserts both succeed.
    fn walkOpen(self: *Harness, newfid: u32, name: []const u8, mode: u8) !void {
        const w = try self.walk(0, newfid, &.{name});
        try testing.expect(w.body == .rwalk);
        const o = try self.open(newfid, mode);
        try testing.expect(o.body == .ropen);
    }

    fn read(self: *Harness, fid: u32, offset: u64, count: u32) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .tread = .{ .fid = fid, .offset = offset, .count = count } } });
    }

    fn write(self: *Harness, fid: u32, data: []const u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .twrite = .{ .fid = fid, .offset = 0, .data = data } } });
    }

    fn clunk(self: *Harness, fid: u32) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .tclunk = .{ .fid = fid } } });
    }

    fn statOf(self: *Harness, fid: u32) !Stat {
        const r = try self.transact(.{ .tag = self.nextTag(), .body = .{ .tstat = .{ .fid = fid } } });
        try testing.expect(r.body == .rstat);
        return try Stat.decode(r.body.rstat.stat);
    }

    /// Read one mouse record (asserts a 49-byte Rread) into `out`.
    fn readRecord(self: *Harness, fid: u32, out: *[mouse_rec_len]u8) !void {
        const r = try self.read(fid, 0, 256);
        try testing.expect(r.body == .rread);
        try testing.expectEqual(mouse_rec_len, r.body.rread.data.len);
        @memcpy(out, r.body.rread.data[0..mouse_rec_len]);
    }
};

test "devinput: stat and walk table" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();

    const root = try h.statOf(0);
    try testing.expectEqualStrings("input", root.name);
    try testing.expectEqual(Stat.DMDIR | @as(u32, 0o555), root.mode);
    try testing.expect(root.qid.qtype.dir);

    _ = try h.walk(0, 1, &.{"mouse"});
    const mouse = try h.statOf(1);
    try testing.expectEqualStrings("mouse", mouse.name);
    try testing.expectEqual(@as(u32, 0o444), mouse.mode);
    try testing.expect(!mouse.qid.qtype.dir);

    _ = try h.walk(0, 2, &.{"kbd"});
    const kbd = try h.statOf(2);
    try testing.expectEqualStrings("kbd", kbd.name);
    try testing.expectEqual(@as(u32, 0o444), kbd.mode);

    _ = try h.walk(0, 3, &.{"ctl"});
    const ctl = try h.statOf(3);
    try testing.expectEqualStrings("ctl", ctl.name);
    try testing.expectEqual(@as(u32, 0o666), ctl.mode);

    // A missing name and a walk beneath a non-directory both fail.
    const miss = try h.walk(0, 4, &.{"nope"});
    try testing.expect(miss.body == .rerror);
    _ = try h.walk(0, 5, &.{"mouse"});
    const under = try h.walk(5, 6, &.{"x"});
    try testing.expect(under.body == .rerror);
    try testing.expectEqualStrings("walk in non-directory", under.body.rerror.ename);
}

test "devinput: mouse record byte-exactness (49-byte golden)" {
    // Direct format: the normative golden (x=102,y=33,b=1,msec=123456).
    var out: [mouse_rec_len]u8 = undefined;
    formatMouseRec(.{ .x = 102, .y = 33, .buttons = 1, .msec = 123456 }, &out);
    try testing.expectEqualStrings("m        102          33           1      123456 ", &out);
    try testing.expectEqual(@as(usize, 49), out.len);

    // Negative coordinates print WITHOUT a leading '+' (the {d:>11} trap) and
    // without an errant sign on the positive fields.
    var neg: [mouse_rec_len]u8 = undefined;
    formatMouseRec(.{ .x = -7, .y = 5, .buttons = 0, .msec = 0 }, &neg);
    try testing.expectEqualStrings("m         -7           5           0           0 ", &neg);

    // Same record delivered over the wire is byte-identical, one per Tread.
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();
    try h.walkOpen(1, "mouse", msg.OREAD);
    h.dev.pushPointer(.down, 102, 33, 0, 123456); // native button 0 => B1
    var rec: [mouse_rec_len]u8 = undefined;
    try h.readRecord(1, &rec);
    try testing.expectEqualStrings("m        102          33           1      123456 ", &rec);
}

test "devinput: R-IN-02 byte-identity — emulated chord == hardware chord" {
    const alloc = testing.allocator;

    // Hardware path (native): a real middle button (DOM button 1 => B2) down/up.
    var hardware: [2 * mouse_rec_len]u8 = undefined;
    {
        const h = try Harness.create(alloc);
        defer h.destroy();
        try h.connect();
        try h.walkOpen(1, "mouse", msg.OREAD);
        h.dev.pushPointer(.down, 40, 50, 1, 100); // B2 down
        h.dev.pushPointer(.up, 40, 50, 1, 200); // B2 up => 0
        try h.readRecord(1, hardware[0..mouse_rec_len]);
        try h.readRecord(1, hardware[mouse_rec_len..][0..mouse_rec_len]);
    }

    // Emulated path (modifier): Alt-armed B1 sweep synthesizes the same B2 chord.
    var emulated: [2 * mouse_rec_len]u8 = undefined;
    {
        const h = try Harness.create(alloc);
        defer h.destroy();
        try h.connect();
        try h.walkOpen(2, "ctl", msg.ORDWR);
        _ = try h.write(2, "profile modifier");
        try h.walkOpen(1, "mouse", msg.OREAD);
        h.dev.pushMod(.down, .alt, 90); // Armed(alt) — no record
        h.dev.pushPointer(.down, 40, 50, 0, 100); // B1-slot down, armed => B2
        h.dev.pushPointer(.up, 40, 50, 0, 200); // up => 0
        h.dev.pushMod(.up, .alt, 210); // idle Armed release — no record
        try h.readRecord(1, emulated[0..mouse_rec_len]);
        try h.readRecord(1, emulated[mouse_rec_len..][0..mouse_rec_len]);
    }

    // The concatenated Rread streams are byte-for-byte identical (R-IN-02).
    try testing.expectEqualSlices(u8, &hardware, &emulated);
}

test "devinput: coalescing — N moves one record, transitions preserved" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();
    try h.walkOpen(1, "mouse", msg.OREAD);

    // B1 down (transition), five moves with rising coords (coalesce to the
    // last), B1 up (transition) => exactly three records.
    h.dev.pushPointer(.down, 0, 0, 0, 1);
    var k: i32 = 1;
    while (k <= 5) : (k += 1) h.dev.pushPointer(.move, k, k, 0, @intCast(10 + k));
    h.dev.pushPointer(.up, 9, 9, 0, 100);

    try testing.expectEqual(@as(usize, 3), h.dev.mouse_q.items.items.len);

    var r0: [mouse_rec_len]u8 = undefined;
    var r1: [mouse_rec_len]u8 = undefined;
    var r2: [mouse_rec_len]u8 = undefined;
    try h.readRecord(1, &r0);
    try h.readRecord(1, &r1);
    try h.readRecord(1, &r2);

    // down: B1 at (0,0); coalesced move: B1 at (5,5) — the LAST move; up: 0.
    var want: [mouse_rec_len]u8 = undefined;
    formatMouseRec(.{ .x = 0, .y = 0, .buttons = B1, .msec = 1 }, &want);
    try testing.expectEqualSlices(u8, &want, &r0);
    formatMouseRec(.{ .x = 5, .y = 5, .buttons = B1, .msec = 15 }, &want);
    try testing.expectEqualSlices(u8, &want, &r1);
    formatMouseRec(.{ .x = 9, .y = 9, .buttons = 0, .msec = 100 }, &want);
    try testing.expectEqualSlices(u8, &want, &r2);

    // Queue drained: the next read parks.
    try h.send(.{ .tag = h.nextTag(), .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 256 } } });
    try testing.expect((try h.recv()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());
}

test "devinput: wheel notches" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();
    try h.walkOpen(1, "mouse", msg.OREAD);

    // Two up-notches => two (set,clear) pairs = four records: 8,0,8,0.
    h.dev.pushWheel(2, 3, 4, 7);
    try testing.expectEqual(@as(usize, 4), h.dev.mouse_q.items.items.len);
    const up_seq = [_]u32{ profiles.WHEEL_UP, 0, profiles.WHEEL_UP, 0 };
    for (up_seq) |want_b| {
        var rec: [mouse_rec_len]u8 = undefined;
        try h.readRecord(1, &rec);
        var want: [mouse_rec_len]u8 = undefined;
        formatMouseRec(.{ .x = 3, .y = 4, .buttons = want_b, .msec = 7 }, &want);
        try testing.expectEqualSlices(u8, &want, &rec);
    }

    // One down-notch => one pair: 16,0.
    h.dev.pushWheel(-1, 3, 4, 8);
    try testing.expectEqual(@as(usize, 2), h.dev.mouse_q.items.items.len);
    var d0: [mouse_rec_len]u8 = undefined;
    try h.readRecord(1, &d0);
    var want_d: [mouse_rec_len]u8 = undefined;
    formatMouseRec(.{ .x = 3, .y = 4, .buttons = profiles.WHEEL_DOWN, .msec = 8 }, &want_d);
    try testing.expectEqualSlices(u8, &want_d, &d0);
}

test "devinput: kbd UTF-8 stream + specials" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();
    try h.walkOpen(1, "kbd", msg.OREAD);

    // 'a' (61), 'é' (C3 A9), Kup=0xF00E (EF 80 8E). Native delivers every key.
    h.dev.pushKey('a', .{}, 1);
    h.dev.pushKey('\u{00E9}', .{}, 2);
    h.dev.pushKey(profiles.Kup, .{}, 3);
    try testing.expectEqualSlices(u8, &.{ 0x61, 0xC3, 0xA9, 0xEF, 0x80, 0x8E }, h.dev.kbd_q.items);

    // count=4 stops on the rune boundary: 'a'+'é' = 3 bytes, Kup would overflow.
    const r1 = try h.read(1, 0, 4);
    try testing.expect(r1.body == .rread);
    try testing.expectEqualSlices(u8, &.{ 0x61, 0xC3, 0xA9 }, r1.body.rread.data);

    // The remainder (Kup) arrives on the next read.
    const r2 = try h.read(1, 0, 256);
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0x80, 0x8E }, r2.body.rread.data);

    // Now empty => the read parks.
    try h.send(.{ .tag = h.nextTag(), .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 256 } } });
    try testing.expect((try h.recv()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());
}

test "devinput: mouse write and kbd write rejected" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();

    // Open both ORDWR (the framework allows it — files aren't directories), then
    // a Twrite is refused with "permission denied" (S-04 §1).
    try h.walkOpen(1, "mouse", msg.ORDWR);
    const wm = try h.write(1, "warp");
    try testing.expect(wm.body == .rerror);
    try testing.expectEqualStrings("permission denied", wm.body.rerror.ename);

    try h.walkOpen(2, "kbd", msg.ORDWR);
    const wk = try h.write(2, "x");
    try testing.expect(wk.body == .rerror);
    try testing.expectEqualStrings("permission denied", wk.body.rerror.ename);
}

test "devinput: exclusive readers" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();

    // First mouse open succeeds and claims the single reader slot.
    try h.walkOpen(1, "mouse", msg.OREAD);

    // A second, independent mouse fid cannot open.
    const w2 = try h.walk(0, 2, &.{"mouse"});
    try testing.expect(w2.body == .rwalk);
    const o2 = try h.open(2, msg.OREAD);
    try testing.expect(o2.body == .rerror);
    try testing.expectEqualStrings("permission denied", o2.body.rerror.ename);

    // Clunking the first frees the slot; the second fid then opens.
    const rc = try h.clunk(1);
    try testing.expect(rc.body == .rclunk);
    const o2b = try h.open(2, msg.OREAD);
    try testing.expect(o2b.body == .ropen);
}

test "devinput: ctl read/write — profile switch, map verb, bad verb" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();
    try h.walkOpen(1, "ctl", msg.ORDWR);

    // Default snapshot.
    const c0 = try h.read(1, 0, 256);
    try testing.expect(c0.body == .rread);
    try testing.expectEqualStrings("profile native\nmap alt 2\nmap meta 3\nuncapturable\n", c0.body.rread.data);

    // profile switch (idle => immediate) + a map verb, both reflected in ctl.
    _ = try h.write(1, "profile modifier");
    _ = try h.write(1, "map alt 3");
    const c1 = try h.read(1, 0, 256);
    try testing.expectEqualStrings("profile modifier\nmap alt 3\nmap meta 3\nuncapturable\n", c1.body.rread.data);

    // A bad verb and a bad argument both => "bad message" (R-P6-11).
    const bad = try h.write(1, "wobble on");
    try testing.expect(bad.body == .rerror);
    try testing.expectEqualStrings("bad message", bad.body.rerror.ename);
    const bad_prof = try h.write(1, "profile touch"); // deferred machine, BadMessage until built
    try testing.expect(bad_prof.body == .rerror);
    try testing.expectEqualStrings("bad message", bad_prof.body.rerror.ename);

    // Deferred switch mid-gesture: a B1 sweep is in progress, so the switch to
    // native is queued until the pointer lifts.
    try h.walkOpen(2, "mouse", msg.OREAD);
    h.dev.pushPointer(.down, 0, 0, 0, 1); // Sweep(B1) — machine not idle
    _ = try h.write(1, "profile native");
    const mid = try h.read(1, 0, 256);
    try testing.expectEqualStrings("profile modifier\nmap alt 3\nmap meta 3\nuncapturable\n", mid.body.rread.data);
    h.dev.pushPointer(.up, 0, 0, 0, 2); // gesture ends => pending applies
    const after = try h.read(1, 0, 256);
    // setProfile preserves the map customization across the switch.
    try testing.expectEqualStrings("profile native\nmap alt 3\nmap meta 3\nuncapturable\n", after.body.rread.data);
}

test "devinput: read blocks until push, completes with the queued record" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();
    try h.walkOpen(1, "mouse", msg.OREAD);

    // Empty queue => the Tread parks with no reply (R-P6-2).
    try h.send(.{ .tag = 70, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 256 } } });
    try testing.expect((try h.recv()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());

    // A push produces a record; the ADAPTER signals the mouse path (R-P6-3),
    // and the parked read completes with it.
    h.dev.pushPointer(.down, 7, 8, 0, 55); // B1 down
    try testing.expectEqual(@as(usize, 1), try h.srv.completeReads(DevInput.mousePath()));
    const r = (try h.recv()).?;
    try testing.expect(r.body == .rread);
    try testing.expectEqual(@as(u16, 70), r.tag);
    var want: [mouse_rec_len]u8 = undefined;
    formatMouseRec(.{ .x = 7, .y = 8, .buttons = B1, .msec = 55 }, &want);
    try testing.expectEqualSlices(u8, &want, r.body.rread.data);
    try testing.expectEqual(@as(usize, 0), h.srv.parkedCount());
}

test "devinput: Tflush cancels a parked read; next read re-parks" {
    const h = try Harness.create(testing.allocator);
    defer h.destroy();
    try h.connect();
    try h.walkOpen(1, "kbd", msg.OREAD);

    // Park a kbd read.
    try h.send(.{ .tag = 61, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 256 } } });
    try testing.expect((try h.recv()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());

    // Tflush(61): Rerror "interrupted" on the old tag FIRST, then Rflush (R-P6-5).
    try h.send(.{ .tag = 62, .body = .{ .tflush = .{ .oldtag = 61 } } });
    const e = (try h.recv()).?;
    try testing.expect(e.body == .rerror);
    try testing.expectEqual(@as(u16, 61), e.tag);
    try testing.expectEqualStrings("interrupted", e.body.rerror.ename);
    const fl = (try h.recv()).?;
    try testing.expect(fl.body == .rflush);
    try testing.expectEqual(@as(u16, 62), fl.tag);
    try testing.expectEqual(@as(usize, 0), h.srv.parkedCount());

    // A subsequent read on the still-empty queue re-parks.
    try h.send(.{ .tag = 63, .body = .{ .tread = .{ .fid = 1, .offset = 0, .count = 256 } } });
    try testing.expect((try h.recv()) == null);
    try testing.expectEqual(@as(usize, 1), h.srv.parkedCount());

    // And a late completion after data arrives still delivers to the re-parked tag.
    h.dev.pushKey('z', .{}, 9);
    try testing.expectEqual(@as(usize, 1), try h.srv.completeReads(DevInput.kbdPath()));
    const r = (try h.recv()).?;
    try testing.expect(r.body == .rread);
    try testing.expectEqual(@as(u16, 63), r.tag);
    try testing.expectEqualSlices(u8, "z", r.body.rread.data);
}

test {
    std.testing.refAllDecls(@This());
}
