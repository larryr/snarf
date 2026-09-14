//! The editor context: owns what ACME's `dat.c` declared as 60 globals (P-3).
//! No globals anywhere else — state hangs off this struct, allocator stored
//! explicitly (P-4). file-as-struct (P-1): this file *is* the Editor.
//! [ref: acme/dat.c + globals]
//!
//! Sub-wave 6c grows this into the interactive editing loop's HOME (R-P6-12):
//! the routing state machine (`handleMouse`/`handleKey`/`frameEnd`) lives here
//! so it is testable natively with no browser and no devinput; `main_wasm` keeps
//! only the adapter that drains the input device into `MouseEvent`s/runes and
//! calls these. The machine is `acme/text.c`'s per-window mouse/keyboard dispatch
//! (text.c:668-942 for keys, 1005-1099 for `textselect`) reduced to the single
//! phase-6/7 gesture set (F-9 single-Text; scroll via the wheel/nav keys).
//!
//! The snarf buffer and the `cut`/`snarfInsert` ops (exec.c:947-1073) live here;
//! /dev/snarf + clipboard sync are deferred (R-P7-5, S-05 §7). Phase 12e carved
//! the mouse gesture machine out to `Gesture.zig` (its doc paragraph went with
//! it); `handleMouse`/`hitTest` below are one-line forwarders into it.
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");
const Text = @import("text/Text.zig");
const typing = @import("text/typing.zig");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");
const Row = @import("Row.zig");
const Column = @import("Column.zig");
const Window = @import("Window.zig");
const errors = @import("errors.zig");
const Gesture = @import("Gesture.zig");
const snarf_ops = @import("snarf.zig");
const place = @import("place.zig");
const exec = @import("exec/exec.zig");
const look = @import("look.zig");
const Load = @import("Load.zig");
const expand = @import("expand.zig");
const Regx = @import("edit/Regx.zig");
const originhook = @import("originhook.zig");
const wintag = @import("wintag.zig");

const Editor = @This();
const Point = draw.Point;
const Rect = draw.Rect;

/// The origin-transport seam (R-P12-7): type + rationale in `originhook.zig`
/// since phase 16a, aliased here because roots install by this name.
pub const OriginHook = originhook.OriginHook;

/// One logical mouse sample, decoded from a `/dev/mouse` record by the adapter
/// (main_wasm). Button STATE (not edges) per the kernel record; the state
/// machine infers press/release from `mouse_state` + `buttons`.
pub const MouseEvent = struct { x: i32, y: i32, buttons: u8, msec: u32 };

