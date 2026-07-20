# Phase 8 routing side contract (O17, with R-P8-9/10 applied) — Editor + boot + main_wasm (W3)

C: acme.c mousethread :510-678 / keyboardthread :448-508, rows.c rowtype :268-302 /
rowwhich :255-266, cols.c colwhich :558-580, dat.h/dat.c globals. Read the master
rulings (esp. R-P8-9 POINT-TO-TYPE override and R-P8-10 hit regions) first.

## Editor.zig growth

```zig
row: ?*Row = null,           // when null: ed.text fallback (all old tests unchanged)
focus: ?*Text = null,        // bookkeeping only (argtext/typetext analog) — NOT key routing
gesture_text: ?*Text = null, // pinned at B1-down; cleared on all-buttons-up (R-P8-11)
mouse_pt: Point = .{...},    // mouse->xy analog

pub const Region = enum { tag, body, scrollbar };
const Hit = struct { text: *Text, region: Region };
fn hitTest(ed, p) ?Hit  // row.which(p) (or ed.text fallback w/ body region); then:
    // region = .scrollbar iff ptInRect(text.scrollr, p) (acme.c:603/630); else per
    // text.what (.tag/.rowtag/.columntag ⇒ .tag; .body ⇒ .body)
```

handleMouse rules (ordering mirrors acme.c:576-672): (1) mouse_pt = pt always.
(2) gesture_text non-null ⇒ route to it unconditionally (chord confinement); clear on
buttons==0. (3) hit = hitTest orelse return. (4) wheel bits: if hit.text.w != null ⇒
hit.text.typeRune(Kscrollone*) — under-pointer, w!=null guard skips row/col tags
(acme.c:618-629); no focus change, no run break. (5) region == .scrollbar and
hit.text.what == .body ⇒ scrollClick(hit.text, button, pt) on press edges (B2-held
moves MAY repeat — include, cheap). Tag scrollr (the button square) ⇒ no-op v1
(drag deferred R-P8-5). (6) B1-down in tag/body ⇒ focus = gesture_text = hit.text;
the existing sweep/double-click machine runs against gesture_text.
handleKey: POINT-TO-TYPE (R-P8-9): `const t = (ed.hitTest(ed.mouse_pt) orelse
fallback).text` — fallback = ed.focus orelse ed.text; keys route to the text under
the pointer (rows.c:279-282); document the -b variant note. Tag texts type through
the identical machinery (wintype filtering deferred).
Pointer-leave tag-commit + 500ms timer (acme.c:583-588, 471-479): correctly absent
(no tag cache) — doc note.
cut/snarfInsert/chordStep/frameEnd signatures unchanged.

## core/boot.zig (birth; S-07 §4 line 107)

Options { win_name = "scratch", body = "" }; Tree { chrome: *Chrome, row: *Row,
deinit }. `pub fn boot(a, display, font, r, opts) !Tree`: Chrome.init; heap Row +
row.init(chrome, r); const c = (try row.add(-1)).?; window via c.add(&winid,
body_file, -1) where body_file is a heap File over Buffer.initFromBytes(opts.body);
then write the window tag literal: opts.win_name ++ " Del Snarf | Look " (wind.c:
475-534 fresh-window composition; row/col headers are seeded by Row/Column.init per
the chrome contract). Fill frames; return Tree. Export via core.zig: boot + Row/
Column/Window/Chrome re-exports.

## main_wasm rewiring

App drops back/high/black/file/text; gains tree: core.boot.Tree; boot body becomes
core.boot.boot(alloc, display, &font, full-screen rect, .{ .win_name = "scratch",
.body = <several demo lines> }); editor.row = tree.row. pushEvent/tick/drainInput
UNCHANGED (wheel uses mouse_pt fallback — shim coordinate plumbing deferred, flag).

## Named tests

"editor: hit-test routes clicks across two windows" · "editor: keyboard follows the
pointer (acme point-to-type)" (pointer over body-2 without clicking ⇒ keys edit
file-2; the R-P8-9 pin) · "editor: wheel scrolls the text under the pointer, focus
elsewhere" · "editor: chord confined to its gesture text" · "editor: tag typing edits
the tag File" (seed string + typed runes) · "editor: scrollbar click scrolls the
body" (B1/B3 press in scrollr) · "boot: tree shape and default tag strings"
(byte-exact literals; what/w back-pointers; rect tiling).
Acceptance (orchestrator): "phase-8: boot chrome scene" + two-window variant per the
chrome contract §9 last paragraph; FROZEN-ACCEPT-8.
