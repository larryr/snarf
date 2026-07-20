# Phase 9 exec side contract (O18) — B2 execute + builtin Exectab + window/tag lifecycle

C ground truth: larryr/plan9port@337c6ac `src/cmd/acme/`. B3/look is O19's; external/origin
commands (exec.c `run`, the `winevent` external branch exec.c:190-233) are the NAMESPACE
phase — FLAG-dropped here. All paths below verified against the local clone `~/proj/plan9port`.

## 1. C ground truth (cite per fn/line — verified)

**The B2 sweep loop** — `text.c`:
- `xselect` text.c:1260-1341 (DELAY=2/MINMOVE=4 enum :1255-1258): the colored transient
  sweep. It draws in `col` (but2col) and **restores** the prior selection at exit
  (:1331-1338) — a B2 sweep NEVER touches `t->q0/q1`; the swept `p0,p1` are locals
  returned to the caller. Loop `do{ q=frcharofpt(...); ... }while(mc->m.buttons==b)`
  (:1279-1316) — the change-sample's position IS included in the sweep before exit.
  Null-collapse: released in <DELAY ms with <MINMOVE px motion ⇒ `p1=p0` (:1317-1325);
  sorted at :1326-1330.
- `textselect23` text.c:1343-1359: `p0 = xselect(...); buts = mousectl->m.buttons;` —
  buts is frozen at the FIRST button-set change. `if((buts & mask)==0) {*q0=p0+org;
  *q1=p1+org;}` (:1351-1354) — for B2, mask=4: the range is committed unless **B3**
  joined. Then drains until ALL buttons release (:1356-1357).
- `textselect2` text.c:1361-1375: `buts = textselect23(t,q0,q1,but2col,4)`; `buts&4 ⇒
  return 0` (B3 cancels, :1368-1369); `buts&1 ⇒ *tp = argtext; return 1` (:1370-1373) —
  **the 2-1 chord: B1 joining while B2 is held = "execute with argument", argument text
  = the global `argtext` = the last B1-selected Text** (set at acme.c:656 on every B1
  press, and by Snarf at exec.c:1013). Plain release ⇒ return 1, tp=nil.
- Click vs sweep: acme distinguishes them **at execute time, not gesture time** — a
  click yields q0==q1 and `execute` word-expands (below); a sweep yields q0<q1 and the
  swept text is executed verbatim.

**How B2 reaches execute** — acme.c:662-665 (mousethread): `else if(m.buttons & 2){
if(textselect2(t,&q0,&q1,&argt)) execute(t, q0, q1, FALSE, argt); }`. B1 branch context:
acme.c:655-661 — after `textselect`: `winsettag(w)`, `argtext = t; seltext = t`
(:656-657). `seltext` is also set at look.c:96/375/427/895; both are nil'ed when a text
closes (text.c:109/113 in textreset/textclose).

**execute** — exec.c:157-259:
- q0==q1 expansion (:164-176): if the click is inside the Text's own selection
  (`t->q1>t->q0 && t->q0<=q0<=t->q1`) use the selection; else expand both ways over
  `isexecc` runes **stopping at ':'** (`isexecc` exec.c:149-155 = `isfilec`
  (look.c:442-450: alnum + `.-+/:@`) plus `<|>`); empty ⇒ return.
- `lookup` exec.c:132-148: skip leading blanks, take the first blank-delimited word,
  linear scan of `exectab`.
