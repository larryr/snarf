# Phase 10 report — Edit language + served tree start

**Merged to main:** (this commit's merge) · **Tests:** 476/476 (`zig build test`),
node smoke 14/14 · **Contracts:** `agents/contracts/phase10-{edit,regx-addr,edit-cmd,
served}.md` (rulings R-P10-1..9 + R-P10-A..J) · **wasm:** 1504.6 KiB (was 1258 —
the whole Edit subsystem + served tree; size watch continues).

## What works now

- **The Edit command language** (S-05 §5): B2 `Edit ,s/b/X/g` in any tag/body runs
  sam's command language against the window body. v1 command set: full addresses
  (`#n`, `n`, `/re/`, `?re?`, `.`, `$`, `+`, `-`, `,`, `;` with the dot-update
  distinction), `a c i d s m t`, the loops `x y g v` (+ bare-`x` per-line), `p =`
  (to the warnings buffer), `u` (with count/sign), `\n` line navigation, `{ }`
  blocks. One Edit = ONE undo transaction (elog buffered against frozen
  coordinates, applied in reverse, marked once).
- **The structural regexp engine** (`core/edit/Regx.zig` + compile/exec): sam's
  operator-precedence compiler and Pike-VM, forward + backward machines (backward
  = reversed concatenation), classes with the negated-class-excludes-newline rule,
  groups `\1..\9`, the leftmost-then-longest match rule, wraparound only at
  infinite eof with one-lap termination.
- **`/mnt/snarf-self` served tree (start)**: a 9P client can attach, walk the
  tree (`index`, `new`, `<id>/{body,ctl,tag}`), read the byte-exact index and ctl
  lines, append to bodies, and drive ctl commands (`clean dirty del delete name` —
  del honors the two-strike). Walking `new` creates a real window. Dead windows
  answer "deleted window"/"file does not exist" exactly like acme. Proven through
  `ninep.mount.Namespace` end-to-end; runtime mounting waits for the first
  in-editor client (R-P10-E).

## Wave log

| Wave | Agent/model | Scope | Outcome |
|---|---|---|---|
| Outline | O20, O21, O22 (fable) | regx/addr, edit-cmd, served contracts | reconciled into R-P10-1..9 + A..J |
| 10a-A1 | opus | Regx engine (3 files, tests 1-23) | merged; NPROG discrepancy resolved in-contract |
| 10a-A2 | opus | ast.zig + parse.zig (+parse_text split) | merged; "unknown command" pinned at PARSE |
| 10a-A3 | opus | served fsys.zig, ctlPrint, errors, makeWindow pub | merged |
| 10b-B1 | sonnet | addr.zig evaluation (tests 24-41) | merged (one-line core.zig conflict) |
| 10b-B2 | sonnet | Elog.zig transcript | merged |
| 10b-B3 | sonnet | served xfid.zig + FileDirty + acceptance | merged |
| 10c-C1 | opus | cmd.zig + edit.zig + Edit builtin row | merged; contract test-9 expectation CORRECTED |
| 10d-D1 | opus | loop.zig: s + x/y/g/v | merged, zero corrections |

**Contract corrections by agents (verified against the C, documented):**
- 10a-A1: the list-overflow test needs ~1026 insts — a literal NPROG=1024 would
  reject it at compile; used the contract's ArrayList alternative. Also chose NOT
  to replicate a latent C bug (QUOTED bit kept on escaped class-range endpoints
  makes them match nothing; pathological input only).
- 10c-C1: the contract's `2,1d` "out of order" example was wrong — the C's check
  is strict (`a2.q1 < a1.q0`) and adjacent lines share a boundary; `3,1d` pins the
  real path. Also pinned: the C's Edit builtin passes **et's window body** to
  editcmd (never seltext), unlike Cut/Paste.

## Orchestrator incident (recorded for future gates)

The merge-gate pipeline `zig build test | grep | awk` returns the LAST pipe
stage's exit code, so `&&`-chained follow-ons ran even when the suite failed —
masked a wrong FROZEN-ACCEPT-10 constant (a shell `printf '0x%x'` mangling of a
>INT64_MAX decimal compounded it) until a forced-failure probe exposed the live
hash. All phase-10 merges were re-verified with `zig build test; echo exit=$?` +
explicit fail/crash greps: exit=0, zero failures, 476/476. Lesson in HANDOFF:
never gate on a piped test run's status; capture the run, check `$?` and grep for
failures explicitly.

## Divergences / deferrals (cited in-code)

- Deferred Edit commands: `b B D e r f w` (disk/menu — namespace phases), `X Y`
  (cross-file), `< | >` (pipes — impossible pre-namespace), `"` file-match
  (parses, evals Unsupported), `'` mark (errors as acme does). Deferred letters
  answer "unknown command" (R-P10-7).
- Elog on the per-Edit Ctx, not File (single-file v1; moves with multi-file Edit).
- Served tree: event file, addr/data/xdata (SEAM(O21) markers — need address()
  wiring into xfid), cons/label/log, rdsel/wrsel, lock/unlock all deferred with
  cites (R-P10-J). utfRead rescans from rune 0 (the C's own fallback; cache is a
  flagged seam). Body writes lose split runes to U+FFFD (no per-fid rpart carry —
  flagged divergence).
- ListOverflow surfaces as error.Edit + diagnostic vs the C's warn-and-continue
  (consistent across addr/loop; regx-level behavior pinned by its own test).

## Acceptance

- `phase-10: served tree scene` (10b-B3): client walk/read/ctl-write through the
  mount table.
- `phase-10: Edit via B2 scene — s-global, one undo, live tag` (orchestrator):
  swept `Edit ,s/b/X/g` rewrites three lines in one transaction; ` Undo` appears
  via the live-tag sweep; one B2 Undo click restores everything.
  **FROZEN-ACCEPT-10 = 0xe9014ecfa82cbc4b** (new freeze, R-P2-7; spot-checks
  first, deterministic across repeated runs).

## Debt noted

- `Editor.zig` still ~1800 lines (gesture-machine carve-out pending; now also
  carries regx/edit_lastpat fields).
- `getArg` raw bytes → filename expansion when namespace `expand` lands.
- Shift-B3 reverse look + `dot=addr`/`addr=dot` ctl commands: wiring exists
  (`reverse` params, addr()) — one small integration wave when needed.
