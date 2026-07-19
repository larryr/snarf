# ADR-0001 — Toolchain: pinned Zig only; wasm32-freestanding; macOS & Linux parity

Status: **Accepted** · Satisfies: R-OV-07, R-BLD-01..05, R-PLAT-03, R-PLAT-04

## Context

The project must build identically on macOS and Linux (R-BLD-01) and produce a WASM module
for the browser. Candidate stacks: Zig's native WASM backend; Emscripten (C/C++ heritage,
huge runtime, generated JS); Rust+wasm-bindgen (excellent but a different language and a
large generated-glue surface); hand-managed clang+wasm-ld.

## Decision

1. **Zig is the entire toolchain.** One pinned version (`.zigversion` +
   `minimum_zig_version` in `build.zig.zon`); `zig build` / `zig build test` /
   `zig build serve` are the only commands. Zig ships as a self-contained archive with
   identical behavior on both host OSes, so "build on macOS and/or Linux" needs no
   per-OS tooling at all.
2. **Target `wasm32-freestanding`**, not `wasm32-wasi`, not Emscripten. Snarf's platform
   is 9P-over-shim, not POSIX; WASI would drag in an emulation layer we'd immediately hide
   behind devices anyway, and Emscripten violates the no-generated-JS rule (R-PLAT-04).
3. **JS shim is hand-written** and part of the reviewed source; the WASM↔JS ABI is declared
   in one Zig file (S-06 §4).
4. **Zig version policy**: Zig is pre-1.0 and releases break APIs; every version bump is a
   dedicated PR that updates the pin files and this ADR's log. Zig's async story is in
   flux — the async-mode event loop (S-00 §2) is therefore specified as explicit state
   machines/continuations, not `async`/`await` keywords, so it survives compiler changes.

## Consequences

- ✅ Contributor setup = download one archive; CI matrix is trivial; cross-compiling the
  native test build for the *other* OS is even possible from either host.
- ✅ No dependency manager, no lockfile churn, no node_modules.
- ⚠️ Pre-1.0 churn: upgrades cost occasional mechanical fixes (accepted; pin absorbs it).
- ⚠️ Freestanding means we implement our own allocator wiring (std.heap.wasm_allocator),
  panic handler, and log sink — small, one-time costs, already accounted in S-00.

## Alternatives rejected

- **Emscripten**: mature but heavy; generated glue conflicts with R-PLAT-04; POSIX layer
  conflicts with the 9P architecture (R-OV-03).
- **wasm32-wasi**: gives file APIs we must not use (the namespace is 9P, not preopens);
  adds a shim (wasi polyfill) for zero benefit.
- **Rust**: fine language, but the project brief fixes Zig; also wasm-bindgen's generated
  JS surface is exactly what we're avoiding.
