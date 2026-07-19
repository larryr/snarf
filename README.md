# snarf

A port of Plan 9's **ACME** editor — rewritten in **Zig**, compiled to **WebAssembly**,
running in the browser. Everything outside the editor is a file served over **9P**: the
page's DOM (`/dev/dom`), the clipboard (`/dev/snarf` — hence the name), browser storage,
the host file system via the File System Access API (`/mnt/host`), and the origin server's
optional 9P export (`/mnt/origin`).

Status: **design phase** — requirements and specifications live in [`docs/`](docs/README.md).

- Requirements: [`docs/requirements/`](docs/requirements/)
- Specifications & diagrams: [`docs/spec/`](docs/spec/)
- Key decisions (toolchain, libraries, /dev/draw, 3-button mouse): [`docs/spec/adr/`](docs/spec/adr/)
