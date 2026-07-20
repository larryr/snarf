# Phase 6 report — interactive editing

Merged to `main` (revert = the one merge commit). Contracts:
`agents/contracts/phase6-input{,-ninep,-devinput,-editing}.md` (rulings R-P6-1..12).
Suite: **259/259**; smoke **14/14** (including a real injected keystroke); boundary
negative-check verified.

## Delivered — Snarf is an editor now

Click into the canvas to place the typing tick, type to insert, backspace to delete,
B1-sweep to select — in the browser, through the real pipeline: DOM event → shim →
pushEvent → devinput chord machine → 49-byte /dev/mouse records & /dev/kbd runes →
parked 9P reads completing → client tickets → Editor state machine → Text
typing/selection → frame surgery → devdraw → canvas.

- **ninep**: parked-read wait queue with kernel-style re-run completion +
  `flush(5)`-exact Tflush interruption (the phase-1 deferral, retired); client read
  TICKETS (beginRead/checkRead/cancelRead) with rpc tag-dispatch — fixing a
  would-have-hung-the-tab spin that O11 caught in review.
- **devinput**: /dev/mouse (byte-exact devmouse.c records) + /dev/kbd (UTF-8 rune
  stream) + ctl; S-04 §5 coalescing (transitions never dropped); native + modifier
  profiles with the 11-row chord state machine. **R-IN-02 proven**: an emulated
  Alt-chord's wire bytes are identical to a hardware chord's.
- **frame**: frdelete in full; frselect reified as an incremental SelectState (the
  blocking C loop can't exist in a threadless module); the real typing tick.
- **core/text**: texttype/textsetselect subset; run-scoped undo grouping (T-1 —
  verified against acme's cache semantics; one transaction per typing run).
- **Editor**: the event-routing state machine (idle/sweeping), natively testable;
  main_wasm boots an EMPTY buffer in the acme palette — content now comes from typing.

## The architecture correction (R-P6-1 — supersedes two phase-5 promises)

O11's keystone finding: per-file blocking reads are wrong under EVERY execution mode —
a single-threaded module must select over mouse+kbd; Atomics.wait inside one device
read wedges everything. S-00 §2's original sentence is CORRECTED (revision log
committed): async mode with tickets IS the architecture; the future Worker move is a
transport swap + one blocking point at the top of the editor loop, throwing away
nothing built here.

## Wave C notes

- 4-agent 6a wave (widest yet) merged clean; A1 discovered the pre-authorized
  ReadError ripple was unnecessary (Zig error-set covariance in return position).
- A2 found and fixed a latent lazy-analysis type bug in merged client.zig.
- Both acceptance scenes (FROZEN-ACCEPT-6a sweep-highlight, 6b typing-tick) passed
  their pixel pins first-composition. Frame-resync-on-undo is a documented deferral
  (the future Text-observer hook); undo/redo currently mutate the File only.
- wasm: 1.08 MiB (crossed the phase-5 ~1 MiB investigate line — input stack growth;
  ReleaseSafe; acceptable, watch it).
- Ops fix during close-out: a `git add -A` briefly staged agent worktrees; amended out
  and `.claude/` is now gitignored.

## Deferred (tracked)

touch/chordbar profiles (R-05 v1 list), IME (R-IN-11), Keyboard Lock, /dev/cons,
double-click word-select + B2/B3 chords/exec/look (next phases), scroll (org fixed;
wheel ignored), Worker+SAB move, frame resync on undo, canvasResize/DPR.