- Mark (:236-240): `if(e->mark && seltext!=nil && seltext->what==Body){ seq++;
  filemark(seltext->w->body.file); }` — the mark applies to **seltext's** body file
  (the command's default target), not et's.
- Argument passing (:241-244): `s` = the remainder of the executed text after the
  command word, passed as `(Rune*, int)` — **so a swept "New foo bar" DOES carry inline
  args**; a click can't (the expansion is one word). Plus `argt` (the 2-1 chord text)
  read via `getarg` exec.c:276-312 (uses look.c `expand` for filenames, else the raw
  argt selection) / `getbytearg` :314-328.
- Call convention (:244): `(*e->fn)(t, seltext, argt, e->flag1, e->flag2, s, n)` —
  **et = the Text where B2 happened; t = seltext; argt = argtext**. This IS the
  tag→body routing: commands reach the body via `et->w->body`.

**Exectab** — struct exec.c:59-67 `{ Rune *name; fn; int mark, flag1, flag2 }`; `XXX`
is **enum value 2** (dat.h:488-493 `enum{FALSE,TRUE,XXX}`) — i.e. XXX is TRUTHY where
it reaches a flag test (load-bearing for Paste, below). Full table exec.c:98-130:

| entry (line) | fn | mark | flag1 | flag2 |
|---|---|---|---|---|
| Abort :100 | doabort | F | XXX | XXX |
| **Cut :101** | cut | **T** | T (dosnarf) | T (docut) |
| **Del :102** | del | F | F (flag1) | XXX |
| **Delcol :103** | delcol | F | XXX | XXX |
| **Delete :104** | del | F | T | XXX |
| Dump :105 | dump | F | T | XXX |
| Edit :106 | edit | F | XXX | XXX |
| Exit :107 | xexit | F | XXX | XXX |
| Font :108 | fontx | F | XXX | XXX |
| Get :109 | get | F | T | XXX |
| ID :110 / Incl :111 / Indent :112 / Kill :113 / Load :114 / Local :115 / Look :116 | … | F | … | … |
| **New :117** | new (look.c:901-942) | F | XXX | XXX |
| **Newcol :118** | newcol | F | XXX | XXX |
| **Paste :119** | paste | **T** | T (selectall) | **XXX (=2, truthy ⇒ tobody!)** |
| Put :120 / Putall :121 | | F | | |
| **Redo :122** | undo | F | **F** (isundo=FALSE) | XXX |
| Send :123 | sendx | T | XXX | XXX |
| **Snarf :124** | cut | **F** | T (dosnarf) | **F** (docut=FALSE) |
| Sort :125 | sort | F | XXX | XXX |
| Tab :126 | tab | F | XXX | XXX |
| **Undo :127** | undo | F | **T** (isundo) | XXX |
| Zerox :128 | zeroxx | F | XXX | XXX |

Note the mark column: only Cut/Paste/Send mark. **Snarf does NOT mark** (no edit);
Undo/Redo manage seq themselves; Del/New/etc. never mark.

**Command implementations**:
- `cut` exec.c:947-1016 — the et/t redirection (:957-974): if `et!=t && dosnarf &&
  et->w!=nil` prefer the **body** selection (and if docut, `filemark(t->file)` again —
  execute marked *seltext's* file, :966-967), else the **tag** selection, else nothing.
  Then: dosnarf ⇒ chunked copy into snarfbuf (:989-1003, `acmeputsnarf` deferred);
  docut ⇒ textdelete+setselect+scrdraw+`winsettag(t->w)` (:1005-1011); **Snarf-only
  sets `argtext = t`** (:1012-1013). Our `ed.cut` (Editor.zig:138-160) is the
  single-Text core of this — the flags map 1:1 (`dosnarf`,`docut`); phase 9 adds the
  redirection wrapper, NOT changes to `ed.cut`.
- `paste` exec.c:1018-1073 — `if(tobody && et->w) { t = &et->w->body;
  filemark(t->file); }` (:1029-1032; tobody = flag2 = XXX = 2 = truthy — **B2 Paste in
  a tag pastes into the body**); then cut-selection + insert +
  `selectall?setselect(q0,q1):setselect(q1,q1)` — our `ed.snarfInsert`
  (Editor.zig:166-179) is the core; wrapper adds tobody.
- `undo` exec.c:436-478 + `seqof` :427-434: guard `et->w`; `seq = seqof(w, flag1)`
  (undo ⇒ `w->body.file->seq`, redo ⇒ `fileredoseq`); 0 ⇒ return; `winundo(et->w,
  flag1)` first, then walk **all** windows undoing any with the same seq (multi-file
  transactions — Edit's territory). `winundo` wind.c:351-372: `fileundo(...,&q0,&q1)`
  then `textshow(body,q0,q1,1)`, `v->dirty = (f->seq != v->putseq)` per text,
  `winsettag(w)`.
- `del` exec.c:397-410: `if(flag1 || et->w->body.file->ntext>1 || winclean(et->w,
  FALSE)) colclose(et->col, et->w, TRUE);` — **flag1 (Delete) skips the clean check**;
  Del = flag1 FALSE.
- `winclean` wind.c:666-685 — THE TWO-STRIKE: isscratch/isdir pass; `if(w->dirty){
  warning("%.*S modified") (or pass silently if unnamed && <100 chars, else "unnamed
  file modified"); w->dirty = FALSE; return FALSE; }` — the warning fires ONCE, `dirty`
  is cleared (while `file->mod` stays true, so the mod dot remains), and the second Del
  passes. Any subsequent body edit re-arms `dirty` (set at text.c:378 textinsert /
  :474 textdelete, Body+tofile only).
- `winclose` wind.c:316-333: decref ⇒ textclose both texts (which nil argtext/seltext,
  text.c:109/113), free.
- `colclose` cols.c:161-209 — neighbor-grows-back geometry: find w; `if(!c->safe)
  colgrow(...)` (:167-168 — our port's `safe` is always true, arm dropped); capture
  `r=w->r`; nil backpointers; dofree ⇒ windelete+winclose; splice out; **nw==0 ⇒ white
  fill and return** (:184-187); else `i==nw` ⇒ LAST window extends DOWN
  (`r.min.y=w[i-1].r.min.y; r.max.y=c->r.max.y`), otherwise the NEXT window extends UP
  (`r.max.y = w[i].r.max.y`) (:189-198); fill BACK, `winresize(w, r, FALSE, TRUE)`
  (:199-207; showdel/movetodel mouse arms dropped per R-P8-7).
- `newcol` exec.c:349-365: `c = rowadd(et->row, nil, -1); if(c){ w =
  coladd(c,nil,nil,-1); winsettag(w); }` — **Newcol also creates one empty window**.
- `delcol` exec.c:370-392: `c = et->col; if(c==nil || colclean(c)==0) return;` (nopen
  external check n/a) then `rowclose(et->col->row, et->col, TRUE)`. `colclean`
  cols.c:582-590 uses `clean &= winclean(w, TRUE)` — **no short-circuit: every dirty
  window gets warned+struck in one pass**, so a second Delcol succeeds (two-strike at
  column granularity).
- `rowclose` rows.c:208-239: mirror of colclose in x — dofree ⇒ `colcloseall`
  (cols.c:211-227); ncol==0 ⇒ white; else last column extends RIGHT / next extends
  LEFT; white fill + colresize.
- `new` look.c:901-942: `getarg(argt, FALSE, TRUE, &a, &na)` — a chord argument
  recurses `new` with it (:911-915); then loops blank-separated names in `arg`, each
  via `dirname`+`expand`+`openfile` (:918-941 — DISK LOADING, namespace phase); **no
  args at all ⇒ `coladd(et->col, nil, nil, -1)` + winsettag** (:921-926), and
  `et->col==nil` (rowtag) ⇒ nothing.
- Evaluated extras: `sort` exec.c:412-425 → `colsort` cols.c:294-330 (qsort by tag
  name + relayout via winresize); `zeroxx` exec.c:541-576 (`coladd(col, nil, t->w,
  -1)` — the CLONE arm of coladd + shared-File ntext machinery); `xexit`
  exec.c:1148-1163 (`rowclean` + threadexits).

**Tag lifecycle** — wind.c:
- `parsetag` wind.c:437-467: the left half ends at `" |"` or `"\t|"`; the NAME ends at
  `" Del Snarf"` if it appears before the pipe, else at the first space/tab. Returns
  the whole tag + name length.
- `winsettag1` wind.c:469-575 — READ CAREFULLY, ported verbatim: (a) sync tag cache —
  n/a, no cache; (b) if the tag's name half ≠ `body.file->name`, splice the real name
  in (:488-495); (c) compose `new` = name + `" Del Snarf"` + (if `w->filemenu`:
  `" Undo"` iff `needundo || delta.nc>0 || ncache` (:506) · `" Redo"` iff
  `epsilon.nc>0` (:510) · `" Put"` iff named && dirty(seq!=putseq||ncache) (:515-519))
  + (`" Get"` iff isdir) + `" |"` (:524-525); (d) **user-suffix preservation**: `k` =
  index just past the OLD tag's `'|'` — everything after it is kept untouched; if the
  old tag had NO pipe, k=end and `" Look "` is appended iff `body.file->seq==0` (fresh
  window) (:527-536); (e) replace only `[j,k)` where j = first differing rune
  (:540-553); (f) preserve the user's tag selection by shifting q0/q1 by the bar
  displacement when `q0 > bar` (:554-562); (g) clamp q0/q1, `textsetselect`,
  `windrawbutton`, and winresize iff resized (:565-574 — taglines is fixed 1 in our
  port; the resize arm is dead, drawButton is not).
- `winsettag` wind.c:577-593: the file->ntext fan-out — collapses to setTag1 (1 Text
  per File in v1).
- Call-site pattern (verified, 29 sites): texttype first-edit (text.c:921-923 via the
  `needundo` pre-set — exists ONLY because the C's tag rewrite must happen before
  ncache hides the edit; our port has no cache ⇒ no needundo), mousethread B1
  (acme.c:655), winundo (wind.c:370), cut/paste/get/put (exec.c ×5), look.c openfile
  ×6, xfid ×5, util warning flush. The pattern = "after anything that can change
  name/mod/undo/redo state".

## 2. Merged reality (what exists / what's missing)

- `Editor.zig` — gesture machine states `{idle, sweeping_b1, double_clicked,
  chording}` (:98); **B2-only press explicitly FLAG-ignored at :274** — our insertion
  point. `chordStep` (:385-424) is B1-anchored (the 1-2/1-3 cut/paste chords) — B2's
  machine is SEPARATE per textselect23, do not touch chordStep. `ed.cut`/
  `ed.snarfInsert` (:138-179) = the C cut/paste cores, caller-marks convention already
  matches execute's. `focus` (:73) is the key-fallback only — acme's argtext/seltext
  are distinct and **must be added** (they diverge from focus: Snarf reassigns
  argtext, exec.c:1013). `frameEnd` (:446) = the tag-sweep site.
- `Window.zig` — header says it: "`winsettag`/`winclean`/`parsetag` are phase 9". Has
  drawButton (mod dot), resize, deinit. **No `dirty` field, no name source** — and
  `File.zig` has **no `name` field** (setTag1 needs one).
- `Column.zig` — `add` (coladd) exists :109-180; header defers colclose/colsort.
  `safe` always true.
- `Row.zig` — `add` (rowadd) exists :96-145 (returns `?*Column`, <100px refusal);
  header defers rowclose.
- Tags are **literal strings** today: boot.zig:38 `tag_suffix = " Del Snarf | Look "`,
  written once at addWinTo (:88-93). Column/Row headers seeded by init (Column.zig:36,
  Row.zig:32 — include "New…Delcol", "Newcol…Exit": B2 on those is what we're wiring).
- Ownership seams: body Files live in `boot.Tree.bodies` (:57); `winid` lives on Tree
  (:59) — both unreachable from the Editor (which sees only `row`). Both must MOVE.
- `Buffer.runeAt` exists (expansion reads); `Frame.charOfPt` exists (sweep tracking);
  `Text.show` exists (winundo's textshow); `File.undoSeq/redoSeq` exist (tag presence
  + seqof).

## 3. CONTRACT

> Master-contract amendments: R-P9-1 overrules §3a's "no but2col highlight" flag —
> the B2 gesture rides the shared `Select23State` (look side §3.2) with `but2col`;
> the `b2_q0/b2_q1` ad-hoc tracking below is REPLACED by `sel23` + a frozen-buts
> field. §3a's field placement is superseded by R-P9-3 (seltext/argtext/warnings land
> in 9a-A2). The exit protocol is R-P9-2. Everything else in this section stands.

### 3a. Editor B2 gesture (Editor.zig)

```zig
// new fields (placement per R-P9-3; sweep state per R-P9-1/2)
seltext: ?*Text = null,   // acme.c:657; look.c:96 — the last B1-selected Text (execute's default target)
argtext: ?*Text = null,   // acme.c:656; exec.c:1013 — the 2-1 chord's argument source
warnings: std.ArrayList(u8) = .empty,  // v1 warning sink (§3e)
sel23: ?draw.Frame.Select23State = null, // live colored sweep (R-P9-1)
sel23_buts: u8 = 0,       // frozen button set at the first change (textselect23:1350); 0 = still pure
mouse_state: enum { idle, sweeping_b1, double_clicked, chording, sweeping_b2, sweeping_b3, draining },
```

handleMouse step 6 grows: `if (b == B1) {… as today, PLUS ed.argtext = t; ed.seltext =
t; }` (acme.c:656-657) and `else if (b == B2) { ed.gesture_text = t; runGesture }`.
(B3 is O19's twin arm.)

runGesture `.idle` gains: `b == B2` and `ptInRect(t.fr.r, …)` ⇒ `sel23 =
select23Begin(&t.fr, pt, but2col orelse fallback, ev.msec)`, `sel23_buts = 0`, state =
`.sweeping_b2`, break the typing run. (A B2 press in a TAG is equally valid —
tags/columntags/rowtags all execute.)

runGesture `.sweeping_b2` (R-P9-2 protocol):
- `b == B2`: `select23Update(&sel23, pt)` — live colored sweep.
- `b != B2`, `b != 0`: fold this sample in, `select23End`, freeze `sel23_buts = b`,
  state = `.draining` (further changes ignored — the C's `while(buttons) readmouse`).
- `b == 0` (direct release or leaving `.draining`): dispatch. `buts & B3 ⇒` cancel to
  idle (nothing runs); else `argt = if (buts & B1 != 0) ed.argtext else null`; q0/q1 =
  `t.org +` the ended range; `try exec.execute(ed, t, q0, q1, argt)`; state = idle.
- After execute returns, do NOT touch `t` again — Del may have destroyed it (§3d
  clears the Editor's pointers; handleMouse's `if (b==0) gesture_text = null` then
  no-ops).

### 3b. exec module (new files per S-07 §4: `src/core/exec/`)

**`exec/exec.zig`** (namespace module):
```zig
pub fn execute(ed: *Editor, t: *Text, aq0: usize, aq1: usize, argt: ?*Text) Text.Error!void
// exec.c:157-259, builtin arm only. q0==q1 ⇒ (a) inside t's selection ⇒ use it (:166-170);
// (b) else expand over isexecc stopping at ':' via t.file.buffer.runeAt (:171-176); empty ⇒ return.
// Read [q0,q1) bytes; lookup; not found ⇒ NO-OP (run()/winevent external branch FLAG-dropped, namespace phase).
// Found: if (e.mark and ed.seltext != null and ed.seltext.?.what == .body)
//        { ed.seq += 1; ed.seltext.?.w.?.body.file.mark(ed.seq); }   // exec.c:236-240
// arg = the remainder after the first word (skipbl/findbl/skipbl :241-243), UTF-8 slice;
// try e.fn(ed, t, ed.seltext, argt, e.flag1, e.flag2, arg);          // et=t, t=seltext (:244)
pub fn isexecc(r: u21) bool   // exec.c:149-155
pub fn isfilec(r: u21) bool   // look.c:442-450 — pub: O19's expand() imports it
fn lookup(word: []const u8) ?*const builtins.Entry   // exec.c:132-148
fn getArg(ed: *Editor, argt: ?*Text, a: Allocator) !?[]u8
// getarg exec.c:276-312 v1: the RAW argt selection [q0,q1) bytes (the expand() filename arm is O19's
// upgrade seam); null when argt==null or empty selection. doaddr/printarg dropped.
```

**`exec/builtins.zig`** (P-7 comptime table):
```zig
pub const Entry = struct {
    name: []const u8,
    fn_: *const fn (ed: *Editor, et: *Text, t: ?*Text, argt: ?*Text,
                    flag1: bool, flag2: bool, arg: []const u8) Text.Error!void,
    mark: bool,
    flag1: bool,
    flag2: bool,
};
pub const exectab = [_]Entry{ // exec.c:98-130 order (alphabetical), v1 subset
    .{ .name = "Cut",    .fn_ = cmd_edit.cut,     .mark = true,  .flag1 = true,  .flag2 = true  }, // :101
    .{ .name = "Del",    .fn_ = cmd_window.del,   .mark = false, .flag1 = false, .flag2 = false }, // :102 (flag2 XXX unused)
    .{ .name = "Delcol", .fn_ = cmd_window.delcol,.mark = false, .flag1 = false, .flag2 = false }, // :103
    .{ .name = "Delete", .fn_ = cmd_window.del,   .mark = false, .flag1 = true,  .flag2 = false }, // :104 (free twin)
    .{ .name = "New",    .fn_ = cmd_window.new,   .mark = false, .flag1 = false, .flag2 = false }, // :117
    .{ .name = "Newcol", .fn_ = cmd_window.newcol,.mark = false, .flag1 = false, .flag2 = false }, // :118
    .{ .name = "Paste",  .fn_ = cmd_edit.paste,   .mark = true,  .flag1 = true,  .flag2 = true  }, // :119 — flag2 is
        // the C's XXX==2 which is TRUTHY (dat.h:488-493): tobody=TRUE is LOAD-BEARING (tag Paste → body).
    .{ .name = "Redo",   .fn_ = cmd_edit.undo,    .mark = false, .flag1 = false, .flag2 = false }, // :122
    .{ .name = "Snarf",  .fn_ = cmd_edit.cut,     .mark = false, .flag1 = true,  .flag2 = false }, // :124
    .{ .name = "Undo",   .fn_ = cmd_edit.undo,    .mark = false, .flag1 = true,  .flag2 = false }, // :127
};
```
Convention: genuinely-unused XXX ⇒ `false` with a `// XXX` comment; the ONE
truthy-XXX-that-matters (Paste.flag2) is `true` with the dat.h cite.

**`exec/cmd_edit.zig`** — Cut/Snarf/Paste/Undo/Redo:
```zig
pub fn cut(ed, et, t0, argt, dosnarf, docut, arg) !void
// exec.c:947-1016 wrapper: var t = t0; if (t != et and dosnarf and et.w != null) {
//   if body sel ⇒ t = &et.w.?.body, and if docut ⇒ t.file.mark(ed.seq)  // :963-967 (execute already seq++'d)
//   else if tag sel ⇒ t = &et.w.?.tag; else t = null; }
// t == null or t.q0==t.q1 ⇒ return; try ed.cut(t, dosnarf, docut);      // the phase-7 core, flags map 1:1
// if (dosnarf and !docut) ed.argtext = t;                               // :1012-1013 Snarf
pub fn paste(ed, et, t0, argt, selectall, tobody, arg) !void
// exec.c:1018-1073: var t = t0; if (tobody and et.w != null) { t = &et.w.?.body; t.file.mark(ed.seq); }
// t == null ⇒ return; try ed.snarfInsert(t, selectall);
pub fn undo(ed, et, t, argt, isundo, _f2, arg) !void
// exec.c:436-478 v1 single-window subset: et.w == null ⇒ return; f = et.w.?.body.file;
// (seqof :427-434 guard ⇒ File.undoSeq()/redoSeq() == 0 ⇒ return — matches "nothing to undo")
// const r = (if (isundo) try f.undo() else try f.redo()) orelse return;
// try et.w.?.body.show(r.q0, r.q1, true);          // winundo wind.c:361 textshow — REQUIRED, File.undo
//                                                  // bypasses the frame; show refills+selects
// try et.w.?.body.scrDraw(); et.w.?.dirty = f.mod; // wind.c:365 v1 approx (putseq deferred with Put)
// FLAG: the same-seq multi-window walk (exec.c:462-477) deferred to the Edit phase (needs shared-File views).
```

**`exec/cmd_window.zig`** — Del/Delete/New/Newcol/Delcol + tree helpers:
```zig
fn colOf(et: *Text) ?*Column  // C's t->col: et.w ⇒ et.w.?.col; et.what==.columntag ⇒ @fieldParentPtr("tag", et); else null
fn rowOf(et: *Text) ?*Row     // C's t->row: colOf(et).?.row; et.what==.rowtag ⇒ @fieldParentPtr("tag", et)
pub fn del(ed, et, t, argt, flag1, _f2, arg) !void
// exec.c:397-410: w = et.w orelse return; c = w.col orelse return;
// if (flag1 or w.clean(ed, false)) try c.close(ed, w, true);   // ntext>1 arm n/a v1
pub fn new(ed, et, t, argt, _f1, _f2, arg) !void
// look.c:901-942 v1: c = colOf(et) orelse return;
// if (try exec.getArg(ed, argt, a)) |name| ⇒ create one EMPTY window named `name` (chord argument);
// else for each blank-separated word in arg ⇒ empty window named by it (openfile/dirname/disk-load
// FLAG-deferred to the namespace phase — an argful New makes a NAMED EMPTY window, honest v1);
// no args at all ⇒ one unnamed empty window (look.c:921-926). Creation helper: heap File("" body,
// owned by the Window §3d), c.add(&rowOf-or-c.row.winid, f, -1), w.body.file.name=…, w.setTag1().
pub fn newcol(ed, et, t, argt, _f1, _f2, arg) !void
// exec.c:349-365: r = rowOf(et) orelse return; c = (try r.add(-1)) orelse return;
// then one unnamed empty window via the same helper (coladd(c,nil,nil,-1) + winsettag).
pub fn delcol(ed, et, t, argt, _f1, _f2, arg) !void
// exec.c:370-392: c = colOf(et) orelse return; if (!c.clean(ed)) return; try rowOf(et).?.close(c, true);
```

### 3c. Window/tag lifecycle ports

`File.zig` gains (required by setTag1 — the C reads `body.file->name`):
```zig
name: std.ArrayList(u8) = .empty,               // file.c name/nname
pub fn setName(f: *File, name: []const u8) !void // filesetname minus the undo record (v1)
```

`Window.zig` gains:
```zig
dirty: bool = false,                    // dat.h:187 w->dirty
pub fn parseTag(w: *Window, a: Allocator) error{OutOfMemory}!struct { text: []u8, name_len: usize }
// wind.c:437-467: whole tag UTF-8 + name end = index of " Del Snarf" before the first " |"/"\t|", else first space/tab
pub fn setTag1(w: *Window) Text.Error!void
// wind.c:469-575 as §1: name splice / " Del Snarf" / Undo iff file.undoSeq()!=0 / Redo iff file.redoSeq()!=0
// (needundo n/a — no tag cache; Put/Get arms FLAG-deferred with Put/isdir) / " |" / preserve all after the
// old '|' / no-pipe+seq==0 ⇒ append " Look " / minimal splice from first differing rune / selection bar-shift
// (:554-562) / clamp+setSelect / drawButton (:571). taglines==1 ⇒ the winresize arm is dead.
pub fn setTag(w: *Window) Text.Error!void   // wind.c:577-593 ⇒ setTag1 (single view v1)
pub fn clean(w: *Window, ed: *Editor, conservative: bool) bool
// wind.c:666-685 two-strike: isscratch/isdir/nopen arms n/a; if (w.dirty) { warn "<name> modified"
// (unnamed && buffer.len()<100 ⇒ silently TRUE, else "unnamed file modified"); w.dirty = false; return false; }
```
`Text.insertAt`/`deleteRange` (Text.zig:250/272) gain the C's dirty hook: `if (tofile
and self.what == .body) if (self.w) |w| { w.dirty = true; }` (text.c:378/474).

`Column.zig` gains:
```zig
pub fn close(c: *Column, ed: *Editor, w: *Window, dofree: bool) Error!void
// cols.c:161-209: find index (assert found); r = w.r; (colgrow/!safe arm :167-168 dropped — safe is
// always true in the port, doc note); if dofree ⇒ ed.dropTextRefs(w) (§3d), w.deinit + destroy (+ owned
// body File); ordered remove; len==0 ⇒ white fill + return; else i==len ⇒ prev window extends DOWN
// (r.min.y=prev.r.min.y, r.max.y=c.r.max.y) else next extends UP (r.max.y=next.r.max.y) (:189-198);
// fill BACK; _ = try neighbor.resize(r, false, true) (:199-207; mouse arms R-P8-7-dropped).
pub fn clean(c: *Column, ed: *Editor) bool
// cols.c:582-590 — `clean &= w.clean(ed, true)` over ALL windows, NO short-circuit (every dirty window
// warns + takes its strike in one pass).
```

`Row.zig` gains:
```zig
winid: u32 = 0,   // dat.c global winid MOVES here (P-3; reachable from Editor via ed.row) — boot.Tree.winid removed
pub fn close(row: *Row, c: *Column, dofree: bool) Error!void
// rows.c:208-239: find; r = c.r; dofree ⇒ colcloseall = c.deinit + destroy (cols.c:211-227); remove;
// ncol==0 ⇒ white fill; else last extends RIGHT / next extends LEFT; white fill + neighbor.resize(r).
```

### 3d. Ownership + dangling-pointer hygiene

- **Body Files move from `boot.Tree.bodies` to the Window**: `Window` gains
  `body_file: *File` + `owns_body: bool = false` (or keeps the borrowed `*File` param
  and just the flag); `Window.deinit` frees when owned. `boot.Tree.bodies` is DELETED;
  `addWinTo` marks ownership. Rationale: Del must be able to destroy a window+file
  mid-session without a registry the Editor can't reach. (The C's refcounted
  File/ntext is the eventual model; 1:1 v1.)
- `Editor.dropTextRefs(w: *Window)`: nil any of `focus/gesture_text/seltext/argtext`
  pointing at `&w.tag`/`&w.body` (textclose's `argtext=nil/seltext=nil`,
  text.c:109/113). Called from `Column.close` before deinit — this is why close takes
  `ed`.
- `boot.addWinTo` switches from the tag literal to `f.setName(name)` + `w.setTag1()` —
  composition is byte-identical to today's `"one Del Snarf | Look "` (verified against
  wind.c:497-536: fresh tag, no pipe, seq==0 ⇒ `name + " Del Snarf" + " |" +
  " Look "`); the `tag_suffix` literal stays only as a test constant.

### 3e. Warnings (FLAG + recommendation)

acme `warning()` (util.c:259+) appends to the `+Errors` window via flushwarnings
(util.c:229-257) — that whole path needs openfile/errorwin (namespace phase). **v1
(recommended, simplest honest): a warnings buffer on the Editor** — `ed.warning(comptime
fmt, args)` appends a formatted line to `ed.warnings` (OOM ⇒ silently drop; a warning
must never fail a command). Tests assert on its contents; the two-strike Del works
regardless (the strike is `w.dirty=false`, not the message). Tag-flash rejected
(invents UI acme doesn't have). `main_wasm` MAY mirror it to console.log via the
existing debug hook — optional, not contract. FLAG: rewire to +Errors in the
served-tree phase.

### 3f. Live tags — the winsettag call site (recommendation)

The C's 29 scattered call sites collapse to **one: a `frameEnd` sweep** (cheapest
faithful site). `Window` gains a cached `tag_state: struct { undo: bool, redo: bool,
mod: bool } = .{}`; `Editor.frameEnd` (before flush) walks `ed.row` (cols × windows),
computes `{file.undoSeq()!=0, file.redoSeq()!=0, file.mod}`, and calls `w.setTag1()` +
updates the cache on change. This covers every C site in-frame: typing (text.c:922 —
the needundo dance is unnecessary, we have no tag cache and sweep AFTER the insert),
commands (exec.c ×5), undo (wind.c:370), B1 selection (acme.c:655). setTag1's own
minimal-splice guard makes redundant calls cheap; the cache avoids per-frame tag
reads/allocs. Name changes only happen at creation in v1 (wincommit tag-rename
deferred), so the tuple needn't carry the name.

### 3g. Argument policy (recommendation) + Sort/Zerox/Exit evaluation

- **2-1 chord: recognized, and passed** — plumbing it costs one field (`argtext`) we
  need anyway. **v1 args consumed by New only** (verified: Cut/Paste/Snarf/Undo/Del/
  Delcol/Newcol all `USED()`-discard arg/argt in the C). Inline sweep-args (swept
  "New foo") come free from execute's `(s,n)` remainder — keep them, same New-only
  policy. New-with-arg = **named empty window** (no disk; openfile is the namespace
  phase) — FLAG'd divergence.
- **Sort** — DEFER (cost: LOW-MED, ~50 lines: colsort cols.c:294-330 + colcmp reading
  tag names; all primitives exist after W1's File.name + Window.resize; zero value
  until many windows). Gap-filler if wave 2 runs ahead.
- **Zerox** — DEFER (cost: HIGH — needs the coladd clone arm and multi-Text-per-File:
  File.ntext fan-out on every insert/delete/undo. That's its own sub-phase; don't
  fake it).
- **Exit** — DEFER (cost: LOW — rowclean + an `ed.exit_requested` flag — but browser
  semantics are undefined until session/Dump work; note it for the Dump/Load phase).
- **Delete** — INCLUDE (zero cost: same fn as Del, flag1=true; exec.c:104).

## 4. Named tests

1. `exec: B2 click on tag word executes Snarf against the body selection` — body sel
   [0,5), scripted B2 down/up on "Snarf" in the window tag ⇒ `ed.snarf == body[0..5)`,
   seq UNCHANGED (mark=F pin).
2. `exec: B2 click executes Cut/Paste/Undo/Redo` — scripted selections; Cut bumps seq
   once on seltext's file; tag-Paste lands in the BODY (tobody pin); Undo then Redo
   round-trip with `show` selection = Range.
3. `exec: B2 sweep executes exactly the swept text` — body "Cut junk": sweep [0,3)
   with B2 ⇒ cut runs; t.q0/q1 (the real selection) untouched by the sweep itself.
4. `exec: word expansion stops at blanks and colon` — isexecc pin; click mid-"Undo";
   `file.txt:12` never matches.
5. `exec: click inside the selection executes the selection` — exec.c:166-170 arm.
6. `exec: 2-1 chord passes argtext to New` — B1-select "alpha" in a body; B2-down on
   "New" in the columntag; B1 joins; release ⇒ new window named "alpha", empty body.
7. `exec: B3 joining a B2 sweep cancels` — textselect2:1368-1369.
8. `exec: unknown word is a no-op` — externals-deferred pin (no crash, no warning spam).
9. `exec: Del clean closes and the neighbor grows back` — 2-window column, Del top ⇒
   bottom window's r covers the column (colclose geometry, both extend-down and
   extend-up cases).
10. `exec: Del dirty two-strikes` — type a rune (dirty), B2 "Del" ⇒ window survives,
    `ed.warnings` contains "modified", `w.dirty==false`, `file.mod` still true (dot
    stays); B2 "Del" again ⇒ gone, neighbor grew; also: edit between strikes re-arms.
11. `exec: Delete closes a dirty window immediately` — flag1 twin.
12. `exec: New/Newcol/Delcol mutate the tree` — counts + rects; Newcol carries one
    empty window; Delcol with one dirty window refuses+warns once (colclean strikes
    ALL windows, no short-circuit) then succeeds; Delcol white-fills when last.
13. `exec: tag exec routes to the body (et/t routing)` — Cut in the tag with a body
    selection cuts the BODY; with only a tag selection cuts the TAG (exec.c:957-974
    pins).
14. `window: parsetag finds the name end` — " Del Snarf" boundary, " |" vs "\t|",
    name-with-no-blanks.
15. `window: setTag1 recomposition` — fresh (== old literal, byte-exact), edit ⇒
    " Undo" appears, undo ⇒ " Redo" appears, user suffix typed after '|' preserved
    verbatim across recompositions, tag-selection bar-shift (:554-562).
16. `editor: frameEnd refreshes tags after an edit` — type ⇒ next frameEnd shows Undo
    in the tag; idle frame does nothing (cache pin).
17. Acceptance (orchestrator): **"phase-9: B2 exec scene"** — boot 2 windows;
    B1-select in body-1; B2 "Snarf" in its tag (snarf filled); type into body-2
    (dirty); B2 "Del" on body-2's tag twice ⇒ warned once then window gone, window-1
    grew; flush; **FROZEN-ACCEPT-9** write-stream hash + spot pins.

## 5. Wave split (superseded by the master contract's sub-wave table)

- W1 — wind/tag lifecycle → master 9a-A2.
- W1' — close geometry → master 9b-B1.
- W2 — exec module → master 9c-C1.
- W3 — gesture + integration → master 9d-C2.

## 6. O19 seams (B3/look)

- `seltext`/`argtext` — O19 reads both (look3's ct bookkeeping, look.c:375/427);
  `dropTextRefs` already clears them.
- `sweeping_b2` is the TEMPLATE for `sweeping_b3`: same textselect23 shape, mask =
  B1|B2 (text.c:1382 — B1 or B2 joining cancels look; no argument chord), then
  `look3(t, q0, q1, FALSE)` instead of execute (acme.c:666-668).
- `exec.isfilec` is pub for O19's `expand()` (look.c:442-450 shared root of isexecc);
  when O19 lands expand, `exec.getArg` upgrades its raw-selection arm to the C's
  filename expansion (exec.c:283-296) — one marked TODO.
- `New`'s named-empty-window helper is what O19's `openfile` (look.c:846-899)
  replaces/extends when the namespace phase brings real loading; keep it a named fn.

Flagged divergences to carry into the phase report: DELAY/MINMOVE included per
R-P9-2 (the original skip-flag is superseded); unknown-command no-op (externals
deferred); warnings buffered on Editor (no +Errors); New-with-arg = named empty window
(no disk); Put/Get tag arms absent until Put lands; undo's multi-window same-seq walk
deferred.
