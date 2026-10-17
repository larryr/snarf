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

**Note (v2, ADR-0006 / phase 18) — the native `devdraw` peer.** `zig build native` and `zig build
devdraw` (macOS only) additionally need (a) **network once**, to fetch the pinned plan9port
snapshot (`larryr/plan9port@337c6ac`) into Zig's global cache — a 22 MB tarball, which Zig then
unpacks to the git-ignored `zig-pkg/<hash>/` (63 MB); offline, copy
`~/.cache/zig/p/N-V-__8AAJxZ3wK-9yFlPu40838vwp3xUVQhAt1ebgXEhI3F.tar.gz` into place or use
`zig build --system <dir>` with `<dir>/<hash>/` unpacked — and (b) the **macOS SDK** from the Xcode
Command Line Tools, for the Cocoa/Metal headers and frameworks. R-BLD-02's "no system C compiler"
still holds: Zig's bundled clang compiles all the C/ObjC. `zig build` and `zig build test` need
neither — no network and no SDK — enforced by the phase-18 gate (`--system <empty dir>`).

## 3. Open questions

- OQ-PLAT-1: Minimum browser versions to state officially — pin at time of first release.
- OQ-BLD-1: Zig is pre-1.0; pick the pin (0.14.x vs 0.15.x) when code starts, and record
  the upgrade policy (ADR-0001 amendment per bump).

## 4. Revision log

- **v1** — initial.
- **v2** (2026-10-11, ADR-0006 / phase 18) — note under §2: `zig build native`/`zig build
  devdraw` on macOS need network once (the pinned plan9port fetch) and the macOS SDK; `zig
  build`/`zig build test` need neither. R-BLD-01's "identical commands and results" is
  honestly narrowed for those two native targets: the bundled `devdraw` is macOS-only for now
  (Linux uses `$DEVDRAW`/`$PLAN9`/`$PATH`); the default and test targets are unchanged.
