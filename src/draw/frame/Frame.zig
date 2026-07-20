//! A text frame — libframe's `Frame` (include/frame.h:31-54), file-as-struct
//! (S-07 P-1): this file *is* the struct. A `Frame` renders a rune range as
//! word-wrapped lines of boxes onto an `Image`, drawing ONLY through the
//! phase-3 draw client (ADR-0003). It owns its box list; text bytes in run
//! boxes are owned UTF-8 slices (frstr.c's `_frallocstr`/`_frinsure` dissolve
//! into Zig slice ownership here — no separate string arena).
//!
//! Ported from larryr/plan9port@337c6ac: this file covers frinit.c
//! (init/setRects/clear), frbox.c (all box primitives), and frdraw.c:207-215
//! (strLen). frinsert.c → insert.zig; frdraw.c/frselect.c → draw.zig;
//! frutil.c/frptofchar.c → util.zig; those attach as method aliases below.
//!
//! INVARIANTS (frame contract §Frame struct):
//!  I-1  boxes partition [0, nchars): Σ box.nrune() == nchars.
//!  I-2  a run box's `wid` always equals `font.stringWidth(text)`.
//!  I-3  run texts hold no '\n', '\t' or NUL (those are break boxes).
//!  I-4  ANY box-list growth invalidates `*Box` pointers — re-fetch `items[n]`
//!       after every addBox/dupBox/splitBox/mergeBox/findBox (the C reloads its
//!       `Frbox*` after each realloc, frinsert.c:64,149-159).
//!  I-5  internal invariant violations panic (the `drawerror` analog,
//!       frutil.c:29); wire errors propagate as Display.Error, allocation as
//!       OutOfMemory.
const std = @import("std");
const proto = @import("../proto.zig");
const Image = @import("../Image.zig");
const Display = @import("../Display.zig");
const Font = @import("../Font.zig");
const util = @import("util.zig");

const Frame = @This();
const Point = proto.Point;

/// TMPSIZE (frinsert.c:8): the per-run BYTE cap at CREATION time only — bxscan
/// breaks a run when the next rune's bytes would reach it (frinsert.c:54-56).
/// Later merges (`_frclean`) may exceed it; it is not a standing invariant.
pub const run_byte_cap: usize = 256;

/// NCOL (frame.h:12-19): number of color slots.
pub const ncol: usize = 5;

/// FRTICKW (frame.h:21): the typing-tick width in pixels (a fixed 3). `tickscale`
/// is omitted from the struct — it is always 1 (F-4, frinit.c:36 `scalesize(1)`),
/// so the tick is exactly `frtick_w` px wide and `frtick_w/2 == 1` px is the
/// vertical-line offset.
pub const frtick_w: i32 = 3;

/// The color-slot order (frame.h:12-19). P4 callers pass
/// `.{ white, white, black, black, black }`.
pub const ColorSlot = enum(usize) { back, high, bord, text, htext };

/// A layout box (frame.h:22-29 `Frbox`) as a P-6 tagged union. A run box holds
/// owned UTF-8 (no '\n'/'\t'/NUL, I-3); a break box holds one tab or newline.
pub const Box = struct {
    /// Pixel width. Runs: `stringWidth(text)` (I-2). Break boxes are seeded to
    /// 5000 at creation; layout (`newWid`) replaces a '\t' box's wid with its
    /// tab advance, but a '\n' box KEEPS the 5000 seed forever — drawSel0 clamps
    /// it (frdraw.c:100-102) and charOfPt relies on the overshoot
    /// (frptofchar.c:90-92). Do not normalize it.
    wid: i32,
    kind: Kind,

    pub const Kind = union(enum) { run: Run, brk: Brk };
    /// Owned UTF-8; `nrune` is the rune count of `text`.
    pub const Run = struct { text: []u8, nrune: u32 };
    /// `bc` is the break char; `minwid` is 0 for '\n', `stringWidth(" ")` for '\t'.
    pub const Brk = struct { bc: u8, minwid: i32 };

    /// NRUNE (frame.h:94): a break box counts as one rune.
    pub fn nrune(self: *const Box) usize {
        return switch (self.kind) {
            .run => |r| r.nrune,
            .brk => 1,
        };
    }
};

