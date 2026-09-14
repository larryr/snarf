# Phase 12c contract — the display fills the browser window and follows resizes (R-GFX-05, DPR 1)

Status: **binding once fable signs §3.** Branch `phase12c` (worktree `../snarf-wt/phase12c`),
based on `main@0270598`. Requirement: R-GFX-05 (resize + HiDPI) — this wave delivers the
**resize** half at devicePixelRatio 1; the HiDPI half is deferred by ruling R-P12c-6.
Spec: S-03 §5 (resize & refresh). User request 2026-09-14: "have the default usable space
enlarged to the current browser window's size."

Pipeline (standing pattern, see phase 12b): fable spec → **opus** codes §3 → **sonnet**
writes §4 tests → **sonnet** runs the gate → **fable** reviews → loop.

## 1. Ground truth

| Item | Where | What |
|---|---|---|
| acme resize | `acme.c:548-555` (pinned `larryr/plan9port@337c6ac`) | `MResize`: `getwindow(display, Refnone)` re-attaches the screen image (re-reads the draw `ctl` line); white-fill `screen->r`; `iconinit()` (palette solids — ours are 1×1 repl, nothing to do); `scrlresize()` (scrollbar temp image — ours has none); **`rowresize(&row, screen->clipr)`**. Nothing else: no per-window logic, columns scale proportionally (rows.c:103-138, already ported as `Row.resize`). |
| libdraw `getwindow`/`gengetwindow` | `src/libdraw/getwindow.c` (p9p) | re-reads the display info line and rebinds `display->image`/`screen` to the new rect; `Refnone` = no backing store. |
| devdraw ctl line | S-03 §1, `src/draw/Display.zig:69-106 parseConnInfo` | 12 fields; fields 4-7 = display image rect, 8-11 = clipr. `Display.init` reads it once; there is no re-read. |
| Current fixed size | `main_wasm.zig:48-55` (`width=640,height=480`, `screen_rect`), `web/index.html:11,15`, `web/shim.js:72-73,224-230`, `tools/smoke_wasm.mjs:25-26` | R-P5-3 froze 640×480 for the goldens. The goldens live in `src/accept.zig` and build their OWN headless backends — they do not depend on main_wasm's size. |
| Backend | `src/dev/draw_backend.zig:396+ HeadlessBackend` (`width,height,fb,display_clipr,dirty`), `src/dev/draw_canvas.zig` (`CanvasBackend` wraps Headless, `blit(ptr,fbW,fbH,x,y,w,h)` on flush) | no resize today. |
| ABI | `src/shim/abi.zig:22 version=4`, `EventKind` 1..7, `web/shim.js:12 ABI_VERSION=4`, `export fn init()` (no args), `pushEvent(kind,a,b,c,t)` | |
| Shim blit | `web/shim.js:131-135` `putImageData(new ImageData(pixels, fbW, fbH), 0,0, x,y,w,h)` | dims come from the module each blit — already size-agnostic. |

## 2. Merged reality

Everything below the row already handles arbitrary rects (`Row.resize`, `Column.resize`,
`Window.resize`, `Text.resize`; phase-8 `boot.boot(alloc, d, font, r, …)` takes the rect).
The screen is fixed only at three places: the backend framebuffer, the `Display` image
rect read once at init, and the shim's canvas/CSS. Input coordinates are canvas-relative
CSS pixels and stay valid at DPR 1.

## 3. CONTRACT

### 3a. Shim + page (`web/index.html`, `web/shim.js`) — ABI **v5**

- CSS: `html, body { margin:0; height:100%; overflow:hidden }`, `canvas { display:block;
  width:100vw; height:100vh; image-rendering: pixelated }`. Remove the 640/480 attributes.
- At load: `const w = window.innerWidth, h = window.innerHeight` (integers, min 1); set
  `canvas.width = w; canvas.height = h` (backing store = CSS pixels ⇒ DPR 1, R-P12c-6);
  call **`init(w, h)`**.
- On `window` `resize` (and `orientationchange`): coalesce to one per animation frame;
  if the size changed: set `canvas.width/height` (this clears the canvas — the module
  repaints everything), then `pushEvent(EK.resize /* 8 */, w, h, 0, msec)`.
- Pointer coordinates unchanged (`xyOf` is canvas-relative; CSS px == device px at DPR 1).
- `ABI_VERSION = 5`; comment the 4→5 reason (`init(w,h)` + `EventKind.resize`).

