# S-00 — Architecture Overview

Satisfies: R-OV-02, R-OV-03, R-PLAT-03, R-PLAT-04, R-CON-02, R-9P-13.

## 1. Layers

Snarf is one WASM module plus one JS shim, structured in four layers with 9P as the only
interface between the top two and the bottom two:

1. **Editor core** — ACME logic: columns/windows, text buffers, tag lines, Edit language,
   mouse-language interpreter. Pure Zig, browser-free, natively testable (R-CON-02).
   It consumes files: it reads `/dev/mouse`, writes `/dev/draw/N/data`, opens
   `/mnt/host/...`. It contains a `libdraw`-like client library so drawing code reads like
   ACME's.
2. **9P kernel** — client (`Tmsg` encoder/decoder, fid table), **mount table/namespace**
   (path → server resolution, `mount`/`bind`), and server framework (dispatch loop, qid
   management). Pure Zig, transport-agnostic.
3. **Device layer** — the in-browser 9P servers: `devdraw`, `devinput`, `devdom`,
   `devsnarf`/`devstorage`/`devmisc`, `devhost`. Each is an ordinary 9P server built on the
   framework; each is the *only* code allowed to call its slice of shim imports.
4. **JS shim** — hand-written, small (R-PLAT-04). Instantiates the module in a **Web
   Worker**, provides the WASM imports (draw blit/flush, event injection, clipboard,
   FS Access, WebSocket, storage), and owns the visible `<canvas>` on the main thread.

![architecture](diagrams/architecture.puml)

Diagram source: [diagrams/architecture.puml](diagrams/architecture.puml)

## 2. Concurrency model (how blocking reads work — R-9P-13)

Plan 9 code is written in a blocking style (`read(mousefd)` parks until an event). WASM in
a worker gives us two options; we support both, chosen at startup:

- **SAB mode** (preferred; requires cross-origin isolation, R-BLD-04): the module runs in
  a worker; shim→module event delivery uses a `SharedArrayBuffer` ring buffer + `Atomics`.
  A blocking `Tread` on `/dev/mouse` becomes `Atomics.wait` on the ring — genuine blocking,
  zero busy-wait, main thread never blocked.
- **Async mode** (fallback, no special headers): the 9P kernel runs an **event loop with
  stackless coroutines** (Zig async-style state machines / explicit continuation structs —
  pre-1.0 Zig async caveat noted in ADR-0001). `Tread` returns a pending ticket; the worker
  yields to JS; `postMessage` events complete tickets. The editor core is written against a
  `Chan`-like API (`recv(mouse)`) that hides which mode is active.

In both modes the **main thread only** captures input events and presents frames; all
Snarf logic runs in the worker.

## 3. Source tree

The top-level shape (per-file layout, C→Zig mapping, and import rules are owned by
[07-source-layout.md](07-source-layout.md)):

```
src/
  core/       editor (browser-free)     draw/   libdraw-like client + frame
  ninep/      9P2000                    dev/    device servers
  shim/       WASM boundary             main_wasm.zig  main_native.zig
web/ (index.html, shim.js)   assets/fonts/   build.zig  build.zig.zon  .zigversion
```

## 4. Boot sequence

1. `index.html` loads `shim.js`; shim feature-detects (SAB? FS Access? touch?), creates the
   worker, instantiates `snarf.wasm` with the import object.
2. Module `init()` builds the namespace: starts device servers, mounts them (in-memory
   transport), attempts `wss://<origin>/9p` → `/mnt/origin` (absence tolerated, R-9P-10).
3. Editor core starts: opens `/dev/draw/new`, `/dev/mouse`, `/dev/kbd`, draws the initial
   column layout, enters the event loop.
4. Shim begins pumping resize/pointer/key/clipboard events into the input ring.

## 5. Error philosophy

Every cross-boundary failure is a 9P `Rerror` with a Plan 9-style string
(`"permission denied"`, `"file does not exist"`); devices never throw across the shim.
The core surfaces errors ACME-style (warnings in the `+Errors` window).

## 6. Trace to requirements

| Area | Requirements | Spec |
|------|--------------|------|
| Editor behavior | R-EDIT-01..18 | S-05 |
| Protocol & transports | R-9P-01..04, R-9P-13 | S-01 |
| Mount trees & file formats | R-9P-05..12, R-9P-14..15 | S-02 |
| Graphics | R-GFX-01..08 | S-03 |
| Input & chords | R-IN-01..11 | S-04 |
| Build & platform | R-PLAT-01..04, R-BLD-01..05 | S-06 |
| Decisions | R-OV-05..08, R-CON-01 | ADR-0001..0004 |