pub const Error = std.mem.Allocator.Error || Display.Error;

allocator: std.mem.Allocator,
font: *Font,
display: *Display,
/// The image the frame draws onto (borrowed).
b: *Image,
/// Color slots, indexed by `ColorSlot` (frame.h:36).
cols: [ncol]*Image,
/// Where text appears (`r.max.y` trimmed to a line multiple).
r: proto.Rect,
/// The full frame rect before trimming.
entire: proto.Rect,
boxes: std.ArrayList(Box),
/// Selection [p0, p1). Zero in phase 4 (R-P4-6 — no select yet).
p0: usize = 0,
p1: usize = 0,
maxtab: i32,
nchars: usize,
nlines: usize,
maxlines: usize,
lastlinefull: bool,
modified: bool,
noredraw: bool,
/// The typing tick (frame.h:49-51). `tick` is a 3×height image of the caret
/// glyph; `tickback` saves the screen pixels under it so it can be lifted; both
/// are allocated by `initTick` (F-5) and freed by `clear(true)`. `ticked` is the
/// on-screen flag. All null/false until `initTick` runs.
tick: ?Image = null,
tickback: ?Image = null,
ticked: bool = false,

// --- method aliases: the sibling frame/* files attach here so callers can
//     write `f.insert(...)`, `f.redraw()`, `f.ptOfChar(p)`, etc. ---
pub const insert = @import("insert.zig").insert;
pub const drawText = @import("draw.zig").drawText;
pub const draw0 = @import("draw.zig").draw0;
pub const drawSel0 = @import("draw.zig").drawSel0;
pub const drawSel = @import("draw.zig").drawSel;
pub const redraw = @import("draw.zig").redraw;
pub const selectPaint = @import("draw.zig").selectPaint;
// NB: the tick *painter* (draw.zig `tick`) is NOT aliased here — the struct has
// a `tick: ?Image` field, and a decl of the same name would collide. draw.zig
// and the sibling files call it as `drawmod.tick(f, ...)`.
pub const delete = @import("delete.zig").delete;
pub const selectBegin = @import("select.zig").selectBegin;
pub const selectUpdate = @import("select.zig").selectUpdate;
pub const selectEnd = @import("select.zig").selectEnd;
pub const SelectState = @import("select.zig").SelectState;
pub const canFit = util.canFit;
pub const ckLineWrap = util.ckLineWrap;
pub const ckLineWrap0 = util.ckLineWrap0;
pub const advance = util.advance;
pub const newWid = util.newWid;
pub const newWid0 = util.newWid0;
pub const clean = util.clean;
pub const ptOfChar = util.ptOfChar;
pub const ptOfCharPtB = util.ptOfCharPtB;
pub const ptOfCharN = util.ptOfCharN;
pub const charOfPt = util.charOfPt;
pub const runeByteIndex = util.runeByteIndex;
pub const stringNWidth = util.stringNWidth;

/// The color image for slot `s`.
pub fn col(f: *const Frame, s: ColorSlot) *Image {
    return f.cols[@intFromEnum(s)];
}

/// `frinit` (frinit.c:7-26): bind font/image/colors, compute `maxtab` =
/// 8·stringWidth("0") (72px for fixed 9x18), then `setRects`. `display` is taken
/// from `b.display` (frinit.c:11). DIVERGENCE F-5: the C's `frinittick` call
/// (frinit.c:24) is NOT made here — `initTick` is a SEPARATE fallible method the
/// caller runs after init, so `Frame.init` stays infallible.
pub fn init(allocator: std.mem.Allocator, r: proto.Rect, font: *Font, b: *Image, cols: [ncol]*Image) Frame {
    var f = Frame{
        .allocator = allocator,
        .font = font,
        .display = b.display,
        .b = b,
        .cols = cols,
        .r = r,
        .entire = r,
        .boxes = .empty,
        .maxtab = 8 * font.stringWidth("0"),
        .nchars = 0,
        .nlines = 0,
        .maxlines = 0,
        .lastlinefull = false,
        .modified = false,
        .noredraw = false,
    };
    f.setRects(r, b);
    return f;
}

