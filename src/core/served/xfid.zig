//! xfid — the served tree's PER-FILE read/write logic (acme's `xfid.c` FILE
//! half, wave 10b-B3). `served/fsys.zig` (wave 10a-A3) owns the qid scheme,
//! dirtabs, and attach/walk/open/dir-read/stat; it delegates every per-file
//! body/tag/index read and ctl/body/tag write here at its `// SEAM(B3)`
//! markers.
//!
//! Ported from larryr/plan9port@337c6ac acme/xfid.c; cite as `xfid.c:NN`. The
//! rulings adopted here are R-P10-G (utfRead has no cache — rescans from rune
//! 0 every call, exactly like the C's own "BUG: stupid code" fallback,
//! xfid.c:955) and R-P10-H (the ctl write subset: clean/dirty/del/delete/
//! name, everything else `error.BadCtl`, "delete" tried before "del").
//!
//! Imports: `std` + `ninep` (errors) + sibling core files + `fsys.zig` (the
//! `Window`↔`Text` import-cycle precedent applies here too: fsys delegates
//! INTO xfid, xfid needs fsys's `Fsys`/`Q` types back — legal in Zig, see
//! Window.zig's header). Never dev/shim.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ninep = @import("ninep");
const Editor = @import("../Editor.zig");
const Window = @import("../Window.zig");
const Text = @import("../text/Text.zig");
const Buffer = @import("../Buffer.zig");
const fsys_mod = @import("fsys.zig");

const Fsys = fsys_mod.Fsys;
const Q = fsys_mod.Q;
const OpError = ninep.errors.OpError;

// ===========================================================================
// Top-level per-file dispatchers (the frozen `xfid.read`/`xfid.write`
// signatures, agents/contracts/phase10-served.md §3.2). `fsys.zig`'s own
// `readOp` already handles `w_ctl` reads and directory/windowless reads
// inline (A3's wave); these dispatchers are the general per-window-file
// entry points its SEAM markers call for body/tag (and, for completeness/
// future consolidation, ctl too).
// ===========================================================================

pub fn read(f: *Fsys, w: ?*Window, q: Q, offset: u64, buf: []u8) OpError!usize {
    const win = w orelse return error.DeletedWindow;
    return switch (q) {
        .w_ctl => blk: {
            var tmp: [128]u8 = undefined;
            const line = win.ctlPrint(&tmp, true);
            if (offset >= line.len) break :blk 0;
            const avail = line[@intCast(offset)..];
            const n = @min(avail.len, buf.len);
            @memcpy(buf[0..n], avail[0..n]);
            break :blk n;
        },
        .w_body => utfRead(&win.body, offset, buf, f.allocator),
        .w_tag => utfRead(&win.tag, offset, buf, f.allocator),
        else => error.FileDoesNotExist,
    };
}

pub fn write(f: *Fsys, w: ?*Window, q: Q, offset: u64, data: []const u8) OpError!usize {
    const win = w orelse return error.DeletedWindow;
    return switch (q) {
        .w_ctl => ctlWrite(f, win, data),
        .w_body => appendWrite(f, &win.body, offset, data),
        .w_tag => appendWrite(f, &win.tag, offset, data),
        else => error.FileDoesNotExist,
    };
}

// ===========================================================================
// utfRead (xfid.c:934-996) — Tread offsets are BYTE offsets over the UTF-8
// stream of a RUNE-indexed buffer. R-P10-G (v1, no cache): rescan the whole
// buffer from rune 0 every call — exactly the C's own fallback path
// (xfid.c:955, "BUG: stupid code: scan from beginning") — then slice the raw
// byte window `[offset, offset+buf.len)`. A read boundary may fall MID-RUNE;
// that is fine, bytes are sliced raw (xfid.c:978-986).
// ===========================================================================

pub fn utfRead(t: *Text, offset: u64, buf: []u8, scratch_alloc: Allocator) OpError!usize {
    const nc = t.file.buffer.len();
    if (nc == 0) return 0;
    const cap = nc * Buffer.max_bytes_per_rune;
    const scratch = scratch_alloc.alloc(u8, cap) catch return error.IoError;
    defer scratch_alloc.free(scratch);
    const all = t.file.buffer.read(0, nc, scratch);
    if (offset >= all.len) return 0; // EOF
    const avail = all[@intCast(offset)..];
    const n = @min(avail.len, buf.len);
    @memcpy(buf[0..n], avail[0..n]);
    return n;
}

