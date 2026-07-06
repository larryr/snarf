# ADR-0003 — Graphics: /dev/draw is the contract; Canvas2D/OffscreenCanvas is the backend

Status: **Accepted** · Satisfies: R-OV-05, R-GFX-01..08 · Fed back into requirements
[R-04](../../requirements/04-graphics.md) (its v2 revision is this decision)

## Context

The brief asks: "decide on how to expose graphics and consider how /dev/draw plays a role
(perhaps back to requirements as well as specification)." Options considered:

1. **Direct canvas calls from the editor** — each widget paints via shim imports
   (`ctx.fillRect`-shaped ABI).
2. **DOM-based UI** — render windows/tags as HTML elements, let the browser lay out text.
3. **/dev/draw device**: editor speaks the Plan 9 draw protocol to a 9P-served draw
   device; a backend inside the device renders via Canvas2D on an OffscreenCanvas.

## Decision

Option 3 — **/dev/draw plays the same role it plays on Plan 9: it *is* the graphics API.**

- The editor core links a `libdraw`-like client and writes protocol messages to
  `/dev/draw/N/data` (subset in S-03 §2). It never sees a canvas.
- The device's v1 backend targets **Canvas2D on an OffscreenCanvas in the worker**;
  pixels cross the shim once per flush, batched by dirty rect.
- Text = Plan 9 bitmap subfonts (deterministic metrics, no browser rasterization).
- A headless memory-framebuffer backend ships for native tests.

Reasoning:

- **Architecture coherence**: R-OV-03 already says *everything* crosses the namespace;
  making graphics the one exception would create a second, ad-hoc ABI. With devdraw, the
  whole system is uniformly "files all the way down," and the shim ABI stays tiny.
- **Fidelity for free**: ACME's drawing code assumes libdraw semantics (repl images,
  clip rects, subfont caches, self-blit scrolling). Porting against the same protocol
  means porting, not redesigning.
- **Testability**: golden-image tests with deterministic fonts need no browser (R-CON-02).
- **Future**: the protocol point is where a WebGL/WebGPU backend, a remote devdraw
  (draw over WebSocket — drawterm-in-reverse), or screenshot tooling plug in later,
  without touching the editor.

## Consequences

- ✅ Editor core is browser-free; backend swappable; external 9P clients could draw too.
- ⚠️ Indirection cost: encode/decode of draw messages in the hot path. Mitigation:
  in-memory transport with zero-copy views (S-01 §3.1), batching one flush per frame
  (S-03 §6). Plan 9 pays this same cost over pipes and remains famously snappy.
- ⚠️ Software compositing for the general mask case (S-03 §3) — rare path, fonts use the
  atlas path.
- 📌 Feedback into requirements (done): R-GFX-01 (draw-only rule), R-GFX-04 (subfonts),
  R-GFX-03 (OffscreenCanvas), R-GFX-05..08 — see R-04 revision log v2.

## Alternatives rejected

- **Direct canvas ABI** (1): fastest to demo, but grows a wide bespoke shim surface,
  breaks headless testing, and every ACME drawing idiom needs rework.
- **DOM UI** (2): fights ACME's model (pixel-exact frames, custom scrollbars, chorded
  selection), tangles the UI with `/dev/dom` (which must remain a *served resource*),
  and browser text metrics differ per platform — the opposite of a faithful port.