/// `frsetrects` (frinit.c:61-69): trim `r.max.y` down to a whole number of text
/// lines and set `maxlines` (from the UNtrimmed height, matching the C).
pub fn setRects(f: *Frame, r: proto.Rect, b: *Image) void {
    f.b = b;
    f.entire = r;
    f.r = r;
    const h = util.fontHeight(f);
    const dy = r.max.y - r.min.y;
    f.r.max.y -= @rem(dy, h);
    f.maxlines = @intCast(@divTrunc(dy, h));
}

/// `frclear` (frinit.c:71-86): free every run box's text and the box list; when
/// `freeall`, also free the tick images (frinit.c:78-83). `ticked` is always
/// cleared (frinit.c:85).
pub fn clear(f: *Frame, freeall: bool) void {
    for (f.boxes.items) |*bx| {
        if (bx.kind == .run) f.allocator.free(bx.kind.run.text);
    }
    f.boxes.deinit(f.allocator);
    f.boxes = .empty;
    if (freeall) {
        if (f.tick) |*t| t.free() catch {};
        if (f.tickback) |*t| t.free() catch {};
        f.tick = null;
        f.tickback = null;
    }
    f.ticked = false;
}

/// `frinittick` (frinit.c:28-59): build the two tick images. DIVERGENCE F-5:
/// this is a SEPARATE fallible method (not folded into `init`); `tickscale` is
/// fixed at 1 (F-4). Allocates `tick` and `tickback` as `frtick_w × height`
/// images in the display channel, then paints the tick glyph with the four draws
/// of frinit.c:52-58 — a BACK ground, a 1px TEXT vertical line at x=1, and 3×3
/// TEXT boxes at the top and bottom. Idempotent: an existing tick/tickback is
/// freed and rebuilt (frinit.c:39-40,44-45). On a `tickback` alloc failure the
/// already-built `tick` is rolled back (frinit.c:47-51).
pub fn initTick(f: *Frame) Error!void {
    const h = util.fontHeight(f);
    const chan = f.b.chan;
    if (f.tick) |*t| try t.free();
    f.tick = try f.display.allocImage(proto.Rect.make(0, 0, frtick_w, h), chan, false, proto.DWhite);
    errdefer {
        if (f.tick) |*t| t.free() catch {};
        f.tick = null;
    }
    if (f.tickback) |*t| try t.free();
    f.tickback = try f.display.allocImage(proto.Rect.make(0, 0, frtick_w, h), chan, false, proto.DWhite);

    const t = &f.tick.?;
    // frinit.c:53 background color (BACK ground over the whole tick).
    try t.draw(t.r, f.col(.back), null, .{});
    // frinit.c:55 vertical line at x = frtick_w/2 == 1, one pixel wide.
    const mid = @divTrunc(frtick_w, 2);
    try t.draw(proto.Rect.make(mid, 0, mid + 1, h), f.col(.text), null, .{});
    // frinit.c:57 box on the top end (3×3).
    try t.draw(proto.Rect.make(0, 0, frtick_w, frtick_w), f.col(.text), null, .{});
    // frinit.c:58 box on the bottom end (3×3).
    try t.draw(proto.Rect.make(0, h - frtick_w, frtick_w, h), f.col(.text), null, .{});
}

// ==========================================================================
// Box primitives (frbox.c). Every list-growth op invalidates `*Box` (I-4);
// callers re-fetch `items[n]` after calling these, exactly as the C reloads its
// `Frbox*` after each realloc.
// ==========================================================================