/// The allocator every long-lived editor allocation flows through (P-4).
allocator: std.mem.Allocator,
/// Global edit sequence number (ACME `seq`); bumped per user command.
seq: u32 = 0,
/// True while a run of consecutive keystrokes is being grouped into one undo
/// transaction (R-P6-8/T-1). `typeRune` sets it on the first key of a run (after
/// bumping `seq` and marking the file) and clears it when an arrow key breaks the
/// run; the 6c input loop also clears it when a B1 gesture begins. One
/// `seq`++/`File.mark` per run — not per keystroke.
in_typing_run: bool = false,
/// The single Text the loop routes to (F-9), the phase-7 fallback target. Kept
/// for the standalone-Text harnesses and pre-boot: when `row == null`, `hitTest`
/// resolves every point to this Text (body region), so all phase-6/7 tests stay
/// green with no chrome. Phase 8 leaves it null in `main_wasm` (the router uses
/// `row`).
text: ?*Text = null,
/// The window tree the router hit-tests against (`rowwhich`, rows.c:255-266).
/// When non-null, `hitTest` walks the real Row/Column/Window chrome; when null,
/// it falls back to `text` (above). Bound by the adapter after `boot`.
row: ?*Row = null,
/// `handleKey`'s keyboard fallback ONLY: the Text keys go to when the pointer is
/// over no Text (R-P8-9 types by the pointer, not focus). This is NOT acme's
/// `argtext`/`seltext` — those are the distinct fields below (R-P9-3) and diverge
/// from `focus` (Snarf reassigns `argtext`, exec.c:1013; a B3 search hit sets
/// `seltext`, look.c:375/427).
focus: ?*Text = null,
/// acme's `seltext` (acme.c:657; look.c:96): the last B1-selected Text — the
/// command's default target that `execute` marks and routes to (exec.c:236-244);
/// a search hit also sets it (look.c:375/427). Written by the B1 press (9d),
/// cleared by `dropTextRefs` (9b) when its window dies.
seltext: ?*Text = null,
/// acme's `argtext` (acme.c:656; exec.c:1013): the 2-1 chord's argument source —
/// the last B1-selected Text, except Snarf reassigns it to its own target. Read
/// by `getArg` (9c); written by the B1 press (9d) and Snarf; cleared by
/// `dropTextRefs`.
argtext: ?*Text = null,
/// acme's `activecol` (dat.c:37): the column a new window goes to when nobody
/// pointed at one — read by `place.makeNewWindow` (util.c:454-455) and written by
/// exactly three events in the C:
///   * a B1 PRESS on a Text that has a column (acme.c:659, "button 1 only");
///   * any typed rune except `Kdown`/`Kleft`/`Kright` (acme.c:487-488 —
///     "scrolling doesn't change activecol");
///   * `colcloseall` nils it when the column it names is destroyed
///     (cols.c:216-217) — the port does that from `Row.close` via `dropColRef`,
///     the R-P9-13 dangling-pointer hygiene lineage.
/// The C's fourth writer, the scrollbar drag arm (acme.c:640 `rowdragcol`/
/// `coldragwin`), has no port (R-P8-5, drag deferred). A global in the C; a field
/// here (S-07 P-3, no globals).
activecol: ?*Column = null,
/// The mouse gesture machine's own state (`Gesture.zig`) — `gesture_text`,
/// `mouse_pt`, `mouse_state`, the chord and B2/B3-sweep trackers. Carved out of
/// this struct in phase 12e; reached through the forwarders below.
gesture: Gesture = .{},
/// The snarf buffer: Editor-owned UTF-8 (R-P7-5, vs the C's Rune `snarfbuf`).
/// Captured via chunked `Buffer.read` so U+FFFD semantics match `captureText`.
snarf: std.ArrayList(u8) = .empty,
/// The Edit language's persistent last-regexp cache (acme `lastpat`, edit.c:181).
/// A non-empty `//`-pattern replaces it; an empty pattern REUSES it — and, per the
/// C, the cache persists ACROSS Edit invocations (a later `Edit s//x/` reuses the
/// pattern from an earlier `Edit`). Added by wave 10a-A2 (R-P10-5); owned by
/// `ed.allocator`, `deinit`'ed below.
edit_lastpat: std.ArrayList(u21) = .empty,
/// The buffered warning list — the C's `static Warning *warnings` (util.c:195),
/// one bucket per directory context (R-EDIT-21). `warning()` appends to the `""`
/// bucket (`warning(nil, …)`); `warningIn()` targets a directory. Drained by
/// `errors.flushWarnings` from `frameEnd` into the `+Errors` windows — since
/// phase 12b these messages are VISIBLE (they were an invisible sink through
/// phase 12, R-P9-6). Read in tests through `warningText()`.
warnings: std.ArrayList(errors.Warning) = .empty,
/// The B2 sweep-highlight solid (`but2col`, acme.c:1084), bound from Chrome at
/// boot. null (headless harness / pre-Chrome) ⇒ `select23Begin` falls back to
/// `t.fr.col(.high)` so the gesture mechanics stay testable. R-P9-12.
but2col: ?*draw.Image = null,
/// The B3 sweep-highlight solid (`but3col`, acme.c:1085); same null fallback.
but3col: ?*draw.Image = null,
/// The platform seam the `Reconnect` builtin routes through (R-P12-7) — an
/// erased ctx plus one verb; `originhook.zig` carries the rationale. Installed
/// by `src/main_wasm.zig` after boot; every native harness leaves it null,
/// which makes `Reconnect` a single warning line instead of a crash.
origin: ?OriginHook = null,
/// The session mount table (S-02 §1); null in headless unit tests that never
/// touch the namespace. `core` reads files only through this — never through a
/// device or the shim (R-OV-03).
///
/// The other half of the R-OV-03 boundary from `origin` above: that hook is the
/// ONE command that must talk to the transport, this handle is every FILE the
/// editor will ever reach. `src/main_wasm.zig` assigns it at boot
/// (`a.editor.ns = &a.ns`), `boot.Tree.bind` assigns it from `boot.Options.ns`,
/// and every harness that never names a path leaves it null. Phase 13a lands
/// the handle; phase 13b (directory windows) is its first consumer, through
/// `ninep.nsjob` — never through `ninep.nsdir`, whose synchronous walk would
/// block the browser's main thread (R-9P-13).
ns: ?*ninep.mount.Namespace = null,
/// The in-flight window loads (phase 13b): acme's blocking `textload`
/// (text.c:192-317) turned into one step-per-frame job each, because the
/// browser's main thread may not block on a 9P reply (R-9P-13). POINTERS, not
/// values — a `ninep.nsjob` job hands its own inline reply buffer to a live
/// ticket and must never MOVE (nsjob.zig's pointer-stability rule), so the list
/// may reallocate but the Loads may not. Owned; `Load.deinitAll` frees them.
loads: std.ArrayList(*Load) = .empty,
/// The ONE parked B3 look (R-P13b-2). acme decides "is this text a file name?"
/// with a synchronous `access()` (look.c:706); Snarf can only answer with a
/// `StatJob` that completes on a later frame, so the look waits here. A newer
/// B3 cancels the older. Owned; stepped by `Load.stepAll`, freed by
/// `expand.dropPending` (reached from `Load.dropWindow`/`Load.deinitAll`).
pending_look: ?*expand.PendingLook = null,
/// Set by any handler that painted into the display's op buffer this tick;
/// `frameEnd` performs at most one `display.flush` per tick when it is set.
needs_flush: bool = false,
/// The structural-regexp engine (R-P10-5). C-global-lived — its `lastregexp`
/// cache spans Edit invocations (regx.c:16,203-204), so it hangs off the Editor
/// rather than being rebuilt per command.
regx: Regx,

pub fn init(allocator: std.mem.Allocator) Editor {
    return .{ .allocator = allocator, .regx = Regx.init(allocator) };
}

pub fn deinit(self: *Editor) void {
    Load.deinitAll(self); // abandon every in-flight window load (phase 13b)
    self.snarf.deinit(self.allocator);
    self.edit_lastpat.deinit(self.allocator);
    for (self.warnings.items) |*wn| wn.deinit(self.allocator);
    self.warnings.deinit(self.allocator);
    self.regx.deinit();
    self.* = undefined;
}

/// `warning(nil, fmt, …)` (util.c:260-273): buffer a formatted line for the
/// plain `+Errors` window. A warning must NEVER fail a command — OOM silently
/// drops the message (the two-strike Del works regardless: the strike is
/// `w.dirty=false`, not the message).
pub fn warning(ed: *Editor, comptime fmt: []const u8, args: anytype) void {
    ed.warningIn("", fmt, args);
}

/// `warning(md, fmt, …)` (util.c:260-273) with a directory context — the
/// `errorwinforwin` lineage (util.c:140-186): the message lands in
/// `dir/+Errors` instead of `+Errors`. No live caller yet; the served tree and
/// the host-command wave are the C's writers (`fsysrunproc`/`run`).
pub fn warningIn(ed: *Editor, dir: []const u8, comptime fmt: []const u8, args: anytype) void {
    errors.warningIn(ed, dir, fmt, args);
}

/// The pending text of the plain (`""`) warning bucket (`errors.warningText`).
pub fn warningText(ed: *Editor) []const u8 {
    return errors.warningText(ed);
}

/// True while any bucket still holds an unflushed message
/// (`errors.warningsPending`).
pub fn warningsPending(ed: *Editor) bool {
    return errors.warningsPending(ed);
}

/// `textclose`'s backpointer hygiene (text.c:109/113): nil any of
/// `focus`/`gesture_text`/`seltext`/`argtext` that point into the dying window
/// `w` (its `&w.tag` or `&w.body`), so a later dispatch never dereferences a
/// freed Text. Called by `Column.close` before the window is destroyed
/// (R-P9-3/R-P9-5).
pub fn dropTextRefs(ed: *Editor, w: *Window) void {
    const tag: *Text = &w.tag;
    const body: *Text = &w.body;
    const fields = .{ "focus", "seltext", "argtext" };
    inline for (fields) |name| {
        if (@field(ed, name)) |t| {
            if (t == tag or t == body) @field(ed, name) = null;
        }
    }
    ed.gesture.dropTextRefs(tag, body); // `gesture_text` moved to Gesture.zig
    Load.dropWindow(ed, w); // and any load still filling this window (13b)
}

