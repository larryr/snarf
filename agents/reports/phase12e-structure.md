# Phase 12e report — structure-only wave: gesture carve-out, OriginMount split, main_wasm trim, size pass

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 575/575 (573 + T5 + T6),
run twice · node smoke 26/26, all seven exports emitted · `zig fmt` clean · boundaries
clean · **no golden moved, no test renamed or dropped** (540 names identical before/after,
+2 new) · **Contract:** `agents/contracts/phase12e-structure.md` (rulings R-P12e-1..5) ·
**wasm (ReleaseSafe default):** 1648274 B = 1609.6 KiB (+4 KiB inlining noise).

Zero behavior change was the rule and the review confirmed it as a pure move: every removed
line pairs with an added one modulo the mechanical `ed.X` → `ed.gesture.X` receiver rename;
the one non-identical statement is the sanctioned `c.fids.put(…)` → `c.seedQid(…)`.

## What moved

| File | Pre-test lines main → now | What |
|---|---|---|
| `src/core/Editor.zig` | 824 → **383** | identity, forwarders, keys, frameEnd |
| `src/core/Gesture.zig` (new) | 230 | acme.c `mousethread`: gesture state struct, B1/B2/B3 arms, `hitTest`, `handleMouse`, `dropTextRefs` |
| `src/core/textselect.zig` (new) | 245 | text.c:1001-1384: the sweep loop (`run`, was `runGesture`), `chordStep`, `dispatchSel23` — entered only via `Gesture.handleMouse` |
| `src/core/snarf.zig` (new) | 68 | exec.c:947-1073 `cut`/`snarfInsert` |
| `src/core/errors.zig` | 185 → 229 | warning-bucket bodies (`warningIn`, `warnBucket`, `warningText`, `warningsPending`) |
| `src/origin/OriginMount.zig` | 466 → **319** | lifecycle, `Phase`/`Event`, constants, fail/lose/unbind |
| `src/origin/handshake.zig` (new) | 198 | `stepDialing/Versioning/Attaching/Binding`, `send/recv`, test helpers |
| `src/ninep/client.zig` | 663 → 672 (+9) | `Client.seedQid(fid, qid)` — encapsulates the fid-cache write the handshake made out of band |
| `src/main_wasm.zig` | 409 → **373** | exports + boot; `wsStage`/`wsPush` are two-line trampolines |
| `src/origin_glue.zig` (new) | 104 | ws staging + `redialOrigin` + `pollOrigin`; `consoleLog` reaches it as a `callconv(.c)` fn pointer (root keeps the extern, R-P5-6) |

Forwarders kept on `Editor` (signatures unchanged, no call site moved): `handleMouse`,
`hitTest`, `warning`, `warningIn`, `warningText`, `warningsPending`, `cut`, `snarfInsert`.
New field `ed.gesture: Gesture`. `dropTextRefs` still nils `focus/seltext/argtext` and, via
`Gesture.dropTextRefs(tag, body)`, `gesture_text` for both texts (R-P9-13 set complete).
Tests relocated with their code: Editor 39 → 24 (+15 in Gesture), OriginMount 14 → 8 (+6 in
handshake); shared harnesses made `pub` and aliased, bodies unchanged except field paths.

## Deviations from the contract's file plan (both accepted)

1. **`textselect.zig`** — the single `Gesture.zig` carve-out landed at 441 pre-test lines;
   split along the C's own mousethread / text.c boundary.
2. **`snarf.zig`** — with §3a+§3b applied `Editor.zig` was still 419; `cut`/`snarfInsert`
   (a §2-named seam) moved.
3. `fail/lose/wsReason/setReason` became `pub` for `handshake.zig`.
4. `export fn wsStage/wsPush` stayed in `main_wasm` as trampolines (only the root holds `app`
   and the `consoleLog` extern).

## Size pass (measured, default NOT changed — user decision 2026-09-14: keep ReleaseSafe)

| optimize | main@2cae711 | phase12e |
|---|---|---|
| ReleaseSafe (default) | 1 644 122 B | 1 648 274 B |
| ReleaseSmall | 198 638 B | 198 152 B |
| ReleaseFast | 1 880 540 B | 1 883 175 B |

ReleaseSmall is 8.3× smaller (194 KiB) but drops bounds/overflow checks (panics → UB). The
user chose to keep ReleaseSafe while the editor is growing fast; revisit when a remote
deploy makes download size matter (a `zig build small` artifact is the cheap middle path).

## Debt after this wave

Closed: Editor gesture carve-out (since phase 9); OriginMount over cap; `Client.seedQid`;
T11 read-error arm (T6). Remaining, untouched by design: `dev/draw.zig` 806, `client.zig`
672, `Window.zig` 536 pre-test lines (stable; split when a wave touches them); `colgrow`;
`textbsinsert` on +Errors; ASCII-only `isalnum`. Nit: `Gesture.zig` imports `exec` and
`place` (needed by the B2/B3 arms) — the only core file besides `Editor` importing `exec`.

## Pipeline

fable spec → opus (3 commits, T1–T4 self-verified, size table) → fable review PASS (run in
parallel with sonnet) → sonnet T5/T6 + contract commit → sonnet gate (twice). No fix loop
needed.
