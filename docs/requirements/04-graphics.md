# R-04 — Graphics Requirements (/dev/draw)

Status: **Draft v2** (this document was revised after ADR-0003, exactly the "back to
requirements" loop anticipated in the project brief)

## 1. Decision context

ACME does not draw pixels itself; it uses `libdraw`, which talks to the kernel's
`/dev/draw` device. ADR-0003 keeps that split: **the editor core's only graphics interface
is a /dev/draw file server**; a pluggable backend renders to the browser. This makes the
core testable headless (backend that renders to an in-memory image) and keeps every browser
API behind the device layer, consistent with R-OV-03.

## 2. Requirements

| ID | Requirement |
|----|-------------|
| R-GFX-01 | Graphics SHALL be performed exclusively by writing Plan 9 draw-protocol messages to `/dev/draw/N/data` (subset defined in [../spec/03-draw-device.md](../spec/03-draw-device.md)); no other component may touch canvas/WebGL. |
| R-GFX-02 | The draw device SHALL support, at minimum: image allocation/free (`b`/`f`), rectangle fill and general `draw` compositing (`d`/`r`), lines (`L`), string drawing with loaded fonts/subfonts, clipping (`c` / repl), and screen refresh (`v`). Enough, by construction, to render everything ACME renders. |
| R-GFX-03 | The v1 backend SHALL render to a **Canvas 2D context on an `OffscreenCanvas`** driven from the worker the WASM module runs in; a WebGL/WebGPU backend is a permitted future optimization behind the same device (OQ-GFX-1). |
| R-GFX-04 | Text rendering SHALL use pre-rasterized bitmap fonts in Plan 9 subfont format, embedded in the module or loaded from the namespace — not browser font rasterization — so metrics are deterministic across platforms and the draw model stays pure. |
| R-GFX-05 | The display SHALL resize with the browser window / element and handle devicePixelRatio (HiDPI) correctly; a resize appears to the client as ACME expects (redraw notification via the draw device's refresh/`ctl` semantics). |
| R-GFX-06 | Target interactive latency: a keystroke-to-glyph paint under one frame (16 ms) for typical windows; scrolling a 10k-line file must not allocate per frame in the hot path. |
| R-GFX-07 | Color model: Plan 9 image channel descriptors with at least `x8r8g8b8`/`r8g8b8a8` and grey formats needed by fonts (`k1`, `k8`) supported. |
| R-GFX-08 | The mouse cursor image SHALL be settable through the device (`/dev/cursor` semantics) — mapped to CSS cursors or a drawn cursor as the backend chooses. |

## 3. Explicitly not required

- Full generality of Plan 9 `draw(3)` (e.g. arbitrary `poly`, ellipses) beyond what ACME
  and its scrollbars/borders need — the subset is enumerated in spec 03 and may grow.
- Direct DOM-node-per-window rendering. Snarf draws its whole UI into one canvas, like
  drawterm; the DOM is a *served resource* (`/dev/dom`), not the UI substrate.

## 4. Open questions

- OQ-GFX-1: WebGL2/WebGPU backend for large-screen scrolling performance. *Measure first.*
- OQ-GFX-2: Font strategy detail — ship Go Regular converted to subfonts, or a public
  Plan 9 font (e.g. `lucm`/`fixed`)? Licensing check needed (Go fonts are BSD-licensed —
  current favorite).

## 5. Revision log

- **v1** — said only "render ACME UI to a canvas".
- **v2** — rewritten around ADR-0003: /dev/draw is the contract (R-GFX-01), bitmap
  subfonts required (R-GFX-04), OffscreenCanvas backend fixed for v1 (R-GFX-03),
  HiDPI + latency requirements added.