/// `cut` (exec.c:947-1016) — forwarder into `snarf.cut`; see there for the
/// dosnarf/docut contract. The CALLER marks first.
pub fn cut(ed: *Editor, t: *Text, dosnarf: bool, docut: bool) !void {
    return snarf_ops.cut(ed, t, dosnarf, docut);
}

/// `paste` (exec.c:1018-1073) — forwarder into `snarf.snarfInsert`.
pub fn snarfInsert(ed: *Editor, t: *Text, selectall: bool) !void {
    return snarf_ops.snarfInsert(ed, t, selectall);
}

/// `colcloseall`'s backpointer hygiene (cols.c:216-217): nil `activecol` when the
/// column it names is about to be destroyed. Called by `Row.close` before the
/// column is freed (same lineage as `dropTextRefs`, R-P9-13).
pub fn dropColRef(ed: *Editor, c: *Column) void {
    if (ed.activecol == c) ed.activecol = null;
}

/// Route one mouse sample — forwarder into the gesture machine
/// (`Gesture.handleMouse`, acme.c:576-672 `mousethread`).
pub fn handleMouse(ed: *Editor, ev: MouseEvent) !void {
    return ed.gesture.handleMouse(ed, ev);
}

/// The `Text` (and region) under a point — forwarder into `Gesture.hitTest`
/// (`rowwhich`, rows.c:255-266).
pub fn hitTest(ed: *Editor, p: Point) ?Gesture.Hit {
    return Gesture.hitTest(ed, p);
}

/// Route one key rune to typing (text.c:668-942 via `Text.typeRune`).
/// POINT-TO-TYPE (R-P8-9, `rowtype` rows.c:279-282): keys go to the Text UNDER
/// THE POINTER, not a sticky focus — this is acme's default. `focus` (then the
/// fallback `text`) is used only when the pointer is over no Text (`rowwhich` →
/// nil). NOTE: acme's `-b` variant instead types into `barttext` (the last
/// button-2/3 text); we implement the default. Keys only edit when idle — a live
/// B1 drag owns the gesture, so keys mid-sweep are FLAG-dropped (text.c: keyboard
/// and mouse threads interlock on `row.lk`).
pub fn handleKey(ed: *Editor, r: u21) !void {
    if (ed.gesture.mouse_state != .idle) return; // FLAG: keys during a gesture are dropped
    const t = if (ed.hitTest(ed.gesture.mouse_pt)) |hit|
        hit.text
    else
        (ed.focus orelse ed.text orelse return);
    // acme.c:486-488: typing claims the active column — but "scrolling doesn't
    // change activecol", so the three arrow/paging runes the C names are excluded.
    if (r != typing.Kdown and r != typing.Kleft and r != typing.Kright) {
        if (place.colOf(t)) |c| ed.activecol = c;
    }
    try t.typeRune(ed, r);
    ed.needs_flush = true;
}

/// End-of-tick: refresh live tags, then flush the display AT MOST ONCE (only if a
/// handler — or the tag refresh — painted this tick).
///
/// The tag sweep (R-P9-4) is the single site the C's 29 scattered `winsettag`
/// calls collapse to: walk `ed.row` (cols × windows), recompute each window's
/// `{undo, redo, mod}` tuple from its body File, and when it differs from the
/// cached `w.tag_state`, recompose the tag (`setTag1`, wind.c:497-536) and update
/// the cache. This gives live " Undo"/" Redo" tag words after every edit/command/
/// undo without a per-frame tag rewrite. `setTag1`'s minimal-splice guard keeps a
/// change cheap; the cache keeps an idle frame free of tag reads/allocs.
pub fn frameEnd(ed: *Editor, display: *draw.Display) !void {
    // The C's main loop drains `cwarn` (acme.c:512-515) before it redraws;
    // running the flush FIRST means a freshly minted `+Errors` window has its
    // live tag composed by the sweep below, in this same frame (util.c:211-258).
    try Load.stepAll(ed); // one 9P state per in-flight window load (13b, §3b)
    try errors.flushWarnings(ed);
    try wintag.sweep(ed); // the live-tag sweep (R-P9-4), moved out in phase 16a
    if (!ed.needs_flush) return;
    try display.flush();
    ed.needs_flush = false;
}

// Compile-time proof the allowed dependencies resolve through this module.
comptime {
    std.debug.assert(@hasDecl(draw, "proto"));
    std.debug.assert(@hasDecl(ninep, "msg"));
}

// ===========================================================================
// Tests (editing side contract §"6c scope"). Frame.TestFixture + a real
// Text/File, mirroring B2's typing/select harness style.
// ===========================================================================
const testing = std.testing;
// The button bits moved to `Gesture.zig` with the machine (R-P12e-2); the
// exec/look gesture tests below still name them.
const B1 = Gesture.B1;
const B2 = Gesture.B2;
const B3 = Gesture.B3;
const Frame = draw.Frame;
const proto = draw.proto;
const boot = @import("boot.zig");

// Harness rect shifted (x 20→4) for the phase-8 scrollbar strip: the 12px
// scrollbar + 4px gap carve leaves the FRAME at (20,20)-(119,470), byte-identical
// to the pre-scrollbar geometry (chrome contract §2).
const rect = proto.Rect{ .min = .{ .x = 4, .y = 20 }, .max = .{ .x = 119, .y = 470 } };