/// `_fraddbox` (frbox.c:9-22): open `n` uninitialised slots at index `bn` and
/// return them for the caller to fill (the adoption path in insert.zig).
pub fn addBox(f: *Frame, bn: usize, n: usize) Error![]Box {
    return f.boxes.addManyAt(f.allocator, bn, n);
}

/// `_frclosebox` (frbox.c:24-35): drop boxes `[n0, n1]` from the list WITHOUT
/// freeing their text (used after ownership has moved).
pub fn closeBox(f: *Frame, n0: usize, n1: usize) void {
    var i: usize = 0;
    while (i < n1 - n0 + 1) : (i += 1) _ = f.boxes.orderedRemove(n0);
}

/// `_frdelbox` (frbox.c:37-44): free text in `[n0, n1]` (frbox.c:46-59
/// `_frfreebox`) then remove them.
pub fn delBox(f: *Frame, n0: usize, n1: usize) void {
    std.debug.assert(n0 <= n1 and n1 < f.boxes.items.len);
    var i = n0;
    while (i <= n1) : (i += 1) {
        const bx = &f.boxes.items[i];
        if (bx.kind == .run) f.allocator.free(bx.kind.run.text);
    }
    f.closeBox(n0, n1);
}

/// `_frfreebox` (frbox.c:46-59): free the run text in `[n0, n1]` (inclusive) but
/// KEEP the slots. Unlike `delBox`, it does not close the gap — `delete.zig`
/// frees the doomed run boxes here, then overwrites their slots by struct copy
/// during the compaction walk and drops the leftovers with `closeBox` (no double
/// free, since `closeBox` never frees). `n1 < n0` ⇒ nothing (frbox.c:51-52).
pub fn freeBox(f: *Frame, n0: usize, n1: usize) void {
    if (n1 < n0) return;
    std.debug.assert(n0 < f.boxes.items.len and n1 < f.boxes.items.len); // frbox.c:53 (I-5)
    var i = n0;
    while (i <= n1) : (i += 1) {
        const bx = &f.boxes.items[i];
        if (bx.kind == .run) f.allocator.free(bx.kind.run.text);
    }
}

/// `dupbox` (frbox.c:70-84): insert a deep copy of run box `bn` right after it,
/// so `items[bn]` is the original and `items[bn+1]` the copy.
pub fn dupBox(f: *Frame, bn: usize) Error!void {
    const orig = f.boxes.items[bn];
    if (orig.kind != .run) @panic("dupbox"); // frbox.c:77 (I-5)
    var copy = orig;
    copy.kind.run.text = try f.allocator.dupe(u8, orig.kind.run.text);
    errdefer f.allocator.free(copy.kind.run.text);
    try f.boxes.insert(f.allocator, bn + 1, copy);
}

/// `truncatebox` (frbox.c:103-112): drop the LAST `n` runes of run box `bn`,
/// recomputing `wid = stringWidth`.
pub fn truncateBox(f: *Frame, bn: usize, n: usize) Error!void {
    const bx = &f.boxes.items[bn];
    if (bx.kind != .run or bx.kind.run.nrune < n) @panic("truncatebox"); // I-5
    const run = &bx.kind.run;
    const keep = run.nrune - n;
    const off = util.runeByteIndex(run.text, keep);
    run.text = try f.allocator.realloc(run.text, off);
    run.nrune = @intCast(keep);
    bx.wid = f.font.stringWidth(run.text);
}

/// `chopbox` (frbox.c:114-126): drop the FIRST `n` runes of run box `bn`,
/// recomputing `wid = stringWidth`.
pub fn chopBox(f: *Frame, bn: usize, n: usize) Error!void {
    const bx = &f.boxes.items[bn];
    if (bx.kind != .run or bx.kind.run.nrune < n) @panic("chopbox"); // I-5
    const run = &bx.kind.run;
    const off = util.runeByteIndex(run.text, n);
    const newtext = try f.allocator.dupe(u8, run.text[off..]);
    f.allocator.free(run.text);
    run.text = newtext;
    run.nrune = @intCast(run.nrune - n);
    bx.wid = f.font.stringWidth(run.text);
}

