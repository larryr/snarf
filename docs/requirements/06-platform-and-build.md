# R-06 — Platform & Build Requirements

Status: **Draft v1**

## 1. Runtime platform

| ID | Requirement |
|----|-------------|
| R-PLAT-01 | Snarf SHALL run in current evergreen **Chromium, Firefox, and Safari** releases. Features with uneven support (File System Access API, keyboard lock) MUST degrade per the fallbacks in R-9P-09 / R-IN-09, never break startup. |
| R-PLAT-02 | The deliverable SHALL be static assets only: `index.html`, one JS shim, one `snarf.wasm`, font/asset files. Any static file host (including `file://` where browsers permit, and GitHub Pages) can serve it; the optional origin 9P endpoint (R-9P-10) is the only dynamic piece. |
| R-PLAT-03 | The WASM module SHALL target `wasm32-freestanding` and run inside a **Web Worker** (so blocking-style 9P reads, R-9P-13, don't stall the UI thread), with `SharedArrayBuffer`+Atomics when cross-origin-isolation headers are present and a postMessage fallback when not. |
| R-PLAT-04 | No Emscripten, no emulated POSIX layer, no JS framework, no npm runtime dependencies. The JS shim is hand-written, small (target < ~1500 lines), and is part of the reviewed source, not generated. |

## 2. Build hosts

| ID | Requirement |
|----|-------------|
| R-BLD-01 | The project SHALL build on **macOS (arm64/x86_64) and Linux (x86_64/arm64)** with identical commands and results. |
| R-BLD-02 | The **only required tool is the pinned Zig toolchain** (ADR-0001). `zig build` produces the complete deployable site; `zig build test` runs unit tests natively on the host. No make, cmake, node, or system C compiler required. |
| R-BLD-03 | The Zig version SHALL be pinned in-repo (`.zigversion` + `build.zig.zon` minimum) and CI SHALL build on both Linux and macOS runners from a clean checkout. |
| R-BLD-04 | A dev loop SHALL exist: `zig build serve` (or documented one-liner, e.g. `python3 -m http.server` over `zig-out/www`) serving with the COOP/COEP headers needed for R-PLAT-03's SAB path. |
| R-BLD-05 | Docs tooling (PlantUML/Java or Kroki) SHALL be needed only to *render* documentation, never to build the software. |

## 3. Open questions

- OQ-PLAT-1: Minimum browser versions to state officially — pin at time of first release.
- OQ-BLD-1: Zig is pre-1.0; pick the pin (0.14.x vs 0.15.x) when code starts, and record
  the upgrade policy (ADR-0001 amendment per bump).

## 4. Revision log

- **v1** — initial.