/// A live Text over `seed`, an Editor bound to it, on a fresh draw fixture.
pub const Harness = struct {
    fx: Frame.TestFixture,
    file: File,
    text: Text,
    ed: Editor,

    pub fn init(seed: []const u8) !*Harness {
        const a = testing.allocator;
        const h = try a.create(Harness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.file = File.init(a, try Buffer.initFromBytes(a, seed));
        h.text = try Text.init(&h.file, a, rect, h.fx.font, &h.fx.disp.image, h.fx.cols());
        h.ed = Editor.init(a);
        h.ed.text = &h.text; // bind the routing target
        try h.text.fill();
        return h;
    }
    pub fn deinit(h: *Harness) void {
        h.ed.deinit();
        h.text.deinit();
        h.file.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    /// The whole buffer as decoded UTF-8 (caller frees).
    pub fn bufText(h: *Harness) ![]u8 {
        const n = h.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, h.file.buffer.read(0, n, dest));
    }
    pub fn expectText(h: *Harness, want: []const u8) !void {
        const got = try h.bufText();
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
    /// Synthesize a mouse sample at the device point of screen char `p`.
    pub fn evAtChar(h: *Harness, p: usize, buttons: u8) MouseEvent {
        return h.evAtCharMsec(p, buttons, 0);
    }
    /// Same, carrying an explicit millisecond timestamp (double-click gating).
    pub fn evAtCharMsec(h: *Harness, p: usize, buttons: u8, msec: u32) MouseEvent {
        const pt = h.text.fr.ptOfChar(p);
        return .{ .x = pt.x, .y = pt.y, .buttons = buttons, .msec = msec };
    }
    /// The current snarf buffer contents.
    pub fn snarf(h: *Harness) []const u8 {
        return h.ed.snarf.items;
    }
};

test "editor init/deinit round-trip" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try std.testing.expectEqual(@as(u32, 0), ed.seq);
    ed.seq += 1;
    try std.testing.expectEqual(@as(u32, 1), ed.seq);
}

test "editor: kbd runes route to typing and mouse breaks the run" {
    const h = try Harness.init("");
    defer h.deinit();

    try h.ed.handleKey('a');
    try h.ed.handleKey('b');
    try h.expectText("ab");
    try testing.expect(h.ed.in_typing_run);
    try testing.expectEqual(@as(u32, 1), h.ed.seq); // one run so far

    // A B1 click (press + release at the caret) ends the typing run.
    try h.ed.handleMouse(h.evAtChar(2, 1));
    try h.ed.handleMouse(h.evAtChar(2, 0));
    try testing.expect(!h.ed.in_typing_run);
    try testing.expect(h.ed.gesture.mouse_state == .idle);

    // The next key starts a fresh run (second seq) and inserts at the caret.
    try h.ed.handleKey('c');
    try h.expectText("abc");
    try testing.expectEqual(@as(u32, 2), h.ed.seq);

    // Two transactions: undo drops 'c', then undo drops "ab".
    _ = try h.file.undo();
    try h.expectText("ab");
    _ = try h.file.undo();
    try h.expectText("");
}

test "editor: frameEnd flushes once" {
    const h = try Harness.init("");
    defer h.deinit();

    // A keystroke paints and asks for a flush.
    try h.ed.handleKey('x');
    try testing.expect(h.ed.needs_flush);

    // First frameEnd flushes (writes reach the fake tree) and clears the flag.
    const before = h.fx.tree.writes.items.len;
    try h.ed.frameEnd(h.fx.disp);
    try testing.expect(!h.ed.needs_flush);
    const after_one = h.fx.tree.writes.items.len;
    try testing.expect(after_one > before); // the flush produced device writes

    // A second frameEnd with nothing pending is a no-op: no further writes.
    try h.ed.frameEnd(h.fx.disp);
    try testing.expectEqual(after_one, h.fx.tree.writes.items.len);
}

// --------------------------------------------------------------------------
// Phase 7b: chord cut/paste + double-click (textselect, text.c:1001-1099).
// --------------------------------------------------------------------------

// --------------------------------------------------------------------------
// Phase 7a scroll tests. "lineNN\n" lines are 7 runes (one 11-wide visual line);
// the 11×25 frame holds 25 lines = 175 runes. See text/typing.zig for the pins.
// --------------------------------------------------------------------------

/// `count` lines of "lineNN\n". Caller frees.
fn genLines(a: std.mem.Allocator, count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var line: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&line, "line{d:0>2}\n", .{i}) catch unreachable;
        try buf.appendSlice(a, &line);
    }
    return buf.toOwnedSlice(a);
}

pub fn scrollHarness() !*Harness {
    const seed = try genLines(testing.allocator, 60);
    defer testing.allocator.free(seed);
    return Harness.init(seed);
}

test "editor: acceptance 60-line scroll scene" {
    const h = try scrollHarness();
    defer h.deinit();
    const t = &h.text;
    const len = t.file.buffer.len(); // 420
    try t.setSelect(len, len); // the user's caret is at the end of the file

    // Three wheel-down notches scroll to line3 (one line/notch, R-P7-2).
    var i: usize = 0;
    while (i < 3) : (i += 1) try h.ed.handleMouse(.{ .x = 0, .y = 0, .buttons = 16, .msec = 0 });
    try testing.expectEqual(@as(usize, 21), t.org); // runeOfLine(3) = 3*7
    try testing.expectEqualStrings("line03", t.fr.boxes.items[0].kind.run.text);

    // Kend shows the end of the file: the last displayed rune is EOF.
    try h.ed.handleKey(Kend_rune);
    try testing.expectEqual(len, t.org + t.fr.nchars);

    // Typing 'X' at the (visible) end appends without scrolling: org unchanged.
    const org_before = t.org;
    try h.ed.handleKey('X');
    try testing.expectEqual(org_before, t.org);
    try testing.expectEqual(len + 1, t.file.buffer.len());
    try testing.expectEqual(@as(u21, 'X'), t.file.buffer.runeAt(len));

    // FROZEN write-stream hash (R-P2-7): flush everything, then hash the whole
    // device byte-stream. RE-FROZEN for phase 8 (R-P8-12): the phase-7 hash
    // (0xc06586b7b6a07f73) legitimately broke because Text.init now back-fills to
    // the scrollbar strip (an extra 'd' per Text) and the harness rect shifted
    // 20→4 (frame geometry byte-identical). The spot-checks above (org, first
    // box, EOF visibility, the appended 'X') all still pass, so this is the one
    // sanctioned re-freeze. Re-freezing again requires orchestrator sign-off.
    try h.fx.disp.flush();
    var hasher = std.hash.Wyhash.init(0);
    for (h.fx.tree.writes.items) |w| hasher.update(w);
    try testing.expectEqual(@as(u64, 0x4e061704e764ed75), hasher.final());
}

const Kend_rune: u21 = 0xF000 | 0x18; // keyboard.h Kend

// --------------------------------------------------------------------------
// Phase 8: multi-Text routing over a real window tree (boot + Row/Column/Window).
// The router hit-tests against `ed.row`; every gesture pins to one Text.
// --------------------------------------------------------------------------

