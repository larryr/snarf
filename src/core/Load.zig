//! One in-flight window load — `textload` (text.c:192-317) turned inside out.
//! file-as-struct (S-07 P-1): this file *is* the Load.
//! Ported from larryr/plan9port@337c6ac; cite as `text.c:NN` / `look.c:NN`.
//!
//! WHY IT IS A STRUCT AND NOT A FUNCTION. acme's `textload` is three blocking
//! syscalls in a row — `open`, `dirfstat`, then `dirread`/`fileload` — and the
//! kernel simply blocks the proc in between. Snarf reads through the 9P
//! namespace, whose replies for `/n/origin` only arrive on a LATER browser tick
//! (`wsPush`), and the main thread must not block (R-9P-13, R-P6-4). So the
//! three syscalls become three `ninep.nsjob` jobs run one state per frame:
//!
//!     StatJob ──QTDIR?──> ListDirJob ──> dirwin.applyListing   (text.c:216-247)
//!             └─else────> ReadFileJob ─> insertAt(0, …)        (text.c:249-253)
//!
//! `Editor.loads` holds the live ones; `Editor.frameEnd` calls `stepAll` once a
//! frame, BEFORE `errors.flushWarnings`, so a load error's warning reaches its
//! `+Errors` window in the same frame the load failed in.
//!
//! POINTER STABILITY (nsjob.zig's rule): a job borrows its own `path` and hands
//! its inline reply buffer to a live ticket, so it must not MOVE once `step` has
//! run. Every `Load` is therefore heap-allocated and `Editor.loads` is a list of
//! POINTERS — a deviation from the contract's literal `ArrayList(Load)`, which
//! would relocate its elements on growth and hand the 9P client dangling reply
//! buffers.
//!
//! A window deleted mid-load drops its `Load` through `dropWindow` (wired to
//! `Editor.dropTextRefs`, the same backpointer-hygiene seam `textclose` uses).
//! That is safe with no coordination because 13a's tickets are TOMBSTONED: the
//! job's `deinit` cancels fire-and-forget and the server's later reply lands in
//! a tombstone instead of poisoning the next ticket.
//!
//! Imports: `std` + `draw` + `ninep` + sibling core files (S-07 §6 — never
//! dev/shim). `/dev` and `/dev/draw` are reached through `nsjob` ONLY.
const std = @import("std");
const ninep = @import("ninep");
const Editor = @import("Editor.zig");
const File = @import("File.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const dirwin = @import("dirwin.zig");
const pendinglook = @import("pendinglook.zig");
const ast = @import("edit/ast.zig");
const addr_eval = @import("edit/addr.zig");
const parse = @import("edit/parse.zig");
const warp = @import("warp.zig");

const Load = @This();
const nsjob = ninep.nsjob;
const Stat = ninep.stat;

/// The three 9P jobs a load runs, in the order `textload` performs them.
pub const Job = union(enum) {
    stat: nsjob.StatJob,
    dir: nsjob.ListDirJob,
    file: nsjob.ReadFileJob,
};

allocator: std.mem.Allocator,
/// The window being loaded into. Dropped (with this Load) by `dropWindow` if it
/// dies first.
w: *Window,
/// The absolute, cleaned path. OWNED, and BORROWED by the live job — it must
/// outlive every job this Load starts, which is why it lives here and not in
/// the caller's frame.
name: []u8,
/// The `:addr` text of the expansion that opened this window (`e->a0..e->a1`,
/// look.c:874-893), evaluated against the loaded body once it is in place.
/// Owned.
addr: ?[]u21 = null,
/// `e->jump` (look.c:897). Carried across the asynchronous load and spent at
/// the tail (`addressAndShow`) on a `/dev/mouse` warp request — R-P15-3, the
/// R-EDIT-25 amendment. `readfile`'s boot window passes FALSE: acme.c:285-300
/// has no `moveto`.
jump: bool = false,
// (`textload`'s `setqid` argument, text.c:192/:277-284, has no Snarf analog yet —
// no qid cache to update; reintroduce with Put/Get.)
/// `ReadFileJob`'s sink.
data: std.ArrayList(u8) = .empty,
job: Job,
/// True once the load has finished (successfully or not); `stepAll` reaps it.
finished: bool = false,

// ==========================================================================
// Starting a load
// ==========================================================================

/// Begin loading `name` into `w` (the `textload(t, 0, e->bname, 1)` of
/// look.c:857 / acme.c:298). `name` and `addr` are COPIED. Fails only on OOM or
/// a syntactically impossible path; every other failure — the path does not
/// exist, the server refuses it — arrives later as the `can't open` warning
/// text.c:216 emits.
pub fn start(
    ed: *Editor,
    w: *Window,
    name: []const u8,
    a0: ?[]const u21,
    jump: bool,
) Text.Error!void {
    const a = ed.allocator;
    const ns = ed.ns orelse {
        // No mount table at all (headless harnesses): the C would have failed
        // its `open`, so say exactly what it says.
        ed.warning("can't open {s}: no namespace\n", .{name});
        return;
    };

    // One load per window (review nit, 13b): a `Get` or a second B3 while a
    // load is still in flight must not leave two loads racing to install into
    // the same body. Drop the older one (its job deinit is tombstone-safe, 13a).
    dropLoadsFor(ed, w);

    const self = try a.create(Load);
    errdefer a.destroy(self);
    self.* = .{
        .allocator = a,
        .w = w,
        .name = try a.dupe(u8, name),
        .jump = jump,
        .job = undefined,
    };
    errdefer a.free(self.name);
    if (a0) |ap| {
        self.addr = try a.dupe(u21, ap);
    }
    errdefer if (self.addr) |ap| a.free(ap);

    self.job = .{ .stat = nsjob.StatJob.init(ns, self.name) catch |e| {
        ed.warning("can't open {s}: {s}\n", .{ name, @errorName(e) });
        a.free(self.name);
        if (self.addr) |ap| a.free(ap);
        a.destroy(self);
        return;
    } };
    try ed.loads.append(a, self);
}

pub fn deinit(self: *Load) void {
    switch (self.job) {
        .stat => |*j| j.deinit(),
        .dir => |*j| j.deinit(),
        .file => |*j| j.deinit(),
    }
    self.data.deinit(self.allocator);
    self.allocator.free(self.name);
    if (self.addr) |ap| self.allocator.free(ap);
    self.* = undefined;
}

// ==========================================================================
// The frame loop
// ==========================================================================

/// Advance every live load by one state, then the parked B3 look (R-P13b-2).
/// Called once per frame from `Editor.frameEnd`, BEFORE `flushWarnings`.
pub fn stepAll(ed: *Editor) Text.Error!void {
    var i: usize = 0;
    while (i < ed.loads.items.len) {
        const ld = ed.loads.items[i];
        try ld.step(ed);
        if (ld.finished) {
            _ = ed.loads.orderedRemove(i);
            ld.deinit();
            ed.allocator.destroy(ld);
        } else i += 1;
    }
    try pendinglook.stepPending(ed); // the parked B3 look (R-P13b-2)
}

/// `textclose`'s backpointer hygiene (text.c:109-118) extended to the
/// asynchronous loads: a window that dies mid-load drops its Load, whose job
/// `deinit` is tombstone-safe. Reached from `Editor.dropTextRefs`.
pub fn dropWindow(ed: *Editor, w: *Window) void {
    dropLoadsFor(ed, w);
    pendinglook.dropWindow(ed, w);
}

/// Abandon every in-flight load targeting `w` (the load half of `dropWindow`;
/// also `start`'s one-load-per-window guard).
fn dropLoadsFor(ed: *Editor, w: *Window) void {
    var i: usize = 0;
    while (i < ed.loads.items.len) {
        const ld = ed.loads.items[i];
        if (ld.w != w) {
            i += 1;
            continue;
        }
        _ = ed.loads.orderedRemove(i);
        ld.deinit();
        ed.allocator.destroy(ld);
    }
}

/// Editor teardown: abandon every in-flight load and the parked look.
pub fn deinitAll(ed: *Editor) void {
    for (ed.loads.items) |ld| {
        ld.deinit();
        ed.allocator.destroy(ld);
    }
    ed.loads.deinit(ed.allocator);
    pendinglook.dropPending(ed);
}

/// One state of this load. Never blocks; never pumps (R-P13a-3) — the entry
/// point polls every in-process server once a tick and the origin's frames
/// arrive on `wsPush`, so a job completes on some later `frameEnd`.
pub fn step(self: *Load, ed: *Editor) Text.Error!void {
    if (self.finished) return;
    switch (self.job) {
        .stat => |*j| {
            const st = j.step() catch |e| return self.fail(ed, e);
            if (st == .pending) return;
            // text.c:213-215 `dirfstat`: QTDIR decides which of the two arms
            // below runs. Read the verdict BEFORE `deinit` (the record's
            // strings alias the job).
            const isdir = j.result.qid.qtype.dir or (j.result.mode & Stat.DMDIR) != 0;
            j.deinit();
            const ns = ed.ns.?; // `start` refused to create a Load without one
            if (isdir) {
                self.job = .{ .dir = nsjob.ListDirJob.init(self.allocator, ns, self.name) catch |e|
                    return self.fail(ed, e) };
            } else {
                self.job = .{
                    .file = nsjob.ReadFileJob.init(
                        self.allocator,
                        ns,
                        self.name,
                        &self.data,
                        nsjob.max_file_bytes, // R-EDIT-10
                    ) catch |e| return self.fail(ed, e),
                };
            }
        },
        .dir => |*j| {
            const st = j.step() catch |e| return self.fail(ed, e);
            if (st == .pending) return;
            try dirwin.applyListing(ed, self.w, j.entries.items); // text.c:218-266
            self.finished = true;
            try self.finishTail(ed);
        },
        .file => |*j| {
            const st = j.step() catch |e| return self.fail(ed, e);
            if (st == .pending) return;
            try self.installFile(ed);
            self.finished = true;
            try self.finishTail(ed);
        },
    }
}

/// `warning(nil, "can't open %s: %r\n", file); return -1` (text.c:216). The
/// window STAYS — empty and named — exactly as acme leaves it after a failed
/// `textload` (look.c:857 ignores the return value for everything but
/// `file->unread`).
fn fail(self: *Load, ed: *Editor, e: anyerror) void {
    ed.warning("can't open {s}: {s}\n", .{ self.name, @errorName(e) });
    self.finished = true;
}

/// The non-directory arm (text.c:249-253 `fileload`): replace the body with the
/// bytes read. Invalid UTF-8 becomes U+FFFD with ONE warning per load — the
/// port's standing rule (S-05 §1), where the C instead elides NULs and warns
/// "%s: NUL bytes elided" (text.c:311).
fn installFile(self: *Load, ed: *Editor) Text.Error!void {
    const w = self.w;
    const t = &w.body;
    w.isdir = false; // text.c:249
    w.filemenu = true; // text.c:250
    try dirwin.resetText(t);
    if (self.data.items.len != 0) {
        const clean = try sanitize(self.allocator, self.data.items);
        defer self.allocator.free(clean.bytes);
        if (clean.replaced) ed.warning("{s}: invalid UTF-8 replaced\n", .{self.name});
        try t.insertAt(0, clean.bytes, true);
    }
}

/// The tail every `textload` caller repeats (look.c:865-897 / acme.c:295-300):
/// the window is clean, its tag recomposed with the caret parked at the end,
/// then the deferred address is evaluated and shown.
fn finishTail(self: *Load, ed: *Editor) Text.Error!void {
    const w = self.w;
    const t = &w.body;
    t.file.mod = false; // look.c:866
    w.dirty = false; // look.c:867
    try w.setTag1(); // look.c:868 winsettag
    const tnc = w.tag.file.buffer.len();
    try w.tag.setSelect(tnc, tnc); // look.c:869
    w.tag_state = .{
        .undo = t.file.undoSeq() != 0,
        .redo = t.file.redoSeq() != 0,
        .mod = t.file.mod,
    };
    try addressAndShow(ed, w, self.addr, self.jump);
}

/// look.c:874-897 on a body that is already in place: evaluate the `:addr` half
/// of the expansion, show the range it names (the current dot when there is no
/// address or it does not evaluate, look.c:891-893) and record the body as the
/// command target. `openfile.openFile` runs this directly on the path that
/// REUSES an already-open window — the one path with no load to wait for.
///
/// `moveto` (look.c:897) is issued as a `/dev/mouse` write when `jump`
/// (R-P15-3): the native host warps the pointer into the window that just
/// opened, the browser host ignores it (R-EDIT-25's divergence, made literal).
pub fn addressAndShow(ed: *Editor, w: *Window, a0: ?[]const u21, jump_in: bool) Text.Error!void {
    const t = &w.body;
    var r = File.Range{ .q0 = t.q0, .q1 = t.q1 }; // look.c:876 eval=FALSE default
    // look.c:892 `if(eval == FALSE) e->jump = FALSE` — an out-of-order address,
    // or one that parsed and then failed to evaluate, suppresses the warp
    // (review fix, phase 15). A run that is not an address at all does NOT:
    // see the `error.Edit` arm below (16b item 5).
    var jump = jump_in;
    if (a0) |ap| {
        if (applyAddress(ed, t, ap)) |got| {
            if (got.q0 > got.q1) {
                ed.warning("addresses out of order\n", .{}); // look.c:882-884
                jump = false;
            } else r = got;
        } else |e| switch (e) {
            // NOT AN ADDRESS AT ALL. `address()` reads runes one at a time and
            // its `default:` arm — anything that is not an address character —
            // simply stops and returns the range it came in with, the current
            // dot, leaving `*evalp` TRUE. So acme shows dot, says nothing, and
            // still jumps. Only an address that PARSED and then failed to
            // evaluate is announced, and `number()`/`regexp()` are the ones
            // that announce it ("address out of range", "no match for
            // regexp") — which is the arm below.
            // [addr.c:193-195 address() default; :141 number() Rescue;
            //  :167 regexp(); look.c:876-893]
            error.Edit => {},
            else => {
                ed.warning("{s}\n", .{addr_eval.describe(e)});
                jump = false;
            },
        }
    }
    try t.show(r.q0, r.q1, true); // look.c:894 textshow(t, r.q0, r.q1, 1)
    try w.setTag1(); // look.c:895
    ed.seltext = t; // look.c:896
    if (jump) warp.toSelection(ed, t); // look.c:897 moveto
    ed.needs_flush = true;
}

/// `address(TRUE, t, range(-1,-1), range(t->q0,t->q1), e->u.at, e->a0, e->a1,
/// …)` (look.c:880) over the ALREADY-EXTRACTED address runes. acme re-reads the
/// characters from the source Text through `agetc`; the port captured them when
/// the expansion was made, because by the time the load completes the source
/// selection may be long gone.
///
/// `parse.Parser.compoundaddr` is the Edit language's own address parser
/// (edit.c:665-686) — the same grammar `address()` implements by hand, so `3`,
/// `/^main/`, `#12`, `1,5` and `$` all mean here exactly what they mean in an
/// `Edit` command.
///
/// IT STOPS AT THE FIRST RUNE IT CANNOT USE, exactly as `address()` does
/// (addr.c:193-195 `default: *qp = q-1; return r`), and the remainder is
/// ignored: `file:3x` is line 3 and `file:12,` is line 12 through `$` (the
/// comma's right-hand side defaults to end of file, addr.c:204-206). The
/// expansion hands over the whole run between the colon and the next white
/// space (look.c:630-636 `amax`), so a trailing non-address rune is ordinary,
/// not exceptional. `error.Edit` means the run named NO address — the caller
/// treats that as acme's `default:` arm, not as a failure.
pub fn applyAddress(ed: *Editor, t: *Text, runes: []const u21) (ast.Error || addr_eval.Error)!File.Range {
    var arena_state = std.heap.ArenaAllocator.init(ed.allocator);
    defer arena_state.deinit();
    var diag: ast.Diag = .{};
    var p = parse.Parser.init(arena_state.allocator(), ed, &diag, runes);
    const ap = (try p.compoundaddr()) orelse return error.Edit;
    const got = try addr_eval.eval(&ed.regx, ap, addr_eval.mkAddr(t), 0);
    return got.r;
}

/// UTF-8 sanitation for loaded bytes (S-05 §1): every invalid sequence becomes
/// one U+FFFD. `Text.insertAt` documents its input as valid UTF-8, so this runs
/// on EVERY loaded file, not only suspicious ones.
fn sanitize(a: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!struct { bytes: []u8, replaced: bool } {
    if (std.unicode.utf8ValidateSlice(bytes)) return .{ .bytes = try a.dupe(u8, bytes), .replaced = false };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i..][0..n])) {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        }
        try out.appendSlice(a, bytes[i..][0..n]);
        i += n;
    }
    return .{ .bytes = try out.toOwnedSlice(a), .replaced = true };
}

