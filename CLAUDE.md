# Snarf — agent guide

Snarf is a port of Plan 9's ACME editor: rewritten in Zig, compiled to WebAssembly,
running in the browser, with 9P file servers exposing the DOM, browser features, the host
file system, and the origin server as one namespace. Design docs live in
[`docs/`](docs/README.md) — read `docs/README.md` for the map and reading order.

**Session handoff: read [`agents/HANDOFF.md`](agents/HANDOFF.md) before starting work,
and maintain it per the protocol below.** It is the shared memory between sessions on
different machines.

## Source choices — binding guidelines

These decisions are settled and recorded; do not re-decide them silently. Changing one
requires amending the relevant ADR in `docs/spec/adr/` and getting user sign-off.

1. **Language & target** (ADR-0001): Zig, pinned version (`.zigversion` +
   `build.zig.zon`), target `wasm32-freestanding`. `zig build` is the only build entry
   point; identical on macOS and Linux. No Emscripten, no WASI, no node/npm in the build.
2. **Dependencies** (ADR-0002): **Zig standard library only.** The `build.zig.zon`
   dependency table stays empty. 9P, the draw client, and the structural-regexp engine
   are written in-project. Embedded assets (fonts) are fine with license notes. Never add
   an external package without an ADR-0002 amendment approved by the user.
3. **Graphics** (ADR-0003): the editor core draws **only** by writing Plan 9 draw-protocol
   messages to `/dev/draw` (spec S-03). Only the device backend touches
   canvas/OffscreenCanvas. Never call browser APIs from `src/core`.
4. **Input** (ADR-0004): the core consumes only `/dev/mouse`//dev/kbd logical events;
   all 3-button/chord emulation lives in the input device server (spec S-04).
5. **Architecture boundary** (R-OV-03, R-CON-02): everything outside the editor's memory
   crosses a 9P namespace. `src/core` and `src/ninep` must compile and pass tests
   natively with no browser and no shim. Import rules are in spec S-07 §6 — `core` never
   imports `dev` or `shim`.

## Code structure rules (spec S-07)

- One type per file, file-as-struct: `Buffer.zig` *is* the struct. Type files
  `PascalCase.zig`, namespace modules `lowercase.zig`.
- Soft cap **~400 lines per file**; split along behavioral seams, never mid-algorithm.
- **No globals** — state hangs off the `Editor` context struct; allocators passed/stored
  explicitly.
- Tagged unions over type-int structs; comptime tables for command/dispatch tables;
  error unions instead of status ints; colocated `test` blocks.
- `zig fmt` clean; the planned tree and C→Zig mapping are in `docs/spec/07-source-layout.md`.

## Reference sources — citation policy

The original C sources are pinned forks; cite them with commit SHA so references never
rot (S-07 §1):

- **Acme editor code**: `larryr/plan9port@337c6ac` — `src/cmd/acme/*`, `src/libframe/*`,
  `src/libdraw/*`. Cite as `acme/text.c:1234`.
- **Kernel device semantics** (/dev/draw, /dev/mouse, /dev/cons): `larryr/plan9@ed1a9c2`
  — `sys/src/9/port/*.c`, manuals `sys/man/`. Cite as `9/port/devdraw.c:567`.

When porting behavior, read the pinned source, don't work from memory. In remote
sessions, ask to attach the forks (`add larryr/plan9port`) and clone shallow.

## Documentation conventions

- Requirements carry stable IDs (`R-EDIT-05`); never renumber — deprecate. Specs cite the
  R-IDs they satisfy. Real decisions get ADRs; decision feedback into a requirements doc
  gets a revision-log entry.
- Diagrams are PlantUML sources in `docs/spec/diagrams/`; never commit rendered images.
  Verify with `plantuml -checkonly` before committing (apt-installable; external
  render services may be blocked in sandboxes).

## Workflow

- Develop on a feature branch; never commit directly to `main` — with **one standing
  exception**: `agents/HANDOFF.md` (see protocol below).
- Known environment gotchas and account-specific facts (GitHub App permissions, network
  policy, fork locations) are maintained in `agents/HANDOFF.md`, not here — check it.

## Session handoff protocol (`agents/HANDOFF.md`)

Purpose: sessions run on different computers with no shared state; this file is the only
channel between them.

1. **Read it first** at the start of any session, right after this file.
2. **Update it** whenever you learn something a future session needs: state changes
   (what's merged, what's in flight), environment facts, decisions made with the user,
   dead ends that shouldn't be repeated.
3. **Commit it to `main`** — this specific file has standing user authorization for
   direct commits to `main` (commit message prefix `handoff:`) at these moments:
   - when the user asks,
   - after any major commit or merge,
   - after creating a PR.
   If `main` moved, pull/rebase and retry; never force-push. Nothing else may ride along
   in a handoff commit.
4. **Keep it lean**: newest session entry first, prune entries that no longer matter,
   target ≤ ~300 lines. It is working memory, not an archive — history lives in git.