### 3b. ABI (`src/shim/abi.zig`)

- `version = 5`. `EventKind.resize = 8` with a doc comment: `a=width b=height` in device
  pixels, `c` unused. Extend the "integer values match the shim mirror" test.

### 3c. Device backend (`src/dev/draw_backend.zig`, `src/dev/draw_canvas.zig`)

```zig
/// Reallocate the framebuffer to `w×h` (zeroed), reset `display_clipr` to the new
/// bounds, drop nothing else (image ids survive), and mark the WHOLE screen dirty so
/// the next flush repaints everything (the canvas was cleared by the size change).
pub fn resize(self: *HeadlessBackend, w: u32, h: u32) Error!void
```
- `displayInfo()` must report the new rect afterwards (this is what the `ctl` line is
  built from — verify where DevDraw composes it and that nothing caches the old size).
- `CanvasBackend.resize(w,h)` forwards. Any per-image pixel store whose rect is the
  screen (image id 0 / the display image) is the framebuffer itself — verify how the
  headless backend represents image 0 and keep it consistent after resize.

### 3d. Draw device (`src/dev/draw.zig`) — `refresh` exposure (S-03 §5, device half)

- DevDraw keeps `pending_refresh: ?Rect`. After a backend resize (a new
  `pub fn noteResize(self: *DevDraw, r: Rect)` called by main_wasm right after
  `canvas.resize`), set it to the full new screen rect.