/// A mouse sample at device `(x,y)` with `buttons`, msec 0.
pub fn mev(x: i32, y: i32, buttons: u8) MouseEvent {
    return .{ .x = x, .y = y, .buttons = buttons, .msec = 0 };
}

/// The center device point of a rect.
pub fn center(r: Rect) Point {
    return .{ .x = @divTrunc(r.min.x + r.max.x, 2), .y = @divTrunc(r.min.y + r.max.y, 2) };
}

/// A booted two-window scene with the Editor router bound to the tree.
pub const TwoWin = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,
    w1: *Window,
    w2: *Window,

    pub fn init() !*TwoWin {
        const a = testing.allocator;
        const h = try a.create(TwoWin);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        const body1 = try genLines(a, 40);
        defer a.free(body1);
        const body2 = try genLines(a, 40);
        defer a.free(body2);
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 600, 460), .{
            .win_name = "one",
            .body = body1,
        });
        h.w2 = try h.tree.addWindow("two", body2);
        h.w1 = h.tree.row.col.items[0].w.items[0];
        h.ed = Editor.init(a);
        h.ed.row = h.tree.row;
        return h;
    }
    pub fn deinit(h: *TwoWin) void {
        const a = testing.allocator;
        h.ed.deinit();
        h.tree.deinit();
        h.fx.deinit();
        a.destroy(h);
    }
    /// A Text's buffer as decoded UTF-8 (caller frees).
    pub fn text(t: *Text) ![]u8 {
        const n = t.file.buffer.len();
        if (n == 0) return testing.allocator.alloc(u8, 0);
        const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
        defer testing.allocator.free(dest);
        return testing.allocator.dupe(u8, t.file.buffer.read(0, n, dest));
    }
};

/// A booted scene with a SECOND column (`c2`, carrying window `w2`), for the
/// `activecol` tests (T7-T9) that need two distinct columns.
const TwoCol = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,
    c2: *Column,
    w2: *Window,

    fn init() !*TwoCol {
        const a = testing.allocator;
        const h = try a.create(TwoCol);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 600, 460), .{
            .win_name = "one",
            .body = "hello\n",
        });
        h.c2 = (try h.tree.row.add(-1)).?;
        h.w2 = try h.tree.addWindow("two", "world\n"); // lands in the LAST column (c2)
        h.ed = Editor.init(a);
        h.ed.row = h.tree.row;
        return h;
    }
    fn deinit(h: *TwoCol) void {
        const a = testing.allocator;
        h.ed.deinit();
        h.tree.deinit();
        h.fx.deinit();
        a.destroy(h);
    }
};

test "editor: B1 press sets activecol; B2/B3 elsewhere leave it (T7)" {
    const h = try TwoCol.init();
    defer h.deinit();
    const ed = &h.ed;
    const c1 = h.tree.row.col.items[0];
    const w1 = c1.w.items[0];

    try testing.expect(ed.activecol == null);
    const p1 = center(w1.body.fr.r);
    try ed.handleMouse(mev(p1.x, p1.y, B1));
    try testing.expectEqual(c1, ed.activecol.?);
    try ed.handleMouse(mev(p1.x, p1.y, 0));

    // A B3 click in the OTHER column must not steer activecol away from c1.
    const p2 = center(h.w2.body.fr.r);
    try ed.handleMouse(mev(p2.x, p2.y, B3));
    try testing.expectEqual(c1, ed.activecol.?);
    try ed.handleMouse(mev(p2.x, p2.y, 0));

    // Neither does a B2 click there.
    try ed.handleMouse(mev(p2.x, p2.y, B2));
    try testing.expectEqual(c1, ed.activecol.?);
    try ed.handleMouse(mev(p2.x, p2.y, 0));
}

test "editor: typed runes set activecol; Kdown/Kleft/Kright do not (T8)" {
    const h = try TwoCol.init();
    defer h.deinit();
    const ed = &h.ed;
    const c1 = h.tree.row.col.items[0];
    const w1 = c1.w.items[0];

    ed.gesture.mouse_pt = center(w1.body.fr.r);
    try testing.expect(ed.activecol == null);
    try ed.handleKey('x');
    try testing.expectEqual(c1, ed.activecol.?);

    ed.activecol = null;
    try ed.handleKey(typing.Kdown);
    try testing.expect(ed.activecol == null);
    try ed.handleKey(typing.Kleft);
    try testing.expect(ed.activecol == null);
    try ed.handleKey(typing.Kright);
    try testing.expect(ed.activecol == null);
}

test "editor: closing the active column nils activecol (T9)" {
    const h = try TwoCol.init();
    defer h.deinit();
    const ed = &h.ed;
    const c2 = h.c2;

    ed.activecol = c2;
    try h.tree.row.close(ed, c2, true); // rows.c close -> dropColRef (cols.c:216-217)
    try testing.expect(ed.activecol == null);
}

test "editor: keyboard follows the pointer (acme point-to-type)" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;

    try h.w1.body.setSelect(0, 0);
    try h.w2.body.setSelect(0, 0);
    // Focus is bookkeeping only — pin it to window 1 to prove it does NOT steer
    // keys (R-P8-9: the pointer does).
    ed.focus = &h.w1.body;

    // Pointer over window 2's body, with NO click: a keystroke edits file-2.
    ed.gesture.mouse_pt = center(h.w2.body.fr.r);
    try ed.handleKey('Z');

    const t2 = try TwoWin.text(&h.w2.body);
    defer testing.allocator.free(t2);
    try testing.expect(t2[0] == 'Z'); // typed into the window under the pointer

    const t1 = try TwoWin.text(&h.w1.body);
    defer testing.allocator.free(t1);
    try testing.expect(t1[0] != 'Z'); // the focused window is untouched
}

test "editor: tag typing edits the tag File" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;

    // The window-1 tag was seeded by boot with the caret parked at its end.
    const seed = try TwoWin.text(&h.w1.tag);
    defer testing.allocator.free(seed);
    try testing.expectEqualStrings("one Del Snarf | Look ", seed);
    const n0 = h.w1.tag.file.buffer.len();

    // Pointer over the window-1 tag: typed runes edit the TAG file, not the body.
    ed.gesture.mouse_pt = center(h.w1.tag.fr.r);
    try ed.handleKey('!');
    try ed.handleKey('x');

    try testing.expectEqual(n0 + 2, h.w1.tag.file.buffer.len());
    const after = try TwoWin.text(&h.w1.tag);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("one Del Snarf | Look !x", after);

    // The body is untouched (still the seeded lines).
    const body = try TwoWin.text(&h.w1.body);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "line00"));
}

