# Phase 8 chrome side contract (O16) — Text deltas, scroll.zig, Window, Chrome, Column, Row

C: plan9port acme wind.c/cols.c/rows.c/scrl.c/acme.c/dat.h. Cite per fn. Read the
master rulings first.

## §1 core/Chrome.zig (~120, W2)

Constants (dat.h:475-479): scrollwid=12, scrollgap=4, border=2, button_border=2.
Colors (acme.c:1036-1086; allocimagemix on deep display = c1*63/255 + white*192/255):
tag_back 0xEAFFFFFF · tag_high 0x9EEEEEFF · tag_bord 0x8888CCFF · tag_text/htext black
· body_back 0xFFFFEAFF · body_high 0xEEEE9EFF · body_bord 0x99994CFF (CHANGES from
black in main_wasm!) · body_text/htext black · mod_blue 0x000099FF · col_button
0x8888CCFF · window/column border fills black.
Chrome struct: allocator, display, font, tag_cols/body_cols ([Frame.ncol]*Image),
black, white, mod_blue, colbutton; `init(a, d, f) !*Chrome` allocImages the solids;
`buttonRect() = Rect(0,0,scrollwid,font.height+1)` (acme.c:1058). Buttons drawn as
fills, not cached images (divergence noted).

## §2 Text.zig deltas (W1, +~60)

```zig
pub const What = enum { columntag, rowtag, tag, body };  // dat.h:166-172
what: What = .body,
w: ?*Window = null,        // dat.h:184; import cycle legal (Image.zig precedent note)
all: draw.Rect,            // dat.h:187
scrollr: draw.Rect,        // dat.h:185 — left scrollwid strip of all
lastsr: draw.Rect = zero,  // dat.h:186
```
init becomes textinit (text.c:25-39): all=r; scrollr = r capped max.x=min.x+scrollwid;
frame rect min.x += scrollwid+scrollgap; redraw backfills to the scrollbar (text.c:
48-51). New `pub fn resize(self, r, keepextra: bool) Error!i32` (textresize text.c:
74-98 + textredraw tail :42-71 minus isdir): trim to line multiple unless keepextra;
reset all/scrollr/lastsr; fr.clear(false)+setRects+backfill+fill()+setSelect; paint
bottom fringe when keepextra; return all.max.y. The five scrdraw FLAG sites go LIVE
as `try self.scrDraw()` (no-op when w==null → all old tests pass): Text setOrigin
(text.c:1645) + show tsd arm (:1133) + Editor cut (exec.c:1009) / snarfInsert
(exec.c:1068) / chordStep (text.c:1091). HARNESS RECT SHIFT: every test rect
(20,y0,x1,y1) becomes (4,y0,x1,y1) so frame min.x stays 20 — assertions byte-identical.
The phase-7 frozen stream hash breaks; orchestrator re-freezes (R-P8-12).

## §3 core/text/scroll.zig (~200, W1; method aliases on Text like typing/select)

`pub fn scrPos(r, p0, p1, tot) draw.Rect` (scrl.c:17-44): tot==0 ⇒ r; tot>1<<20 ⇒
>>=10 all three; min.y += h*p0/tot when p0>0; max.y -= h*(tot-p1)/tot when p1<tot;
2px minimum clamped inside r.
`pub fn scrDraw(t) Error!void` (scrl.c:56-80, direct-draw R-P8-1): return unless
t.w != null and t.what == .body (scrl.c:61); r2 = scrPos(t.scrollr, org,
org+fr.nchars, buffer.len()); lastsr memo short-circuit; three fills into fr.b:
bord over scrollr, back over r2, bord over r2's right 1px.
`pub fn scrollClick(t, but: u3, pt) Error!void` (scrl.c:107-159 one step, R-P8-8):
s = scrollr inset 1; my clamped; but2 ⇒ p0 = len*(my-s.min.y)/h, if p0>=q1 p0 =
backNL(p0,2), setOrigin(p0,false); but1 ⇒ setOrigin(backNL(org,(my-s.min.y)/
font.height), true); but3 ⇒ setOrigin(org + fr.charOfPt(.{s.max.x, my}), true).

## §4 core/Window.zig (~350, W1)