// ===========================================================================
// indexRead (xfid.c:1090-1147) — per column, per window, in TREE order (NOT
// sorted): each line is `winctlprint(w, ..., fonts=false)` (exactly
// `Window.ctl_size` = 60 bytes) then the tag's first line (up to the first
// '\n', or the whole tag if none) plus a trailing '\n'. The whole blob is
// rebuilt on every read, then offset/count sliced (xfid.c:1131-1140).
// ===========================================================================

pub fn indexRead(ed: *Editor, offset: u64, buf: []u8, alloc: Allocator) OpError!usize {
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(alloc);

    if (ed.row) |row| {
        for (row.col.items) |c| {
            for (c.w.items) |w| {
                var ctlbuf: [Window.ctl_size]u8 = undefined;
                const line = w.ctlPrint(&ctlbuf, false);
                blob.appendSlice(alloc, line) catch return error.IoError;

                const tag_nc = w.tag.file.buffer.len();
                if (tag_nc > 0) {
                    const cap = tag_nc * Buffer.max_bytes_per_rune;
                    const scratch = alloc.alloc(u8, cap) catch return error.IoError;
                    defer alloc.free(scratch);
                    const tagtext = w.tag.file.buffer.read(0, tag_nc, scratch);
                    const nl = std.mem.indexOfScalar(u8, tagtext, '\n') orelse tagtext.len;
                    blob.appendSlice(alloc, tagtext[0..nl]) catch return error.IoError;
                }
                blob.append(alloc, '\n') catch return error.IoError;
            }
        }
    }

    if (offset >= blob.items.len) return 0;
    const avail = blob.items[@intCast(offset)..];
    const n = @min(avail.len, buf.len);
    @memcpy(buf[0..n], avail[0..n]);
    return n;
}

// ===========================================================================
// Body/tag append writes (xfid.c:577-608). v1 DIVERGENCE (flagged): the C's
// `fullrunewrite` carries a partial-rune tail across writes (`Fid.nrpart`/
// `rpart`) so a write boundary can split a multi-byte rune without losing
// bytes. Snarf's `Ops.write` framework exposes no per-fid scratch for that
// carry, so v1 decodes whatever arrived in ONE write and substitutes U+FFFD
// for any invalid byte (Buffer's own read-time convention) rather than
// buffering a partial tail — a write that itself splits a rune mid-sequence
// loses that rune to U+FFFD instead of joining with the next write. This is
// safe for storage (Text.insertAt's precondition is valid UTF-8; Buffer's
// verbatim-byte guarantee applies to the LOAD path, not the typed-edit path)
// and matches the C's end state whenever a write is not itself rune-split.
// The append always lands at `t.file.buffer.len()` (`t->file->b.nc`),
// ignoring the client's requested offset (DMAPPEND semantics). `winsettag`
// runs after (xfid.c:606).
// ===========================================================================

fn appendWrite(f: *Fsys, t: *Text, offset: u64, data: []const u8) OpError!usize {
    _ = offset; // append-only: the write lands at the file end regardless (DMAPPEND).
    const w = t.w orelse return error.IoError;
    if (std.unicode.utf8ValidateSlice(data)) {
        t.insertAt(t.file.buffer.len(), data, true) catch return error.IoError;
    } else {
        const sanitized = sanitizeUtf8(f.allocator, data) catch return error.IoError;
        defer f.allocator.free(sanitized);
        t.insertAt(t.file.buffer.len(), sanitized, true) catch return error.IoError;
    }
    w.setTag() catch return error.IoError;
    return data.len; // xfid.c:608 fc.count = x->fcall.count (the request size)
}

const RuneStep = struct { step: usize, valid: bool };

/// Local copy of Buffer's private rune-validity walk (nothing public exposes
/// it): the length/validity of the rune starting at `bytes[i]`.
fn runeStep(bytes: []const u8, i: usize) RuneStep {
    const seqlen = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return .{ .step = 1, .valid = false };
    if (i + seqlen > bytes.len) return .{ .step = 1, .valid = false };
    _ = std.unicode.utf8Decode(bytes[i..][0..seqlen]) catch return .{ .step = 1, .valid = false };
    return .{ .step = seqlen, .valid = true };
}