test "editor: dropTextRefs nils dangling text pointers" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;

    // Pin all four backpointers at window 1's tag/body.
    ed.focus = &h.w1.tag;
    ed.gesture.gesture_text = &h.w1.body;
    ed.seltext = &h.w1.body;
    ed.argtext = &h.w1.tag;

    ed.dropTextRefs(h.w1);
    try testing.expect(ed.focus == null);
    try testing.expect(ed.gesture.gesture_text == null);
    try testing.expect(ed.seltext == null);
    try testing.expect(ed.argtext == null);

    // A pointer at a DIFFERENT window survives dropTextRefs for window 1.
    ed.focus = &h.w2.body;
    ed.dropTextRefs(h.w1);
    try testing.expectEqual(&h.w2.body, ed.focus.?);
}

// ===========================================================================
// Phase 9 (9d): B2 execute / B3 look gestures + the frameEnd tag sweep.
// Drives the full mouse machine (press/release edges) against a booted scene,
// mirroring the phase-6/7/8 gesture-test style. B1=1, B2=2, B3=4.
// ===========================================================================

/// A booted single-window scene with the router bound. Unlike `TwoWin` (fixed
/// genLines bodies) the name/body are caller-controlled for the exec/look tests.
const OneWin = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,

    fn init(name: []const u8, body: []const u8) !*OneWin {
        const a = testing.allocator;
        const h = try a.create(OneWin);
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
    fn deinit(h: *OneWin) void {
        h.ed.deinit();
        h.tree.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn win(h: *OneWin) *Window {
        return h.tree.row.col.items[0].w.items[0];
    }
};

/// A mouse sample at the device point of char `p` in Text `t`, carrying `msec`.
fn evAtT(t: *Text, p: usize, buttons: u8, msec: u32) MouseEvent {
    const pt = t.fr.ptOfChar(p);
    return .{ .x = pt.x, .y = pt.y, .buttons = buttons, .msec = msec };
}

/// The `n`th (0-based) rune index of ASCII `word` in `t`'s buffer (runes == bytes
/// for ASCII).
fn nthWord(t: *Text, word: []const u8, n: usize) usize {
    const nc = t.file.buffer.len();
    var count: usize = 0;
    var i: usize = 0;
    outer: while (i + word.len <= nc) : (i += 1) {
        for (word, 0..) |ch, j| {
            if (t.file.buffer.runeAt(i + j) != ch) continue :outer;
        }
        if (count == n) return i;
        count += 1;
    }
    unreachable;
}

fn findWord(t: *Text, word: []const u8) usize {
    return nthWord(t, word, 0);
}

/// A B2/B3 CLICK: press + release at the same char and time. With no motion the
/// sweep stays a caret, so `execute`/`look` word-expand at that point.
fn clickBut(ed: *Editor, t: *Text, p: usize, but: u8) !void {
    try ed.handleMouse(evAtT(t, p, but, 100));
    try ed.handleMouse(evAtT(t, p, 0, 100));
}

fn bodyEql(w: *Window, want: []const u8) !void {
    const n = w.body.file.buffer.len();
    const dest = try testing.allocator.alloc(u8, @max(1, n) * Buffer.max_bytes_per_rune);
    defer testing.allocator.free(dest);
    try testing.expectEqualStrings(want, w.body.file.buffer.read(0, n, dest));
}

fn tagHas(w: *Window, needle: []const u8) bool {
    var buf: [256]u8 = undefined;
    const n = w.tag.file.buffer.len();
    return std.mem.indexOf(u8, w.tag.file.buffer.read(0, n, &buf), needle) != null;
}

test "exec: B2 click on tag word executes Snarf against the body selection" {
    const h = try OneWin.init("scratch", "hello world");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();

    // A body selection is the command's default target (the B1-select's seltext).
    try w.body.setSelect(0, 5); // "hello"
    ed.seltext = &w.body;
    const seq0 = ed.seq;

    // B2-click "Snarf" in the window tag. Snarf copies the body selection into the
    // snarf buffer; Snarf.mark == false so `seq` is NOT bumped (the exec.c:236-240
    // pin), and Snarf reassigns argtext to its target.
    try clickBut(ed, &w.tag, findWord(&w.tag, "Snarf") + 2, B2);
    try testing.expect(ed.gesture.mouse_state == .idle);
    try testing.expectEqualStrings("hello", ed.snarf.items);
    try testing.expectEqual(seq0, ed.seq);
    try testing.expectEqual(&w.body, ed.argtext.?); // Snarf set argtext (exec.c:1013)
}

test "exec: B2 click executes Cut/Paste/Undo/Redo" {
    const h = try OneWin.init("scratch", "hello world");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();

    // Append the command words to the tag so a click can hit each. No frameEnd runs
    // here, so the tag layout (and these offsets) stay put.
    const tn = w.tag.file.buffer.len();
    try w.tag.insertAt(tn, " Cut Paste Undo Redo", true);

    try w.body.setSelect(0, 5); // "hello"
    ed.seltext = &w.body;
    const seq0 = ed.seq;

    // Cut: marks once (seq++), snarfs "hello", deletes it from the body.
    try clickBut(ed, &w.tag, findWord(&w.tag, "Cut") + 1, B2);
    try testing.expectEqual(seq0 + 1, ed.seq);
    try testing.expectEqualStrings("hello", ed.snarf.items);
    try bodyEql(w, " world");

    // Paste (tobody, the truthy XXX): lands in the BODY at its caret ⇒ restored.
    try clickBut(ed, &w.tag, findWord(&w.tag, "Paste") + 1, B2);
    try bodyEql(w, "hello world");

    // Undo reverses the paste; Redo re-applies it — a clean round-trip.
    try clickBut(ed, &w.tag, findWord(&w.tag, "Undo") + 1, B2);
    try bodyEql(w, " world");
    try clickBut(ed, &w.tag, findWord(&w.tag, "Redo") + 1, B2);
    try bodyEql(w, "hello world");
}

test "exec: 2-1 chord passes argtext to New" {
    const h = try OneWin.init("one", "alpha beta\n");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();
    const c = h.tree.row.col.items[0];
    const ctag = &c.tag;
    const before = c.w.items.len;

    // B1-select "alpha" [0,5) in the body: the B1 press records argtext = body.
    const a0 = w.body.fr.ptOfChar(0);
    const a5 = w.body.fr.ptOfChar(5);
    try ed.handleMouse(mev(a0.x, a0.y, B1));
    try ed.handleMouse(mev(a5.x, a5.y, B1));
    try ed.handleMouse(mev(a5.x, a5.y, 0));
    try testing.expectEqual(&w.body, ed.argtext.?);
    try testing.expectEqual(@as(usize, 0), w.body.q0);
    try testing.expectEqual(@as(usize, 5), w.body.q1);

    // B2-down on "New" in the columntag; B1 joins (2-1 chord); all release.
    const np = ctag.fr.ptOfChar(findWord(ctag, "New") + 1);
    try ed.handleMouse(mev(np.x, np.y, B2));
    try testing.expect(ed.gesture.mouse_state == .sweeping_b2);
    try ed.handleMouse(mev(np.x, np.y, B1 | B2));
    try testing.expect(ed.gesture.mouse_state == .draining);
    try ed.handleMouse(mev(np.x, np.y, 0));
    try testing.expect(ed.gesture.mouse_state == .idle);

    // New made one window named after the argt selection, with an empty body.
    try testing.expectEqual(before + 1, c.w.items.len);
    const nw = c.w.items[c.w.items.len - 1];
    try testing.expectEqualStrings("alpha", nw.body.file.name.items);
    try testing.expectEqual(@as(usize, 0), nw.body.file.buffer.len());
}

test "exec: B3 joining a B2 sweep cancels" {
    const h = try OneWin.init("scratch", "Cut junk");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();
    const seq0 = ed.seq;

    // B2-down in the body, then B3 joins ⇒ textselect2 cancels (buts & 4).
    const p = w.body.fr.ptOfChar(1);
    try ed.handleMouse(mev(p.x, p.y, B2));
    try testing.expect(ed.gesture.mouse_state == .sweeping_b2);
    try ed.handleMouse(mev(p.x, p.y, B2 | B3));
    try testing.expect(ed.gesture.mouse_state == .draining);
    try ed.handleMouse(mev(p.x, p.y, 0));

    // Nothing executed: idle, snarf empty, no seq bump, body intact.
    try testing.expect(ed.gesture.mouse_state == .idle);
    try testing.expectEqual(seq0, ed.seq);
    try testing.expectEqual(@as(usize, 0), ed.snarf.items.len);
    try bodyEql(w, "Cut junk");
}

test "exec: Del clean closes and the neighbor grows back" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;
    const c = h.tree.row.col.items[0];
    try testing.expectEqual(@as(usize, 2), c.w.items.len);

    const topY = h.w1.r.min.y;
    const botY = h.w2.r.max.y;
    const w2 = h.w2;

    // B2-click "Del" in the clean top window's tag ⇒ it closes and window 2 grows
    // up to cover the whole window region (colclose extend-next-up).
    try clickBut(ed, &h.w1.tag, findWord(&h.w1.tag, "Del") + 1, B2);
    try testing.expectEqual(@as(usize, 1), c.w.items.len);
    try testing.expectEqual(w2, c.w.items[0]);
    try testing.expectEqual(topY, w2.r.min.y);
    try testing.expectEqual(botY, w2.r.max.y);
    // The gesture never touches the freed window after dispatch (dropTextRefs).
    try testing.expect(ed.gesture.gesture_text == null);
}

