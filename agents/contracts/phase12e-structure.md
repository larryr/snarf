# Phase 12e contract — structure-only wave: gesture carve-out, OriginMount split, main_wasm trim, size pass

Status: **binding once fable signs §3.** Branch `phase12e` (worktree `../snarf-wt/phase12e`),
based on `main@2cae711`. Requirement served: S-07 (soft cap ~400 pre-test lines per file,
file-as-struct, one type per file). User direction 2026-09-14: "do all recommendations in
sensible order" — this is recommendation 1 (structure, hash-guarded) plus the two small
items that live in files this wave already touches (recommendation 2's `Client.seedQid`
and the T11 read-error test) and the size measurement (recommendation 5).

**The one rule of this wave: zero behavior change.** Every FROZEN-ACCEPT hash, every test
name, every public signature used outside the file being split stays identical. A hash
that moves is a defect, not a re-freeze candidate (R-P12e-1).

Pipeline: fable spec → **opus** moves code → **sonnet** verifies + adds the two tests →
**sonnet** runs the gate → **fable** reviews the diff as a pure move → loop.

## 1. Measured state (`main@2cae711`)

| File | Pre-test lines | Target |
|---|---|---|
| `src/core/Editor.zig` | 825 (39 tests) | ≤ 400 |
| `src/origin/OriginMount.zig` | 467 (14 tests) | ≤ 400 |
| `src/main_wasm.zig` | 409 (no tests) | ≤ 400 |
| `src/core/Row.zig` | 380 | untouched |
| `src/dev/draw.zig`, `src/ninep/client.zig`, `src/core/Window.zig` | 806 / 663 / 536 | **untouched this wave** (stable, not on the path — recommendation 3) |

Wasm: 1 643 275 B, built `ReleaseSafe` by default (`build.zig:67-69` maps Debug→ReleaseSafe).

## 2. Seams (read the files; these are the observed boundaries)

`Editor.zig`: fields 73-218 mix editor identity (`allocator, seq, in_typing_run, text, row,
focus, seltext, argtext, activecol, snarf, edit_lastpat, warnings, origin, needs_flush,
regx`) with **gesture-machine state** (`gesture_text, mouse_pt, scroll_but, mouse_state,
chord_state, chord_buttons, press_pt`, and whatever else the arms use — verify by reading
`handleMouse`/`runGesture`/`chordStep`). Functions: warnings 236-283 (`warning, warningIn,
warnBucket, warningText, warningsPending`); `dropTextRefs/dropColRef` 285-303; `cut,
snarfInsert` 316-361; `Region/Hit/hitTest` 362-393; **gesture machine 394-697**
(`handleMouse, runGesture, dispatchSel23, chordStep`); `handleKey` 698; `frameEnd` 723.
Gesture state is referenced outside Editor.zig only by `src/accept.zig` (14 tests).

`OriginMount.zig`: constants + `Phase`/`Event` 65-143; lifecycle `init/deinit/dial/push/poll`
145-239; **handshake steps 240-336** (`stepDialing, stepVersioning, stepAttaching,
stepBinding`); accessors 337-355; `send/recv` 356-372; `fail/lose/wsReason/setReason/unbind`
373-426; test helpers 427-466 (`feed, feedBinWalk, bringUp, bringUpBin`). `stepAttaching`
writes `c.fids.put(...)` into the Client's cache directly (12d review nit b).

`main_wasm.zig`: exports `abi_version/init/wsStage/wsPush/pushEvent/wake/tick`; App struct
95-145; `boot` 159-250; origin glue `redialOrigin` 251, `wsStage/wsPush` 262-311 (+
`stage_cap`), `pollOrigin` 399-409.

## 3. CONTRACT

### 3a. `src/core/Gesture.zig` (new, file-as-struct) — the mouse gesture machine

- A `Gesture` struct holding ALL gesture-machine state moved out of `Editor`:
  `mouse_state`, `chord_state`, `chord_buttons`, `press_pt`, `mouse_pt`, `scroll_but`,
  `gesture_text`, plus any private helper state the arms use (verify). Field docs move
  with the fields, verbatim.