/// `_frsplitbox` (frbox.c:128-134): split run box `bn` so `items[bn]` keeps the
/// first `n` runes and `items[bn+1]` the rest.
pub fn splitBox(f: *Frame, bn: usize, n: usize) Error!void {
    try f.dupBox(bn);
    const total = f.boxes.items[bn].kind.run.nrune;
    try f.truncateBox(bn, total - n);
    try f.chopBox(bn + 1, n);
}

/// `_frmergebox` (frbox.c:136-147): append `items[bn+1]` onto `items[bn]` and
/// delete the second. Widths and rune counts add; text is concatenated.
pub fn mergeBox(f: *Frame, bn: usize) Error!void {
    const a = &f.boxes.items[bn];
    const b = &f.boxes.items[bn + 1];
    if (a.kind != .run or b.kind != .run) @panic("_frmergebox"); // frstr.c:29 (I-5)
    const alen = a.kind.run.text.len;
    a.kind.run.text = try f.allocator.realloc(a.kind.run.text, alen + b.kind.run.text.len);
    @memcpy(a.kind.run.text[alen..], b.kind.run.text);
    a.wid += b.wid;
    a.kind.run.nrune += b.kind.run.nrune;
    f.delBox(bn + 1, bn + 1); // frees the (already-copied) second text
}

/// `_frfindbox` (frbox.c:149-159): from box `bn0` (having consumed `p0` runes),
/// find the box holding rune `q`, splitting so `q` lands on a box boundary.
/// Returns the index of the box that starts at `q`.
pub fn findBox(f: *Frame, bn0: usize, p0: usize, q: usize) Error!usize {
    var bn = bn0;
    var p = p0;
    while (bn < f.boxes.items.len and p + f.boxes.items[bn].nrune() <= q) : (bn += 1) {
        p += f.boxes.items[bn].nrune();
    }
    if (p != q) {
        try f.splitBox(bn, q - p);
        bn += 1;
    }
    return bn;
}

/// `_frstrlen` (frdraw.c:207-215): total rune count from box `nb` to the end.
pub fn strLen(f: *const Frame, nb: usize) usize {
    var n: usize = 0;
    var i = nb;
    while (i < f.boxes.items.len) : (i += 1) n += f.boxes.items[i].nrune();
    return n;
}

// ==========================================================================
// Tests. The FakeDrawTree+Pipe fixture lives ONCE here as a test-only
// `pub const TestFixture` (R-P4-5), shared by the frame/* sibling test blocks;
// it is modelled on draw.zig's FakeDrawTree (R-P2-6 lineage). Pixel goldens stay
// in src/accept.zig.
// ==========================================================================
const testing = std.testing;
const ninep = @import("ninep");
const nserver = ninep.server;
const OpError = ninep.errors.OpError;
const Qid = ninep.Qid;

// Pull the sibling files' tests into this module's test binary.
test {
    _ = @import("insert.zig");
    _ = @import("draw.zig");
    _ = @import("util.zig");
    _ = @import("delete.zig");
    _ = @import("select.zig");
}

