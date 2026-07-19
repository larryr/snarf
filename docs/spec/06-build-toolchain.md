# S-06 — Build & Toolchain Specification

Satisfies: R-PLAT-01..04, R-BLD-01..05. Decision record:
[adr/0001-zig-toolchain-and-hosts.md](adr/0001-zig-toolchain-and-hosts.md).

## 1. Toolchain

- **Zig, pinned** (exact version recorded in `.zigversion` and `build.zig.zon`
  `minimum_zig_version`). OQ-BLD-1 **resolved 2026-07-19 → `0.16.0`** (the earlier
  "0.14.x/0.15.x" estimate predated the 0.16 release; see ADR-0001 revision log). Zig is
  a hermetic cross-compiler: the same tarball builds the WASM
  target on macOS (arm64/x86_64) and Linux (x86_64/arm64) — this alone satisfies R-BLD-01.
- Recommended install: `zvm`/`zigup` or direct tarball; `zig version` must equal the pin.
  No Homebrew/apt requirement (their versions lag).
- **Nothing else is required** (R-BLD-02): no node, no make, no system compiler. Java or
  Docker (Kroki) only if you want to render docs diagrams locally (R-BLD-05).

## 2. Targets

| Artifact | Target | Notes |
|----------|--------|-------|
| `snarf.wasm` | `wasm32-freestanding` | `ReleaseSafe` default (bounds checks are cheap insurance in v1; `ReleaseSmall` build offered for size comparison). Exports: `init`, `wake`, `tick`; imports: the shim ABI (§4). |
| unit tests | native host | `zig build test` — core, ninep, edit-language, devinput state machine, devdraw golden images (headless backend, S-03 §7). |
| `snarf-headless` | native host | optional dev tool: runs the core against headless devices for fuzzing/scripting. |

Threads/SAB: the module is built single-threaded; SAB is used only as a ring-buffer wait
target (`Atomics`), not `-fshared-memory` WASM threads, keeping both S-00 §2 modes on one
binary.

## 3. Build graph (`zig build`)

![build-flow](diagrams/build-flow.puml)

Diagram source: [diagrams/build-flow.puml](diagrams/build-flow.puml)

Steps: compile wasm → copy `web/` verbatim → embed/copy `assets/fonts` → assemble
`zig-out/www/`. `zig build serve` runs a tiny std.http dev server over `zig-out/www` with
`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`
(R-BLD-04) plus `application/wasm` MIME. `zig build dist` = same tree, plus gzip/brotli
precompression later.

## 4. JS shim ABI (contract, R-PLAT-04)

Single `web/shim.js` (main-thread part + worker bootstrap in one reviewed file, target
< ~1500 lines). Import surface (WASM `env`), intentionally narrow — each import belongs to
exactly one device server (R-OV-03):

```
draw:    blit(imgId, x,y,w,h, ptr), flush(rectsPtr,n), canvasResize→event
input:   (no imports — events flow in via ring buffer / postMessage)
dom:     domOp(opPtr,len) → resultTicket        (batched text ops)
snarf:   clipboardRead(ticket), clipboardWrite(ptr,len,ticket)
host:    fsOp(opPtr,len,ticket)                 (FS Access / OPFS ops)
ws:      wsOpen(urlPtr,len,id), wsSend(id,ptr,len), wsClose(id)
misc:    notify, setTitle, getLocation, navigate, consoleLog, storageOp
time:    nowMs(), raf tick subscription
```

All async imports complete by pushing a completion record (ticket id + payload) into the
inbound ring; no JS→WASM re-entrancy. This ABI is versioned in one Zig file
(`src/shim/abi.zig`) and one JS mirror; drift is a build error via a generated checksum
constant (OQ-BLD-2: consider generating the JS stub from `abi.zig` with a build step —
std-only, still no node).

## 5. CI (sketch)

GitHub Actions: matrix `{ubuntu-latest, macos-latest}` × steps: install pinned Zig (cache
tarball) → `zig build` → `zig build test` → upload `zig-out/www` artifact → (later)
Playwright smoke test (browser available in CI image; not a repo dependency) → optional
Pages deploy from main. Docs job: render `docs/spec/diagrams/*.puml` via `plantuml` action,
attach SVGs to the run — sources stay authoritative (R-BLD-05).

## 6. Repository conventions

- `zig fmt` clean is CI-enforced (`zig fmt --check .`).
- No git submodules, no vendored deps expected at all while ADR-0002 holds; `build.zig.zon`
  dependency table stays empty (fonts live in-tree under `assets/`).
- Diagram edits: change `.puml`, never commit rendered images (keeps diffs reviewable).
