# Phase 12c report — the display fills the browser window and follows resizes (R-GFX-05, DPR 1)

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 557/557 (`zig build test`,
was 547 + 10 named), run twice · node smoke 25/25 (was 20; +5 resize/ABI checks) ·
`zig fmt` clean · boundary clean · **no golden hash moved** (R-P12c-3) · **Contract:**
`agents/contracts/phase12c-canvas-resize.md` (rulings R-P12c-1..6) · **wasm:** 1629492 B =
1591.3 KiB (+10 KiB). User request 2026-09-14: "enlarge the default usable space to the
current browser window's size."

## What works now

- **Boot fills the window.** `web/shim.js` sizes the canvas to `innerWidth×innerHeight`
  (CSS px = device px, DPR 1) *before* calling the new **`init(w, h)`**; `main_wasm`
  builds the backend and the row over that rect. The fixed 640×480 (R-P5-3) is gone from
  the page; the goldens keep their own 640×480 harnesses.
- **Live resize** = acme's `MResize` (acme.c:548-555): the shim coalesces window
  `resize`/`orientationchange` to one `pushEvent(EventKind.resize=8, w, h)` per animation
  frame (same size ⇒ skipped); the module reallocates the framebuffer
  (`HeadlessBackend.resize`), posts the exposure (`DevDraw.noteResize`), re-reads the draw
  `ctl` line like libdraw `getwindow` (`Display.getWindow`, init.c:149-174), white-fills
  and runs `rowresize` (`Tree.resize` → `Row.resize`). Columns scale proportionally, text
  reflows, typing still lands under the pointer.
- **`refresh` file** (S-03 §5 device half): a one-shot 16-byte LE rect after a resize, 0
  bytes otherwise — non-blocking until phase 13's parked reads (R-9P-13).
- **ABI v5**: `init(w,h)` + `EventKind.resize`; S-03 §5 and S-06 §4 carry revision-log
  entries.

## Files

New: `src/screen.zig` (71 — the resize sequence + display-size clamps), `src/input_pump.zig`
(83 — the device drain, moved out of main_wasm to stay under the cap; main_wasm 412→403).
Changed: `web/index.html`, `web/shim.js`, `tools/smoke_wasm.mjs`, `src/shim/abi.zig`,
`src/dev/draw_backend.zig`, `src/dev/draw_canvas.zig`, `src/dev/draw.zig`,
`src/draw/Display.zig`, `src/core/boot.zig` (`Tree.resize`, 427 lines with tests — first
time over the soft cap, test growth), `src/core/Row.zig`, `docs/spec/03-draw-device.md`,
`docs/spec/06-build-toolchain.md`.

## Deviations from the contract (all accepted in review)

1. **Per-column width floor in `Row.resize`** (the substantive one). The contract's 100 px
   screen clamp was not enough: proportional scaling of a 3-column row gave ~16 px columns
   and libframe traps below ~25 px (`frinsert pt1 too far`, frinsert.c:169-170). Each
   column is now floored at `scrollwid+scrollgap+font.height` after the border band; the
   floor cascades and may clip the rightmost columns off-screen instead of trapping. It
   never binds above `rowadd`'s 100 px minimum (rows.c:74-75), so no golden moved.
   Documented as a Snarf divergence with cites.
2. `screen.zig`/`input_pump.zig` split kept (both headers state ownership).
3. Spec revision-log entries added (doc convention, not requested).
4. Inherited `init.c`/`rows.c` cite line numbers corrected; `Tree.resize` doc corrected to
   record the measured horizontal limit.
5. T5/T10 live in `src/accept.zig`, not `draw/Display.zig`: `draw`'s test build has no
   `dev` (G7 independence) — the contract's table was wrong.
6. T6 asserts the body reaches within one line of the bottom, per `Text.resize`'s
   whole-line quantization (text.c:80-81), not the exact pixel.
7. Review nit applied by the orchestrator: `installResize` fires once after installing its
   listeners so a resize between `init(w,h)` and the listeners is not missed.

## Deferred (recorded)

- **R-P12c-6 — HiDPI half of R-GFX-05**: backing store = CSS pixels; Retina stays soft.
  Crisp text needs a 2× bitmap font asset (phase-3 lineage). On the ADR-0005 native host
  `devdraw` handles it for free.
- `boot.zig` 427 / `Row.zig` 509 lines: debt, not split in this wave.
- Manual check for Larry (§5.4): `make run`, drag the window edge.

## Pipeline

fable spec → opus (interrupted once, resumed by a fresh agent from the staged state; 1
commit) → sonnet tests (10 blocks, 1 skipped-none) → sonnet gate (twice) → fable review
PASS with two non-code blockers (this report; merge onto moved `main`) + one shim nit.