// ==========================================================================
// Smoke tests. The named battery (T11) is the test writer's; these only keep
// the module's decls reachable and pin the pure helper.
// ==========================================================================
const testing = std.testing;

test "Load: sanitize replaces invalid UTF-8 with U+FFFD and reports it" {
    const a = testing.allocator;
    const ok = try sanitize(a, "héllo");
    defer a.free(ok.bytes);
    try testing.expect(!ok.replaced);
    try testing.expectEqualStrings("héllo", ok.bytes);

    const bad = try sanitize(a, "a\xffb");
    defer a.free(bad.bytes);
    try testing.expect(bad.replaced);
    try testing.expectEqualStrings("a\u{FFFD}b", bad.bytes);
}

test "Load: with no namespace a load warns instead of trapping" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var w: Window = undefined;
    try start(&ed, &w, "/nowhere", null, false);
    try testing.expectEqual(@as(usize, 0), ed.loads.items.len);
    try testing.expectEqualStrings("can't open /nowhere: no namespace\n", ed.warningText());
}

// ===========================================================================
// Named battery (phase-13b contract §4, T11).
// ===========================================================================
const draw = @import("draw");
const boot = @import("boot.zig");
const openfile = @import("openfile.zig");
const served_fsys = @import("served/fsys.zig");
const Column = @import("Column.zig");

