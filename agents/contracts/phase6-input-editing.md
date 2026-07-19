# Phase 6 editing side contract (O13) — frame delete/select/tick + Text typing/selection + Editor loop

Read with the master (R-P6-8/9/12 bind). C: plan9port src/libframe/{frdelete,frselect,
frdraw,frinit}.c, include/frame.h, src/cmd/acme/{text,file}.c. Builds on merged
phase-4 frame/* — read the real files. Fixed-9x18 numbers as in phase 4
(rect (20,20,119,470) = 11 cols x 25 lines).

## A4 scope — src/draw/frame/* growth

Frame.zig: add `pub const frtick_w: i32 = 3;` (FRTICKW frame.h:21), fields
`tick: ?Image = null, tickback: ?Image = null, ticked: bool = false` (tickscale
omitted, =1, cite frinit.c:36); `pub fn initTick(f: *Frame) Error!void` (frinittick
frinit.c:28-59: two allocImage(3xheight, display chan) + the 4 draws — BACK ground,
1px TEXT vertical at x=1, 3x3 TEXT boxes top+bottom; SEPARATE from init, F-5
divergence documented); `pub fn freeBox(f: *Frame, n0: usize, n1: usize) void`
(_frfreebox frbox.c:46-59: frees run text KEEPING slots); clear(freeall=true) now
really frees tick/tickback; alias `pub const delete = @import("delete.zig").delete;`
+ selectBegin/selectUpdate/selectEnd aliases + test-aggregator imports.

draw.zig: REPLACE the tick stub with the real port `pub fn tick(f: *Frame, pt: Point,
ticked: bool) Frame.Error!void` (frtick frdraw.c:163-172 + _frtick :143-161: no-op if
already in state/images absent/pt outside r; on: save screen r=(pt.x-1,pt.y)-(pt.x+2,
pt.y+h) clamped at r.max.x into tickback, blit tick; off: restore tickback) — now
fallible, existing drawSel call sites gain try. drawSel prologue (frdraw.c:37-38):
if f.ticked, tick off at ptOfChar(f.p0) first. redraw ticked save/restore
(frdraw.c:125-133).

insert.zig: activate the two commented tick lines (tick off before surgery when
p0==p1 at insert.zig:141-ish; tick on after the p0/p1 adjustment at :264-ish).

delete.zig NEW: `pub fn delete(f: *Frame, p0: usize, p1: usize) Frame.Error!usize`
(frdelete.c:7-131 in full — the clause-by-clause port map: guard+clamp :18-21;
findBox n0/n1 (I-4 re-fetch) :22-25; pt0=ptOfCharN/pt1=ptOfChar :26-27; tick off when
f.p0==f.p1 :28-29; freeBox(n0,n1-1) :31; the compaction walk :36-85 (ckLineWrap0/
ckLineWrap, canFit panic on 0 (I-5), run branch with splitBox + screen copy
f.b.draw + BACK blank clamped at r.max.x :53-67, break branch with newWid0 + HIGH
when f.p0<=cn1<f.p1 :68-77, advance/newWid :79-80, box compaction by struct copy
:81); tail selectPaint when n1==nbox and pt0.x!=pt1.x :86-87; multi-line close-up
:88-109 (ptOfCharPtB(32767) :91, panic pt2.y>r.max.y :92-93 (I-5), three draws
:100-105 + two BACK selectPaints :106-108); closeBox(n0,n1-1) :110; merge-adjacent
prologue + clean :111-116; the four p0/p1 selection adjustments :117-124;
nchars -= p1-p0 :125; tick back on :126-127; return old_nlines-new_nlines with
nlines = (pt.y-r.min.y)/h + (pt.x>r.min.x) :128-131).

select.zig NEW: the incremental sweep (R-P6-9; frselect.c:18-103 minus readmouse/
flushimage/scroll):
```zig
pub const SelectState = struct { f: *Frame, p0: usize, p1: usize, pt0: Point,
    pt1: Point, reg: i8 };  // region(p1,p0) in {-1,0,1}, frselect.c:8-16
pub fn selectBegin(f: *Frame, mp: Point) Frame.Error!SelectState  // :20-36 —
    // un-draw old selection, p0=p1=charOfPt(mp), drawSel(...,true) shows the tick
pub fn selectUpdate(s: *SelectState, mp: Point) Frame.Error!void  // one loop body
    // :58-96: q=charOfPt; no-op q==p1; anchor-cross reset :60-70; forward wing
    // extend/retract :72-77; backward mirror :78-83; commit + ordered f.p0/f.p1 :84-95
pub fn selectEnd(s: *SelectState, mp: Point) Frame.Error!void     // final update
```

A4 named tests: "frame: delete mid-line run" ("abcde" delete(1,3) => "ade" wid 27) ·
"frame: delete across a wrap" (33-rune fixture delete(7,13), hand-computed pins) ·
"frame: delete across a newline joins lines" (delete(17,19)) · "frame: delete to end
cleans last line" ("ab\ncd" delete(3,5)) · "frame: delete adjusts selection
endpoints" (the four :117-124 cases) · "frame: delete moves the tick" ·
"frame: inittick image ops" (write-stream: 2 allocs + 4 draws of frinit.c:52-58) ·
"frame: tick on/off restores pixels" · "frame: redraw preserves tick" ·
"frame: select begin places tick and clears old selection" · "frame: select sweep
forward then retract" (delta-only painting asserted by op-count) · "frame: select
crosses the anchor" · "frame: select across lines".

## B2 scope — src/core/text/*

Text.zig grows: `q0: usize = 0, q1: usize = 0` (FILE coords);
`pub fn insertAt(t: *Text, q0: usize, bytes: []const u8, tofile: bool) Error!void`
(textinsert text.c:366-413 single-Text subset: File.insert when tofile; adjust
q0/q1/org; fr.insert when visible — org-fixed so the q0<org arm is dead but ported);
`pub fn deleteRange(t: *Text, q0: usize, q1: usize, tofile: bool) Error!void`
(textdelete text.c:460-508: File.delete when tofile; adjust; fr.delete over the
visible clip :492-504; then fill() :505); Text.init becomes Error!Text and calls
fr.initTick() (F-5); method aliases typeRune/setSelect/selectBegin/selectMove/
selectEnd; private `sel: ?draw.Frame.SelectState = null` + `last_click_msec: u32 = 0,
last_click_q: usize = 0` (double-click SEAM only — expansion deferred, phase 7).

typing.zig NEW: `pub fn typeRune(t: *Text, ed: *Editor, r: u21) Text.Error!void`
(texttype text.c:668-942 subset; R-P6-8/T-1 undo grouping — one ed.seq++/file.mark
per typing run; ed.in_typing_run flag): Kleft (:684-689) end run + setSelect(q0-1
clamped); Kright (:690-693) mirror; DEFERRED cite-in-header: Kup/Kdown/pgup/pgdown/
home/end/^A/^E (:694-757 scroll), Kcmd snarf (:758-768,798-819), ^U/^W (:847-851),
^F/Kins (:828-833), Kesc (:834-845), autoindent (:885-899); else start-or-continue
run; if q1>q0: deleteRange(q0,q1,true) FIRST (cut=delete, F-6) and Kbs STILL erases
one more before the collapsed caret (text.c:820-852 quirk — port it); Kbs (:847-884
collapsed): q0==0 return; deleteRange(q0-1,q0,true); setSelect(q0-1,q0-1); printable/
'\n': utf8Encode; insertAt(q0, bytes, true); setSelect(q0+1,q0+1) (:937).

select.zig NEW: `pub fn setSelect(t: *Text, q0: usize, q1: usize) Text.Error!void`
(textsetselect text.c:1192-1259 IN FULL: clip to frame p0/p1 with ticked computation
:1199-1211; the p0==fr.p0&&p1==fr.p1 tick fast path :1212-1216; p0>p1 panic :1217-18
(I-5); no-overlap easy path :1220-26; the four incremental extend/trim arms
:1228-43; ends fr.p0=p0, fr.p1=p1); selectBegin/selectMove/selectEnd (B1 gesture:
charOfPt => frame selectBegin; moves; end => q0/q1 = org + fr.p0/p1, textselect
text.c:1044-1054 minus off-frame selectq — org fixed).

B2 named tests: "typing: runes insert at the tick" · "typing: newline is part of the
run" · "typing: arrow ends the run" ("ab" Kleft "c" => "acb", two transactions) ·
"typing: backspace" (still one transaction inside the run) · "typing: type over
selection deletes then inserts (and bs quirk)" ("hello" sel[1,4) 'X' => "hXo";
sel[1,4)+Kbs => "o") · "typing: mouse ends the run" · "select: setselect easy path
and tick" · "select: setselect incremental arms" (extend-back/trim-front/extend-fwd/
trim-tail :1228-43) · "select: click collapses to caret" · "select: sweep sets q0/q1
with org" (org=18).

## 6c scope — Editor.zig + main_wasm + abi/shim

Editor.zig grows: `pub const MouseEvent = struct { x: i32, y: i32, buttons: u8,
msec: u32 };` fields `text: ?*core.Text = null, mouse_state: enum { idle,
sweeping_b1 } = .idle, in_typing_run: bool = false, needs_flush: bool = false`;
`pub fn handleMouse(ed, ev) !void` / `pub fn handleKey(ed, r: u21) !void` /
`pub fn frameEnd(ed, display) !void` (flush at most once per tick when needs_flush).
State machine: idle+B1-down-in-fr.r => sweeping (end typing run; selectBegin);
sweeping+move(b&1) => selectMove; sweeping+buttons==0 => idle (selectEnd);
idle+key => typeRune; B1 outside r ignored; wheel/B2/B3 ignored with FLAG comments.
main_wasm: App gains DevInput + second Pipe+Server (devdraw pattern) + editor + Text
bound; boot scene: acme palette (R-P6-9/F-10) + EMPTY buffer; pushEvent export
(devinput side contract) then adapter calls completeReads(mousePath/kbdPath); wake =
drain hook; tick: checkRead standing tickets on mouse+kbd (R-P6-4: parse 49-byte
records => Editor.handleMouse; UTF-8 => handleKey; re-arm beginRead), then
Editor.frameEnd. abi.zig v3 + EventKind; shim.js listeners + KEYRUNE + ABI 3 (devinput
side contract §shim). Editor tests: "editor: b1 click-move-release drives one
selection" · "editor: kbd runes route to typing and mouse breaks the run" ·
"editor: frameEnd flushes once".

## Acceptance (Wave C, orchestrator) — the phase-6 scene

"phase-6: click, type, sweep — editing through the full stack": full assembly, EMPTY
buffer, acme palette, rect (20,20,119,470), Editor-seam driven (F-8, no devinput
needed): (1) type a b \n c d => buffer "ab\ncd", q0=q1=5, tick at (38,38); (2) B1
(33,25)->(33,43) sweep => q0=1 q1=4; FROZEN-ACCEPT-6a + spot checks ('b' cell HIGH
0xEEEE9E, L1 tail HIGH, 'c' cell HIGH, 'd' cell BACK 0xFFFFEA, no tick); (3) 'X' =>
"aXd"; (4) Kbs => "ad"; (5) B1 click (50,25) => caret at end; FROZEN-ACCEPT-6b +
tick-pixel pins (vertical line (38,28) black; top box (37,21); bottom box (39,36);
(37,28) BACK; (41,28) BACK); (6) undo x2 => "ab\ncd" => ""; redo x2 round-trips.
