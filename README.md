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

Pinned Zig, see `.zigversion`. `zig build native` builds `snarf-native` **and** its
`devdraw` display server in-tree from a pinned plan9port snapshot (ADR-0006, macOS) — no
plan9port install needed; the first build fetches once, `zig build`/`zig build test` stay
network-free. `zig build run-native` runs it; `make install` puts both binaries side by
side in `$(PREFIX)/bin` (default `~/.local/bin`), installing `snarf-native` as `snarf`. A deliberate `$DEVDRAW` still wins, and
`$PLAN9`/`$PATH` remain fallbacks (resolution order in ADR-0006).

### Snarf Palette Options

`snarf -colors=NAME` picks the color scheme at startup (ADR-0007, named after New
Hampshire mountains); an unknown name exits listing the valid ones. The browser build
always uses the default.

| Name | Scheme | body / tag |
|------|--------|------------|
| `sunapee` | **default** — manila-paper body, periwinkle tag | `#FFF2E5` / `#EEEEFF` |
| `whiteface` | rio's greys: white body, pale blue-green tag | `#FFFFFF` / `#E7FAFA` |
| `monadnock` | dark: light text on near-black | `#22201C` / `#1C2228` |
| `acme` | the original acme palette, byte-exact | `#FFFFEA` / `#EAFFFF` |

Full token tables, contrast math, and the history (no, Pike never explained the yellow):
[ADR-0007](docs/spec/adr/0007-snarf-colors.md),
[`notes/claude/snarf-color-scheme-proposal-2026-10-26.md`](notes/claude/snarf-color-scheme-proposal-2026-10-26.md).

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
