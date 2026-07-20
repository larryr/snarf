# Phase 9 report — exec & look (B2 executes, B3 searches, live tags)

**Merged to main:** (this commit's merge) · **Tests:** 369/369 (`zig build test`), node
smoke 14/14 · **Contracts:** `agents/contracts/phase9-{exec-look,exec,look}.md`
(rulings R-P9-1..13) · **wasm:** 1258.5 KiB (was ~1177 — exec module + look + tag
lifecycle; size watch continues).

## What works now (in the browser after reload)

- **B2 (Alt-click / middle) executes**: click `Snarf`/`Cut`/`Paste`/`Undo`/`Redo`/
  `Del`/`Delete`/`New`/`Newcol`/`Delcol` in any tag (window/column/row) or sweep any
  text and release. Tag commands route to the window body per acme's et/seltext
  convention (exec.c:244). A B2 sweep paints acme's dark-red overlay; B3 joining
  cancels; B1 joining passes the last B1 selection as the argument (2-1 chord —
  `New` names its window from it).
- **B3 (Cmd-click / right) searches**: the clicked alnum word (or swept literal, or
  current selection) is searched forward from the selection end with wraparound;
  the hit is selected and scrolled visible (textshow quarter-frame placement). B3
  sweeps paint dark green. B3 in a tag searches that window's body.
- **Live tags** (R-P9-4): ` Undo`/` Redo` appear/disappear in window tags as undo
  state changes; anything typed after the `|` is preserved verbatim; the selection
  shifts with the bar. The C's 29 `winsettag` sites collapse to one cached
  `frameEnd` sweep.
- **Two-strike Del** (wind.c:666-685): first Del on a dirty window warns
  ("<name> modified" — buffered on `ed.warnings` until +Errors exists) and clears
  the strike; the second closes it; any edit re-arms. `Delete` skips the check.
  Closing grows the neighbor back (colclose/rowclose geometry); `Delcol` strikes
  every dirty window in one pass (no short-circuit).

## Wave log

| Wave | Agent/model | Scope | Outcome |
|---|---|---|---|
| Outline | O18, O19 (fable) | exec + look contracts vs pinned C | reconciled into R-P9-1..12 |
| 9a-A1 | opus | shared xselect/selrestore colored sweep + Chrome but2/but3 | merged, first-try |
| 9a-A2 | opus | File.name, setTag1/parseTag/clean, ownership move, warnings | merged, first-try |
| 9b-B1 | sonnet | Column/Row.close, colclean, dropTextRefs | merged; **flagged the R-P9-13 defect** |
| 9b-B2 | opus | core/look.zig search/look | merged, first-try |
| 9c-C1 | opus | exec module (execute, exectab, cmd_edit, cmd_window) | merged, first-try |
| 9d-C2 | opus | gesture machine arms, dispatch, frameEnd tag sweep, boot binding | merged; FROZEN-ACCEPT-8 re-frozen (approved) |

**R-P9-13 (the one real incident):** the original contract froze
`Row.close(row, c, dofree)` with no `ed` — Delcol would have freed a column's
windows while `seltext/argtext/focus/gesture_text` still pointed into them. B1
flagged it instead of coding around it; orchestrator patched (`Row.close(row, ed,
c, dofree)` drops refs per window), amended the contract before 9c consumed it,
and pinned a regression test.

**FROZEN-ACCEPT-8 re-frozen** (`0x9816211a7aca91d7`): the frameEnd tag sweep now
adds the live ` Undo` word to the edited window's tag in the phase-8 scene — a
real behavioral improvement; spot-checks retained plus new tag assertions.
**FROZEN-ACCEPT-9 new freeze** (`0xb52b86b54d50d100`): tag-Snarf against the body
selection, live-tag Undo, two-strike Del, neighbor regrowth. The B3 look scene
pins occurrence cycling + wraparound + scroll-visible without a hash.

## Divergences / deferrals (all cited in-code)

- Bare B3 click expands the **alnum run** only — `expandfile` (paths/URLs/line
  numbers) always fails with no host fs; restored in the namespace phases.
- `New` with an argument makes a **named empty window** (no disk load) — the
  `makeWindow` helper is the seam `openfile` replaces (R-P9-9).
- Warnings buffer on the Editor (no +Errors window yet, R-P9-6).
- Undo's multi-window same-seq walk deferred to the Edit phase (R-P9-10);
  `w.dirty = f.mod` approximates putseq until Put.
- Sort (low cost, low value until many windows), Zerox (needs multi-Text-per-File
  — its own sub-phase), Exit (needs session semantics) deferred (R-P9-7).
- Shift-B3 reverse search: engine supports `reverse`, input wiring deferred.
- `moveto` mouse warp on a hit: permanently dropped (browser, R-P8-6 lineage).

## Debt noted

- `Editor.zig` is ~1743 lines (gesture machine should be carved out next
  structural pass); `Window.zig` ~413 non-test lines.
- `getArg` returns raw selection bytes; upgrade to filename expansion with the
  namespace-phase `expand`.
