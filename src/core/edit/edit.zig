//! The Edit-language entry point (acme/edit.c:151-194 + exec.c:1128-1146),
//! single-threaded collapse. `editcmd` decodes a command string, parses it into a
//! sequence of newline-separated commands, executes them against ONE `cmd.Ctx`
//! (so they share ONE Elog transaction), then applies the buffered transcript
//! ONCE and finalizes (select / scroll / tag), mirroring the C's `allupdate`
//! (edit.c:118-134). `builtin` is the `Edit` B2 command (exectab, R-P10-8).
//!
//! Error model (R-P10-4/§2.7): no editthread/editerrc/longjmp. `editerror`
//! becomes `error.Edit` + a `Diag` message; the whole `runAll` is a single
//! `try`-chain and any error DISCARDS the transaction (elog.term, edit.c:145-146)
//! and surfaces as ONE `ed.warning("Edit: {s}\n", ...)`. A successful Edit that
//! buffered nothing applies nothing (Elog.empty). Never propagates.
//!
//! Ported from larryr/plan9port@337c6ac; cite as `edit.c:NN` / `exec.c:NN`.
const std = @import("std");
const ast = @import("ast.zig");
const cmd = @import("cmd.zig");
const parse = @import("parse.zig");
const Elog = @import("Elog.zig");
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const exec = @import("../exec/exec.zig");

