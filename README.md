# snarf

A port of Plan 9's **ACME** editor — rewritten in **Zig**. Everything outside the editor
is a file served over **9P**: `/dev/draw`, `/dev/mouse`, `/dev/kbd`, the clipboard
(`/dev/snarf` — hence the name), the host file system, and (on the frozen browser build)
the DOM and an origin server's 9P export.

Status: **implementation in progress**. As of 2026-10-11 ([ADR-0005 amendment](docs/spec/adr/0005-two-hosts-one-core.md),
[roadmap v0.2](docs/product/roadmap.md)) the **native host is primary** — a real window via
Plan 9's `devdraw` — and the **browser build is a frozen secondary**: it keeps building and
testing, but gets no new features. The browser version was the original zero-install
showcase; native is the daily-driver target now.

## Native (primary)

Pinned Zig, see `.zigversion`. `zig build native` builds `snarf-native`; `zig build
run-native` runs it. It needs a `devdraw` to talk to:

- Today, that means a [plan9port](https://github.com/larryr/plan9port) install, found via
  `$PLAN9/bin/devdraw` or `devdraw` on `$PATH`.
- Building `devdraw` in-tree from a pinned plan9port snapshot — no separate install —
  is implemented in [PR #24](https://github.com/larryr/snarf/pull/24) (ADR-0006), pending
  merge. Until then, a **prebuilt preview** (native snarf + bundled `devdraw`, macOS
  arm64 only, unsigned) is available for direct download from the
  [`release/native-preview-2026-10-17`](https://github.com/larryr/snarf/raw/release/native-preview-2026-10-17/dist/snarf-native-preview-macos-arm64.zip)
  branch (see that branch's `dist/README.md` for the Gatekeeper quarantine step).

`snarf-native -colors=NAME` picks a color scheme: `sunapee` (default), `whiteface`,
`monadnock` (dark), or `acme` (the original palette) — see [ADR-0007](docs/spec/adr/0007-snarf-colors.md).

`zig build test` runs everything natively, with no browser or devdraw dependency.

## Browser (frozen secondary)

`zig build serve` builds `snarf.wasm` and runs the **origin server** on
http://127.0.0.1:8017 — static files with the WASM/COOP/COEP headers plus a
9P2000-over-WebSocket export at `/9p` (`version`, `bin/`, `fs/` = this repo;
`-Dexport=<dir>` to change). An interactive editor runs in the browser (click/type/select,
B2 execute, B3 look, the Edit language), but this build only gets bug fixes going forward.

## Docs

- Requirements: [`docs/requirements/`](docs/requirements/)
- Specifications & diagrams: [`docs/spec/`](docs/spec/)
- Key decisions (toolchain, libraries, /dev/draw, 3-button mouse, native-vs-browser):
  [`docs/spec/adr/`](docs/spec/adr/)
- Product roadmap: [`docs/product/roadmap.md`](docs/product/roadmap.md)

AI agents working in this repo: start with [`CLAUDE.md`](CLAUDE.md) (aliased as
`AGENTS.md`), then read the cross-session memory at [`agents/HANDOFF.md`](agents/HANDOFF.md).
