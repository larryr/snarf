# Phase 5 report — browser bring-up (the vertical slice complete)

Merged to `main` (revert = the one merge commit). Contract:
`agents/contracts/phase5-browser.md` (rulings R-P5-1..9). Suite: **195/195**; wasm
links freestanding; boundary negative-check verified; node smoke **13/13**.

## Delivered

Snarf runs in the browser. `zig build` emits a 921 KiB ReleaseSafe `snarf.wasm` whose
`init()` assembles the ENTIRE editor stack in-module — piece-table Buffer → File →
Text → Frame → Font (embedded misc-fixed, decompressed at boot) → 9P over an in-memory
Pipe → devdraw → canvas backend — and presents the phase-4 text scene via one `blit`
import onto a real `<canvas>`.

- `dev/draw_canvas.zig` — the thin canvas backend (zero pixel logic): wraps the
  golden-verified HeadlessBackend; flush blits the dirty rect. **Pixel-identity with
  the frozen goldens is BY CONSTRUCTION and pinned by a test** (the phase-2 scene
  through CanvasBackend reproduces FROZEN-ACCEPT `0x1a99dc0d115ae2bf` exactly).
- `shim/abi.zig` v2 — comptime-gated `blit` extern + native `test_blit` seam;
  runtime `abi_version()` mirror check in shim.js before init.
- `main_wasm.zig` — the real boot: `std.heap.wasm_allocator`, FullPanic→consoleLog→trap,
  the one sanctioned module-level App context (P-3 analog of main_native's frame,
  absorbed by future core/boot.zig).
- `web/shim.js` + `index.html` — env.blit (putImageData with dirty-rect args),
  env.consoleLog, ABI check, fixed 640×480 canvas.
- `tools/smoke_wasm.mjs` — manual node smoke (never wired into zig build; R-BLD-02
  intact): **13/13 pass** against the real binary — exports, ABI v2, init without
  trap, one blit with correct dims, dirty rect covering the text, and pixel
  spot-checks (white ground, inked 'h' cell) read directly from wasm memory.

## Key insight of the phase (O9)

The "full" S-03 §3 per-image OffscreenCanvas design would have FAILED the phase goal:
canvas compositing cannot reproduce the integer-exact CALC11/12 (+128) rounding the
frozen goldens pin. The software-composite wrapper isn't a shortcut — it is the only
correct v1. S-03 §3 carries a revision note; per-image canvases become a later
performance phase.

## Flagged divergences (reviewable; spec revision notes committed)

1. **Main-thread wasm** (S-00 §2 mandates a Worker): accepted for bring-up — nothing
   exists to block on yet; Worker + SAB rings land with devinput; the ABI survives
   the move unchanged. (S-00 revision note.)
2. **One merged blit import** supersedes S-06 §4's blit+flush pair; consoleLog added
   as the panic sink. ABI checked at runtime; OQ-BLD-2 codegen still deferred.
   (S-06 revision note.)
3. Fixed 640×480; canvasResize + devicePixelRatio (R-GFX-05) deferred to the input
   phase. Demo scene in main_wasm is temporary bring-up code (future core/boot.zig).
4. SAB caveat recorded: ImageData rejects shared buffers — the blit path needs a copy
   or the Worker/OffscreenCanvas route once SAB mode lands.

## Verification note

Browser eyeball: the Chrome-extension screenshot was unavailable in this session; the
node smoke's pixel assertions against the actual binary stand in. **Manual step for
Larry**: `zig build serve` → http://127.0.0.1:8017/ → expect "hello, acme wraps" /
"second line⇥tab" (2 lines, tab gap) in misc-fixed 9x18, black on white, top-left at
(20,20) of a 640×480 canvas. (A server was left running at the time of this report.)

## The vertical slice, complete

Phases 1→5: 9P core → rectangle → glyph → text-from-a-buffer → browser. Every layer
contract-built by concurrent agents from pinned C sources, golden-verified natively,
and composed first-try at every phase boundary. 195 tests; 5 frozen scenes.

## Next (per plan Part A, re-planned in detail next)

Phase 6+: devinput (mouse/kbd + chord emulation, Worker+SAB move, blocking reads +
Tflush wait queues), typing/selection, Window/Column/Row, Edit language, served tree.