- Methods moved verbatim (bodies unchanged except `ed.X` → `ed.gesture.X` for moved
  fields, or `g.X` inside methods that receive `g: *Gesture`): `handleMouse`,
  `runGesture`, `dispatchSel23`, `chordStep`, `hitTest`, `Hit`, `Region`, `ptInRect`.
  Recommended shape: `pub fn handleMouse(g: *Gesture, ed: *Editor, ev: Editor.MouseEvent) !void`.
- `Editor` keeps a field `gesture: Gesture = .{}` and a **one-line forwarder**
  `pub fn handleMouse(ed: *Editor, ev: MouseEvent) !void { return ed.gesture.handleMouse(ed, ev); }`
  so `accept.zig`, `main_wasm`/`input_pump`, and every existing test keep compiling with no
  call-site change. `Editor.MouseEvent`, `Editor.Region` remain exported from Editor (alias
  `pub const Region = Gesture.Region;`) if anything outside references them (grep).
- `dropTextRefs` must still nil `gesture_text` — it now lives in `ed.gesture`; keep the
  hygiene set complete (R-P9-13).
- The 39 Editor tests: those that exercise the gesture machine move to `Gesture.zig` with
  their `Harness`; those about warnings/undo/keys stay. Test NAMES do not change (sonnet
  verifies the before/after name list is identical). References `ed.mouse_state` etc. in
  moved tests and in `accept.zig` become `ed.gesture.mouse_state`.