/// Decode `data`, substituting U+FFFD for each invalid byte, into an owned,
/// always-valid-UTF-8 buffer (caller frees) — the precondition `Text.insertAt`
/// requires.
fn sanitizeUtf8(a: Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < data.len) {
        const rs = runeStep(data, i);
        if (rs.valid) {
            try out.appendSlice(a, data[i..][0..rs.step]);
        } else {
            try out.appendSlice(a, "\u{FFFD}");
        }
        i += rs.step;
    }
    return out.toOwnedSlice(a);
}

// ===========================================================================
// ctl write (xfidctlwrite, xfid.c:622-844) — v1 subset (R-P10-H): clean,
// dirty, delete, del, name. Commands are packed back-to-back in one write;
// each consumes its own prefix (+ argument for `name`), trailing '\n's are
// skipped between commands (xfid.c:827-828), and the FIRST failure aborts
// the whole write (xfid.c:835-838: `err` set ⇒ the reported count is 0 — Zig
// mirrors this by returning an error instead of a partial usize). "delete"
// MUST be tried before "del" (a prefix of it) — table order below matters.
// ===========================================================================

const CtlCmd = struct {
    name: []const u8,
    takes_arg: bool,
    run: *const fn (f: *Fsys, w: *Window, arg: []const u8) OpError!void,
};

const ctltab = [_]CtlCmd{
    .{ .name = "clean", .takes_arg = false, .run = cmdClean },
    .{ .name = "dirty", .takes_arg = false, .run = cmdDirty },
    .{ .name = "delete", .takes_arg = false, .run = cmdDelete },
    .{ .name = "del", .takes_arg = false, .run = cmdDel },
    .{ .name = "name ", .takes_arg = true, .run = cmdName },
};

fn ctlWrite(f: *Fsys, w: *Window, data: []const u8) OpError!usize {
    var n: usize = 0;
    while (n < data.len) {
        // Trailing '\n's between commands are skipped (xfid.c:827-828) — also
        // covers leading ones, so a write of just "\n" is a no-op success.
        if (data[n] == '\n') {
            n += 1;
            continue;
        }
        const p = data[n..];
        var found: ?*const CtlCmd = null;
        for (&ctltab) |*cmd| {
            if (p.len >= cmd.name.len and std.mem.eql(u8, p[0..cmd.name.len], cmd.name)) {
                found = cmd;
                break;
            }
        }
        const cmd = found orelse return error.BadCtl;
        var m = cmd.name.len;
        var arg: []const u8 = "";
        if (cmd.takes_arg) {
            // "name <s>\n": the argument runs to the first '\n'; an absent or
            // immediately-following '\n' (empty arg) is ill-formed
            // (xfid.c:681-685: `q==nil || q==pp`).
            const rest = p[m..];
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.BadCtl;
            if (nl == 0) return error.BadCtl;
            arg = rest[0..nl];
            m += nl + 1; // consume the argument AND its terminating '\n'
        }
        try cmd.run(f, w, arg);
        n += m;
    }
    return data.len;
}

/// `clean` (xfid.c:656-663): `filereset` (drops undo/redo, keeps text+mod),
/// then `mod = FALSE`, `dirty = FALSE`, retag.
fn cmdClean(_: *Fsys, w: *Window, arg: []const u8) OpError!void {
    _ = arg;
    w.body.file.reset();
    w.body.file.mod = false;
    w.dirty = false;
    w.setTag() catch return error.IoError;
}

/// `dirty` (xfid.c:665-671): the mirror — mark modified/dirty, retag. Does
/// NOT touch seq (a "Put" must not appear from this alone, per the C comment).
fn cmdDirty(_: *Fsys, w: *Window, arg: []const u8) OpError!void {
    _ = arg;
    w.body.file.mod = true;
    w.dirty = true;
    w.setTag() catch return error.IoError;
}

/// `delete` (xfid.c:758-761): unconditional close — no clean check.
fn cmdDelete(f: *Fsys, w: *Window, arg: []const u8) OpError!void {
    _ = arg;
    const c = w.col orelse return error.IoError;
    c.close(f.ed, w, true) catch return error.IoError;
}

