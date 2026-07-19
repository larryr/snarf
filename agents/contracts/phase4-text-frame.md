# Phase 4 frame contract (O8) — libframe subset + minimal Text

Read with the master `phase4-text.md` (rulings R-P4-4..6 bind). C citations: plan9port
@337c6ac — include/frame.h, src/libframe/{frinit,frbox,frinsert,frdraw,frutil,
frptofchar,frselect,frstr}.c, acme/text.c; man 2/frame. Build on the MERGED phase-3
draw API (Display/Image/Font/proto — read the real files; NO changes to them).

## Files (phase 4 builds 4; delete.zig/select.zig DEFERRED)

- `src/draw/frame/Frame.zig` (~300): struct + frinit.c (init/setRects/clear) + frbox.c
  (all box primitives) + frdraw.c:207-215 strLen. frstr.c dissolves into slice
  ownership (cite once in header).
- `src/draw/frame/insert.zig` (~290): frinsert.c IN FULL (bxscan/chopFrame/insert).
- `src/draw/frame/draw.zig` (~210): frdraw.c drawText/draw0/drawSel0/drawSel/redraw +
  frselect.c:105-132 selectPaint (moved here — frinsert needs it); tick() no-op stub.
- `src/draw/frame/util.zig` (~240): frutil.c all + frptofchar.c all + runeByteIndex
  (frbox.c:86-101) + stringNWidth (= font.stringWidth(s[0..runeByteIndex(s,nr)])).
- `src/draw/draw.zig`: + `pub const Frame = @import("frame/Frame.zig");`

Imports: frame/* → Display/Image/Font/proto + std ONLY (never core; ninep.server only
inside test blocks per R-P4-5).

## Box (P-6 tagged union; frame.h:22-29)

```zig
pub const Box = struct {
    wid: i32,  // runs: stringWidth(text); breaks: layout-time newWid; '\n' KEEPS the
               // 5000 seed forever (drawSel0 clamps frdraw.c:100-102; charOfPt relies
               // on the overshoot frptofchar.c:90-92) — do not "fix".
    kind: Kind,
    pub const Kind = union(enum) { run: Run, brk: Brk };
    pub const Run = struct { text: []u8, nrune: u32 };  // owned UTF-8; no \n/\t/NUL
    pub const Brk = struct { bc: u8, minwid: i32 };     // '\n'⇒minwid 0; '\t'⇒stringWidth(" ")
    pub fn nrune(self: *const Box) usize;               // NRUNE: break box = 1 rune
};
pub const run_byte_cap = 256; // TMPSIZE frinsert.c:8 — BYTES not runes; creation-time
                              // cap only (bxscan breaks when next rune's bytes would
                              // reach the cap, frinsert.c:54-56); merge may exceed.
```

## Frame struct (frame.h:31-54; file-as-struct)

Fields: allocator, font: *Font, display: *Display, b: *Image, cols: [5]*Image
(enum ColorSlot{back,high,bord,text,htext}), r/entire: proto.Rect, boxes:
ArrayList(Box), p0/p1: usize (=0 in P4), maxtab: i32, nchars/nlines/maxlines: usize,
lastlinefull/modified/noredraw: bool. OMITTED: tick fields (phase 6), scroll ptr
(phase 7). Error = Allocator.Error || Display.Error.

Fns: init (maxtab = 8*stringWidth("0") — frinit.c:12; = 72px for fixed 9x18; then
setRects), setRects (trim r.max.y to line multiple; maxlines = Dy/height —
frinit.c:61-69), clear(freeall) (frinit.c:71-86). Box primitives pub: addBox/closeBox/
delBox/dupBox/truncateBox/chopBox/splitBox/mergeBox/findBox/strLen with the exact
frbox.c semantics (truncate drops LAST n runes, chop drops FIRST n; both recompute
wid = stringWidth). Method aliases: `pub const insert = @import("insert.zig").insert;`
etc. for redraw/drawText/ptOfChar/charOfPt.

INVARIANTS (document in header): I-1 boxes partition [0,nchars), Σnrune == nchars;
I-2 run wid == stringWidth(text) always; I-3 run texts hold no \n/\t/NUL; I-4 any
box-list growth invalidates *Box pointers — re-fetch after (the C reloads b after
realloc, frinsert.c:64,149-159); I-5 internal violations panic (drawerror analog,
frutil.c:29), wire errors propagate as Display.Error, allocation as OutOfMemory.

## insert.zig

`pub fn insert(f: *Frame, s: []const u8, p0: usize) Frame.Error!void` — frinsert.c:
97-291 in full: UTF-8 input, rune offset; early return p0 > nchars or s.len == 0.
bxscan (frinsert.c:11-74): the C static scratch Frame (frinsert.c:9) becomes a
caller-local scratch sharing f's allocator/font/r/maxtab/cols (P-3); runs ≤
run_byte_cap bytes; '\n'/'\t' break boxes (wid seed 5000); stop after maxlines
newlines (:29); ends ckLineWrap0 + draw.draw0(scratch). Box ADOPTION (frinsert.c:
271-273) MOVES owned text slices — no re-dup; scratch discarded without freeing
adopted runs. The static pts array (:106-108) becomes a local ArrayList of point
pairs. chopFrame (:76-95) ported faithfully INCLUDING the `/* BUG */` comment (:93).

## draw.zig

- drawText (frdraw.c:7-19): per run box — ckLineWrap then DECOMPOSED stringbg: back
  rect via Image.draw ('d'), then font.drawString ('s'). Honors noredraw. Break boxes
  draw nothing; pt.x += wid always.
- draw0 (frdraw.c:174-205): pure LAYOUT — walks boxes, splits at canFit, tab widths
  via newWid, truncates (delBox) at r.max.y. Emits nothing.
- drawSel0 (frdraw.c:57-119): partial-run width/draw via runeByteIndex byte-slicing;
  keep the x clamp (:100-102) and both wrapped-line back-fills (:80-84, :111-117).
- drawSel (frdraw.c:33-55): shape stub — P4 callers use issel=false only; tick calls
  route to the no-op.
- redraw (frredraw frdraw.c:121-141): P4 exercises the p0==p1 arm — full-frame
  drawSel0(ptOfChar(0), 0, nchars, cols[back], cols[text]).
- selectPaint (frselect.c:105-132). tick(): no-op.

## util.zig

canFit (frutil.c:7-31: run ⇒ #runes fitting via per-rune charWidth walk; brk ⇒
minwid <= left; panic on 0-fit at line start); ckLineWrap (:33-40 — brk uses minwid,
run uses wid); ckLineWrap0 (:42-49); advance (:51-59 — '\n' ⇒ CR+LF); newWid (:61-66);
newWid0 (:68-84 — TAB RULE: only '\t' recomputes; local x resets to r.min.x if
pt.x+minwid > r.max.x; x += maxtab; x -= (x - r.min.x) % maxtab; if x-pt.x < minwid
or x > r.max.x ⇒ wid = minwid); clean (_frclean :86-111: merge adjacent runs fitting
the line; set lastlinefull = pt.y >= r.max.y); ptOfChar (frptofchar.c:36-40);
ptOfCharPtB (:7-34); ptOfCharN (:42-53 — takes the box-count limit as a PARAMETER
instead of mutating nbox; note divergence); charOfPt (:67-115 + private _frgrid
:55-65); runeByteIndex; stringNWidth.

## Numbers (fixed 9x18: width 9, height 18, ascent 13; maxtab 72)

Default test rect R = (20,20)-(119,470): 11 chars/line, maxlines 25. Tab stops at
x = 20+k·72 (20, 92, 164, ...). Tab after 1 char (x=29): wid 63 → 92. Tab after 10
chars (x=110): stop 164 > 119 ⇒ wid = minwid 9 → 119. Newline never wraps (minwid 0).

## core/text/Text.zig (4b, sonnet; ~120 impl)

```zig
file: *File, fr: draw.Frame, org: usize = 0,
pub fn init(file: *File, allocator, r: draw.Rect, font: *draw.Font, b: *draw.Image,
            cols: [draw.Frame.ncol]*draw.Image) Text;
