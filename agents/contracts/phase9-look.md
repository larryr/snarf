# Phase 9 look side contract (O19) — B3 search/look (literal, within-window)

All C cites are `~/proj/plan9port/src/cmd/acme/<file>:<line>` (pinned
larryr/plan9port@337c6ac); all Zig paths under the repo root.

## 1. The C reality (verified, line-cited)

### 1.1 Dispatch — how B3 reaches look3

`acme.c:664-667`: in `mousethread`, `else if(m.buttons & (4|(4<<Shift)))` →
`if(textselect3(t, &q0, &q1)) look3(t, q0, q1, FALSE, (m.buttons&(4<<Shift))!=0);`.
B3 works in **any** Text (tag, body, column/row tag) — no region guard. `4<<Shift` is
the shifted-B3 **reverse** search bit. Also note `acme.c:656-657`: a B1 press sets
`argtext = t; seltext = t;`.

### 1.2 The B3 sweep — textselect3 / textselect23 / xselect

- `text.c:1377-1384` `textselect3`: `h = (textselect23(t, q0, q1, but3col, 1|2) == 0);
  return h;` — look fires **only if no other button was pressed during the B3 sweep**.
  Chord verdict: **B1 or B2 joining a B3 sweep CANCELS it** — `textselect23` returns
  nonzero, `*q0/*q1` are never assigned (text.c:1348-1351 assigns them only when
  `(buts & mask)==0`), and it drains until all buttons release (text.c:1355-1356
  `while(mousectl->m.buttons) readmouse`). No cut/paste chords exist on a B3-initiated
  gesture. (For B2, `text.c:1362-1375` `textselect2`: mask=4 so B3-join cancels;
  B1-join returns 1 with `*tp = argtext` — the argument pickup, O18's.)
- `text.c:1343-1359` `textselect23`: one shared function for both buttons — `p0 =
  xselect(&t->fr, mousectl, high, &p1)`, converts to file coords with `+t->org`.
- `text.c:1260-1341` `xselect` — the colored sweep. Key mechanics:
  - Paints with `frdrawsel0(f, pt, a, b, col, display->white)` — **colored background,
    WHITE text** (text.c:1294, 1299, 1307), NOT the HIGH/HTEXT pair.
  - **Never touches `f->p0/f->p1`.** The real selection stays; the sweep is a temporary
    overlay. Un-painting goes through `selrestore` (`text.c:1160-1189`), which repaints
    a range splitting it against the REAL `f->p0/p1`: outside → (BACK,TEXT), inside →
    (HIGH,HTEXT). No color-slot swap needed — direct `drawSel0` with a custom image + a
    `selRestore` port.
  - Tick handling: lifts the tick if `f->p0==f->p1` at entry (text.c:1272-1274), shows
    it at the anchor while the sweep is null (1279, 1311-1312), restores it at exit
    (1334-1336).
  - Null-click rule `text.c:1253-1258, 1315-1321`: enum `DELAY=2, MINMOVE=4` — release
    in <2ms with <4px movement collapses an accidental micro-sweep to `p0`.
  - Same incremental region/reset structure as frselect (anchor crossing at 1290-1296,
    wings 1297-1307) — already ported in `src/draw/frame/select.zig`.

### 1.3 The sweep colors

`acme.c:1084-1085` (in `iconinit`, acme.c:1037):
```c
but2col = allocimage(display, r, screen->chan, 1, 0xAA0000FF);  /* dark red */
but3col = allocimage(display, r, screen->chan, 1, 0x006600FF);  /* dark green */
```
Declared `dat.c:25-26`, extern `dat.h` (~527). So B2 sweeps **red**, B3 sweeps
**green**, both with white glyphs.

### 1.4 look3 — which arms are v1

`look.c:82-229` `look3(Text *t, uint q0, uint q1, int external, int reverse)`:
- `look.c:93-96` — `ct = seltext; if(ct == nil) seltext = t;` (only feeds the deferred
  file arms).
- `look.c:97-146` external-client event arm (`nopen[QWevent]`) — **DEFERRED** (no 9P
  clients).
- `look.c:147-196` plumber arm (`plumbsendfid`, whitespace word, `click=` attr) —
  **DEFERRED entirely** (no plumber, S-05 §6 with namespace phases).
- `look.c:197-199` `if(expanded == FALSE) return;` — expansion failed → silent no-op.
- `look.c:200-201` `if(e.name || e.u.at) openfile(t, &e);` — the path:line/URL/file
  arm — **DEFERRED** (FLAG: `expandfile`, look.c:592-729, and `openfile` are
  namespace-phase work).
- **v1 arm, look.c:202-223**:
  - `look.c:203-204` `if(t->w == nil) return;`
  - `look.c:205` `ct = &t->w->body;` — **verified: B3 in a tag searches the BODY** (the
    needle is still read from the tag's file: `bufread(&t->file->b, e.q0, r, n)` at
    look.c:217).
  - `look.c:206-207/220-221` winlock/winunlock — dropped (single-threaded).
  - `look.c:208-213` **the skip-current-selection setup**: only when `t == ct` (B3 in
    the body itself), `q = e.q1` (`e.q0` if reverse); `textsetselect(ct, q, q)` —
    collapse the caret to the END of the expanded word so the forward search starts
    past it.
  - `look.c:215-218` read runes `[e.q0,e.q1)`, `if(search(ct, r, n, reverse) &&
    e.jump) moveto(...)` — the `moveto` warps the mouse to the hit (look.c:219);
    **DEFERRED** (mouse warp impossible in browser, R-P8-7 precedent).
- **Not-found verdict (cited)**: `search` returns FALSE and look3 does nothing more —
  **silent, no beep**. But because of look.c:208-213, in the body case the selection
  has already been collapsed to `e.q1`; a failed search leaves the caret collapsed at
  the end of the clicked word. In the tag case, nothing moves at all.

### 1.5 The expansion — what a bare B3 click searches for

`look.c:731-756` `expand`:
- `look.c:738-743`: if `q0==q1` and the click falls **inside the current selection**
  (`t->q1>t->q0 && t->q0<=q0 && q0<=t->q1`), the selection itself becomes the needle
  (`e->jump=FALSE` when in a tag).
- `look.c:745` `expandfile(...)` tried first — the `isfilec` run (look.c:605-613, char
  class `isfilec` look.c:442-451: `isalnum` + `.-+/:@`) **plus** a filesystem/window
  check: `lookfile` (look.c:707) or `access(e->bname,0)` (look.c:712). When the name is
  not an open window and not an accessible file → `Isntfile` → returns FALSE.
- `look.c:748-752`: only then the bare-click fallback: `while(q1<nc &&
  isalnum(textreadc(t,q1))) q1++; while(q0>0 && isalnum(textreadc(t,q0-1))) q0--;` —
  the plain **alnum run** (`isalnum` = util.c's permissive rune class, already ported
  as `isAlnum` in `src/core/text/select.zig:186-192`).

**Decision (fidelity)**: with no host fs and no window-name table consulted,
`expandfile` would *always* fail in v1 — so the faithful v1 expansion for a bare B3
click is exactly the **alnum run** (look.c:748-752), reusing select.zig's `isAlnum`.
FLAG-DIVERGENCE: a word containing `isfilec` punctuation that names a real file
(`src/main.c:12`) opens in acme but literal-searches its clicked alnum sub-run in v1;
restored by the namespace-phase `expandfile` port.

### 1.6 search — the literal wraparound search

`look.c:313-441` `search(Text *ct, Rune *r, uint n, int reverse)`:
- Guards `look.c:317-322`: `n==0 || n > ct->file->b.nc` → FALSE; `2*n > RBUFSIZE` →
  warn "string too long" → FALSE (an fbuf-windowing artifact; our `Buffer.runeAt` scan
  needs no such cap — drop with note).
- **Forward arm `look.c:381-436`**: start `q = ct->q1` (look.c:383) — *the*
  not-current-selection start point; on `q >= nc` wrap to `q=0`, `around=1`
  (look.c:385-389); on match (`runeeq`, look.c:420) → `if(ct->w) { textshow(ct, q,
  q+n, 1); winsettag(ct->w); } else { ct->q0=q; ct->q1=q+n; }` (look.c:421-426), then
  `seltext = ct` (look.c:427), return TRUE; advance `q++` and `if(around && q>=ct->q1)
  break` (look.c:432-435) → one full lap terminates. Corollary: the sole occurrence of
  a word **re-finds itself** after wrapping (q0 < q1 is reached before the break) —
  acme reselects the same text; keep this.
- Reverse arm `look.c:330-380`: mirror — starts at `q1 = ct->q0` (look.c:332), wraps
  to `nc`, hit shows `[q1-n, q1)` (look.c:369), `seltext = ct` at look.c:375.
- The b/nb buffer-window dance (look.c:391-407 etc.) is a bufread optimization — port
  as a plain `runeAt` scan (Buffer already block-caches).

### 1.7 Landing the hit + globals

- `text.c:1101-1147` `textshow` — already ported faithfully as `Text.show`
  (`src/core/text/Text.zig:380-406`, quarter-frame placement, long-line creep).
  `Text.setSelect` = `src/core/text/select.zig:21-77`. `winsettag` (look.c:418)
  deferred with the tag-dirty machinery — NOTE: superseded, the master contract's
  frameEnd tag sweep (R-P9-4) covers it for free.
- `dat.c:30-32`: `Text *seltext; Text *argtext; Text *mousetext;`. look3 **reads**
  `seltext` only to nil-default it (look.c:93-96, feeds deferred arms); `search`
  **writes** `seltext = ct` on every hit (look.c:375, 427); B1 writes both
  `argtext`/`seltext` (acme.c:656-657). `mousetext` (acme.c:634 area) is our existing
  `Editor.gesture_text`/`focus`. `argtext` is consumed only by O18's
  `textselect2`/`execute` (text.c:1370-1372, exec.c:234-242).

## 2. Merged reality (what exists in snarf)

- `src/core/Editor.zig` — gesture machine `mouse_state: enum { idle, sweeping_b1,
  double_clicked, chording }` (line 98); `handleMouse` arm (6) at lines 272-280
  currently FLAG-ignores B2/B3-only presses. `focus`, `gesture_text` exist; **no
  `seltext`/`argtext` fields yet** (master: they land in 9a-A2, R-P9-3).
- `src/draw/frame/select.zig` — `SelectState` + `selectBegin/Update/End` (frselect
  port); the same region/anchor structure xselect needs.
- `src/draw/frame/draw.zig` — `drawSel0(f, pt0, p0, p1, back: *Image, text: *Image)`
  (line 74, **pub**, already takes arbitrary color images — exactly what xselect
  needs), `drawSel` (line 137), `pub fn tick(f, pt, ticked)` (line 217). `Frame.zig`
  re-exports `drawSel0` (line 114).
- `src/core/text/select.zig` — `setSelect`, `isAlnum` (lines 186-192, util.c-faithful;
  currently PRIVATE — promote to `pub`, master R-P9-8).
- `src/core/text/Text.zig` — `show` (line 380), `setSelect` alias (line 101),
  `file.buffer.runeAt`.
- `src/core/Chrome.zig` — palette struct (lines 41-59); **no but2/but3 yet**;
  `display.white` available.
- `src/dev/profiles.zig:108` — `Mod` enum already has `shift` (reverse-look wiring is
  possible later; FLAG below).

## 3. Contract

### 3.1 Chrome (`src/core/Chrome.zig`)

```zig
pub const palette = struct {
    ...
    /// but2col — the B2 sweep highlight (acme.c:1084).
    pub const but2: Color = 0xAA0000FF;
    /// but3col — the B3 sweep highlight (acme.c:1085).
    pub const but3: Color = 0x006600FF;
};
but2_img: Image,          // owned solids, freed in deinit
but3_img: Image,
but2col: *Image,          // handles (dat.c:25-26)
but3col: *Image,
```
Allocated in `Chrome.init` via the existing `solid()` helper. Sweep glyphs paint in
`display.white` (text.c:1294 `frdrawsel0(..., col, display->white)`).

### 3.2 Frame — the SHARED textselect23 mechanics (`src/draw/frame/select.zig`) — O18 seam

The C has ONE function for both buttons; port it once, O18 consumes it for B2.

```zig
/// xselect's live colored sweep (text.c:1260-1341). Unlike SelectState (B1),
/// this NEVER writes f.p0/f.p1 — the paint is a temporary overlay over the
/// real selection, un-painted via selRestore.
pub const Select23State = struct {
    f: *Frame,
    col: *Image,          // but2col or but3col; glyphs in f.display-white
    p0: usize, p1: usize,
    pt0: Point, pt1: Point,
    reg: i8,
    start_pt: Point,      // DELAY/MINMOVE null-click test (text.c:1253-1258)
    start_msec: u32,
};

/// text.c:1270-1279: lift the tick if the real selection is a caret, anchor at
/// mp, tick the anchor.
pub fn select23Begin(f: *Frame, mp: Point, col: *Image, msec: u32) Frame.Error!Select23State;

/// Loop body text.c:1280-1313: anchor-cross reset + wing extend/retract, painting
/// with drawSel0(f, .., col, white) and un-painting with selRestore.
pub fn select23Update(s: *Select23State, mp: Point) Frame.Error!void;

/// Exit tail text.c:1314-1341: apply the <2ms/<4px null-click collapse, order
/// p0<=p1, selRestore the whole swept range (the overlay vanishes), restore the
/// tick if the REAL f.p0==f.p1. Returns the swept FRAME range; f.p0/f.p1 are
/// byte-identically untouched. Called on ANY button-set change (the C exits its
/// loop on change, not only release); the caller decides commit vs cancel.
pub fn select23End(s: *Select23State, mp: Point, msec: u32) Frame.Error!struct { p0: usize, p1: usize };

/// selrestore (text.c:1160-1189): repaint [p0,p1) split against the REAL
/// f.p0/f.p1 — (HIGH,HTEXT) inside, (BACK,TEXT) outside. Module-private.
fn selRestore(f: *Frame, pt0: Point, p0: usize, p1: usize) Frame.Error!void;
```

No `Frame.drawSel` color-swap hack, no scratch image: `drawSel0` (frame/draw.zig:74)
already accepts arbitrary (back,text) pairs, and `tick` (frame/draw.zig:217) is pub.
Add `Frame.zig` aliases `select23Begin/Update/End`, `Select23State`.

### 3.3 Editor (`src/core/Editor.zig` + new `src/core/look.zig`)

Fields per master R-P9-3 (seltext/argtext land in 9a-A2); sweep state per R-P9-1/2
(`sel23`, `sel23_buts`, states `.sweeping_b2/.sweeping_b3/.draining`). Sweep-color
bindings:
```zig
/// Sweep highlight solids, bound from Chrome at boot (acme.c:1084-1085).
/// null (harness/pre-boot) falls back to f.col(.high) — mechanics still tested.
but2col: ?*draw.Image = null,
but3col: ?*draw.Image = null,
```

`handleMouse` arm (6) grows (acme.c:655-667 order): B1 press sets
`focus/argtext/seltext`; B3 press (tag AND body; scrollbar handled earlier) sets
`gesture_text` and enters the sweep via
`select23Begin(&t.fr, pt, ed.but3col orelse t.fr.col(.high), ev.msec)` →
`.sweeping_b3`.

`runGesture` `.sweeping_b3` arm (textselect3, text.c:1377-1384 + textselect23
:1343-1359, R-P9-2 protocol):
- `b == B3` → `select23Update(&sel23, pt)`.
- `b == 0` → `const r = select23End(...)`; `q0 = t.org + r.p0; q1 = t.org + r.p1`
  (text.c:1348-1350); `.idle`; `try ed.look(t, q0, q1, false)`.
- anything else (B1/B2 joined) → `_ = select23End(...)` (paint restored, range
  discarded — the `buts & (1|2)` cancel); `.draining`.

New file `src/core/look.zig` (namespace module, aliased on Editor like Text's
select/scroll pattern):

```zig
/// look3 v1 (look.c:82-229, minus :97-196 external/plumb and :200-201 openfile —
/// FLAG namespace phases). q0==q1 expands: current-selection capture
/// (look.c:738-743) else the alnum run (look.c:748-752, select.zig isAlnum);
/// expandfile (look.c:745) is the DEFERRED file/URL arm. Empty expansion ⇒
/// silent return (look.c:198-199).
pub fn look(ed: *Editor, t: *Text, q0: usize, q1: usize, reverse: bool) Text.Error!void;

/// search (look.c:313-441) as a runeAt scan (the fbuf windowing dropped; the
/// RBUFSIZE cap with it). Forward from ct.q1 with wrap at nc (look.c:383-436);
/// reverse from ct.q0 (look.c:330-380). Hit: ct.show(q, q+n, true)
/// (look.c:417/369) + ed.seltext = ct (look.c:427/375).
/// Miss: returns false, changes nothing.
pub fn search(ed: *Editor, ct: *Text, needle: []const u21, reverse: bool) Text.Error!bool;
```

`look` body order (cited): expand → `ct = if (t.w) |w| &w.body else t` (look.c:203-205;
the `else t` is a FLAG-divergence so standalone-Text harnesses work — the C returns
when `t->w==nil`) → if `t == ct`: `try ct.setSelect(q, q)` with `q = if (reverse)
e.q0 else e.q1` (look.c:208-213, the skip-current mechanism) → read needle runes
`[e.q0, e.q1)` from `t.file` (look.c:215-217) → `_ = try ed.search(ct, needle,
reverse)` — the `e.jump`/`moveto` warp (look.c:219) is permanently dropped (R-P8-6
lineage). Not-found is silent; the body-case caret stays collapsed at `e.q1`.

### 3.4 Flags / deferrals (summary)

| FLAG | C cite | disposition |
|---|---|---|
| plumb arm | look.c:147-196 | namespace phases (S-05 §6) |
| external QWevent arm | look.c:97-146 | 9P client phases |
| expandfile / openfile / URL | look.c:592-729, 200-201 | namespace phases; v1 alnum-run divergence noted §1.5 |
| moveto warp on hit | look.c:219 | permanent (browser, R-P8-6 lineage) |
| winsettag on hit | look.c:418 | covered by the frameEnd tag sweep (R-P9-4) |
| winlock/unlock | look.c:206-207,220-221 | single-threaded, dropped |
| reverse via Shift-B3 | acme.c:667 `4<<Shift` | `reverse` param is in every signature; input wiring deferred (profiles.zig:108 has `Mod.shift`) |
| `ct = t` when `t.w == null` | look.c:203-204 returns | harness divergence, documented |

## 4. O18 seams (coordinate)

1. **`select23Begin/Update/End` + `Select23State` + `selRestore`** in
   `src/draw/frame/select.zig` is the shared port of `xselect`/`textselect23` — one
   implementation, parameterized by `col` (`but2col` red / `but3col` green), exactly
   as text.c:1343-1359 parameterizes by `high`+`mask`. Lands in 9a-A1; O18's B2
   consumes with `but2col` and mask-4 semantics.
2. **`Editor.mouse_state`**: `.sweeping_b3` + shared `.draining` here; `.sweeping_b2`
   is O18's. The exit protocol is identical (R-P9-2): button-set change ⇒
   `select23End` (always restores paint), then per-mask commit/cancel, then
   `.draining` if any button still down.
3. **`seltext`/`argtext` fields** on Editor: land in 9a-A2 (R-P9-3); look adds the
   search-hit `seltext` write (look.c:427); B1-press writes are the gesture wave's;
   O18 reads `argtext` (text.c:1370-1372) and `seltext` (exec.c:234-242).
4. **Chrome `but2col`/`but3col`** and the Editor's nullable bindings: added once by
   9a-A1 (Chrome) / 9d-C2 (boot wiring).

## 5. Named tests

Frame (`src/draw/frame/select.zig`):
- `"frame: select23 colored sweep paints and restores (write-stream)"` — real
  selection at [1,3); B3-sweep [5,8) with a distinct col image; assert sweep draws use
  `col`+white (exact encoded 'd' bytes, per the existing select test style); after
  `select23End`, `f.p0/f.p1` still 1/3 and the restore repainted [5,8) in BACK/TEXT;
  tick restored when p0==p1.
- `"frame: select23 restore splits across the real selection"` — sweep overlapping
  [1,3): restore paints HIGH/HTEXT inside, BACK/TEXT outside (selrestore
  text.c:1160-1189 three-way split).
- `"frame: select23 null-click collapses under delay+minmove"` — text.c:1253-1258.

Chrome:
- `"chrome: but2/but3 sweep colors match iconinit"` — 0xAA0000FF / 0x006600FF
  (acme.c:1084-1085).

core/look.zig:
- `"look: search wraps around and skips the current selection"` — buffer
  `"foo bar foo baz foo"`, selection on the middle `foo`; `search` finds the third,
  then wraps to the first (start `q=ct.q1`, look.c:383).
- `"look: search single occurrence re-finds itself after wrap"` — look.c:432-435 lap
  semantics.
- `"look: search not-found returns false and moves nothing"` — q0/q1/org unchanged.
- `"look: bare click inside the current selection searches the selection"` —
  look.c:738-743.
- `"look: reverse search walks backwards from q0"` — look.c:330-380.

Editor:
- `"editor: b3 click on word finds next occurrence and scrolls it visible"` —
  multi-occurrence buffer with the next hit below the fold; press+release B3 on the
  word; assert selection at the next occurrence AND `org` moved so it's on-screen
  (show's maxlines/4 placement, text.c:1139-1140).
- `"editor: b3 sweep searches the swept literal"` — sweep a non-word substring;
  release; next occurrence selected.
- `"editor: repeated b3 cycles matches and wraps"` — three clicks on the same word
  cycle 2nd → 3rd → 1st.
- `"editor: b3 not-found leaves the caret at word end"` — the look.c:208-213 collapse
  is the ONLY state change; buffer and org untouched.
- `"editor: b1 or b2 during a b3 sweep cancels the look"` — selection unchanged, no
  search, `.draining` until all-up (text.c:1382 mask `1|2`, 1355-1356).
- `"editor: b3 in the tag searches the body"` — TwoWin scene; B3 a word in w1's tag;
  w1 body selection jumps + shows; the tag's own selection untouched (look.c:205, 208
  `t != ct`).
- `"editor: b3 press updates no argtext, b1 press updates seltext+argtext"` —
  acme.c:656-657 bookkeeping; search hit sets `seltext` to the body (look.c:427).

Acceptance sketch: `"editor: acceptance b3 look scene"` — 60-line buffer with `needle`
on lines 2, 30, 50; caret at 0; B3 press+release on line-2 `needle` → selection
[line30 hit) and hit visible; second B3 → line 50; third → wraps to line 2. Optional
frozen write-stream hash of the whole scene (Wyhash over the fixture writes, per the
Editor.zig precedent) — a NEW freeze, not a re-freeze.

## 6. Wave split (superseded by the master contract's sub-wave table)

- Wave A (frame + chrome) → master 9a-A1.
- Wave B (core search/look) → master 9b-B2.
- Wave C (editor gesture) → master 9d-C2.
