//! A window: a tag `Text` stacked over a body `Text`, sharing one rectangle with
//! a 1px divider between them and a scroll/modified button at the body's
//! scrollbar origin. file-as-struct (S-07 P-1): this file *is* the Window.
//!
//! Ported from larryr/plan9port@337c6ac acme/wind.c; cite as `wind.c:NN`. This is
//! the no-clone `wininit` (wind.c:17-90) and the taglines==1 `winresize`
//! (wind.c:179-250) with the mouse-warp arms dropped (R-P8-7 — a browser can't
//! `moveto` the pointer). `winsettag`/`winclean`/`parsetag` are phase 9.
//!
//! The `Window`↔`Text` import cycle is intended and legal in Zig (the Display↔
//! Image precedent, see Image.zig's header): a `Text` back-points to its Window
//! via `?*Window`, and a Window embeds two `Text`s by value.
//!
//! Imports: `std` + `draw` + sibling core files only (S-07 §6).
const std = @import("std");
const draw = @import("draw");
const Chrome = @import("Chrome.zig");
const Text = @import("text/Text.zig");
const File = @import("File.zig");
const Buffer = @import("Buffer.zig");
const Column = @import("Column.zig");
const Editor = @import("Editor.zig");

const Window = @This();
const Rect = draw.Rect;
const Image = draw.Image;

pub const Error = Text.Error;

tag: Text,
body: Text,
/// The tag's backing `File` (its editable text), owned by the Window. The body's
/// `File` is passed in and owned by the caller.
tag_file: File,
r: Rect,
/// First tag line, for the collapsed-tag hit region (dat.h:275; wind.c:38).
tagtop: Rect,
id: u32,
/// The owning `Column` (wave-2, retyped from the wave-1 `?*anyopaque`
/// placeholder). A stored back-pointer only; `Column.add` sets it. The
/// `Window`↔`Column` import cycle is intended and legal in Zig, the same
/// precedent as the `Window`↔`Text` cycle above.
col: ?*Column = null,
/// Tag height in lines — fixed at 1 this phase (R-P8-1; `wintaglines` is later).
taglines: i32 = 1,
maxlines: usize = 0,
/// `w->dirty` (dat.h:187): set true by a recorded BODY edit (Text.insertAt/
/// deleteRange, text.c:378/474); read by `clean` (the Del two-strike) and, once
/// 9d lands, the `frameEnd` tag sweep. Distinct from `file.mod` (which survives a
/// clean strike so the mod dot stays).
dirty: bool = false,
/// Cached tag-presence tuple for the `frameEnd` sweep (R-P9-4/§3f): the last
/// `{undoSeq()!=0, redoSeq()!=0, file.mod}` `setTag1` was called for. The field
/// only — the sweep that reads/updates it is wave 9d.
tag_state: struct { undo: bool = false, redo: bool = false, mod: bool = false } = .{},
/// True when this Window owns its body `File` and must free it in `deinit`
/// (R-P9-5). Set by the creator (`boot.addWinTo`, and later New/Newcol). When
/// false the body `File` is borrowed (caller-owned), as in the wave-1 harnesses.
owns_body: bool = false,
chrome: *const Chrome,