/// `del` (xfid.c:762-768): the two-strike clean check, CONSERVATIVE=TRUE
/// (vs the mouse Del builtin's FALSE, R-P10-H) — a dirty window is warned and
/// its `dirty` flag cleared by THIS call but the close is refused
/// (`error.FileDirty`, "file dirty"); the window survives for a second `del`
/// to actually close it. `Window.clean` already implements the two-strike
/// (wind.c:666-685) — never re-implement it here.
fn cmdDel(f: *Fsys, w: *Window, arg: []const u8) OpError!void {
    _ = arg;
    if (!w.clean(f.ed, true)) return error.FileDirty;
    const c = w.col orelse return error.IoError;
    c.close(f.ed, w, true) catch return error.IoError;
}

/// `name <s>\n` (xfid.c:678-702): validate no NUL/control chars in the new
/// name (simplified vs the C's two distinct error strings — R-P10-H's
/// catch-all is `error.BadCtl`, a documented divergence), bump `ed.seq` +
/// `File.mark` (the established mark idiom, e.g. `Column.zig:552-553`), set
/// the name, retag.
fn cmdName(f: *Fsys, w: *Window, arg: []const u8) OpError!void {
    for (arg) |ch| {
        if (ch < ' ') return error.BadCtl; // xfid.c:693-697 (simplified to BadCtl)
    }
    f.ed.seq += 1;
    w.body.file.mark(f.ed.seq); // filemark, xfid.c:700
    w.body.file.setName(arg) catch return error.IoError;
    w.setTag() catch return error.IoError;
}

// ===========================================================================
// Tests (side contract §4, tests 3-4 — the byte-exact test 1's index/tag
// composition is exercised here too since fsys.zig's own test file owns
// tests 1/2/5/6/7; xfid.zig's own harness mirrors the Fsys one).
// ===========================================================================
const testing = std.testing;
const chan = ninep.chan;
const msg = ninep.msg;
const Server = ninep.server.Server;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const boot = @import("../boot.zig");

/// Heap-pinned harness identical in shape to fsys.zig's — a Pipe + Server
/// over a booted tree, driven with raw msg frames.
const Harness = struct {
    alloc: Allocator,
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,
    fsys: Fsys,
    pipe: *chan.Pipe,
    srv: Server,
    rbuf: [8192]u8 = undefined,
    tag: u16 = 0,

    fn create(alloc: Allocator, name: []const u8, body: []const u8) !*Harness {
        const self = try alloc.create(Harness);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.tag = 0;
        self.fx = try Frame.TestFixture.init();
        self.tree = try boot.boot(alloc, self.fx.disp, self.fx.font, proto.Rect.make(0, 0, 640, 480), .{
            .win_name = name,
            .body = body,
        });
        self.ed = Editor.init(alloc);
        self.ed.row = self.tree.row;
        self.fsys = Fsys.init(&self.ed);
        self.pipe = try chan.Pipe.init(alloc, 16384);
        self.srv = try Server.init(alloc, self.pipe.serverEnd(), &Fsys.ops, &self.fsys, 8192);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.srv.deinit();
        self.pipe.deinit();
        self.ed.deinit();
        self.tree.deinit();
        self.fx.deinit();
        self.alloc.destroy(self);
    }

    fn nextTag(self: *Harness) u16 {
        self.tag += 1;
        return self.tag;
    }

    fn send(self: *Harness, m: msg.Message) !void {
        var enc: [4096]u8 = undefined;
        const n = try msg.encode(&m, &enc);
        try self.pipe.clientEnd().writeMsg(enc[0..n]);
        _ = try self.srv.step();
    }

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

    fn read(self: *Harness, fid: u32, offset: u64, count: u32) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .tread = .{ .fid = fid, .offset = offset, .count = count } } });
    }

    fn write(self: *Harness, fid: u32, offset: u64, data: []const u8) !msg.Message {
        return self.transact(.{ .tag = self.nextTag(), .body = .{ .twrite = .{ .fid = fid, .offset = offset, .data = data } } });
    }
};