/// A canned draw tree (R-P2-6 shape): root(1) → new(2); dir "1"(3) → data(4).
/// `new` reads back a fixed connection line; `data` records every write. Same
/// shape as draw.zig's FakeDrawTree and Font.zig's FakeTree, compact so the
/// frame tests stand alone (R-P4-5).
pub const FakeDrawTree = struct {
    alloc: std.mem.Allocator,
    conn_line: [Display.info_size]u8,
    writes: std.ArrayList([]u8) = .empty,

    fn qidOf(path: u64) Qid {
        return .{ .path = path, .qtype = .{ .dir = path == 1 or path == 3 } };
    }
    fn attach(_: *anyopaque, _: *nserver.Server, _: *nserver.Fid, _: []const u8) OpError!Qid {
        return qidOf(1);
    }
    fn walk1(_: *anyopaque, _: *nserver.Server, fid: *nserver.Fid, name: []const u8) OpError!Qid {
        const eq = std.mem.eql;
        return switch (fid.qid.path) {
            1 => if (eq(u8, name, "new")) qidOf(2) else if (eq(u8, name, "1")) qidOf(3) else if (eq(u8, name, "..")) qidOf(1) else error.FileDoesNotExist,
            3 => if (eq(u8, name, "data")) qidOf(4) else if (eq(u8, name, "..")) qidOf(1) else error.FileDoesNotExist,
            else => error.WalkNoDir,
        };
    }
    fn open(_: *anyopaque, _: *nserver.Server, fid: *nserver.Fid, _: u8) OpError!Qid {
        return fid.qid;
    }
    fn read(ctx: *anyopaque, _: *nserver.Server, fid: *nserver.Fid, offset: u64, buf: []u8) OpError!usize {
        const self: *FakeDrawTree = @ptrCast(@alignCast(ctx));
        if (fid.qid.path != 2 or offset >= self.conn_line.len) return 0;
        const n = @min(buf.len, self.conn_line.len - offset);
        @memcpy(buf[0..n], self.conn_line[@intCast(offset)..][0..n]);
        return n;
    }
    fn write(ctx: *anyopaque, _: *nserver.Server, fid: *nserver.Fid, _: u64, data: []const u8) OpError!usize {
        const self: *FakeDrawTree = @ptrCast(@alignCast(ctx));
        if (fid.qid.path != 4) return error.PermissionDenied;
        const copy = self.alloc.dupe(u8, data) catch return error.IoError;
        self.writes.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return error.IoError;
        };
        return data.len;
    }
    fn statOp(_: *anyopaque, _: *nserver.Server, fid: *nserver.Fid) OpError!ninep.stat {
        return .{
            .qid = fid.qid,
            .mode = if (fid.qid.qtype.dir) (ninep.stat.DMDIR | 0o555) else 0o666,
            .length = 0,
            .name = "draw",
        };
    }
    const ops = nserver.Ops{ .attach = attach, .walk1 = walk1, .open = open, .read = read, .write = write, .stat = statOp };

    fn buildConnLine(self: *FakeDrawTree, fields: [12][]const u8) void {
        for (fields, 0..) |field, i| {
            const cell = self.conn_line[i * 12 ..][0..12];
            @memset(cell, ' ');
            @memcpy(cell[11 - field.len ..][0..field.len], field);
        }
    }
};