/// `wininit` (wind.c:17-90), no-clone: lay out the tag over the top strip and the
/// body below a 1px purpleblue divider, draw the scrollbar + button. `body_file`
/// is borrowed (caller-owned); the tag's File is constructed here.
pub fn init(w: *Window, chrome: *const Chrome, body_file: *File, id: u32, r: Rect) Error!void {
    const a = chrome.allocator;
    const font = chrome.font;
    const fh: i32 = font.height;
    const screen = &chrome.display.image;

    w.chrome = chrome;
    w.taglines = 1; // wind.c:27
    w.id = id; // wind.c:30
    w.col = null;
    w.r = r;

    // tagtop = the first tag line (dat.h:275; wind.c:38-39).
    w.tagtop = r;
    w.tagtop.max.y = r.min.y + fh;

    // Tag over the 1-line strip (wind.c:36-45); its File is built here.
    var r1 = r;
    r1.max.y = r1.min.y + w.taglines * fh;
    w.tag_file = File.init(a, try Buffer.initFromBytes(a, ""));
    errdefer w.tag_file.deinit();
    w.tag = try Text.init(&w.tag_file, a, r1, font, screen, chrome.tag_cols);
    w.tag.what = .tag; // wind.c:45
    w.tag.w = w; // wind.c:26

    // Body below the tag + a 1px divider (wind.c:57-71).
    r1 = r;
    r1.min.y += w.taglines * fh + 1;
    if (r1.max.y < r1.min.y) r1.max.y = r1.min.y; // wind.c:59-60
    w.body = try Text.init(body_file, a, r1, font, screen, chrome.body_cols);
    w.body.what = .body; // wind.c:70
    w.body.w = w; // wind.c:29

    // 1px PURPLEBLUE divider above the body (wind.c:72-74 — tagcols[BORD], NOT
    // black).
    r1.min.y -= 1;
    r1.max.y = r1.min.y + 1;
    try screen.draw(r1, w.tag.fr.col(.bord), null, .{});

    try w.body.scrDraw(); // wind.c:75
    w.r = r; // wind.c:76
    try w.drawButton(); // wind.c:77-80
    w.maxlines = w.body.fr.maxlines; // wind.c:82
}

/// Free the two Texts and the tag's File. The body's File is freed here only when
/// `owns_body` (R-P9-5 — Del must destroy a window+file with no external
/// registry); otherwise it is caller-owned.
pub fn deinit(w: *Window) void {
    const owned_body: ?*File = if (w.owns_body) w.body.file else null;
    w.body.deinit();
    w.tag.deinit();
    w.tag_file.deinit();
    if (owned_body) |bf| {
        const a = w.chrome.allocator;
        bf.deinit();
        a.destroy(bf);
    }
}

/// `winresize` (wind.c:179-250), taglines==1, no mouse warp: relayout the tag
/// over the top strip and the body below the divider (or collapse the body when
/// the rect is too short for even one line). Returns the new `r.max.y`.
///
/// `safe` (the C's tagsafe/eqrect short-circuits) is accepted for call-site
/// parity with `Column.resize` but unused: we always relayout — behaviourally
/// identical, only skipping an optimization we don't track.
pub fn resize(w: *Window, r: Rect, safe: bool, keepextra: bool) Error!i32 {
    _ = safe;
    const font = w.chrome.font;
    const fh: i32 = font.height;
    const screen = &w.chrome.display.image;

    // tagtop is the first tag line (wind.c:190-191).
    w.tagtop = r;
    w.tagtop.max.y = r.min.y + fh;

    var r1 = r; // wind.c:193-194
    r1.max.y = @min(r.max.y, r1.min.y + w.taglines * fh);
    // taglines stays 1 (no wintaglines recompute, wind.c:196-200).

    // Resize & redraw the tag (wind.c:204-208).
    _ = try w.tag.resize(r1, true);
    var y = w.tag.fr.r.max.y; // wind.c:206
    try w.drawButton(); // wind.c:207
    // (mouse-warp arms wind.c:210-222 dropped, R-P8-7.)

    // Resize & redraw the body (wind.c:226-247).
    r1 = r;
    r1.min.y = y;
    const oy = y; // wind.c:229
    if (y + 1 + fh <= r.max.y) { // wind.c:230 room for one line
        r1.min.y = y;
        r1.max.y = y + 1;
        try screen.draw(r1, w.tag.fr.col(.bord), null, .{}); // wind.c:233 divider
        y += 1;
        r1.min.y = @min(y, r.max.y); // wind.c:235
        r1.max.y = r.max.y; // wind.c:236
    } else { // wind.c:237-241 too short: fill leftover, give the body an empty rect
        try screen.draw(r1, w.body.fr.col(.back), null, .{}); // wind.c:238
        r1.min.y = y; // wind.c:239
        r1.max.y = y; // wind.c:240
    }
    y = try w.body.resize(r1, keepextra); // wind.c:242
    w.r = r; // wind.c:243
    w.r.max.y = y; // wind.c:244
    try w.body.scrDraw(); // wind.c:245
    w.body.all.min.y = oy; // wind.c:246
    w.maxlines = @min(w.body.fr.nlines, @max(w.maxlines, w.body.fr.maxlines)); // wind.c:248
    return w.r.max.y; // wind.c:249
}