test "served: index two windows" {
    const h = try Harness.create(testing.allocator, "one", "hello\n");
    defer h.destroy();
    _ = try h.tree.addWindow("two", "hi\n"); // id 2
    try h.connect();

    const col = h.tree.row.col.items[0];
    const w1 = col.w.items[0];
    const w2 = col.w.items[1];
    try testing.expectEqual(@as(usize, 21), w1.tag.file.buffer.len()); // "one Del Snarf | Look "
    try testing.expectEqual(@as(usize, 21), w2.tag.file.buffer.len()); // "two Del Snarf | Look "

    _ = try h.walk(0, 1, &.{"index"});
    _ = try h.open(1, msg.OREAD);
    const rr = try h.read(1, 0, 4096);
    try testing.expect(rr.body == .rread);

    var tag1buf: [128]u8 = undefined;
    var tag2buf: [128]u8 = undefined;
    const tag1 = w1.tag.file.buffer.read(0, w1.tag.file.buffer.len(), &tag1buf);
    const tag2 = w2.tag.file.buffer.read(0, w2.tag.file.buffer.len(), &tag2buf);

    var expbuf: [512]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&expbuf);
    stream.print("{d:>11} {d:>11} {d:>11} {d:>11} {d:>11} ", .{ @as(u32, w1.id), @as(usize, 21), @as(usize, w1.body.file.buffer.len()), @as(u32, 0), @as(u32, 0) }) catch unreachable;
    stream.writeAll(tag1) catch unreachable;
    stream.writeAll("\n") catch unreachable;
    stream.print("{d:>11} {d:>11} {d:>11} {d:>11} {d:>11} ", .{ @as(u32, w2.id), @as(usize, 21), @as(usize, w2.body.file.buffer.len()), @as(u32, 0), @as(u32, 0) }) catch unreachable;
    stream.writeAll(tag2) catch unreachable;
    stream.writeAll("\n") catch unreachable;
    const exp = stream.buffered();

    try testing.expectEqualStrings(exp, rr.body.rread.data);
    // Tree order (col.items[0] then [1]), not id-sorted — both happen to
    // coincide here, so also check the id fields land where tree order says.
    try testing.expectEqual(@as(u32, 1), w1.id);
    try testing.expectEqual(@as(u32, 2), w2.id);
}

test "served: body utf read across rune boundary" {
    // "a" (1) + "é" (2) + "€" (3) + "x" (1) = 7 bytes, 4 runes.
    const h = try Harness.create(testing.allocator, "one", "a\u{00e9}\u{20ac}x");
    defer h.destroy();
    try h.connect();
    const w = h.tree.row.col.items[0].w.items[0];
    try testing.expectEqual(@as(usize, 4), w.body.file.buffer.len());
    try testing.expectEqual(@as(usize, 7), w.body.file.buffer.rawByteLen());

    _ = try h.walk(0, 1, &.{ "1", "body" });
    _ = try h.open(1, msg.OREAD);

    const r0 = try h.read(1, 0, 7);
    try testing.expectEqualStrings("a\u{00e9}\u{20ac}x", r0.body.rread.data);

    // read(2,2): raw 2-byte window starting mid-'é' (byte 1) through byte 2 —
    // splits the rune, sliced raw exactly like the C.
    const r1 = try h.read(1, 2, 2);
    try testing.expectEqual(@as(usize, 2), r1.body.rread.data.len);
    try testing.expectEqualSlices(u8, "a\u{00e9}\u{20ac}x"[2..4], r1.body.rread.data);

    // EOF past the end.
    const r2 = try h.read(1, 7, 100);
    try testing.expectEqual(@as(usize, 0), r2.body.rread.data.len);
}

