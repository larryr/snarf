# Phase 12b report — paper fidelity: `Look`, `+Errors`, `makenewwindow`/`activecol`

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 547/547 (`zig build test`,
was 522 + 4 smoke + 21 named), run twice for determinism · node smoke 20/20 · `zig fmt`
clean · boundary clean · **Contract:** `agents/contracts/phase12b-paper-fidelity.md`
(rulings R-P12b-1..7) · **wasm:** 1619443 B = 1581.5 KiB (was 1554 KiB; +27 KiB — the
size watch continues; `std.fmt.allocPrint` in the warning path and the placement module
are the likely cost).

Origin: the 2026-09-13 re-verification of Pike's paper (`docs/acme/acme.md`) against
R-02 and the code, which produced R-02 v4 (R-EDIT-20..25) and three real gaps. Two
further "gaps" claimed at first were disproved by the C and withdrawn (B2 expansion
already uses `isexecc`; `New` correctly uses the executing tag's column, look.c:922).

## What works now

- **`Look`** (exec.c:116, 1076-1097; R-EDIT-07): B2 `Look` in a tag searches the body
  for the body's selection; `Look word` searches for the inline word; the 2-1 chord
  argument wins over the selection. Reuses `core/look.zig:search` (R-P12b-1).
- **`activecol`** (dat.c:37; acme.c:486-488, 658-659; cols.c:216-217; R-EDIT-23): set
  by a B1 press and by typing (not by `Kdown/Kleft/Kright`, "scrolling doesn't change
  activecol"), never by B2/B3, cleared when its column closes.
- **`makeNewWindow`** (util.c:449-495; R-EDIT-23) in new `core/place.zig`: column =
  activecol, else seltext's, else t's, else the last column (created if none); inside
  it the emptiest blank spot if big enough, else the biggest window split at its
  midpoint (or t's own window if not much smaller); the C's `>=` lower-of-equals ties.
  Wired to the served `new` walk (acme.c:877). `New`/`Newcol` deliberately unchanged
  (R-P12b-2). `mintWindow(c, y, name)` is now the single window-creation seam.
- **`+Errors`** (util.c:79-114, 189-258; R-EDIT-21) in new `core/errors.zig`: warnings
  are buffered per directory (`ed.warning` = the `""` bucket, `ed.warningIn(dir, …)`),
  flushed from `Editor.frameEnd` before the live-tag sweep into the window
  `dir/+Errors` (or `+Errors`) found by `lookFile` or minted in the **rightmost**
  column (R-P12b-5), `filemenu=false` (no Undo/Redo tag words, wind.c:505), not dirty.
  The two-strike `Del` warning is therefore finally visible in the UI.

## Files

New: `src/core/place.zig` (181 pre-test), `src/core/errors.zig` (182), `src/core/exec/cmd_look.zig` (96).
Changed: `Editor.zig` (+~60 impl lines: `activecol`, warning buckets, flush call, `dropColRef`; now 824 pre-test lines — the carve-out debt stands), `exec/cmd_window.zig` (placement moved out; 160 pre-test), `exec/builtins.zig` (13 entries), `Window.zig` (`filemenu`), `Row.zig` (`dropColRef` on close), `served/fsys.zig` (`new` → `makeNewWindow`), `text/typing.zig` (K-runes `pub`), `core.zig`, `accept.zig`, plus the mechanical `ed.warnings.items` → `ed.warningText()` rename in 6 files.

## Deviations from the contract (all cited in-code, all accepted in review)

1. `makeNewWindow`/`mintWindow` in `core/place.zig`, not `exec/cmd_window.zig` (the
   contract's own escape hatch; keeps cmd_window under the cap with T10-T14 present).
2. `flushWarnings(ed)` takes no `Display` (permitted); with `ed.row == null` buckets stay
   pending (keeps ~20 headless warning tests valid).
3. `dirName` reads `body.file.name`, not `parsetag` — identical in v1 (no rename path).
4. `cleanname` ported only as "strip one trailing `/`, keep root" (look.c:454-465 `.`/`..`
   collapsing deferred, T17 pins the behavior).
5. The C's fatal `error("can't make column")` (util.c:96, :462) → `error.IoError`; in
   `flushWarnings` an unplaceable bucket is dropped (`catch continue`) rather than
   failing the frame (review nit, applied by the orchestrator).
6. `activecol` is nilled on `Row.close` only, not on bare tree teardown (never
   dereferenced there).

## Frozen hashes (R-P2-7)

- **FROZEN-ACCEPT-9 re-frozen** (R-P12b-6): `0xb52b86b54d50d100` → `0x8ca565d7961f44cf`.
  Spot-check (asserts precede the hash in the scene): the phase-9 two-strike `Del`
  now grows exactly one extra window after `frameEnd`, named `+Errors`, body
  `"notes modified\n"`, `dirty == false`, `filemenu == false`, `warningsPending() ==
  false`, in the rightmost column; every pre-existing assertion still runs unchanged
  before the flush.
- **FROZEN-ACCEPT-12B** new: `0xa4af36d064fbd9c9` — scene `phase-12b: +Errors scene —
  two-strike Del warning surfaces in the rightmost column` (two columns; dirty window
  in column 0; the warning lands in column 1). Spot-checks precede the hash.

## Pipeline (user's standing pattern, first full run)

fable design + test spec (contract §3/§4) → **opus** coded §3 (4 commits, suite green,
flagged the hash change instead of re-freezing) → **sonnet** wrote T1-T23 (21 new test
blocks; T14's setup adjusted, honestly — the precondition `Dy(t.w.r) > 2/3 Dy(bigw.r)`
is asserted before the call) → **sonnet** ran the gate independently (twice) → **fable**
reviewed the full diff against the C and the contract: PASS with two non-code blockers
(this report; rebase-free `--no-ff` merge onto the moved `main`) and two nits (vacuous
assert in T13; per-bucket `catch continue`), both applied by the orchestrator.

## Deferred / next

- `colgrow` (cols.c:333+): the `maxlines < 2` arm after `makeNewWindow` (R-P12b-3).
- `errorwinforwin` callers (`warningIn` with a real directory) arrive with external
  commands / Edit `<|>` pipes; `openfile`/`plumblook` will call `makeNewWindow(t)`.
- `textbsinsert` backspace processing on `+Errors` output (plain insert today).
- `Editor.zig` carve-out (gesture machine) — unchanged debt, now 824 pre-test lines.