/// `windrawbutton` (wind.c:95-108) as fills (R-P8-1, not the cached button
/// images): a `tag_back` ground, a 2px `tag_bord` ring, and — when the body file
/// is modified — a `mod_blue` center (the `modbutton`, iconinit acme.c:1073-1078).
/// isdir/isscratch/ncache are dropped (single-window F-9).
pub fn drawButton(w: *Window) Error!void {
    const screen = &w.chrome.display.image;
    const dim = w.chrome.buttonRect(); // (0,0,Scrollwid,height+1)
    const dx = dim.max.x - dim.min.x;
    const dy = dim.max.y - dim.min.y;
    var br: Rect = undefined;
    br.min = w.tag.scrollr.min; // wind.c:105
    br.max = .{ .x = br.min.x + dx, .y = br.min.y + dy }; // wind.c:106-107
    try screen.draw(br, w.tag.fr.col(.back), null, .{}); // iconinit acme.c:1069
    try border(screen, br, Chrome.button_border, w.tag.fr.col(.bord)); // acme.c:1070
    if (w.body.file.mod) { // wind.c:102 (mod ⇒ modbutton)
        try screen.draw(insetRect(br, Chrome.button_border), w.chrome.mod_blue, null, .{});
    }
}

/// `border` SoverD (border.c:6-24): a ring of thickness `i` inside `r` — top,
/// bottom, then the left/right sides between them.
fn border(img: *Image, r: Rect, i: i32, color: *Image) Error!void {
    try img.draw(.{ .min = .{ .x = r.min.x, .y = r.min.y }, .max = .{ .x = r.max.x, .y = r.min.y + i } }, color, null, .{});
    try img.draw(.{ .min = .{ .x = r.min.x, .y = r.max.y - i }, .max = .{ .x = r.max.x, .y = r.max.y } }, color, null, .{});
    try img.draw(.{ .min = .{ .x = r.min.x, .y = r.min.y + i }, .max = .{ .x = r.min.x + i, .y = r.max.y - i } }, color, null, .{});
    try img.draw(.{ .min = .{ .x = r.max.x - i, .y = r.min.y + i }, .max = .{ .x = r.max.x, .y = r.max.y - i } }, color, null, .{});
}

/// `insetrect` (rectclip.c): shrink `r` by `n` on every side.
fn insetRect(r: Rect, n: i32) Rect {
    return .{ .min = .{ .x = r.min.x + n, .y = r.min.y + n }, .max = .{ .x = r.max.x - n, .y = r.max.y - n } };
}

// ===========================================================================
// Tag lifecycle (wind.c:437-593, :666-685). The C works in Rune arrays; this
// port decodes the tag to `[]u21`, does all strstr/compare/splice-index math in
// runes (so the `Text` splice offsets are correct for non-ASCII names), then
// issues `insertAt`/`deleteRange` with rune offsets + UTF-8 byte slices.
// ===========================================================================

/// `parsetag` boundary: the rune index where the file-name ends (wind.c:450-465).
const del_snarf_runes = [_]u21{ ' ', 'D', 'e', 'l', ' ', 'S', 'n', 'a', 'r', 'f' };

/// Decode the tag Text's whole buffer to an owned rune slice (caller frees).
fn tagRunes(w: *Window, a: std.mem.Allocator) error{OutOfMemory}![]u21 {
    const nc = w.tag.file.buffer.len();
    const r = try a.alloc(u21, nc);
    var i: usize = 0;
    while (i < nc) : (i += 1) r[i] = w.tag.file.buffer.runeAt(i);
    return r;
}

