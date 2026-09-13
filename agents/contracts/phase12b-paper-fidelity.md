# Phase 12b contract — paper fidelity wave: `Look`, `+Errors`, `makenewwindow`/`activecol`

Status: **DRAFT → binding once the orchestrator (fable) signs §3.** Branch `phase12b`
(worktree `../snarf-wt/phase12b`), based on `main@8294ce8`. Requirements served:
R-EDIT-07 (`Look`), R-EDIT-21 (`+Errors`), R-EDIT-23 (placement / active column),
R-EDIT-25 (no warp). Paper: `docs/acme/acme.md` §User interface, §Nuances.

Pipeline (user's standing pattern): fable writes this design + test spec → **opus**
codes §3 → **sonnet** writes the named tests of §4 → **sonnet** runs the suite → **fable**
reviews everything → repeat until the gate (§5) passes. Agents work ONLY in the worktree.

## 1. C ground truth (pinned `larryr/plan9port@337c6ac`, `src/cmd/acme/`)

Read these before coding; cite line numbers in doc comments as every other module does.

| Item | Where | What |
|---|---|---|
| `Look` builtin | `exec.c:116` (exectab `{LLook, look, FALSE, XXX, XXX}`), `exec.c:1076-1097` | `t = &et->w->body`; inline arg (`narg>0`) ⇒ `search(t, arg, narg, FALSE)`; else `getarg(argt, FALSE, FALSE, …)`; if no arg ⇒ the body's own selection `[t->q0,t->q1)`; then `search(t, r, n, FALSE)`. Nothing if `et->w == nil`. |
| `search` | `look.c:314-420` | `n==0 || n>nc` ⇒ FALSE silently; `2*n > RBUFSIZE` ⇒ `warning(nil,"string too long\n")`; forward search starts at `ct->q1`, wraps once; on hit `textshow(ct,q0,q1,1)` + `winsettag`; miss ⇒ FALSE with **no** warning. The Zig `core/look.zig:search` already ports this — reuse, do not re-implement. |
| `isexecc`/`isfilec` | `exec.c:150-155`, `look.c:443-450` | Already ported (`exec.zig:isexecc`). NO change — recorded here because the R-02 v4 pass mis-flagged it. |
| `makenewwindow` | `util.c:449-495` | Column choice: `activecol`, else `seltext->col`, else `t->col`, else last column (creating one if `row.ncol==0`); then **`activecol = c`**. If `t==nil || t->w==nil || c->nw==0` ⇒ `coladd(c,nil,nil,-1)`. Else scan `c->w[]`: `bigw` = max `body.fr.maxlines` (`>=` picks the lower one), `emptyw` = max `maxlines-nlines` (`>=`). `el = emptyw's maxlines-nlines`; if `el>15 || (el>3 && el>(bigw.maxlines-1)/2)` ⇒ `y = emptyb->fr.r.min.y + nlines*font->height`; else if `t->col==c && Dy(t->w->r) > 2*Dy(bigw->r)/3` ⇒ `bigw = t->w`; `y = (bigw->r.min.y+bigw->r.max.y)/2`; `w = coladd(c,nil,nil,y)`; `if(w->body.fr.maxlines<2) colgrow(w->col,w,1)`. |
| Callers of `makenewwindow` | `acme.c:877` (served `new` via `cnewwindow`, `t=nil`), `look.c:283` (`openfile`, future), `look.c:856` (`plumblook`/`look3` new window, future) | **`New` (look.c:922) uses `coladd(et->col,…,-1)` — NOT makenewwindow.** The Zig `cmd_window.new` is therefore already faithful; leave it alone. |
| `activecol` writers | `acme.c:487-488` (typing: any key except `Kdown/Kleft/Kright` in a Text with a column), `acme.c:659` (B1 press, "button 1 only"), `acme.c:640` (scrollbar drag arm — `rowdragcol/coldragwin`, deferred in Zig, skip), `cols.c:216-217` (`colclose` clears it if it was the closed column) | `activecol` is a global in the C (`dat.c:37`); in Zig it hangs off `Editor` (no globals, S-07). |
| `errorwin1` | `util.c:79-114` | name = `dir + "/" + "+Errors"` when `ndir!=0`, else `"+Errors"`; `lookfile(name)`; if none: ensure a column exists (`rowadd(&row,nil,-1)`), `w = coladd(row.col[row.ncol-1], nil, nil, -1)` (**rightmost column**, R-EDIT-21 "towards the right"), `w->filemenu = FALSE`, `winsetname`. `incl` handling and `autoindent`: skip (no incl, no autoindent in Zig). |
| `errorwin` / `errorwinforwin` | `util.c:116-135`, `140-186` | Lock/retry loops — irrelevant single-threaded; `errorwinforwin` derives `dir` from `dirname(&w->body)` and treats `"."` as no dir. |
| `dirname` | `look.c:542-578` | Directory of the window's tag name: the runes up to (not including) the last `/` of the name part of the tag (`parsetag`); a name with no `/` ⇒ empty; an absolute `r` argument is returned as-is (the join arm is for relative names — we need only the "dir of this window" query). `cleanrname` (path cleaning) — port only if trivial, else defer with cite. |
| `lookfile` | `look.c:456-480` | Match a window by body-file name across all columns, ignoring ONE trailing `/` on either side; returns the window (curtext arm collapses in single-Text-per-File v1). |
| `addwarningtext`/`flushwarnings` | `util.c:189-258` | Warnings are buffered per `md` (directory context) and flushed from the main loop; flush: `w = errorwin(md)`, append at end of body (`textbsinsert`, backspace-processing — v1 plain insert is acceptable, cite the divergence), `textshow(t, q0, nc, 1)`, `winsettag`, `w->dirty = FALSE`. |

## 2. Merged reality (main@8294ce8)

- `exec/builtins.zig` exectab: 12 entries, no `Look`. `core/look.zig` has `look()` (B3 arm)
  and `search(ed, ct, needle []const u21, reverse) bool` + `landHit` (textshow analog).
- `Editor.warning()` appends formatted text to `ed.warnings: ArrayList(u8)`; nothing ever
  drains it (HANDOFF: "ed.warnings still invisible in the UI"). `Window.zig:394-410`
  (two-strike Del) and the Edit `p`/`=` commands are the live callers.
- `Column.add(c, winid, body_file, y_in)` = `coladd` (steal at `-1`, split at `y`);
  `Row.add(row, x_in) ?*Column`; `Column.close`; no `colgrow`. `exec/cmd_window.makeWindow(c,
  name)` mints a window in a given column and is called by `New`, `Newcol` and
  `served/fsys.zig` (walk-to-`new`: "column chosen by the caller: `ed.seltext`'s, else the
  first column" — the approximation this wave replaces).
- `Editor` has `seltext/argtext/focus/gesture_text` but no `activecol`.
- Frame exposes `nlines`/`maxlines` (`draw/frame/Frame.zig:96-97`).
- Acceptance scenes live in `src/accept.zig` (`test "phase-N: …"`), hashes frozen per
  R-P2-7 (`FROZEN-ACCEPT-N` constants; spot-check before freezing). The phase-9 exec scene
  performs a two-strike Del, so it WILL now grow a `+Errors` window — FROZEN-ACCEPT-9
  needs a sanctioned re-freeze (ruling R-P12b-6).

## 3. CONTRACT (opus codes exactly this)

### 3a. `Look` builtin — `src/core/exec/cmd_look.zig` (new, ≤ ~80 lines + tests slot)

```zig
pub fn look(ed: *Editor, et: *Text, _: ?*Text, argt: ?*Text, _: bool, _: bool, arg: []const u8) Text.Error!void
```
- `et.w orelse return` (exec.c:1084); `t = &w.body`.
- `arg.len > 0` ⇒ needle = runes of `arg` (exec.c:1086-1088). Else `exec.getArg(ed, argt)`
  (bytes → runes) if non-null (exec.c:1090); else the body's own selection `[t.q0,t.q1)`
  (exec.c:1091-1094).
- `_ = try look.search(ed, t, needle, false)` (exec.c:1096). Miss ⇒ nothing (look.c).
- exectab entry `.{ .name = "Look", .fn_ = cmd_look.look, .mark = false, .flag1 = false,
  .flag2 = false }, // exec.c:116` — keep the table **sorted** (binary-search lookup, if
  that is how `lookup` works — verify; otherwise the C's linear scan order is irrelevant).
  Update the `names` test list in `builtins.zig`.

### 3b. `activecol` — `Editor.zig`

- Field `activecol: ?*Column = null` with a doc comment citing `dat.c:37` + the three
  writers. Set it: (i) in the B1 **press** arm on a Text with a column (acme.c:659,
  "button 1 only"); (ii) in the key path for every rune except `Kdown/Kleft/Kright`
  (acme.c:487-488) when the target Text has a column; (iii) `Column.close` (or its
  Editor-side caller) nils it when the closed column is `activecol` (cols.c:216-217).
- Add `activecol` to the dangling-pointer hygiene set (`dropTextRefs`, R-P9-13 lineage)
  — a freed column must never remain referenced.

### 3c. `makenewwindow` — `src/core/exec/cmd_window.zig` (or `core/place.zig` if
cmd_window would exceed ~400 lines; S-07 soft cap)

```zig
/// `makenewwindow` (util.c:449-495): column choice + placement heuristics (R-EDIT-23).
pub fn makeNewWindow(ed: *Editor, t: ?*Text) Text.Error!*Window
```
- Column choice and `ed.activecol = c` exactly as §1. "Last column, creating one if none"
  = `row.col.items[len-1]`, else `try row.add(-1) orelse error` (choose an existing
  `Text.Error` member or add one with a cite; the C `error()`s = fatal).
- `t == null or t.w == null or c.w.items.len == 0` ⇒ `c.add(&row.winid, file, -1)`.
- Heuristic scan on `body.fr.maxlines/nlines` with the C's `>=` tie rule; the two `y`
  formulas; `2*Dy(bigw.r)/3` in integer math (`@divTrunc`).
- After `add`: `if (w.body.fr.maxlines < 2)` ⇒ **DEFERRED** `colgrow(w.col, w, 1)` —
  leave a `// DEFERRED colgrow (cols.c:333+) R-P12b-3` comment; do NOT port colgrow here.
- Creates the empty `File` exactly as `makeWindow` does today (`owns_body`, `setTag1`,
  caret at tag end, `fill`). Refactor so `makeWindow(c, name)` and `makeNewWindow`
  share one private `mintWindow(c, y, name)` helper rather than duplicating the body.
- **Wire the served `new` walk** (`served/fsys.zig`) to `makeNewWindow(ed, null)`
  (acme.c:877 passes `nil`). `New`/`Newcol` keep calling `makeWindow` (look.c:922 —
  faithful; see §1).

### 3d. `+Errors` — `src/core/errors.zig` (new; `Editor` stays out of the file cap)

```zig
/// `lookfile` (look.c:456-480): the window whose body-file name equals `name`, one trailing '/' ignored on either side.
pub fn lookFile(row: *Row, name: []const u8) ?*Window
/// `dirname` query arm (look.c:542-578): directory part of the window's name ("" when no '/').
pub fn dirName(w: *Window) []const u8
/// `errorwin1` (util.c:79-114): find-or-create `dir/+Errors` (or `+Errors`) in the RIGHTMOST column.
pub fn errorWin(ed: *Editor, dir: []const u8) Text.Error!*Window
/// `flushwarnings` (util.c:211-258): append every buffered warning to its +Errors body, show the tail, tag, not dirty.
pub fn flushWarnings(ed: *Editor, d: *draw.Display) Text.Error!void
```
- `Editor.warnings` becomes a small list of buckets `{ dir: []u8, text: ArrayList(u8) }`
  (the C's per-`md` `Warning` list); `ed.warning(fmt,args)` keeps its signature and
  appends to the `""` bucket (`warning(nil, …)`), and a new `ed.warningIn(dir, fmt, args)`
  targets a directory (`errorwinforwin` lineage; no live caller yet — served/exec later).
  Keep the **never-fails** rule (Editor.zig:214-216). Preserve a cheap
  `ed.warningsPending()`/byte-count accessor so the existing two-strike tests that read
  `ed.warnings.items.len` can be adapted with a one-line change (sonnet may adjust
  those asserts; opus must keep them compiling).
- `flushWarnings` runs from `Editor.frameEnd` **before** the live-tag sweep, so the new
  window's tag is composed in the same frame (C: `flushwarnings` from the main loop's
  `cwarn` alt, then `winsettag` inside flush). Behavior per §1: find-or-create,
  `insertAt(len, text)` (plain insert — DIVERGENCE note vs `textbsinsert`), scroll so the
  appended text is visible (`landHit`/textshow analog: reuse, don't fork), `w.dirty =
  false`, `w.filemenu = false` (add the bool to `Window` if absent; it only gates the
  future Put/Get tag words — cite wind.c). Empty row (`row.col` empty) ⇒ `row.add(-1)`.
  No `Display` available (headless unit tests) must still work — take `d` only if the
  existing `frameEnd` needs it for redraw; otherwise drop the parameter.

### 3e. Rulings

- **R-P12b-1** `Look` reuses `look.search`; no second search engine.
- **R-P12b-2** `New`/`Newcol` placement is unchanged (faithful to look.c:922); only
  auto-created windows (`new` walk now; openfile/plumb later) use `makeNewWindow`.
- **R-P12b-3** `colgrow` stays deferred; the `<2 lines` arm is a cited comment.
- **R-P12b-4** No mouse warp anywhere (R-EDIT-25): the C's `moveto` calls near these
  paths are dropped with a cite.
- **R-P12b-5** `+Errors` windows land in the rightmost column (util.c:98), never via
  `makeNewWindow` — the paper's "output windows towards the right".
- **R-P12b-6** FROZEN-ACCEPT-9 re-freeze is sanctioned **only after** spot-checks confirm
  the sole difference is the new `+Errors` window (name in tag, body text, position in the
  rightmost column); record old/new hashes in the phase report.
- **R-P12b-7** No new globals, no browser APIs, `core` imports nothing from `dev`/`shim`;
  `zig fmt` clean; every file ≤ ~400 lines.

## 4. Named tests (sonnet writes; opus leaves them unwritten)

Colocated `test` blocks unless stated; use the harness patterns already in each file
(`Harness`/`WinHarness` in `look.zig`, `OneWin` in `Editor.zig`, the phase-8/9 scenes in
`accept.zig` for multi-column setups).

| # | Where | Test |
|---|---|---|
| T1 | `cmd_look.zig` | Body `"foo bar foo\n"`, selection `[0,3)`, tag text `"Look"`: executing `Look` from the tag selects `[8,11)`. |
| T2 | `cmd_look.zig` | Inline arg: executing `"Look bar"` selects `[4,7)` regardless of the selection. |
| T3 | `cmd_look.zig` | 2-1 chord: `argt` = another Text with selection `"bar"`; `Look` with empty `arg` uses it. |
| T4 | `cmd_look.zig` | Miss: `Look zzz` leaves `q0/q1` unchanged and adds no warning. |
| T5 | `cmd_look.zig` | Wraparound: selection on the LAST `foo`, `Look` → first `foo`. |
| T6 | `builtins.zig` | `names` list includes `"Look"`; lookup of `"Look"` resolves to `cmd_look.look`. |
| T7 | `Editor.zig` | B1 press in a window's body sets `ed.activecol` to its column; a B3 click and a B2 click in another column do NOT change it. |
| T8 | `Editor.zig` | Typing a rune sets `activecol`; `Kdown`, `Kleft`, `Kright` do not. |
| T9 | `Editor.zig`/`Column.zig` | Closing the active column nils `ed.activecol`. |
| T10 | `cmd_window.zig` | `makeNewWindow(ed, null)` with `activecol == null` and `seltext == null` uses the LAST column and sets `activecol` to it. |
| T11 | `cmd_window.zig` | With `activecol` = column A and `t` in column B, the window lands in A. |
| T12 | `cmd_window.zig` | Empty-space arm: one window whose body has 2 lines in a tall column (`el > 15`) ⇒ new window's `r.min.y == emptyb.fr.r.min.y + nlines*font.height` (allow the C's border adjustments performed by `coladd` — assert the `y` passed, or the resulting split point per `Column.add`'s clamp rules). |
| T13 | `cmd_window.zig` | Split arm: column whose windows are all full of text (`el <= 3`) ⇒ the biggest window is split at its vertical midpoint; the `>=` tie picks the LOWER window. |
| T14 | `cmd_window.zig` | Own-window arm: `t` in `c`, `Dy(t.w.r) > 2/3 Dy(bigw.r)` ⇒ `t.w` is the one split. |
| T15 | `served` tests | Walking `new` through the mount table lands the window per `makeNewWindow` (with `activecol` set to column A, the served window appears in A). |
| T16 | `errors.zig` | `lookFile`: finds `"/a/b"` given `"/a/b/"` and vice-versa; `null` when absent. |
| T17 | `errors.zig` | `dirName`: `"/a/b/c.zig"` → `"/a/b"`; `"c.zig"` → `""`; `"/x/"` → `"/x"` (verify against look.c and adjust the expectation with a cite). |
| T18 | `errors.zig` | `ed.warning("x\n")` + `flushWarnings` on a two-column row: a window named `+Errors` exists in column 1 (rightmost), body `"x\n"`, `dirty == false`, no pending warnings left; a second warning `"y\n"` appends (body `"x\ny\n"`), no second window. |
| T19 | `errors.zig` | `warningIn("/a/b", …)` creates `"/a/b/+Errors"`; a simultaneous `""` warning creates `"+Errors"` — two windows, both rightmost. |
| T20 | `errors.zig` | Empty row (no columns): flush creates a column first (util.c:96-98). |
| T21 | `Window.zig` | Existing two-strike tests updated to the new pending-warnings accessor; behavior unchanged. |
| T22 | `accept.zig` | New scene `"phase-12b: +Errors scene — two-strike Del warning surfaces in the rightmost column"`: two columns, dirty window in column 0, B2 `Del` once ⇒ after `frameEnd` a `+Errors` window with `"<name> modified\n"` exists in column 1; freeze `FROZEN-ACCEPT-12B` after spot-checks (R-P2-7). |
| T23 | `accept.zig` | FROZEN-ACCEPT-9 re-frozen per R-P12b-6 with the spot-check evidence in the test comment. |

## 5. Gate (fable reviews; loop until all hold)

1. `zig build test` to a file; `$?==0`; grep shows 0 failures (HANDOFF gate lesson).
2. `zig fmt --check src build.zig` clean; `zig build` (wasm) succeeds; node smoke passes.
3. Boundary: `grep -rn '@import("dev\|@import("shim' src/core` empty.
4. Every §3 item present with C cites; every §4 test present and green; no test weakened
   to pass (fable diff-reviews `accept.zig` hashes against the spot-check notes).
5. Report `agents/reports/phase12b-paper-fidelity.md` (what/why/hashes/divergences).