fn pumpT11(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}

test "Load: a missing file's window stays empty+named and warns can't open into +Errors (T11)" {
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();

    var ns = ninep.mount.Namespace.init(testing.allocator);
    defer ns.deinit();

    var tree = try boot.boot(testing.allocator, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 640, 480), .{
        .win_name = "one",
        .body = "",
        .ns = &ns,
    });
    defer tree.deinit();

    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    tree.bind(&ed);

    // Serve /mnt/snarf-self for real so a StatJob against a name under it gets
    // a genuine "file does not exist" from the SERVER (text.c:216's actual
    // failure shape), not merely nsjob's "nothing is mounted here" verdict.
    var fsys = served_fsys.Fsys.init(&ed);
    var pipe = try ninep.chan.Pipe.init(testing.allocator, 16384);
    defer pipe.deinit();
    var srv = try ninep.server.Server.init(testing.allocator, pipe.serverEnd(), &served_fsys.Fsys.ops, &fsys, 8192);
    defer srv.deinit();
    var cl = try ninep.Client.init(testing.allocator, pipe.clientEnd(), 8192);
    defer cl.deinit();
    cl.pump = .{ .ctx = &srv, .run = pumpT11 };
    _ = try cl.version(8192);
    const root = try cl.attach("larry", "");
    try ns.mount("/mnt/snarf-self", &cl, root.fid);

    const col = tree.row.col.items[0];
    const target = try openfile.readFile(&ed, col, "/mnt/snarf-self/nonexistent");

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try ed.frameEnd(fx.disp); // steps Load.stepAll then flushes warnings (§3b)
        _ = try srv.poll();
    }

    try testing.expect(!ed.warningsPending()); // drained into `+Errors`

    // The window being loaded stays: empty, still named, never flipped to a
    // directory (text.c:216 "the window stays" — acme leaves a failed load's
    // window exactly as it was).
    try testing.expectEqual(@as(usize, 0), target.body.file.buffer.len());
    try testing.expectEqualStrings("/mnt/snarf-self/nonexistent", target.body.file.name.items);
    try testing.expect(!target.isdir);

    // The `+Errors` window landed in the rightmost column (util.c:98) with the
    // exact "can't open" text.
    const errw = col.w.items[col.w.items.len - 1];
    try testing.expectEqualStrings("+Errors", errw.body.file.name.items);
    var ebuf: [256]u8 = undefined;
    const etxt = errw.body.file.buffer.read(0, errw.body.file.buffer.len(), &ebuf);
    try testing.expect(std.mem.startsWith(u8, etxt, "can't open /mnt/snarf-self/nonexistent: "));

    // --- a window deleted mid-load drops its Load without error ------------
    const w2 = try openfile.readFile(&ed, col, "/mnt/snarf-self/gone-too");
    try testing.expectEqual(@as(usize, 1), ed.loads.items.len);
    try col.close(&ed, w2, true); // dropTextRefs -> Load.dropWindow (tombstone-safe)
    try testing.expectEqual(@as(usize, 0), ed.loads.items.len);

    // The server's reply, when it eventually lands, hits a tombstoned ticket
    // harmlessly — a few more frames must not trap or warn again.
    const warnings_before = ed.warnings.items.len;
    i = 0;
    while (i < 8) : (i += 1) {
        try ed.frameEnd(fx.disp);
        _ = try srv.poll();
    }
    try testing.expectEqual(warnings_before, ed.warnings.items.len);
}