/// Encode a rune slice to owned UTF-8 (caller frees). Runes come from `runeAt`
/// (never surrogates), so encoding cannot fail; a stray invalid rune degrades to
/// U+FFFD rather than erroring.
fn runesToUtf8(a: std.mem.Allocator, runes: []const u21) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var tmp: [4]u8 = undefined;
    for (runes) |r| {
        const n = std.unicode.utf8Encode(r, &tmp) catch std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
        try buf.appendSlice(a, tmp[0..n]);
    }
    return buf.toOwnedSlice(a);
}

fn appendAsciiRunes(list: *std.ArrayList(u21), a: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
    for (s) |c| try list.append(a, c);
}

fn appendUtf8AsRunes(list: *std.ArrayList(u21), a: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
    const view = std.unicode.Utf8View.init(s) catch {
        for (s) |_| try list.append(a, 0xFFFD);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try list.append(a, cp);
}

fn indexOfRune(hay: []const u21, needle: u21) ?usize {
    for (hay, 0..) |r, i| if (r == needle) return i;
    return null;
}

fn indexOfRunes(hay: []const u21, needle: []const u21) ?usize {
    if (needle.len == 0) return 0;
    if (hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.mem.eql(u21, hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// The earliest " |" or "\t|" — the left-half terminator (wind.c:455-457).
fn pipeDelim(runes: []const u21) ?usize {
    const sp = indexOfRunes(runes, &[_]u21{ ' ', '|' });
    const tb = indexOfRunes(runes, &[_]u21{ '\t', '|' });
    if (sp) |s| return if (tb) |t| @min(s, t) else s;
    return tb;
}

/// `parsetag`'s name-end computation (wind.c:450-465), rune index.
fn nameEndRune(runes: []const u21) usize {
    const pipe = pipeDelim(runes);
    if (indexOfRunes(runes, &del_snarf_runes)) |ds| {
        if (pipe == null or ds < pipe.?) return ds;
    }
    var i: usize = 0;
    while (i < runes.len) : (i += 1) {
        if (runes[i] == ' ' or runes[i] == '\t') return i;
    }
    return runes.len;
}

/// `parsetag` (wind.c:437-467): return the whole tag as UTF-8 plus the name-end
/// index. NOTE: `name_len` is a RUNE index (the C's `*len`), equal to the byte
/// index for the ASCII tags of v1. Caller frees `text`.
pub fn parseTag(w: *Window, a: std.mem.Allocator) error{OutOfMemory}!struct { text: []u8, name_len: usize } {
    const runes = try w.tagRunes(a);
    defer a.free(runes);
    const nl = nameEndRune(runes);
    const text = try runesToUtf8(a, runes);
    return .{ .text = text, .name_len = nl };
}

/// `winsettag1` (wind.c:469-577), ported per exec contract §3c. No tag cache, so
/// the C's ncache/wincommit sync (wind.c:484-486) and `needundo` dance are n/a;
/// Put/Get arms are FLAG-deferred (no putseq/isdir yet). taglines==1 ⇒ the final
/// `winresize` arm (wind.c:573-576) is dead, but `drawButton` (wind.c:572) is not.
pub fn setTag1(w: *Window) Error!void {
    const a = w.chrome.allocator;

    // old = current tag runes; name-splice if the tag's name half differs from
    // body.file.name (wind.c:487-495).
    var old = try w.tagRunes(a);
    defer a.free(old);
    {
        const i = nameEndRune(old);
        const old_name = try runesToUtf8(a, old[0..i]);
        defer a.free(old_name);
        if (!std.mem.eql(u8, old_name, w.body.file.name.items)) {
            try w.tag.deleteRange(0, i, true); // wind.c:489 textdelete
            try w.tag.insertAt(0, w.body.file.name.items, true); // wind.c:490 textinsert
            const fresh = try w.tagRunes(a); // wind.c:492-494 re-read
            a.free(old);
            old = fresh;
        }
    }

    // Compose `new` (wind.c:497-536).
    var new: std.ArrayList(u21) = .empty;
    defer new.deinit(a);
    try appendUtf8AsRunes(&new, a, w.body.file.name.items); // wind.c:500-502 name
    try appendAsciiRunes(&new, a, " Del Snarf"); // wind.c:503
    // filemenu is true for a normal window in v1 (no dir/scratch windows yet):
    if (w.body.file.undoSeq() != 0) try appendAsciiRunes(&new, a, " Undo"); // wind.c:506-508
    if (w.body.file.redoSeq() != 0) try appendAsciiRunes(&new, a, " Redo"); // wind.c:510-512
    // Put (wind.c:514-518) / Get (wind.c:520-522) FLAG-deferred: no putseq/isdir.
    try appendAsciiRunes(&new, a, " |"); // wind.c:524
    // user-suffix preservation: k = just past the old '|'; else append " Look "
    // for a fresh window (wind.c:526-535).
    var k: usize = undefined;
    if (indexOfRune(old, '|')) |bar| {
        k = bar + 1;
    } else {
        k = old.len;
        if (w.body.file.seq == 0) try appendAsciiRunes(&new, a, " Look "); // wind.c:531-534
    }
    const i_new = new.items.len;

    // Replace [j,k) from the first differing rune if new != old[0..k]
    // (wind.c:538-562).
    if (!std.mem.eql(u21, new.items, old[0..k])) {
        const n = @min(k, i_new);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (old[j] != new.items[j]) break;
        }
        const q0 = w.tag.q0;
        const q1 = w.tag.q1;
        try w.tag.deleteRange(j, k, true); // wind.c:550
        const ins = try runesToUtf8(a, new.items[j..i_new]);
        defer a.free(ins);
        try w.tag.insertAt(j, ins, true); // wind.c:551
        // Preserve the user's tag selection past the bar (wind.c:552-561).
        if (indexOfRune(old, '|')) |bar_old| {
            if (q0 > bar_old) {
                const bar_new = indexOfRune(new.items, '|').?;
                const shift = @as(isize, @intCast(bar_new)) - @as(isize, @intCast(bar_old));
                w.tag.q0 = shiftClamp(q0, shift);
                w.tag.q1 = shiftClamp(q1, shift);
            }
        }
    }

    // Clear the tag file's mod flag, clamp + reselect, redraw the button
    // (wind.c:565-572). No ncache ⇒ n is just the tag length.
    w.tag_file.mod = false;
    const n_total = w.tag.file.buffer.len();
    if (w.tag.q0 > n_total) w.tag.q0 = n_total;
    if (w.tag.q1 > n_total) w.tag.q1 = n_total;
    try w.tag.setSelect(w.tag.q0, w.tag.q1);
    try w.drawButton();
}

fn shiftClamp(v: usize, shift: isize) usize {
    const r = @as(isize, @intCast(v)) + shift;
    return if (r < 0) 0 else @intCast(r);
}

/// `winsettag` (wind.c:577-593): the `file->ntext` fan-out collapses to one
/// `setTag1` (a single Text per File in v1).
pub fn setTag(w: *Window) Error!void {
    try w.setTag1();
}

/// `winclean` (wind.c:666-685) — THE TWO-STRIKE. isscratch/isdir/nopen arms are
/// n/a in v1 (`conservative` unused). A dirty window warns ONCE and clears
/// `dirty` (while `file.mod` stays true so the mod dot remains), returning false;
/// the second call sees `dirty==false` and returns true. A later body edit
/// re-arms `dirty` (Text.insertAt/deleteRange). Small unnamed files pass silently.
pub fn clean(w: *Window, ed: *Editor, conservative: bool) bool {
    _ = conservative;
    if (w.dirty) {
        if (w.body.file.name.items.len != 0) {
            ed.warning("{s} modified\n", .{w.body.file.name.items}); // wind.c:675
        } else {
            if (w.body.file.buffer.len() < 100) return true; // wind.c:677-678 too small: pass
            ed.warning("unnamed file modified\n", .{}); // wind.c:679
        }
        w.dirty = false; // wind.c:681
        return false; // wind.c:682
    }
    return true;
}

// ===========================================================================
// Control line (winctlprint, wind.c:688-696) — the /dev/acme ctl + index line.
// Ported for the served tree (S-07 §4, ruling R-P10-F). Cite as `wind.c:NN`.
// ===========================================================================

/// `Ctlsize = 5*12` (xfid.c:17): the fixed byte length of the non-fonts ctl
/// prefix — five `%11d ` columns.
pub const ctl_size: usize = 60;

/// `winctlprint` (wind.c:688-696): format `w`'s control line into `buf`,
/// returning the written slice. The base line is five `%11d ` columns
/// (12 bytes each = `ctl_size`): id, tag rune count, body rune count,
/// `isdir` (always 0 in v1 — dir/scratch windows are unbuilt), `dirty`.
///
/// With `fonts`, the /dev/acme-index arm appends five more fields
/// `"%11d %q %11d %11d %11d "`: `Dx(w.body.fr.r)`, the font name, `fr.maxtab`,
/// `seqof(w,1)!=0` (undo pending) and `seqof(w,0)!=0` (redo pending). Snarf's
/// `Font` carries no name (FLAG, R-P10-F) so the literal `fixed9x18` stands in.
///
/// Every column is formatted UNSIGNED: Zig's `{d:>11}` prints a leading `+` for
/// a positive SIGNED int (the devinput/devdraw trap), which `%11d` never does.
/// `buf` must hold at least `ctl_size` (non-fonts) / ~120 bytes (fonts).
pub fn ctlPrint(w: *Window, buf: []u8, fonts: bool) []u8 {
    const id: u32 = w.id;
    const tag_nc: usize = w.tag.file.buffer.len();
    const body_nc: usize = w.body.file.buffer.len();
    const isdir: u32 = 0; // wind.c:695 (single-window: no dir windows)
    const dirty: u32 = @intFromBool(w.dirty);

    const base = std.fmt.bufPrint(buf, "{d:>11} {d:>11} {d:>11} {d:>11} {d:>11} ", .{
        id, tag_nc, body_nc, isdir, dirty,
    }) catch return buf[0..0];
    std.debug.assert(base.len == ctl_size);
    if (!fonts) return base;

    const dx: u32 = @intCast(w.body.fr.r.max.x - w.body.fr.r.min.x); // Dx(w->body.fr.r)
    const maxtab: u32 = @intCast(w.body.fr.maxtab);
    const undo: u32 = @intFromBool(w.body.file.undoSeq() != 0); // seqof(w,1)
    const redo: u32 = @intFromBool(w.body.file.redoSeq() != 0); // seqof(w,0)
    const rest = std.fmt.bufPrint(buf[base.len..], "{d:>11} fixed9x18 {d:>11} {d:>11} {d:>11} ", .{
        dx, maxtab, undo, redo,
    }) catch return base;
    return buf[0 .. base.len + rest.len];
}

// ===========================================================================
// Tests. 9x18 font (height 18), Scrollwid 12 / Scrollgap 4 / ButtonBorder 2.
// ===========================================================================
const testing = std.testing;
const Frame = draw.Frame;
const proto = draw.proto;

/// Count draw ('d')/string ('s') verbs in one flushed write (mirrors select.zig).
fn countDraws(buf: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < buf.len) {
        switch (buf[i]) {
            'v' => i += 1,
            'd' => {
                i += 45;
                n += 1;
            },
            's' => {
                const ni = std.mem.readInt(u16, buf[i + 45 ..][0..2], .little);
                i += 47 + 2 * ni;
                n += 1;
            },
            else => break,
        }
    }
    return n;
}

const WinHarness = struct {
    fx: Frame.TestFixture,
    chrome: *Chrome,
    body_file: File,
    w: Window,

    fn init(seed: []const u8, r: Rect) !*WinHarness {
        const a = testing.allocator;
        const h = try a.create(WinHarness);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        h.chrome = try Chrome.init(a, h.fx.disp, h.fx.font);
        h.body_file = File.init(a, try Buffer.initFromBytes(a, seed));
        try h.w.init(h.chrome, &h.body_file, 1, r);
        return h;
    }
    fn deinit(h: *WinHarness) void {
        h.w.deinit();
        h.body_file.deinit();
        h.chrome.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
};

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

test "window: resize splits tag/divider/body with 9x18 font" {
    const seed = try genLines(testing.allocator, 40);
    defer testing.allocator.free(seed);
    const h = try WinHarness.init(seed, proto.Rect.make(0, 20, 300, 380));
    defer h.deinit();
    const w = &h.w;

    const bot = try w.resize(proto.Rect.make(0, 20, 300, 380), false, false);

    // Two texts, correctly typed and back-pointed.
    try testing.expect(w.tag.what == .tag);
    try testing.expect(w.body.what == .body);
    try testing.expect(w.tag.w == w and w.body.w == w);

    // tagtop + tag occupy exactly one 18px line at the top.
    try testing.expectEqual(@as(i32, 38), w.tagtop.max.y); // 20 + 18
    try testing.expectEqual(@as(i32, 38), w.tag.fr.r.max.y);

    // Body begins one pixel below the tag (the divider), and its `all.min.y` is
    // pinned to the tag bottom (wind.c:246).
    try testing.expectEqual(@as(i32, 38), w.body.all.min.y); // oy
    try testing.expectEqual(@as(i32, 39), w.body.fr.r.min.y); // past the 1px divider

    // Scrollbar carved off the body's left: strip [x,x+12), text at x+16.
    try testing.expectEqual(w.body.all.min.x + 12, w.body.scrollr.max.x);
    try testing.expectEqual(w.body.all.min.x + 16, w.body.fr.r.min.x);

    // resize returns w.r.max.y (the body's trimmed bottom).
    try testing.expectEqual(w.r.max.y, bot);
    try testing.expectEqual(w.body.all.max.y, bot);
}

test "window: too-short rect collapses the body" {
    const seed = try genLines(testing.allocator, 40);
    defer testing.allocator.free(seed);
    const h = try WinHarness.init(seed, proto.Rect.make(0, 20, 300, 380));
    defer h.deinit();
    const w = &h.w;

    // Height 30: room for the 18px tag, but y(38)+1+18 > 50 ⇒ the body collapses
    // to an empty rect at the tag bottom (wind.c:237-241).
    const bot = try w.resize(proto.Rect.make(0, 20, 300, 50), false, false);
    try testing.expectEqual(@as(usize, 0), w.body.fr.maxlines);
    try testing.expectEqual(@as(i32, 38), w.body.all.min.y);
    try testing.expectEqual(@as(i32, 38), bot); // w.r.max.y == the tag bottom
}

test "window: drawButton reflects file.mod" {
    const seed = try genLines(testing.allocator, 40);
    defer testing.allocator.free(seed);
    const h = try WinHarness.init(seed, proto.Rect.make(0, 20, 300, 380));
    defer h.deinit();
    const w = &h.w;

    // Unmodified: a tag_back ground + a 4-rect tag_bord ring = 5 fills.
    try testing.expect(!w.body.file.mod);
    try h.fx.disp.flush();
    var base = h.fx.tree.writes.items.len;
    try w.drawButton();
    try h.fx.disp.flush();
    try testing.expectEqual(@as(usize, 5), countDraws(h.fx.tree.writes.items[base]));

    // Modified: the mod_blue center adds a 6th fill (the modbutton).
    w.body.file.mod = true;
    base = h.fx.tree.writes.items.len;
    try w.drawButton();
    try h.fx.disp.flush();
    try testing.expectEqual(@as(usize, 6), countDraws(h.fx.tree.writes.items[base]));
}

// --- Tag lifecycle (wind.c:437-593, :666-685) ---------------------------------

const win_rect = proto.Rect.make(0, 20, 300, 380);

test "window: parsetag finds the name end" {
    const a = testing.allocator;

    // " Del Snarf" (before the " |" pipe) ends the name.
    {
        const h = try WinHarness.init("body\n", win_rect);
        defer h.deinit();
        try h.w.tag.insertAt(0, "foo Del Snarf | Look ", true);
        const pt = try h.w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqual(@as(usize, 3), pt.name_len); // "foo"
        try testing.expectEqualStrings("foo Del Snarf | Look ", pt.text);
    }

    // "\t|" is a valid pipe terminator; a " Del Snarf" AFTER the pipe is ignored,
    // so the name ends at the first blank.
    {
        const h = try WinHarness.init("body\n", win_rect);
        defer h.deinit();
        try h.w.tag.insertAt(0, "a b\t| Del Snarf", true);
        const pt = try h.w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqual(@as(usize, 1), pt.name_len); // "a"
    }

    // A name with no blanks and no pipe: the whole tag is the name.
    {
        const h = try WinHarness.init("body\n", win_rect);
        defer h.deinit();
        try h.w.tag.insertAt(0, "foobar", true);
        const pt = try h.w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqual(@as(usize, 6), pt.name_len);
    }
}

test "window: setTag1 recomposition" {
    const a = testing.allocator;
    const h = try WinHarness.init("hello\n", win_rect);
    defer h.deinit();
    const w = &h.w;
    try h.body_file.setName("f");

    // Fresh window (seq==0, no undo/redo): the composed tag is byte-exact.
    try w.setTag1();
    {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqualStrings("f Del Snarf | Look ", pt.text);
    }

    // A user types a suffix after the '|'.
    try w.tag.insertAt(w.tag.file.buffer.len(), "xyz", true); // "f Del Snarf | Look xyz"

    // Select the user suffix "xyz" (both ends are past the bar).
    try w.tag.setSelect(19, 22);

    // A recorded body edit ⇒ undoSeq()!=0 ⇒ " Undo" appears before the pipe; the
    // user suffix after '|' survives verbatim, and the selection shifts by the
    // bar displacement (+5 for " Undo", wind.c:554-562).
    h.body_file.mark(1);
    try w.body.insertAt(0, "X", true);
    try w.setTag1();
    {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqualStrings("f Del Snarf Undo | Look xyz", pt.text);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Undo") != null);
    }
    try testing.expectEqual(@as(usize, 24), w.tag.q0); // 19 + 5
    try testing.expectEqual(@as(usize, 27), w.tag.q1); // 22 + 5

    // Undo the body edit ⇒ redoSeq()!=0, undoSeq()==0 ⇒ " Redo" replaces " Undo".
    _ = try h.body_file.undo();
    try w.setTag1();
    {
        const pt = try w.parseTag(a);
        defer a.free(pt.text);
        try testing.expectEqualStrings("f Del Snarf Redo | Look xyz", pt.text);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Undo") == null);
        try testing.expect(std.mem.indexOf(u8, pt.text, " Redo") != null);
        // The user suffix after the pipe is still there.
        try testing.expect(std.mem.endsWith(u8, pt.text, " Look xyz"));
    }
}

test "window: clean two-strikes on dirty" {
    const a = testing.allocator;
    const h = try WinHarness.init("hello\n", win_rect);
    defer h.deinit();
    const w = &h.w;
    try h.body_file.setName("f");

    var ed = Editor.init(a);
    defer ed.deinit();

    // A recorded body edit arms `dirty` (and `file.mod`) via the text.c:378 hook.
    h.body_file.mark(1);
    try w.body.insertAt(0, "X", true);
    try testing.expect(w.dirty);
    try testing.expect(w.body.file.mod);

    // First strike: warn once, clear dirty (mod stays), refuse.
    try testing.expect(!w.clean(&ed, false));
    try testing.expect(!w.dirty);
    try testing.expect(w.body.file.mod); // the mod dot remains
    try testing.expect(std.mem.indexOf(u8, ed.warnings.items, "f modified") != null);

    // Second strike passes (dirty already cleared).
    try testing.expect(w.clean(&ed, false));

    // A later body edit re-arms dirty, so the next Del warns again.
    const warn_len = ed.warnings.items.len;
    h.body_file.mark(2);
    try w.body.insertAt(0, "Y", true);
    try testing.expect(w.dirty);
    try testing.expect(!w.clean(&ed, false));
    try testing.expect(!w.dirty);
    try testing.expect(ed.warnings.items.len > warn_len); // warned again
}