- Reading `refresh` returns the pending rect once as 16 bytes (`x0 y0 x1 y1`, little-endian
  i32 each, the S-03 wire rect encoding used elsewhere in the file — match it) and clears
  it; with nothing pending it returns 0 bytes as today (**non-blocking** — the blocking
  long-poll is phase 13's parked-ops work; cite R-9P-13 and say so in the doc comment).
- `ctl` reads must reflect the new display rect (they are composed from `displayInfo`
  — verify, don't assume).

### 3e. Client (`src/draw/Display.zig`)

```zig
/// libdraw `getwindow(display, Refnone)` (getwindow.c): re-read the ctl line and rebind
/// the display image rect/clipr to what the device now reports. Returns the new clipr.
pub fn getWindow(self: *Display) Error!proto.Rect
```
- Re-read `ctl` through the existing client fid (keep the fid open or re-walk — follow
  how `init` reads it); `parseConnInfo`; assign `self.image.r` and `self.image.clipr`.
  No image reallocation: the display image is id 0 on the device.

### 3f. Core (`src/core/boot.zig`, `src/core/Row.zig`, `src/core/Editor.zig`)

```zig
/// acme.c:548-555 MResize after getwindow: white-fill the new screen rect, then
/// `rowresize(&row, screen->clipr)`. iconinit/scrlresize have no Snarf analog (1×1 repl
/// solids; no scroll temp image) — say so in the comment.
pub fn resize(tree: *Tree, r: Rect) !void
```
- Calls `screen.draw(r, white)` then `row.resize(r)`. Verify `Row.resize` tolerates a
  SMALLER rect (columns narrower than 100 px, windows shorter than a tag line): it must
  not error out or index past the end; if `Column.resize`/`Window.resize` need a clamp
  that the C has (cols.c:235-272 `colresize`, wind.c `winresize` safe/buggered logic),
  port it with cites; if the C itself misbehaves at absurd sizes, clamp the rect in
  `Tree.resize` to a minimum of (`3*font.height + 2*border`) tall and `100` wide, and
  document that as a Snarf divergence.
- `Editor`: nothing new except `needs_flush = true` after a resize (via the caller).

### 3g. Entry point (`src/main_wasm.zig`)

- `export fn init(w: u32, h: u32)`; `boot(w,h)`: backend `CanvasBackend.init(alloc, w, h)`,
  `screen_rect = (0,0,w,h)`. Remove the `width/height` constants (keep the R-P5-3 note as
  history in a comment).
- `pushEvent` case `.resize`: `a.canvas.resize(w,h)`, `a.dd.noteResize(rect)`,
  `const r = try a.display.getWindow()`, `try a.tree.resize(r)`, `a.editor.needs_flush =
  true`. Errors here are fatal like `error("attach to window")` (acme.c:550) — panic
  with the error name as the other export paths do.
- Sizes are clamped to `>= 1`; a resize to the same size is a no-op.

### 3h. Smoke (`tools/smoke_wasm.mjs`)

- Call `init(FB_W, FB_H)` with 800×600 (not 640×480 — proves the size is honored) and
  assert the first blit's `fbW/fbH` are 800×600. Then `pushEvent(8, 1024, 768, 0, t)`,
  `tick()`, and assert a later blit reports 1024×768 and covers the full screen.
  Update `ABI_VERSION` there too (it checks `abi_version()`).

### 3i. Rulings

- **R-P12c-1** The editor path is main_wasm-driven (shim resize event → getWindow →
  Tree.resize); the `refresh` file is the device-side S-03 §5 contract for OTHER clients
  and is non-blocking in this wave.
- **R-P12c-2** `New`/window geometry rules are untouched; only `Row.resize` runs.
- **R-P12c-3** No golden hash changes are expected (accept scenes own their 640×480
  backends). If one changes, STOP and report — do not re-freeze.
- **R-P12c-4** `core` imports nothing from `dev`/`shim`; `src/draw` stays a pure 9P client.
- **R-P12c-5** No new globals; `zig fmt` clean; files ≤ ~400 lines (main_wasm is a
  non-core entry point but still split if it crosses the cap).
- **R-P12c-6 (DEFERRED, needs a user decision later)** devicePixelRatio > 1: the bitmap
  font has one size, so a DPR-scaled backing store would halve the text's physical size on
  Retina. This wave keeps backing store = CSS pixels (browser upscales; slightly soft on
  Retina, same as today). Crisp HiDPI needs a 2× font asset (phase-3 lineage) — record as
  the remaining half of R-GFX-05 in HANDOFF.

## 4. Named tests (sonnet)

| # | Where | Test |
|---|---|---|
| T1 | `draw_backend.zig` | `HeadlessBackend.resize(800,600)` from 640×480: `fb.len == 800*600*4`, all zero, `display_clipr == (0,0,800,600)`, `displayInfo()` reports the new rect, `dirty` covers the whole screen. Shrink to 320×200 likewise. |
| T2 | `draw_backend.zig` | Images allocated before the resize are still present and drawable after it (alloc id 5, resize, draw id 5 onto the screen — no error). |
| T3 | `dev/draw.zig` | After `noteResize`, a `ctl` read parses (via `Display.parseConnInfo`) to the new display rect and clipr. |
| T4 | `dev/draw.zig` | `refresh` read returns the 16-byte rect exactly once after `noteResize`, then 0 bytes; with nothing pending, 0 bytes. |
| T5 | `draw/Display.zig` | Against a live DevDraw over the pipe (pattern: the phase-2/3 tests in `draw.zig`): resize backend + `noteResize`, `getWindow()` returns `(0,0,800,600)` and `display.image.r/clipr` equal it. |
| T6 | `core/boot.zig` | Boot at 640×480, `tree.resize((0,0,1024,768))`: `row.r` is the new rect, the single column spans the full width, the window's body reaches the bottom, no rect exceeds the screen. |
| T7 | `core/boot.zig` | Shrink: 640×480 → 400×300 with two columns and two windows in one column: every column/window rect lies within the screen; columns keep left-to-right order; no error. |
| T8 | `core/boot.zig` | Degenerate: resize to 50×20 either errors cleanly (`Error` returned, tree still consistent) or clamps per §3f — assert whichever §3f chose, with the C cite. |
| T9 | `shim/abi.zig` | `EventKind.resize == 8`, `version == 5` (extend the existing mirror test). |
| T10 | `accept.zig` | New scene `phase-12c: resize scene — grow then shrink keeps the tiling and the text`: boot 640×480 with body text, resize to 900×700, type a rune, resize back to 640×480; assert row/column/window rects tile exactly (adjacent edges differ by the border) and the body text still contains the typed rune. **No hash** (R-P12c-3) — geometry asserts only. |
| T11 | `tools/smoke_wasm.mjs` | As §3h: init 800×600 blits 800×600; resize event → 1024×768 blit. |

## 5. Gate (fable)

1. `zig build test` to a file, `$?==0`, 0 failures, run twice.
2. `zig fmt --check`; `zig build`; `node tools/smoke_wasm.mjs` green with the new checks.
3. Boundary grep empty; no golden re-freeze (R-P12c-3).
4. Manual (Larry): `make run` — the editor fills the browser window; drag the window
   edge — columns rescale, text reflows, typing still lands under the pointer.
5. Report `agents/reports/phase12c-canvas-resize.md`; HANDOFF: canvasResize done,
   DPR half (R-P12c-6) stays on the backlog, `web/index.html:15` note retired.
