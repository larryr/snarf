# Snarf documentation

**Snarf** is a port of Plan 9's ACME editor, rewritten in Zig, compiled to WebAssembly,
running in the browser, with 9P file servers exposing the DOM, browser features, the host
file system, and the origin server as one namespace.

## How this tree is organized

- **[requirements/](requirements/)** — *what and why*. Numbered R-documents with stable
  requirement IDs (`R-EDIT-05`, `R-9P-10`, …), each ending with Open Questions and a
  Revision Log (requirements are iterated; v2 revisions reflect decision feedback).
- **[spec/](spec/)** — *how*. Numbered S-documents that cite the R-IDs they satisfy.
- **[spec/adr/](spec/adr/)** — decision records for the four choices the project brief
  called out: toolchain, external libraries, graphics//dev/draw, and the 3-button mouse.
- **[spec/diagrams/](spec/diagrams/)** — PlantUML sources (`.puml`). Sources are
  authoritative; rendered images are never committed.

## Reading order

| # | Document | One-liner |
|---|----------|-----------|
| 1 | [requirements/01-overview.md](requirements/01-overview.md) | Vision, top-level requirements, glossary |
| 2 | [requirements/02-editor-functional.md](requirements/02-editor-functional.md) | ACME behavior that must survive the port |
| 3 | [requirements/03-namespace-and-9p.md](requirements/03-namespace-and-9p.md) | Mandatory mounts: DOM, browser, host FS, origin |
| 4 | [requirements/04-graphics.md](requirements/04-graphics.md) | /dev/draw as the graphics contract |
| 5 | [requirements/05-input.md](requirements/05-input.md) | Keyboard + the 3-button/chord problem |
| 6 | [requirements/06-platform-and-build.md](requirements/06-platform-and-build.md) | Browsers, macOS/Linux builds |
| 7 | [requirements/07-constraints-non-goals.md](requirements/07-constraints-non-goals.md) | Std-lib bias, sandbox limits, non-goals |
| 8 | [spec/00-architecture.md](spec/00-architecture.md) | Layers, concurrency, boot, source tree |
| 9 | [spec/01-9p-protocol.md](spec/01-9p-protocol.md) | 9P2000 subset, transports, blocking reads |
| 10 | [spec/02-namespaces.md](spec/02-namespaces.md) | Every file in every mount, formats & ctl verbs |
| 11 | [spec/03-draw-device.md](spec/03-draw-device.md) | Draw protocol subset, Canvas backend, fonts |
| 12 | [spec/04-input-devices.md](spec/04-input-devices.md) | /dev/mouse//dev/kbd, chord synthesis machine |
| 13 | [spec/05-editor-core.md](spec/05-editor-core.md) | Piece table, mouse language, Edit engine |
| 14 | [spec/06-build-toolchain.md](spec/06-build-toolchain.md) | zig build graph, shim ABI, CI |
| 15 | [spec/07-source-layout.md](spec/07-source-layout.md) | ACME C survey → Zig module structure, C→Zig map |
| — | [spec/adr/](spec/adr/) | ADR-0001..0004 |

## Rendering the diagrams

Diagrams are plain PlantUML. Any of:

```sh
# local (needs Java)
plantuml -tsvg docs/spec/diagrams/*.puml

# no install, via Kroki
curl -s --data-binary @docs/spec/diagrams/architecture.puml \
     https://kroki.io/plantuml/svg > architecture.svg
```

VS Code's PlantUML extension and GitHub/GitLab PlantUML integrations also work. Rendering
tools are documentation-time only and never build dependencies (R-BLD-05).

## Conventions

- Requirement IDs are permanent; never renumber — deprecate instead.
- Every spec section that implements behavior cites R-IDs; the traceability table lives in
  [spec/00-architecture.md](spec/00-architecture.md) §6.
- Decisions with real alternatives get an ADR; requirement docs get a revision-log entry
  when a decision feeds back (see R-04 v2 and R-05 v2 for the pattern).
- Original-source citations use the pinned reference forks `larryr/plan9port@337c6ac`
  (acme code) and `larryr/plan9@ed1a9c2` (device semantics) — see
  [spec/07-source-layout.md](spec/07-source-layout.md) §1.