Fields: tag: Text, body: Text, tag_file: File, r, tagtop (first tag line rect,
dat.h:275), id: u32, col: ?*Column, taglines=1, maxlines: usize, chrome: *const Chrome.
`init(w, chrome, body_file: *File, id, r)` = wininit (wind.c:17-90) no-clone: tag.w/
body.w = w (wind.c:26,29); tagtop = r capped min.y+font.height; tag Text (tag_cols,
.tag) over the 1-line strip; body Text (body_cols, .body) below tag+1px; 1px tag_bord
divider (wind.c:72-74 — PURPLEBLUE not black); body.scrDraw(); drawButton. Body File
passed in; tag File constructed inside.
`resize(w, r, safe, keepextra) Error!i32` = winresize (wind.c:180-250, taglines=1,
no warp): tagtop; tag.resize(r1,true) → y (frame bottom, wind.c:204-206) + drawButton;
if y+1+font.height <= r.max.y: 1px tag_bord band, body below; ELSE fill leftover
body_back, body gets EMPTY rect at y (wind.c:237-241); y = body.resize(r1, keepextra);
w.r capped max.y=y; body.scrDraw(); maxlines update (wind.c:248); return w.r.max.y.
`drawButton` = windrawbutton (wind.c:95-108) as fills at tag.scrollr.min: tag_back +
2px tag_bord ring + mod_blue inset center when body.file.mod.
winsettag/winclean/parsetag: PHASE 9.

## §5 core/Column.zig (~300, W2)

Fields: r, tag: Text, tag_file: File, row: ?*Row, w: ArrayList(*Window) (heap-created
pointers — stability §8), safe, chrome.
init = colinit (cols.c:26-50): white ground; tag Text (.columntag) over top strip;
border-px black band; header literal "New Cut Paste Snarf Sort Zerox Delcol "
(cols.c:15-24) caret at end; colbutton purple square over tag.scrollr.
add(c, winid: *u32, body_file, y_in) !*Window = coladd (cols.c:52-158) no-clone/no-
warp: y<r.min.y & nw>0 ⇒ steal half of last window's body (cols.c:62-64); find
landing v (cols.c:66-71); minht = font.height+border+1; ymax per next window; clamp
y (cols.c:99-103); can't fit ⇒ buggered; resize v shrunk (cols.c:112-118) + black
band; heap-create Window over remainder, splice; buggered ⇒ colresize(c, c.r)
(cols.c:146-148).
resize = colresize (cols.c:235-272): tag strip + colbutton; black band; proportional
stacking (new/old = Dy minus nw*(border+font.height); per-window formula cols.c:
256-262 + clamp :264 + 2px black top bands :265-268); w.resize(r1, false, is_last).
which = colwhich (cols.c:559-580): tag.all ⇒ &tag; per window: tagtop or tag.all ⇒
&tag; the dead corner (pt.x >= body.scrollr.max.x and pt.y >= body.fr.r.max.y) ⇒
null; else &body.
colsort/colclose/coldragwin/colgrow: NOT this phase.

## §6 core/Row.zig (~350, W2)

Fields: r, tag: Text, tag_file: File, col: ArrayList(*Column), chrome.
init = rowinit (rows.c:25-48): white fill; tag (.rowtag) top strip; black band;
header "Newcol Kill Putall Dump Exit " (rows.c:16-23).
add(row, x_in) !?*Column = rowadd (rows.c:50-101): steal 3/5 of last col when x<min
(rows.c:60-63); Dx(landing) < 100 ⇒ null (rows.c:74-75); split at min(x-border,
r.max.x-50); colresize left; black vertical band; heap-create Column over remainder,
c.row = row, splice.
resize = rowresize (rows.c:103-138): deltax; tag strip + band; per column proportional
x-scale (rows.c:126-129); border bands between (130-135); colresize.
which = rowwhich (rows.c:256-266): row.tag.all ⇒ &tag; else whichCol → col.which.
whichCol = rowwhichcol (rows.c:242-254).
rowtype/rowdragcol/rowclose/Dump/Load: phases 9/10.

## §7-8 Pipeline + stability

Layout runs at boot (and future canvasResize) only, never per tick. Windows/Columns
individually heap-allocated (allocator.create), Row heap-allocated by boot —
SelectState aliases Text.fr, Text.w aliases Windows.

## §9 Named tests (implement exactly; hand-computed with 9x18/border 2/scrollwid 12/gap 4)

"window: resize splits tag/divider/body with 9x18 font" · "window: too-short rect
collapses the body" · "window: drawButton reflects file.mod" · "scroll: scrPos
elevator math" (4 cases) · "scroll: scrDraw paints bar+elevator+edge once" (+ lastsr
memo no-op) · "scroll: scrDraw no-ops for tags and unbound texts" · "scroll: click
actions map B1/B2/B3 to setOrigin" · "column: resize stacks windows proportionally" ·
"column: add steals half of the landing window" (+ buggered fallback) · "column:
which routes tag vs body vs partial-line" · "row: add steals 3/5 split and refuses
<100px" · "row: resize scales columns in x with row tag strip" · "row: which finds
rowtag/columntag/tag/body" · "chrome: palette matches acme".
