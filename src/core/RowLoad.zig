//! One in-flight `Load` (the builtin) — `rowload` (rows.c:559-844 at
//! larryr/plan9port@337c6ac). file-as-struct (S-07 P-1): this file *is* the
//! RowLoad. Cite as `rows.c:NN`.
//!
//! The dump file is read through the namespace with one `nsjob.ReadFileJob`
//! (stepped from `Session.step`); once it is in memory the whole layout is
//! rebuilt in ONE frame with no I/O inside, exactly the order rows.c reads it
//! in. The format is `dumpfmt.zig`'s (R-P17-6). The files the `f` records
//! name are then loaded by ordinary asynchronous `Load`s (the C's synchronous
//! `get`, rows.c:820), each carrying the record's dot as a deferred show.
//!
//! As in acme, loading never clears the existing windows (`initing = FALSE`,
//! rows.c:605), and a malformed line stops the load with `bad load file
//! <path>:<line>`, keeping whatever was built (rows.c:839-842).
//!
//! DIVERGENCES: the `wdir` line is not `chdir`'d (Snarf's working directory is
//! always `/`, R-P13b-3) and the font lines are ignored (one font); the `F`
//! body is inserted directly instead of through a temp file (rows.c:792-816);
//! `x`/`e` records are skipped with a warning (R-P17-6).
//!
//! Imports: `std` + `ninep` + sibling core files (S-07 §6 — never dev/shim).
const std = @import("std");
const ninep = @import("ninep");
const Chrome = @import("Chrome.zig");
const Column = @import("Column.zig");
const Editor = @import("Editor.zig");
const Load = @import("Load.zig");
const Row = @import("Row.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const dumpfmt = @import("dumpfmt.zig");
const openfile = @import("openfile.zig");
const place = @import("place.zig");
const wintag = @import("wintag.zig");

const RowLoad = @This();
const nsjob = ninep.nsjob;

allocator: std.mem.Allocator,
/// Absolute path of the dump file. OWNED; borrowed by the job.
path: []u8,
/// The dump file's bytes (`ReadFileJob`'s sink).
data: std.ArrayList(u8) = .empty,
job: nsjob.ReadFileJob,
finished: bool = false,

/// `rowload(&row, file, FALSE)` from the absolute `path`. Null when the read
/// could not even be set up (warned, rows.c:578-580's wording).
pub fn start(ed: *Editor, path: []const u8) Text.Error!?*RowLoad {
    const a = ed.allocator;
    const ns = ed.ns orelse {
        ed.warning("can't open load file {s}: no namespace\n", .{path});
        return null;
    };
    const self = try a.create(RowLoad);
    errdefer a.destroy(self);
    self.* = .{ .allocator = a, .path = try a.dupe(u8, path), .job = undefined };
    errdefer a.free(self.path);
    self.job = nsjob.ReadFileJob.init(a, ns, self.path, &self.data, nsjob.max_file_bytes) catch |e| {
        ed.warning("can't open load file {s}: {s}\n", .{ path, @errorName(e) });
        a.free(self.path);
        a.destroy(self);
        return null;
    };
    return self;
}

pub fn deinit(self: *RowLoad) void {
    self.job.deinit();
    self.data.deinit(self.allocator);
    self.allocator.free(self.path);
    self.* = undefined;
}

/// One state: the read, then — in the frame it completes — the whole rebuild.
pub fn step(self: *RowLoad, ed: *Editor) Text.Error!void {
    if (self.finished) return;
    const st = self.job.step() catch |e| {
        ed.warning("can't open load file {s}: {s}\n", .{ self.path, @errorName(e) }); // rows.c:579
        self.finished = true;
        return;
    };
    if (st == .pending) return;
    self.finished = true;
    var p = Parser{ .data = self.data.items };
    apply(ed, &p) catch |e| switch (e) {
        error.BadLoad => ed.warning("bad load file {s}:{d}\n", .{ self.path, p.line }), // rows.c:840
        else => |x| return x,
    };
    ed.needs_flush = true;
}

const Error = Text.Error || error{BadLoad};

/// `Brdline` + the line counter (rows.c:515-524): one '\n'-terminated line
/// (returned without it). An unterminated tail is end of file, as with Brdline.
const Parser = struct {
    data: []const u8,
    pos: usize = 0,
    line: usize = 0,

    fn next(p: *Parser) ?[]const u8 {
        const rest = p.data[p.pos..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
        p.pos += nl + 1;
        p.line += 1;
        return rest[0..nl];
    }

    fn need(p: *Parser) error{BadLoad}![]const u8 {
        return p.next() orelse error.BadLoad;
    }
};

/// rows.c:586-837 over the bytes in hand.
fn apply(ed: *Editor, p: *Parser) Error!void {
    const row = ed.row orelse return;
    _ = try p.need(); // rows.c:587-594 wdir (no chdir: wdir is always `/`)
    _ = try p.need(); // rows.c:596-603 the two global fonts — one font, ignored
    _ = try p.need();
    var pbuf: [10]f64 = undefined;
    const pcts = dumpfmt.parsePcts(try p.need(), &pbuf) orelse return error.BadLoad; // rows.c:606-613
    try placeColumns(row, pcts);

    // rows.c:641-681: the `c`/`w` tag lines, until the first window record.
    var l = p.next();
    while (l) |line| : (l = p.next()) {
        if (line.len == 0) break;
        switch (line[0]) {
            'c' => {
                if (line.len < 12) return error.BadLoad;
                const i = dumpfmt.atoi(line[1..]);
                if (i >= row.col.items.len) return error.BadLoad;
                const rest = line[12..];
                const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len; // rows.c:650-655
                try replaceText(ed, &row.col.items[i].tag, rest[@min(rest.len, sp + 1)..]);
            },
            'w' => try replaceText(ed, &row.tag, line[@min(line.len, 2)..]), // rows.c:660-670
            else => break,
        }
    }

    // rows.c:682-837: the window records.
    while (l) |line| : (l = p.next()) {
        const rec = dumpfmt.parseWinRec(line) orelse return error.BadLoad;
        switch (rec.kind) {
            .e => { // rows.c:684-705: ctl, directory, command
                ed.warning("load: external/zerox record skipped\n", .{});
                for (0..3) |_| _ = try p.need();
                continue;
            },
            .x => { // a zerox: its ctl+tag line only
                ed.warning("load: external/zerox record skipped\n", .{});
                _ = try p.need();
                continue;
            },
            .f, .F => try loadWindow(ed, row, p, rec),
        }
    }
}

/// rows.c:614-640: move the existing column borders to the dumped percents
/// (pairwise, both sides keeping ≥ 50 px), and add any extra columns.
fn placeColumns(row: *Row, pcts: []const f64) Text.Error!void {
    const screen = &row.chrome.display.image;
    const bd = Chrome.border;
    const ncol = row.col.items.len;
    const dx: f64 = @floatFromInt(row.r.max.x - row.r.min.x);
    for (pcts, 0..) |pc, i| {
        var x: i32 = row.r.min.x + @as(i32, @intFromFloat(pc * dx / 100.0 + 0.5)); // rows.c:615
        if (i < ncol) {
            if (i == 0) continue; // rows.c:617-618
            const c1 = row.col.items[i - 1];
            const c2 = row.col.items[i];
            var r1 = c1.r;
            var r2 = c2.r;
            if (x < bd) x = bd; // rows.c:623-624
            r1.max.x = x - bd;
            r2.min.x = x;
            if (r1.max.x - r1.min.x < 50 or r2.max.x - r2.min.x < 50) continue; // rows.c:627-628
            try screen.draw(.{ .min = r1.min, .max = r2.max }, row.chrome.white, null, .{}); // rows.c:629
            try c1.resize(r1);
            try c2.resize(r2);
            r2.min.x = x - bd;
            r2.max.x = x;
            try screen.draw(r2, row.chrome.black, null, .{}); // rows.c:632-634
        } else {
            _ = try row.add(x); // rows.c:636-637 rowadd(row, nil, x)
        }
    }
}

/// One `f`/`F` record and the lines that belong to it (rows.c:733-833).
fn loadWindow(ed: *Editor, row: *Row, p: *Parser, rec: dumpfmt.WinRec) Error!void {
    const a = ed.allocator;
    if (rec.col > 10 or row.col.items.len == 0) return error.BadLoad; // rows.c:750-751
    const c: *Column = row.col.items[@min(rec.col, row.col.items.len - 1)]; // rows.c:752-754
    const dy: f64 = @floatFromInt(c.r.max.y - c.r.min.y);
    var y: i32 = c.r.min.y + @as(i32, @intFromFloat(rec.pct * dy / 100.0 + 0.5)); // rows.c:755
    if (y < c.r.min.y or y >= c.r.max.y) y = -1; // rows.c:756-757
    const w = try place.mintWindow(c, y, ""); // rows.c:759 coladd(c, nil, nil, y)

    // rows.c:767-789: the ctl+tag line — name up to the first blank, then the
    // user's suffix after the first '|'.
    const tag = try dumpfmt.tagOf(a, try p.need());
    defer a.free(tag);
    const clean = try Load.sanitize(a, tag);
    defer a.free(clean.bytes);
    const t = clean.bytes;
    const n = std.mem.indexOfScalar(u8, t, ' ') orelse t.len; // rows.c:790-795
    const name = t[0..n];
    try wintag.setName(w, name); // rows.c:796-797 winsetname
    try wintag.clearTag(w); // rows.c:800 wincleartag
    if (std.mem.indexOfScalarPos(u8, t, n, '|')) |bar| { // rows.c:798-799
        try w.tag.insertAt(w.tag.file.buffer.len(), t[bar + 1 ..], true); // rows.c:801
    }

    var load: ?*Load = null;
    if (rec.ndumped) |nd| { // rows.c:802-826: the body, `nd` RUNES of the stream
        const rest = p.data[p.pos..];
        const nb = dumpfmt.runeBytes(rest, nd) orelse return error.BadLoad; // rows.c:812-818
        p.line += std.mem.count(u8, rest[0..nb], "\n"); // rows.c:810-811
        p.pos += nb;
        const body = try Load.sanitize(a, rest[0..nb]);
        defer a.free(body.bytes);
        try w.body.insertAt(0, body.bytes, true); // seq 0: no undo (textload)
        w.body.file.mod = true; // rows.c:822
        w.dirty = true; // rows.c:823-824
        try w.setTag(); // rows.c:825
    } else if (name.len != 0 and !scratchName(name)) { // rows.c:826-827
        const abs = try openfile.absName(a, name);
        defer a.free(abs);
        load = try Load.start(ed, w, abs, null, false); // the asynchronous `get`
    }

    // rows.c:833-835: clamp, then show. For a pending `f` load the body is
    // still empty, so the show is handed to the Load's tail.
    if (load) |ld| ld.show_range = .{ .q0 = rec.q0, .q1 = rec.q1 };
    const nc = w.body.file.buffer.len();
    const ok = rec.q0 <= nc and rec.q1 <= nc and rec.q0 <= rec.q1;
    try w.body.show(if (ok) rec.q0 else 0, if (ok) rec.q1 else 0, true);
}

/// rows.c:826 `r[ns+1]!='+' && r[ns+1]!='-'`: the name's last component starts
/// with `+` or `-` (`+Errors`, `-host` windows) — not a file to read.
fn scratchName(name: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
    return base.len != 0 and (base[0] == '+' or base[0] == '-');
}

/// rows.c:656-657 / :666-667: replace a whole tag with the dumped text.
fn replaceText(ed: *Editor, t: *Text, bytes: []const u8) Text.Error!void {
    const clean = try Load.sanitize(ed.allocator, bytes);
    defer ed.allocator.free(clean.bytes);
    try t.deleteRange(0, t.file.buffer.len(), true);
    try t.insertAt(0, clean.bytes, true);
}

// ==========================================================================
// Smoke test. The named battery (T16/T17) is the test writer's.
// ==========================================================================
const testing = std.testing;

test "RowLoad: scratchName follows the last component" {
    try testing.expect(scratchName("+Errors"));
    try testing.expect(scratchName("/a/b/+Errors"));
    try testing.expect(scratchName("/x/-host"));
    try testing.expect(!scratchName("/a/b/c.zig"));
    try testing.expect(!scratchName("/a/+b/c"));
}