fn pump(ctx: *anyopaque) anyerror!void {
    const s: *nserver.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

/// A live `Display` + embedded fixed-9x18 `Font` wired to a `FakeDrawTree` over
/// a chan.Pipe (640×480 display). `makeFrame` hands back a `Frame` over the
/// display image with the P4 color slots `{white,white,black,black,black}`.
pub const TestFixture = struct {
    pipe: *ninep.chan.Pipe,
    tree: *FakeDrawTree,
    srv: *nserver.Server,
    cl: *ninep.Client,
    disp: *Display,
    font: *Font,

    pub fn init() !TestFixture {
        const a = testing.allocator;
        const pipe = try ninep.chan.Pipe.init(a, 16384);
        const tree = try a.create(FakeDrawTree);
        tree.* = .{ .alloc = a, .conn_line = undefined };
        tree.buildConnLine(.{ "1", "0", "x8r8g8b8", "0", "0", "0", "640", "480", "0", "0", "640", "480" });
        const srv = try a.create(nserver.Server);
        srv.* = try nserver.Server.init(a, pipe.serverEnd(), &FakeDrawTree.ops, tree, 8192);
        const cl = try a.create(ninep.Client);
        cl.* = try ninep.Client.init(a, pipe.clientEnd(), 8192);
        cl.pump = .{ .ctx = srv, .run = pump };
        _ = try cl.version(8192);
        const root = try cl.attach("glenda", "");
        const disp = try Display.init(a, cl, root.fid);
        const font = try a.create(Font);
        font.* = try Font.init(a, disp, Font.default_subfont);
        return .{ .pipe = pipe, .tree = tree, .srv = srv, .cl = cl, .disp = disp, .font = font };
    }

    pub fn deinit(self: *TestFixture) void {
        const a = testing.allocator;
        self.font.deinit();
        a.destroy(self.font);
        self.disp.deinit();
        self.cl.deinit();
        self.srv.deinit();
        for (self.tree.writes.items) |w| a.free(w);
        self.tree.writes.deinit(a);
        a.destroy(self.cl);
        a.destroy(self.srv);
        a.destroy(self.tree);
        self.pipe.deinit();
    }

    /// The P4 color slots (frame contract §4b): back/high white, bord/text/htext
    /// black.
    pub fn cols(self: *TestFixture) [ncol]*Image {
        return .{ &self.disp.white, &self.disp.white, &self.disp.black, &self.disp.black, &self.disp.black };
    }

    /// A `Frame` over the display image with the P4 color slots.
    pub fn makeFrame(self: *TestFixture, r: proto.Rect) Frame {
        return Frame.init(testing.allocator, r, self.font, &self.disp.image, self.cols());
    }
};

test "frame: init and setrects metrics" {
    var fx = try TestFixture.init();
    defer fx.deinit();

    // fixed 9x18: height 18, ascent 13, stringWidth("0") 9 ⇒ maxtab 72.
    try testing.expectEqual(@as(u8, 18), fx.font.height);
    try testing.expectEqual(@as(u8, 13), fx.font.ascent);
    try testing.expectEqual(@as(i32, 9), fx.font.stringWidth("0"));

    // Default rect (20,20)-(119,470): 450px / 18 = 25 lines, no trim.
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);
    try testing.expectEqual(@as(i32, 72), f.maxtab);
    try testing.expectEqual(@as(usize, 25), f.maxlines);
    try testing.expectEqual(@as(i32, 470), f.r.max.y); // already a line multiple
    try testing.expectEqual(proto.Rect.make(20, 20, 119, 470), f.entire);
    try testing.expectEqual(@as(usize, 0), f.nchars);
    try testing.expectEqual(fx.disp, f.display);

    // A height that is not a line multiple trims r.max.y but keeps maxlines from
    // the untrimmed span: (475-20)=455, 455/18 = 25 lines, r.max.y -> 20+450=470.
    var g = fx.makeFrame(proto.Rect.make(20, 20, 119, 475));
    defer g.clear(true);
    try testing.expectEqual(@as(usize, 25), g.maxlines);
    try testing.expectEqual(@as(i32, 470), g.r.max.y);
    try testing.expectEqual(@as(i32, 475), g.entire.max.y);
}