pub fn deinit(self: *Text) void;              // fr.clear(true)
pub fn fill(self: *Text) Error!void;          // textfill text.c:424-457, v1-tiny:
    // if (fr.lastlinefull) return; loop: n = file.buffer.len() - (org + fr.nchars);
    // if n==0 break; n = @min(n, 2000); read into a 4*2000 scratch (R-P4-1); cap at
    // (maxlines - nlines) newlines by scanning the decoded bytes and cutting after
    // the nl-th '\n'; fr.insert(chunk, fr.nchars); until lastlinefull.
pub fn redraw(self: *Text) Error!void;        // fr.redraw()
```
NO typing/select/scroll (phases 6/7). + `pub const Text = @import("text/Text.zig");`
in core.zig.

## Named tests (implement exactly)

Frame (in the respective frame/* files; fixture per R-P4-5): "frame: init and setrects
metrics" · "frame: bxscan boxes for nl and tab" ("ab\ncd\te" — expected boxes/wids as
computed) · "frame: wrap layout hello-acme-wraps" ("hello, acme wraps\nsecond
line\ttab", 33 runes — box list + nchars 33/nlines 4 + ptOfChar pins 0→(20,20),
11→(20,38), 17→(74,38), 18→(20,56), 29→(20,74), 30→(92,74), 33→(119,74)) · "frame:
exact-fit line then newline" ("hello, acme\nX" — NO blank line) · "frame: tab stops
and edge wrap" (three §Numbers cases) · "frame: ptofchar/charofpt round-trip" (all p
in 0..33 + mid-cell rounding + below-text clamp) · "frame: lastlinefull and chop at
maxlines" (3-line frame, 4 lines in) · "frame: mid-frame insert shifts and merges"
("abcde" then "XY"@2) · "frame: box primitives split/merge/find" (incl. multibyte
"café": runeByteIndex(...,4)==5) · "frame: drawtext write stream" ("ab"@0 — selectPaint
'd' rect (20,20)-(38,38), drawText 'd'+'s' p=(20,33), indices {'a','b'}) · "frame: run
cap at 256 bytes" (2000 ASCII into 3-line frame ⇒ nchars 33, lastlinefull).

Text: "text: fill renders a buffer" · "text: fill honors org" (org=18 ⇒ "second line"
first) · "text: fill stops at frame full" (2nd fill no-op) · "text: fill chunk cap"
(4000-rune line, 25-line frame ⇒ nchars 275).

## Acceptance (Wave C, orchestrator)

"phase-4: wrapped buffer text through a frame onto a headless display" — phase-3
stack + File("hello, acme wraps\nsecond line\ttab") + Text over Rect.make(20,20,119,470)
with cols {white,white,black,black,black}; fill + flush. Layout: L1 "hello, acme"
y∈[20,38); L2 " wraps" y∈[38,56); L3 "second line" y∈[56,74); L4 tab gap to x=92 then
"tab" y∈[74,92). Spot-checks: white above/below/right; L1 'h' + wrap-point 'e' cells
inked; L2 leading-space cell all white + 'w' cell inked; L3 's' cell inked; tab gap
(20..92,74..92) all white + 't'/'b' cells inked; fr.nchars 33, nlines 4, !lastlinefull,
ptOfChar(30).x == 92; flush_count 1. FROZEN-ACCEPT-3 per protocol.
