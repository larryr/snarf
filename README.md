# snarf

A port of Plan 9's **ACME** editor — rewritten in **Zig**, compiled to **WebAssembly**,
running in the browser. Everything outside the editor is a file served over **9P**: the
page's DOM (`/dev/dom`), the clipboard (`/dev/snarf` — hence the name), browser storage,
the host file system via the File System Access API (`/mnt/host`), and the origin server's
optional 9P export (`/mnt/origin`).

Status: **implementation in progress** — an interactive editor runs in the browser
(click/type/select, B2 execute, B3 look, the Edit language); requirements and
specifications live in [`docs/`](docs/README.md).

Quick start (pinned Zig, see `.zigversion`): `zig build serve` builds `snarf.wasm`, then
runs the **origin server** on http://127.0.0.1:8017 — static files with the WASM/COOP/COEP
headers plus a 9P2000-over-WebSocket export at `/9p` (`version`, `bin/`, `fs/` = this
repo; `-Dexport=<dir>` to change). `zig build test` runs everything natively.

- Requirements: [`docs/requirements/`](docs/requirements/)
- Specifications & diagrams: [`docs/spec/`](docs/spec/)
- Key decisions (toolchain, libraries, /dev/draw, 3-button mouse): [`docs/spec/adr/`](docs/spec/adr/)

AI agents working in this repo: start with [`CLAUDE.md`](CLAUDE.md) (aliased as
`AGENTS.md`), then read the cross-session memory at [`agents/HANDOFF.md`](agents/HANDOFF.md).