test "served: ctl write clean and del mutate" {
    const h = try Harness.create(testing.allocator, "one", "hello\n");
    defer h.destroy();
    try h.connect();
    const col = h.tree.row.col.items[0];
    const w = col.w.items[0];

    // Dirty the window via a recorded body edit.
    h.ed.seq += 1;
    w.body.file.mark(h.ed.seq);
    try w.body.insertAt(0, "X", true);
    try testing.expect(w.dirty);
    try testing.expect(w.body.file.mod);

    _ = try h.walk(0, 1, &.{ "1", "ctl" });
    _ = try h.open(1, msg.ORDWR);
    const rc = try h.write(1, 0, "clean\n");
    try testing.expect(rc.body == .rwrite);
    try testing.expectEqual(@as(u32, 6), rc.body.rwrite.count);
    try testing.expect(!w.dirty);
    try testing.expect(!w.body.file.mod);
    try testing.expectEqual(@as(u32, 0), w.body.file.undoSeq()); // filereset dropped the stack

    // "del" on a now-CLEAN window closes it outright (no dirty warning).
    const rd = try h.write(1, 0, "del\n");
    try testing.expect(rd.body == .rwrite);
    try testing.expectEqual(@as(usize, 0), col.w.items.len);

    // Rebuild and dirty a fresh window; "del" first strike refuses with
    // "file dirty" (the two-strike), second strike closes it.
    const h2 = try Harness.create(testing.allocator, "two", "hello\n");
    defer h2.destroy();
    try h2.connect();
    const col2 = h2.tree.row.col.items[0];
    const w2 = col2.w.items[0];
    h2.ed.seq += 1;
    w2.body.file.mark(h2.ed.seq);
    try w2.body.insertAt(0, "Y", true);
    try testing.expect(w2.dirty);

    _ = try h2.walk(0, 1, &.{ "1", "ctl" });
    _ = try h2.open(1, msg.ORDWR);
    const strike1 = try h2.write(1, 0, "del\n");
    try testing.expect(strike1.body == .rerror);
    try testing.expectEqualStrings("file dirty", strike1.body.rerror.ename);
    try testing.expectEqual(@as(usize, 1), col2.w.items.len); // still open
    try testing.expect(!w2.dirty); // cleared by the first strike

    const strike2 = try h2.write(1, 0, "del\n");
    try testing.expect(strike2.body == .rwrite);
    try testing.expectEqual(@as(usize, 0), col2.w.items.len); // closed now
}

test "served: ctl write name renames" {
    const h = try Harness.create(testing.allocator, "one", "hello\n");
    defer h.destroy();
    try h.connect();
    const w = h.tree.row.col.items[0].w.items[0];

    _ = try h.walk(0, 1, &.{ "1", "ctl" });
    _ = try h.open(1, msg.ORDWR);
    const rw = try h.write(1, 0, "name renamed\n");
    try testing.expect(rw.body == .rwrite);
    try testing.expectEqual(@as(u32, 13), rw.body.rwrite.count);
    try testing.expectEqualStrings("renamed", w.body.file.name.items);

    // The recomposed tag shows the new name in its name half (parseTag).
    const pt = try w.parseTag(testing.allocator);
    defer testing.allocator.free(pt.text);
    try testing.expect(std.mem.startsWith(u8, pt.text, "renamed"));

    // A NUL/control byte in the name is ill-formed.
    const bad = try h.write(1, 0, "name bad\x01name\n");
    try testing.expect(bad.body == .rerror);
    try testing.expectEqualStrings("ill-formed control message", bad.body.rerror.ename);
}

test "served: body write appends" {
    const h = try Harness.create(testing.allocator, "one", "hello\n");
    defer h.destroy();
    try h.connect();
    const w = h.tree.row.col.items[0].w.items[0];
    try testing.expectEqual(@as(usize, 6), w.body.file.buffer.len());

    _ = try h.walk(0, 1, &.{ "1", "body" });
    _ = try h.open(1, msg.ORDWR);

    // Write "MORE" at offset 0 — append semantics ignore the requested
    // offset and land at the file's END regardless (DMAPPEND).
    const rw = try h.write(1, 0, "MORE");
    try testing.expect(rw.body == .rwrite);
    try testing.expectEqual(@as(u32, 4), rw.body.rwrite.count);

    var rbuf: [64]u8 = undefined;
    const nc = w.body.file.buffer.len();
    try testing.expectEqual(@as(usize, 10), nc); // "hello\n" (6) + "MORE" (4)
    try testing.expectEqualStrings("hello\nMORE", w.body.file.buffer.read(0, nc, &rbuf));

    // The tag was recomposed (setTag ran) — sanity: it still starts with the
    // window's name.
    const pt = try w.parseTag(testing.allocator);
    defer testing.allocator.free(pt.text);
    try testing.expect(std.mem.startsWith(u8, pt.text, "one"));

    // A second append lands after the first, not at the given offset either.
    const rw2 = try h.write(1, 3, "!");
    try testing.expect(rw2.body == .rwrite);
    const nc2 = w.body.file.buffer.len();
    try testing.expectEqualStrings("hello\nMORE!", w.body.file.buffer.read(0, nc2, &rbuf));
}