/// `editcmd` (edit.c:151-194), single-threaded. `ct` is the body the commands run
/// against (the C's `curtext`); the caller (the `Edit` builtin, or a test) has
/// already bumped `ed.seq` so the first Elog mutation marks a fresh transaction.
/// Never propagates: every failure is a warning, and the buffer is left untouched
/// on error (the transaction is discarded before any of it applies).
pub fn editcmd(ed: *Editor, ct: *Text, command: []const u8) void {
    if (command.len == 0) return; // edit.c:155-156

    var arena_state = std.heap.ArenaAllocator.init(ed.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const runes = decodeRunes(arena, command) catch {
        ed.warning("Edit: out of memory\n", .{});
        return;
    };

    var x = cmd.Ctx{
        .ed = ed,
        .arena = arena,
        .elog = Elog.init(ed.allocator, ed),
        .rx = &ed.regx,
    };
    defer x.elog.deinit();

    runAll(&x, ct, runes) catch |e| {
        x.elog.term(); // edit.c:145-146 a failed Edit applies NOTHING
        switch (e) {
            error.Edit => ed.warning("Edit: {s}\n", .{x.diag.msg}), // edit.c:191
            error.OutOfMemory => ed.warning("Edit: out of memory\n", .{}),
            else => ed.warning("Edit: command failed\n", .{}), // Text mutation error
        }
    };
}

/// The `editthread` loop (edit.c:79-91) + `allupdate` (edit.c:118-134), collapsed:
/// parse-and-exec each command in turn (all sharing `x.elog`), then apply once and
/// update the view. `allupdate`'s single-window collapse (R-P10-6): the C sweeps
/// every window on the shared File; v1 is single-file, so it is exactly `ct`.
fn runAll(x: *cmd.Ctx, ct: *Text, runes: []const u21) ast.Error!void {
    var p = parse.Parser.init(x.arena, x.ed, &x.diag, runes);
    while (try p.parsecmd(0)) |cp| {
        _ = try cmd.cmdexec(x, ct, cp);
    }
    if (!x.elog.empty()) try x.elog.apply(ct); // elog.c: elogapply on the target body
    try ct.setSelect(ct.q0, ct.q1); // edit.c:132 textsetselect
    try ct.scrDraw(); // edit.c:133 textscrdraw (no-op when w==null)
    if (ct.w) |w| try w.setTag1(); // edit.c:134 winsettag (windows only)
}

/// Decode `command` to runes and guarantee the trailing `\n` `editcmd` needs
/// (edit.c:168-169). Invalid UTF-8 bytes become U+FFFD (buffer-sourced input is
/// already valid; this only guards direct/malformed callers) so the only failure
/// is OOM.
fn decodeRunes(arena: std.mem.Allocator, command: []const u8) error{OutOfMemory}![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i < command.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(command[i]) catch {
            try out.append(arena, 0xFFFD);
            i += 1;
            continue;
        };
        if (i + seq_len > command.len) {
            try out.append(arena, 0xFFFD);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(command[i .. i + seq_len]) catch {
            try out.append(arena, 0xFFFD);
            i += 1;
            continue;
        };
        try out.append(arena, cp);
        i += seq_len;
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n')
        try out.append(arena, '\n');
    return out.items;
}

/// `edit` (exec.c:1128-1146), the `Edit` B2 builtin. The chord `argt` selection
/// WINS over the inline `arg` remainder (getarg, exec.c:1137); `ed.seq += 1`
/// UNCONDITIONALLY before running (exec.c:1141 — Edit manages its own transaction,
/// so the exectab row is `mark=false` and `File.mark` happens lazily inside the
/// first Elog.apply). The command runs against `et`'s window BODY (the C's
/// `curtext = &ct->w->body`, edit.c:180-183); with no window it runs against `et`.
pub fn builtin(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    argt: ?*Text,
    _: bool,
    _: bool,
    arg: []const u8,
) Text.Error!void {
    const argbuf = try exec.getArg(ed, argt); // exec.c:1137 getarg wins over arg
    defer if (argbuf) |b| ed.allocator.free(b);
    ed.seq += 1; // exec.c:1141 seq++ unconditional, before editcmd
    const target: *Text = if (et.w) |w| &w.body else et; // edit.c:180-183
    editcmd(ed, target, argbuf orelse arg);
}

// ==========================================================================
// Tests (side contract §3: tests 7-17, 32-35). Commands are driven through
// `editcmd` on a Text harness (bumping `ed.seq` per Edit, as the builtin does).
// Every expected buffer/dot is hand-derived against the pinned C.
// ==========================================================================
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");
const Window = @import("../Window.zig");
const boot = @import("../boot.zig");

const rect = proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

/// A standalone Text over `seed` with an Editor — no window (setTag1 is skipped,
/// scrDraw is a no-op). `run` bumps `ed.seq` first, mirroring the builtin.
const EH = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,
    ed: Editor,

    fn init(seed: []const u8) !*EH {
        const a = testing.allocator;
        const h = try a.create(EH);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.text = try Text.init(&h.file, a, rect, h.fx.font, &h.fx.disp.image, h.fx.cols());
        h.ed = Editor.init(a);
        h.ed.text = &h.text;
        try h.text.fill();
        return h;
    }
    fn deinit(h: *EH) void {
        h.ed.deinit();
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn sel(h: *EH, q0: usize, q1: usize) !void {
        try h.text.setSelect(q0, q1);
    }
    fn run(h: *EH, command: []const u8) void {
        h.ed.seq += 1; // the builtin's exec.c:1141 seq++
        editcmd(&h.ed, &h.text, command);
    }
    fn bufText(h: *EH) ![]u8 {
        const n = h.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, h.file.buffer.read(0, n, dest));
    }
    fn expectText(h: *EH, want: []const u8) !void {
        const got = try h.bufText();
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
    fn expectDot(h: *EH, q0: usize, q1: usize) !void {
        try testing.expectEqual(q0, h.text.q0);
        try testing.expectEqual(q1, h.text.q1);
    }
    fn warnings(h: *EH) []const u8 {
        return h.ed.warnings.items;
    }
};

test "edit: bare d uses dot" {
    const h = try EH.init("abcdef");
    defer h.deinit();
    try h.sel(2, 4);
    h.run("d");
    try h.expectText("abef");
    try h.expectDot(2, 2);
}

test "edit: line address" {
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run("2d");
        try h.expectText("a\nc\n");
        try h.expectDot(2, 2);
    }
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run("0a/X/"); // insert at rune 0
        try h.expectText("Xa\nb\nc\n");
    }
}

test "edit: compound and whole-file" {
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run(",d"); // whole file
        try h.expectText("");
    }
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run("1,2p"); // report lines 1-2
        try testing.expectEqualStrings("a\nb\n", h.warnings());
        try h.expectText("a\nb\nc\n"); // p never edits
    }
    {
        // DISCREPANCY (documented): the contract wrote `2,1d`, but on adjacent
        // lines line1.q1 == line2.q0, so `2,1` yields the empty range (2,2), NOT
        // an error (ecmd.c:1128's check is `a2.q1 < a1.q0`). `3,1` genuinely
        // reverses (line1.q1=4 < line3.q0=8) and exercises the same path.
        const h = try EH.init("abc\ndef\nghi\n");
        defer h.deinit();
        h.run("3,1d");
        try testing.expect(std.mem.indexOf(u8, h.warnings(), "addresses out of order") != null);
        try h.expectText("abc\ndef\nghi\n"); // nothing applied
    }
}