// ---------------------------------------------------------------------------
// 16b item 5 smoke: the `:addr` half stops at the first rune it cannot use.
// ---------------------------------------------------------------------------
const Buffer = @import("Buffer.zig");

test "Load: applyAddress stops at the first non-address rune (16b item 5)" {
    // [addr.c:175-296 address(); look.c:630-636 the amax run]
    const a = testing.allocator;
    var ed = Editor.init(a);
    defer ed.deinit();
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var file = File.init(a, try Buffer.initFromBytes(a, "abc\ndef\nghi\njkl\n"));
    defer file.deinit();
    const rect = draw.proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };
    var t = try Text.init(&file, a, rect, fx.font, &fx.disp.image, fx.cols());
    defer t.deinit();
    try t.fill();

    const line2 = File.Range{ .q0 = 4, .q1 = 8 };
    // (No white space in these: the expansion's `amax` already ends the run
    // at the first space/tab/newline — look.c:630-636.)
    for ([_][]const u8{ "2", "2x", "2x9", "2:z" }) |s| {
        var buf: [8]u21 = undefined;
        for (s, 0..) |c, i| buf[i] = c;
        try testing.expectEqual(line2, try applyAddress(&ed, &t, buf[0..s.len]));
    }
    // `file:12,` — the comma's right-hand side defaults to `$` (addr.c:204-206).
    var comma = [_]u21{ '2', ',' };
    try testing.expectEqual(File.Range{ .q0 = 4, .q1 = 16 }, try applyAddress(&ed, &t, &comma));

    // A run that names no address at all is `address()`'s `default:` arm, not
    // an error the user hears about: dot, in silence.
    var junk = [_]u21{'x'};
    try testing.expectError(error.Edit, applyAddress(&ed, &t, &junk));
}