test "exec: Del dirty two-strikes" {
    const h = try TwoWin.init();
    defer h.deinit();
    const ed = &h.ed;
    const c = h.tree.row.col.items[0];
    const w1 = h.w1;

    // Name + dirty window 1 (a named dirty window warns on Del).
    try w1.body.file.setName("one");
    ed.seq += 1;
    w1.body.file.mark(ed.seq);
    try w1.body.insertAt(0, "X", true);
    try testing.expect(w1.dirty);

    // Strike 1: survives, warns, dirty cleared, but file.mod stays true (dot stays).
    try clickBut(ed, &w1.tag, findWord(&w1.tag, "Del") + 1, B2);
    try testing.expectEqual(@as(usize, 2), c.w.items.len);
    try testing.expect(!w1.dirty);
    try testing.expect(w1.body.file.mod);
    try testing.expect(std.mem.indexOf(u8, ed.warningText(), "one modified") != null);

    // An edit between strikes re-arms dirty (text.c:378 hook).
    ed.seq += 1;
    w1.body.file.mark(ed.seq);
    try w1.body.insertAt(0, "Y", true);
    try testing.expect(w1.dirty);

    // Strike 2 (re-armed): warns again, survives.
    try clickBut(ed, &w1.tag, findWord(&w1.tag, "Del") + 1, B2);
    try testing.expectEqual(@as(usize, 2), c.w.items.len);
    try testing.expect(!w1.dirty);

    // Strike 3 (now clean): gone.
    try clickBut(ed, &w1.tag, findWord(&w1.tag, "Del") + 1, B2);
    try testing.expectEqual(@as(usize, 1), c.w.items.len);
}

test "editor: frameEnd refreshes tags after an edit" {
    const h = try OneWin.init("scratch", "");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();

    // Type into the body (pointer over it) ⇒ the body File becomes undoable.
    ed.gesture.mouse_pt = center(w.body.fr.r);
    try ed.handleKey('a');
    try testing.expect(!tagHas(w, " Undo")); // tag not yet swept

    try ed.frameEnd(h.fx.disp);
    try testing.expect(tagHas(w, " Undo")); // live Undo word (R-P9-4)
    try testing.expect(w.tag_state.undo);

    // A second frameEnd with no change is a no-op: the tag_state cache blocks the
    // rewrite, so no further device writes are produced.
    const before = h.fx.tree.writes.items.len;
    try ed.frameEnd(h.fx.disp);
    try testing.expectEqual(before, h.fx.tree.writes.items.len);
}

