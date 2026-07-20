# Phase 7b side contract (O15) — snarf + chords + double-click

ONE opus agent (R-P7-8), builds AFTER 7a merges. Files: src/core/Editor.zig,
src/core/text/{typing,select,Text}.zig. C: acme text.c/exec.c/util.c. Cite per fn.

## Editor.zig — snarf + ops

Field `snarf: std.ArrayList(u8) = .empty` (freed in deinit). 
`pub fn cut(ed, t: *Text, dosnarf: bool, docut: bool) !void` (exec.c:948-1016 minus
command plumbing): q0==q1 => return with snarf UNTOUCHED (:984-988); dosnarf =>
clearRetainingCapacity + append decoded [q0,q1) via chunked Buffer.read (:989-1002);
docut => t.deleteRange(q0,q1,true) + t.setSelect(q0,q0) (:1005-1007). CALLER does
seq++/mark first (as in the C).
`pub fn snarfInsert(ed, t: *Text, selectall: bool) !void` (exec.c:1019-1073 minus
tobody/clipboard): empty snarf => no-op (:1038-1039); self-cut cut(t, false, true)
(:1046); insertAt(t.q0, snarf.items, true) (:1047-1062); selectall ? setSelect(q0,
q0+n) : caret after (:1063-1066). Chord passes selectall=true (text.c:1087).
Clipboard/dev-snarf deferred (R-P7-5 comment).

## Editor.zig — chord state machine (text.c:1001-1099)

mouse_state grows {double_clicked, chording}; new fields chord_state {none,cut,paste},
sweep_q0: usize, chord_buttons: u8, press_pt.
Transitions (each cites its C line — see O15 §2.2 in this file's history; the
essentials): sweeping_b1 + (b&1 and b&6) => selectEnd (frselect exits on set change,
frselect.c:102), sweep_q0 = t.q0, chord_state=.none, chord_buttons=0, .chording, then
process this event's chord. chording: act ONLY when ev.buttons != chord_buttons
(edge trigger, R-P7-6), then update chord_buttons: if (b&1 and b&6): chord_state==
.none => ed.seq+=1, t.file.mark(ed.seq) (:1068-1071); b&2 (:1072-1080): .paste =>
File.undo() + setSelect(sweep_q0, undo Range.q1) + .none; else if !=.cut =>
ed.cut(t,true,true), .cut; else b&4 (:1081-1090): .cut => undo+reselect+.none; else
if !=.paste => ed.snarfInsert(t,true), .paste; clear last_click (:1065,:1097).
buttons==0 => .idle (NOT before — :1064). needs_flush after ops.
double_clicked state: B2/B3 join => sweep_q0=t.q0, .chording; B1-only moved >=3px
from press_pt => selectBegin(press_pt), .sweeping_b1 (anchor divergence commented,
:1026-1030); buttons==0 => .idle (last_click stays cleared — no triple-click, :1054).
sweeping_b1 release with q0==q1 => record last_click{q,msec} (:1056-1057); nonempty
sweep clears it (:1059-1060).

## typing.zig — one semantic change (R-P7-4)

Type-over-selection block becomes `if (t.q1 > t.q0) try ed.cut(t, true, true);`
(text.c:823 — dosnarf=TRUE). Update the F-6 notes. Kbs-over-selection consequently
snarfs too (extend the existing quirk test).

## select.zig + Text.zig — double-click

Text: replace last_click_msec/last_click_q with `last_click: ?struct { q: usize,
msec: u32 } = null` (nothing else reads the old fields — verified).
select.zig comptime tables (text.c:1386-1404): left1 {'{','[','(','<',0xAB}, right1
{'}',']',')','>',0xBB}, left2 {'\n'}, left3 {'\'','"','`'}; left_tab {left1,left2,
left3}, right_tab {right1,left2,left3}.
`pub fn doubleClick(t, q0: *usize, q1: *usize) void` (textdoubleclick :1407-1454
MINUS textclickhtmlmatch — p9p-only, flagged): char left of q (q==0 reads '\n',
:1421-1422) in left set => clickMatch(+1); match => q1 = q-(c!='\n') (:1427-1428 —
bracket INTERIOR; '\n' keeps trailing newline = line select at BOL); char AT q
(q==nc reads '\n') in right set => backward mirror (:1432-1443); fallback isAlnum
word fill both ways (:1448-1453).
`fn clickMatch(t, cl, cr, dir: i8, q: *usize) bool` (:1457-1482; boundary returns
cl=='\n' and nest==1).
`fn isAlnum(c: u21) bool` (util.c:328-342: false for <=' ', 0x7F..0xA0, ASCII punct;
true otherwise incl. ALL runes >= 0xA1).
Trigger (press-time, in the idle B1-down path BEFORE selectBegin): q = org +
charOfPt(pt); if last_click != null and q == last_click.q and msec -% last_click.msec
< 500 and t.q0 == t.q1 == q => doubleClick + setSelect + last_click=null +
.double_clicked; else normal sweep. (The C's release-time second site subsumed —
divergence comment.)

## Named tests (13 from the O15 report — implement exactly)

"editor: chord cut mid-sweep snarfs and ends the sweep" · "editor: chord paste
inserts snarf selected" · "editor: chord toggle undoes within the gesture" (verify
the reselect end == File.undo Range.q1 vs the C) · "editor: repeated chord press
while held is a no-op" · "editor: null-selection chord cut preserves snarf" ·
"editor: chord gesture ends only when all buttons release" · "editor: undo grouping
around chords" · "select: double-click selects a word" (incl. non-ASCII word char) ·
"select: double-click on bracket pairs selects the nested interior" (incl. quotes) ·
"select: double-click at line boundaries selects the line" · "editor: double-click
trigger gates on 500ms and same q" · "editor: double-click then chord cuts the word"
· "typing: type-over-selection snarfs the replaced text" (+ Kbs variant).
