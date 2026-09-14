# Phase 13b report — directory windows, `openfile`, `expandfile`, `Get` for directories, acme boot layout

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 620/620 (605 + 15), run twice ·
node smoke 30/30 (+1) · `zig fmt` clean · boundaries clean · **no existing golden moved;
FROZEN-ACCEPT-13B = `0x35f686fc5162d2cf` new** (two-column boot, `/` rightmost, spot-checks
precede the hash) · **Contract:** `agents/contracts/phase13b-directory-windows.md` (rulings
R-P13b-1..7) · **wasm:** 2085778 B = 2036.9 KiB (**+297 KiB** ReleaseSafe; +43 KiB at
ReleaseSmall 259394 B — genuine new code ×~7 by safety checks; debt-pass item).

R-EDIT-03 is satisfied; R-EDIT-07/13/20/23 gain their file-opening half; R-EDIT-25 holds
(no warp). The paper's directory-window workflow now runs against the real namespace.

## What works now (user-visible)

- **Boot = acme's** (acme.c:242-260): two columns; the right one holds a directory window
  on `/` — tag `/ Del Snarf Get | Look `, body `dev/	mnt/` — the left is empty. The
  `scratch` demo is gone. The listing arrives asynchronously within the first frames.
- **Directory windows** (text.c:200-275): tag name ends in `/`, entries sorted rune-wise
  (`dircmp`), directories suffixed `/`, **columnated** exactly per `textcolumnate`
  (text.c:136-198) with the narrower `TABDIR` tab width (27 px at 9×18); `filemenu` off (no
  `Put`/`Undo`), ` Get` present, `Del` never blocked, served `ctl` reports `isdir`.
- **B3 opens files and directories** (`look3` → `expandfile` → `openfile`, look.c:83-905):
  `mnt/` in the `/` window opens `/mnt/` (which lists `snarf-self/`), `index` under it opens
  the served index as a file window; `file:12`, `file:/re/`, `:/re/` (own window) select the
  address after load; relative names resolve against the clicked window's directory
  (R-EDIT-20), `wdir` = `/` for tags with no window; an already-open name reuses its window;
  a missing name ⇒ `can't open <name>: <err>` in `+Errors`, the window stays named and empty.
  A word that is not a file falls through to the literal search as before.
- **`Get` on a directory window** re-reads the listing (`Get` after the origin attaches shows
  `bin/ n/`); `Get` on a file window warns that files await the Put/Get wave (R-P13b-5).
- **`/mnt/snarf-self/ns`** renders the mount table (`ns(1)` shape).

## The one recorded divergence (R-P13b-2)

acme decides file-vs-text on a right click with a synchronous `access()`. The browser cannot
block, so Snarf parks the look: `expandfile` finds the candidate, a `StatJob` runs for one
round trip (in-memory mounts resolve on the next frame), then `openfile` or the literal
search. One pending look at a time; a newer B3 cancels the older. Documented in `look.zig`,
S-05 §6, R-02 v5 (browser-host note under R-EDIT-07, no ID change).

## Files (pre-test lines)

New: `core/dirwin.zig` 254, `core/Load.zig` ~360 (the asynchronous `textload`: StatJob →
ListDirJob/ReadFileJob, stepped from `frameEnd` before `flushWarnings`, one load per window),
`core/openfile.zig` 181, `core/expand.zig` 399 (at the cap), `exec/cmd_get.zig` 72.
Changed: `Editor.zig` 326→344 (2 fields + 3 one-line calls), `Window.zig` (`isdir`,
`dirnames`, tag `Get`, `clean`), `look.zig` (seam → `expand.startLook`), `boot.zig`
(`Options.dir_boot`), `served/fsys.zig` (`isdir`, `ns`), `builtins.zig` (`Get` row, exec.c:109),
`main_wasm.zig` 399 (at the cap), `tools/smoke_wasm.mjs` (probes moved to the right column),
docs S-05 §2/§6, S-02 §6, R-02 v5; `agents/contracts/phase13-opfs.md` → `phase14-opfs.md`.

## Deviations (all accepted in review)

1. `Editor.loads` holds `*Load` (heap) — a job's inline ticket buffer must not move.
2. `isMtpt` is an EXACT match on `/mnt/snarf-self` (the C's prefix guard only exists to stop a
   synchronous `textload` deadlocking on acme's own server; our loads are polled), so files
   under the served tree open.
3. `parse.Parser.compoundaddr` made `pub` for the deferred `:addr` evaluation.
4. No `maxtab_override` seam: only `Frame.init` writes `maxtab`, so `columnate`'s value
   survives redraws. **Pre-existing divergence logged as debt:** normal windows keep libframe's
   `frinit` default 72 px tab (acme's `textinit` sets 36); fixing it moves FROZEN-ACCEPT-3.
5. `Get` keeps the old listing on screen until the reload lands (no flash of empty).
6. Two exectab-shape tests edited for the new `Get` row; the served root-listing test updated
   (contract-sanctioned); smoke probes moved for the new boot layout.
7. Orchestrator after review: one load per window (`Load.start` drops an older load for the
   same window); dead `setqid` field removed.

## Debt / notes
`expand.zig` and `main_wasm.zig` at 399; `applyAddress` parses the whole `:addr` run where
the C stops at the first non-address rune (edge case, noted); `expandFile` drops the C's
`reverse` bookkeeping until Shift-B3 lands; wasm size (see header); normal-window `maxtab`
72 vs 36; `errors.dirName` doc vs behavior (strips the trailing `/`; callers re-add it).

## Pipeline
fable spec → opus (8 commits) → sonnet T1–T15 + FROZEN-ACCEPT-13B → fable review PASS
(parallel with sonnet; 2 nits applied by the orchestrator) → sonnet gate → merge.