test "edit: address past EOF" {
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run("99d");
        try testing.expect(std.mem.indexOf(u8, h.warnings(), "address out of range") != null);
        try h.expectText("a\nb\nc\n");
    }
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run("#999d");
        try testing.expect(std.mem.indexOf(u8, h.warnings(), "address out of range") != null);
        try h.expectText("a\nb\nc\n");
    }
}

test "edit: implicit plus" {
    const h = try EH.init("b\nx\ny\n");
    defer h.deinit();
    h.run("/b/2d"); // /b/ +2 lines => line 3 = "y\n"
    try h.expectText("b\nx\n");
    try h.expectDot(4, 4);
}

test "edit: empty file boundaries" {
    {
        const h = try EH.init("");
        defer h.deinit();
        h.run("a/hi/");
        try h.expectText("hi");
    }
    {
        const h = try EH.init("");
        defer h.deinit();
        h.run("1p"); // line 1 of empty is (0,0) => prints ""
        try testing.expectEqualStrings("", h.warnings());
        try h.expectText("");
    }
}

test "edit: a/i dot selects insertion" {
    {
        const h = try EH.init("ab");
        defer h.deinit();
        try h.sel(0, 1);
        h.run("a/X/"); // append at dot.q1=1
        try h.expectText("aXb");
        try h.expectDot(1, 2); // dot = the inserted "X"
    }
    {
        const h = try EH.init("ab");
        defer h.deinit();
        try h.sel(0, 1);
        h.run("i/Y/"); // insert at dot.q0=0
        try h.expectText("Yab");
        try h.expectDot(0, 1); // dot = the inserted "Y" (before the old dot)
    }
}

test "edit: c sets dot to new text" {
    const h = try EH.init("a\nb\n");
    defer h.deinit();
    h.run("1c/zzz/"); // replace line 1 = (0,2) INCLUDING its newline
    try h.expectText("zzzb\n");
    try h.expectDot(0, 3); // dot = "zzz"
}

test "edit: m and t" {
    {
        const h = try EH.init("a\nb\n");
        defer h.deinit();
        h.run("1m$"); // move line 1 to end
        try h.expectText("b\na\n");
    }
    {
        const h = try EH.init("a\nb\n");
        defer h.deinit();
        h.run("1t$"); // copy line 1 to end
        try h.expectText("a\nb\na\n");
    }
    {
        const h = try EH.init("a\nb\n");
        defer h.deinit();
        h.run("1m1"); // move to self: no-op
        try h.expectText("a\nb\n");
    }
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run("1,2m1"); // src (0,4) overlaps dest after line 1
        try testing.expect(std.mem.indexOf(u8, h.warnings(), "move overlaps itself") != null);
        try h.expectText("a\nb\nc\n");
    }
}

test "edit: = reports line and does not move dot" {
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        try h.sel(5, 5); // dot mid-file
        h.run("2="); // report line of line-2's range
        try testing.expectEqualStrings("2\n", h.warnings());
        try h.expectDot(5, 5); // = never moves dot
    }
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run(",=#"); // char range of the whole file
        try testing.expectEqualStrings("#0,#6\n", h.warnings());
    }
}

test "edit: newline command navigates" {
    {
        const h = try EH.init("a\nb\nc\n");
        defer h.deinit();
        h.run("3"); // address-only => nl_cmd shows line 3
        try h.expectDot(4, 6);
    }
    {
        // Bare newline, no address, dot mid-line: extend to the whole line.
        const h = try EH.init("abc\ndef\n");
        defer h.deinit();
        try h.sel(1, 1); // inside "abc"
        h.run("\n");
        try h.expectDot(0, 4); // "abc\n"
    }
}

test "edit: u command" {
    const h = try EH.init("abc");
    defer h.deinit();
    h.run("a/X/"); // transaction 1 => "Xabc", dot (0,1)
    try h.expectText("Xabc");
    h.run("a/Y/"); // transaction 2: append at dot.q1=1 => "XYabc"
    try h.expectText("XYabc");

    h.run("u2"); // undo two steps
    try h.expectText("abc");

    h.run("u-1"); // redo one step
    try h.expectText("Xabc");

    const g = try EH.init("abc");
    defer g.deinit();
    g.run("a/Z/");
    try g.expectText("Zabc");
    g.run("u"); // bare u == one undo
    try g.expectText("abc");
}

