//! The `:addr` tail of a window load — look.c:874-897 on a body that is
//! already in place. Namespace module (S-07 P-1), pure-moved out of `Load.zig`
//! in phase 17 so that file stays inside the ~400-line cap after `Get`'s file
//! arm landed there (contract §3f). `Load.addressAndShow`/`Load.applyAddress`
//! remain as decl forwarders; the 16b tests moved with the code, names intact.
//! Ported from larryr/plan9port@337c6ac; cite as `look.c:NN` / `addr.c:NN`.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("Editor.zig");
const File = @import("File.zig");
const Text = @import("text/Text.zig");
const Window = @import("Window.zig");
const ast = @import("edit/ast.zig");
const addr_eval = @import("edit/addr.zig");
const parse = @import("edit/parse.zig");
const warp = @import("warp.zig");

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

// ===========================================================================
// Tests — moved verbatim from `Load.zig` (names unchanged).
// ===========================================================================
const testing = std.testing;
const draw = @import("draw");
const boot = @import("boot.zig");
// ---------------------------------------------------------------------------
// 16b item 5 smoke (moved from Load.zig, phase 17): the `:addr` half stops
// at the first rune it cannot use.
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