- Cite: `acme.c` mousethread (the machine's origin) stays in the moved doc comments.

### 3b. `Editor.zig` warnings → `src/core/errors.zig`

- Move the bodies of `warningIn`, `warnBucket`, `warningText`, `warningsPending` into
  `errors.zig` (`pub fn warningIn(ed: *Editor, dir, fmt, args)` …). Keep one-line
  forwarders on `Editor` with the SAME names and signatures (`ed.warning(...)`,
  `ed.warningIn(...)`, `ed.warningText()`, `ed.warningsPending()`) — 20+ call sites and tests
  depend on them. `errors.zig` must stay ≤ ~400 pre-test lines after the move; if not,
  put the bucket functions in `src/core/warnings.zig` instead and say so.

### 3c. `src/origin/handshake.zig` (new, namespace module) — the 9P handshake steps

- Move `stepDialing`, `stepVersioning`, `stepAttaching`, `stepBinding`, `send`, `recv` and the
  test helpers `feed`, `feedBinWalk`, `bringUp`, `bringUpBin` (as `pub` test-section helpers
  or a `pub const testing = struct{…}` namespace) into `handshake.zig`, taking
  `self: *OriginMount`. `OriginMount.poll` dispatches to `handshake.step*`. `Phase`, `Event`,
  constants, lifecycle, `fail/lose/unbind/reason*` stay in `OriginMount.zig`.
- **`Client.seedQid(fid, qid)`** added to `src/ninep/client.zig` (a 5-line public method
  that inserts/overwrites the fid-cache entry, doc: "the Rattach/Rwalk qid a hand-driven
  handshake learned out of band — see origin/handshake.zig"); `stepAttaching` calls it
  instead of touching `c.fids`. This is the ONLY behavior-adjacent change; it is a pure
  encapsulation (same map write). `client.zig` gains ≤ 10 lines.
- The 14 OriginMount tests keep their names; those that only exercise the handshake may
  move to `handshake.zig`.

### 3d. `src/main_wasm.zig` trim

- Move `wsStage`, `wsPush`, `stage_cap`, `redialOrigin`, `pollOrigin` into
  `src/origin_glue.zig` (namespace module beside `screen.zig`/`input_pump.zig`) — the
  `export fn`s can live there as long as the module is referenced from `main_wasm` so they
  are emitted (verify with `zig build` + the smoke script's export checks; if an export in a
  non-root file is not emitted, keep a one-line `export fn` trampoline in main_wasm and
  move only the bodies). Header comment states what the file owns.

### 3e. Size pass (measure, do NOT change the default)

- Build the wasm at `-Doptimize=ReleaseSafe` (default), `ReleaseSmall`, `ReleaseFast`; record
  bytes for each in the report. If `wasm-objdump`/`twiggy` are unavailable (likely), add a
  coarse per-module estimate by building with `-Dstrip` variants only if the build exposes
  it — otherwise just the three sizes. Note that ReleaseSmall/Fast drop safety checks
  (overflow/bounds → UB) so switching the default is a user decision, not this wave's.

### 3f. Rulings

- **R-P12e-1** Zero behavior change: no FROZEN hash moves, no test renamed or dropped (count
  and name list identical or larger), no public signature used across files changes
  (forwarders keep `Editor.handleMouse/handleKey/frameEnd/warning*`, `OriginMount.poll/
  dial/push`, all `export fn` names). A hash move ⇒ STOP and report.
- **R-P12e-2** Moves are verbatim: doc comments and C cites travel with their code;
  diff-review must be able to pair each removed block with an added one.
- **R-P12e-3** Every touched file ≤ ~400 pre-test lines after the wave: `Editor.zig`,
  `Gesture.zig`, `errors.zig` (or `warnings.zig`), `OriginMount.zig`, `handshake.zig`,
  `main_wasm.zig`, `origin_glue.zig`, `client.zig` (already over — may grow by ≤ 10 lines
  for `seedQid`; do not split it this wave).
- **R-P12e-4** Boundaries unchanged: `core` imports nothing from `dev`/`shim`/`origin`;
  `ninep` imports std + itself; `Gesture.zig` imports only core siblings + `draw`.
- **R-P12e-5** `zig fmt` clean; no globals introduced (the `App` pointer in main_wasm is the
  pre-existing sanctioned one; `origin_glue` reaches it through a passed `*App`, not a new
  global).

## 4. Named tests / verifications (sonnet)

| # | Where | Check |
|---|---|---|
| T1 | gate | All FROZEN-ACCEPT literals byte-identical (`git diff main -- src/accept.zig | grep FROZEN` empty) and every accept scene passes. |
| T2 | gate | `grep -rhn '^test "' src | sort` before (on `main`) and after: the after-list ⊇ the before-list, same count + 2 (T5, T6 below). Report the diff. |
| T3 | gate | Pre-test line counts of every file in R-P12e-3 ≤ 400 (`awk '/^test "/{print NR; exit}'`); `client.zig` grew ≤ 10. |
| T4 | gate | `grep -rn 'mouse_state\|chord_state\|gesture_text' src` outside `Gesture.zig`/tests only appears as `ed.gesture.` (no stray field left on Editor). |
| T5 | `client.zig` | `Client.seedQid(fid, qid)`: after seeding, a `walk` with zero names (clone) on that fid reports the seeded qid; overwriting an existing entry replaces it. |
| T6 | `nsdir.zig` | 12d nit (c): a union member whose directory OPEN succeeds but READ fails is skipped — the other member's entries still arrive (sysfile.c:340 `catch 0` arm). Add a `FailReadTree`/server fixture in the test section. |
| T7 | report | Size table (ReleaseSafe/Small/Fast bytes) present in `agents/reports/phase12e-structure.md`. |

## 5. Gate (fable)

1. `zig build test --summary all` to a file, `$?==0`, 0 failures, twice; `zig fmt --check`;
   `zig build`; `node tools/smoke_wasm.mjs` (all export checks green); boundary greps empty.
2. T1–T4 as shell evidence in the runner's report.
3. Review reads the diff as a pure move: each removed block pairs with an added block.
4. Report `agents/reports/phase12e-structure.md`; HANDOFF: Editor carve-out debt CLOSED,
   OriginMount cap restored, size table recorded, remaining debt list updated.