test "frame: box primitives split/merge/find" {
    var fx = try TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    // runeByteIndex over a multibyte string: café = c,a,f,é(2 bytes) ⇒ 5 bytes.
    try testing.expectEqual(@as(usize, 5), runeByteIndex("café", 4));
    try testing.expectEqual(@as(usize, 3), runeByteIndex("café", 3));
    try testing.expectEqual(@as(usize, 0), runeByteIndex("café", 0));

    // Build one run box "café" (4 runes, 5 bytes, wid 4*9=36).
    try f.insert("café", 0);
    try testing.expectEqual(@as(usize, 1), f.boxes.items.len);
    try testing.expectEqual(@as(u32, 4), f.boxes.items[0].kind.run.nrune);
    try testing.expectEqual(@as(i32, 36), f.boxes.items[0].wid);

    // splitBox(0,2): "ca"(2,18) + "fé"(2 runes, 3 bytes, 18).
    try f.splitBox(0, 2);
    try testing.expectEqual(@as(usize, 2), f.boxes.items.len);
    try testing.expectEqualStrings("ca", f.boxes.items[0].kind.run.text);
    try testing.expectEqual(@as(i32, 18), f.boxes.items[0].wid);
    try testing.expectEqualStrings("fé", f.boxes.items[1].kind.run.text);
    try testing.expectEqual(@as(u32, 2), f.boxes.items[1].kind.run.nrune);
    try testing.expectEqual(@as(i32, 18), f.boxes.items[1].wid);

    // mergeBox(0): back to "café".
    try f.mergeBox(0);
    try testing.expectEqual(@as(usize, 1), f.boxes.items.len);
    try testing.expectEqualStrings("café", f.boxes.items[0].kind.run.text);
    try testing.expectEqual(@as(u32, 4), f.boxes.items[0].kind.run.nrune);
    try testing.expectEqual(@as(i32, 36), f.boxes.items[0].wid);

    // findBox(0,0,3): puts rune 3 on a boundary by splitting ⇒ returns 1.
    const bn = try f.findBox(0, 0, 3);
    try testing.expectEqual(@as(usize, 1), bn);
    try testing.expectEqualStrings("caf", f.boxes.items[0].kind.run.text);
    try testing.expectEqualStrings("é", f.boxes.items[1].kind.run.text);

    // truncateBox drops the last rune; chopBox drops the first.
    try f.truncateBox(0, 1);
    try testing.expectEqualStrings("ca", f.boxes.items[0].kind.run.text);
    try f.chopBox(0, 1);
    try testing.expectEqualStrings("a", f.boxes.items[0].kind.run.text);
    try testing.expectEqual(@as(i32, 9), f.boxes.items[0].wid);

    // strLen sums rune counts from a box to the end.
    try testing.expectEqual(@as(usize, 2), f.strLen(0)); // "a" + "é"
    try testing.expectEqual(@as(usize, 1), f.strLen(1)); // "é"
}

test "frame: inittick image ops" {
    var fx = try TestFixture.init();
    defer fx.deinit();
    var f = fx.makeFrame(proto.Rect.make(20, 20, 119, 470));
    defer f.clear(true);

    const base = fx.tree.writes.items.len;
    try f.initTick();
    try fx.disp.flush();

    // Two eager-flushed allocImage 'b' writes, then one flush carrying the 4 draws
    // of frinit.c:53-58 (ground, vertical, top box, bottom box) + trailing 'v'.
    try testing.expectEqual(base + 3, fx.tree.writes.items.len);
    try testing.expectEqual(@as(u8, 'b'), fx.tree.writes.items[base][0]);
    try testing.expectEqual(@as(usize, 51), fx.tree.writes.items[base].len);
    try testing.expectEqual(@as(u8, 'b'), fx.tree.writes.items[base + 1][0]);

    const tid = f.tick.?.id;
    const white = fx.disp.white.id; // BACK (slot 0)
    const black = fx.disp.black.id; // TEXT (slot 3)
    const w = fx.tree.writes.items[base + 2];

    const draws = [_]proto.Op{
        .{ .draw = .{ .dstid = tid, .srcid = white, .maskid = white, .r = proto.Rect.make(0, 0, 3, 18) } }, // ground
        .{ .draw = .{ .dstid = tid, .srcid = black, .maskid = white, .r = proto.Rect.make(1, 0, 2, 18) } }, // vertical at x=1
        .{ .draw = .{ .dstid = tid, .srcid = black, .maskid = white, .r = proto.Rect.make(0, 0, 3, 3) } }, // top box
        .{ .draw = .{ .dstid = tid, .srcid = black, .maskid = white, .r = proto.Rect.make(0, 15, 3, 18) } }, // bottom box
    };
    var exp: [45]u8 = undefined;
    for (draws, 0..) |op, i| {
        _ = try proto.encode(op, exp[0..45]);
        try testing.expectEqualSlices(u8, &exp, w[i * 45 ..][0..45]);
    }
    try testing.expectEqual(@as(u8, 'v'), w[180]);
}