test "editor: b3 click on word finds next occurrence and scrolls it visible" {
    var seed: std.ArrayList(u8) = .empty;
    defer seed.deinit(testing.allocator);
    try seed.appendSlice(testing.allocator, "needle\n");
    var i: usize = 0;
    while (i < 60) : (i += 1) try seed.appendSlice(testing.allocator, "filler\n");
    try seed.appendSlice(testing.allocator, "needle\n");

    const h = try OneWin.init("scratch", seed.items);
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();
    const second = nthWord(&w.body, "needle", 1);

    // B3-click the first "needle" (chars 0..6): expand ⇒ collapse ⇒ forward search.
    try clickBut(ed, &w.body, 2, B3);
    try testing.expect(ed.gesture.mouse_state == .idle);
    try testing.expectEqual(second, w.body.q0);
    try testing.expectEqual(second + 6, w.body.q1);
    try testing.expect(w.body.org > 0); // scrolled the hit into view
    try testing.expect(w.body.org <= second);
    try testing.expectEqual(&w.body, ed.seltext.?);
}

test "editor: b3 sweep searches the swept literal" {
    const h = try OneWin.init("scratch", "one TARGET two TARGET three");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();

    // Sweep the non-word literal "ARGE" inside the first TARGET ([5,9)).
    try ed.handleMouse(evAtT(&w.body, 5, B3, 0));
    try testing.expect(ed.gesture.mouse_state == .sweeping_b3);
    try ed.handleMouse(evAtT(&w.body, 9, B3, 5)); // motion ⇒ a real sweep
    try ed.handleMouse(evAtT(&w.body, 9, 0, 5)); // release ⇒ look the literal
    try testing.expect(ed.gesture.mouse_state == .idle);

    const second = nthWord(&w.body, "ARGE", 1);
    try testing.expectEqual(second, w.body.q0);
    try testing.expectEqual(second + 4, w.body.q1);
    try testing.expectEqual(&w.body, ed.seltext.?);
}

test "editor: repeated b3 cycles matches and wraps" {
    const h = try OneWin.init("scratch", "foo a foo b foo");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();
    try w.body.setSelect(0, 0); // "foo" at [0,3),[6,9),[12,15)

    try clickBut(ed, &w.body, 1, B3); // first ⇒ second
    try testing.expectEqual(@as(usize, 6), w.body.q0);
    try testing.expectEqual(@as(usize, 9), w.body.q1);

    try clickBut(ed, &w.body, 7, B3); // (inside second) ⇒ third
    try testing.expectEqual(@as(usize, 12), w.body.q0);
    try testing.expectEqual(@as(usize, 15), w.body.q1);

    try clickBut(ed, &w.body, 13, B3); // (inside third) ⇒ wraps to first
    try testing.expectEqual(@as(usize, 0), w.body.q0);
    try testing.expectEqual(@as(usize, 3), w.body.q1);
}

test "editor: b3 not-found leaves the caret at word end" {
    // The clicked word occurs exactly once, so the wraparound search finds no OTHER
    // match and re-finds the same word (look.c:432-435 sole-occurrence rule): the
    // selection settles ON it, ending at the word end, and neither the buffer nor
    // org (single visible line) changes. A genuine absent-needle miss is covered by
    // look.zig's direct "search not-found" test; a body click can never produce an
    // absent needle (the needle is read from the body itself), so this is the
    // faithful "nothing new found" realization of the collapse-to-word-end setup.
    const h = try OneWin.init("scratch", "solitary word");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();
    try w.body.setSelect(0, 0);

    try clickBut(ed, &w.body, 3, B3); // inside "solitary" [0,8)
    try testing.expectEqual(@as(usize, 0), w.body.q0);
    try testing.expectEqual(@as(usize, 8), w.body.q1); // active end at word end
    try testing.expectEqual(@as(usize, 0), w.body.org); // buffer/org untouched
}

test "editor: b1 or b2 during a b3 sweep cancels the look" {
    const h = try OneWin.init("scratch", "foo bar foo");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();
    try w.body.setSelect(0, 0);

    // B3-down, then B1 joins ⇒ textselect3 cancels (buts & (1|2)).
    try ed.handleMouse(evAtT(&w.body, 1, B3, 0));
    try testing.expect(ed.gesture.mouse_state == .sweeping_b3);
    try ed.handleMouse(evAtT(&w.body, 1, B1 | B3, 0));
    try testing.expect(ed.gesture.mouse_state == .draining);
    try ed.handleMouse(evAtT(&w.body, 1, 0, 0));
    try testing.expect(ed.gesture.mouse_state == .idle);

    // No search ran: selection unchanged, no target recorded.
    try testing.expectEqual(@as(usize, 0), w.body.q0);
    try testing.expectEqual(@as(usize, 0), w.body.q1);
    try testing.expect(ed.seltext == null);
}

test "editor: b3 in the tag searches the body" {
    const h = try OneWin.init("scratch", "alpha needle beta");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();

    // Append "needle" to the tag; B3-click it (t == tag, ct == body).
    const tn = w.tag.file.buffer.len();
    try w.tag.insertAt(tn, " needle", true);
    const tagQ0 = w.tag.q0;
    const tagQ1 = w.tag.q1;
    const nstart = findWord(&w.body, "needle");

    try clickBut(ed, &w.tag, findWord(&w.tag, "needle") + 1, B3);

    // The body selection jumped to its "needle"; the tag's own selection untouched
    // (t != ct ⇒ no collapse, look.c:205/208).
    try testing.expectEqual(nstart, w.body.q0);
    try testing.expectEqual(nstart + 6, w.body.q1);
    try testing.expectEqual(&w.body, ed.seltext.?);
    try testing.expectEqual(tagQ0, w.tag.q0);
    try testing.expectEqual(tagQ1, w.tag.q1);
}

test "editor: b3 press updates no argtext, b1 press updates seltext+argtext" {
    const h = try OneWin.init("scratch", "foo needle foo");
    defer h.deinit();
    const ed = &h.ed;
    const w = h.win();

    // A B1 press records BOTH argtext and seltext (acme.c:656-657).
    const p0 = w.body.fr.ptOfChar(0);
    try ed.handleMouse(mev(p0.x, p0.y, B1));
    try testing.expectEqual(&w.body, ed.argtext.?);
    try testing.expectEqual(&w.body, ed.seltext.?);
    try ed.handleMouse(mev(p0.x, p0.y, 0));

    // A B3 gesture must NOT touch argtext; only a search hit sets seltext
    // (look.c:427). Clear both, then B3-click "needle".
    ed.argtext = null;
    ed.seltext = null;
    try clickBut(ed, &w.body, findWord(&w.body, "needle") + 1, B3);
    try testing.expect(ed.argtext == null);
    try testing.expectEqual(&w.body, ed.seltext.?);
}