test "edit: error discards whole transaction" {
    // First command buffers a replace; the second (99d) errors. The shared elog is
    // discarded, so the buffer is UNCHANGED and one warning is emitted.
    const h = try EH.init("a\nb\nc\n");
    defer h.deinit();
    h.run("1c/X/\n99d");
    try testing.expect(std.mem.indexOf(u8, h.warnings(), "address out of range") != null);
    try h.expectText("a\nb\nc\n"); // the buffered replace never applied
}

test "edit: out-of-sequence warns once and proceeds" {
    // `{2d\n1d}`: dot evaluated once, each child re-addresses absolutely. Deleting
    // line 2 then line 1 records descending q0 => ONE out-of-sequence warning; both
    // deletes apply (reverse-of-append), landing on the clamped result.
    const h = try EH.init("a\nb\nc\n");
    defer h.deinit();
    h.run("{\n2d\n1d\n}");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.warnings(), "changes out of sequence"));
    try h.expectText("b\n"); // reverse-apply artifact: del[0,2) then del[2,4)
}

// --- test 35: the Edit builtin row, driven through `execute` -----------------

const Scene = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,

    fn init(name: []const u8, body: []const u8) !*Scene {
        const a = testing.allocator;
        const h = try a.create(Scene);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 600, 460), .{
            .win_name = name,
            .body = body,
        });
        h.ed = Editor.init(a);
        h.ed.row = h.tree.row;
        return h;
    }
    fn deinit(h: *Scene) void {
        h.ed.deinit();
        h.tree.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn win0(h: *Scene) *Window {
        return h.tree.row.col.items[0].w.items[0];
    }
    fn bodyText(t: *Text) ![]u8 {
        const n = t.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, t.file.buffer.read(0, n, dest));
    }
};

fn tagRange(t: *Text, word: []const u8) [2]usize {
    const nc = t.file.buffer.len();
    var i: usize = 0;
    outer: while (i + word.len <= nc) : (i += 1) {
        for (word, 0..) |ch, j| {
            if (t.file.buffer.runeAt(i + j) != ch) continue :outer;
        }
        return .{ i, i + word.len };
    }
    unreachable;
}

test "edit: builtin row" {
    const builtins = @import("../exec/builtins.zig");
    // The exectab carries Edit with mark=false (exec.c:106), alphabetically between
    // Delete and New.
    var edit_idx: ?usize = null;
    for (&builtins.exectab, 0..) |*e, idx| {
        if (std.mem.eql(u8, e.name, "Edit")) edit_idx = idx;
    }
    const ei = edit_idx.?;
    try testing.expect(!builtins.exectab[ei].mark);
    try testing.expectEqualStrings("Delete", builtins.exectab[ei - 1].name);
    try testing.expectEqualStrings("New", builtins.exectab[ei + 1].name);

    // Inline-arg path: sweeping "Edit ,d" in the tag runs `,d` against the BODY.
    {
        const h = try Scene.init("scratch", "hello world\n");
        defer h.deinit();
        const w = h.win0();
        const tw = w.tag.file.buffer.len();
        try w.tag.insertAt(tw, " Edit ,d", true);
        const rng = tagRange(&w.tag, "Edit ,d");
        try exec.execute(&h.ed, &w.tag, rng[0], rng[1], null);
        const body = try Scene.bodyText(&w.body);
        defer testing.allocator.free(body);
        try testing.expectEqualStrings("", body); // whole body deleted
        try testing.expectEqual(@as(u32, 1), h.ed.seq); // builtin bumped seq once
    }

    // Chord argt OVERRIDES the inline arg: inline "p" would only print, but the
    // argt selection ",d" wins and empties the body.
    {
        const h = try Scene.init("scratch", "hello world\n");
        defer h.deinit();
        const w = h.win0();
        const argw = try h.tree.addWindow("arg", ",d\n");
        try argw.body.setSelect(0, 2); // ",d"
        const tw = w.tag.file.buffer.len();
        try w.tag.insertAt(tw, " Edit p", true);
        const rng = tagRange(&w.tag, "Edit p");
        try exec.execute(&h.ed, &w.tag, rng[0], rng[1], &argw.body);
        const body = try Scene.bodyText(&w.body);
        defer testing.allocator.free(body);
        try testing.expectEqualStrings("", body); // argt ",d" won
    }
}