test "Load: addressAndShow — error.Edit is dot in silence; an evaluation failure warns (16b item 5 integration)" {
    // look.c:876-894, the `addressAndShow` tail. `error.Edit` (the parser's
    // `default:` arm, not an address at all) shows the CURRENT dot with no
    // warning; an address that PARSES and then fails to evaluate — here an
    // out-of-order compound, "5,1" (line 5's start, line 1's end, q0>q1) —
    // warns "addresses out of order" (look.c:882-884) and ALSO shows dot,
    // through the OTHER arm.
    const a = testing.allocator;
    var fx = try draw.Frame.TestFixture.init();
    defer fx.deinit();
    var tree = try boot.boot(a, fx.disp, fx.font, draw.proto.Rect.make(0, 0, 600, 460), .{
        .win_name = "one",
        .body = "abc\ndef\nghi\njkl\n",
    });
    defer tree.deinit();
    const w = tree.row.col.items[0].w.items[0];

    var ed = Editor.init(a);
    defer ed.deinit();

    // Dot pinned at [4,8) ("def") so "unchanged" is unambiguous.
    try w.body.setSelect(4, 8);
    const before = ed.warnings.items.len;
    var junk = [_]u21{'%'};
    try addressAndShow(&ed, w, &junk, true);
    try testing.expectEqual(before, ed.warnings.items.len); // silent — error.Edit
    try testing.expectEqual(@as(usize, 4), w.body.q0); // dot, unchanged
    try testing.expectEqual(@as(usize, 8), w.body.q1);

    // "5,1": parses fine as a compound address, then fails at EVALUATION
    // (q0 > q1) — the other arm, which DOES warn.
    try w.body.setSelect(4, 8);
    var backwards = [_]u21{ '5', ',', '1' };
    try addressAndShow(&ed, w, &backwards, true);
    try testing.expectEqual(before + 1, ed.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, ed.warningText(), "addresses out of order") != null);
    try testing.expectEqual(@as(usize, 4), w.body.q0); // still dot: the default `r`
    try testing.expectEqual(@as(usize, 8), w.body.q1);
}
