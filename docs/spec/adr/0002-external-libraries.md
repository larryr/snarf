# ADR-0002 — External libraries: Zig std only

Status: **Accepted** · Satisfies: R-OV-08, R-CON-01

## Context

The brief: "decide on external libraries — but bias should be use only standard libraries
where possible." Candidate temptations and what std already covers:

| Need | Obvious external | Zig std / in-project answer |
|------|------------------|------------------------------|
| allocators, ArrayList/HashMap, sort | — | `std.heap`, `std.ArrayList`, `std.HashMap` |
| UTF-8/unicode | ICU-ish libs | `std.unicode` (enough: ACME needs code points, not grapheme clusters — divergence documented) |
| regex (Edit language) | PCRE, an external regex pkg | **write it**: Plan 9 structural regexps are a small, well-specified engine; every ACME port implements its own (S-05 §5) |
| 9P | a 9p package | **write it**: the protocol is tiny and central to the project's identity; owning it is the point |
| draw protocol | — | in-project by design (ADR-0003) |
| fonts | FreeType/HarfBuzz | **not needed**: pre-rasterized Plan 9 subfonts as embedded assets (S-03 §4); shaping is out of scope (OQ below) |
| JSON (dom event detail) | — | `std.json` |
| WebSocket framing | ws lib | browser provides WebSocket; the shim uses it; Zig side sees framed 9P bytes |
| dev HTTP server | node, caddy | `std.http.Server` in `zig build serve` |
| testing | frameworks | `zig build test` built-in |

## Decision

- The WASM module and native test builds depend on **the Zig standard library only**.
  `build.zig.zon` keeps an **empty dependency table**; adding any entry requires amending
  this ADR with the concrete justification and a review of transitive cost.
- **Assets are not libraries**: embedded font data (v1: XFree86 misc-fixed subfont,
  public domain — OQ-GFX-2 resolved, see assets/fonts/fixed/README.md; Go fonts BSD-3
  deferred pending an offline conversion tool) and any icon/cursor bitmaps are permitted
  with license notes in-tree.
- **Docs-time tools** (PlantUML/Java or Kroki, GitHub Actions) never become build
  dependencies (R-BLD-05).
- **Browser APIs are the platform, not dependencies**: Canvas2D/OffscreenCanvas,
  Clipboard, File System Access/OPFS, WebSocket, IndexedDB via shim — allowed by
  definition, but only behind the device layer (R-OV-03).

## Consequences

- ✅ No supply-chain surface; a fresh clone + Zig builds forever-reproducibly.
- ✅ Forces the 9P/draw/regex cores to be owned, understood, testable code — these *are*
  the project.
- ⚠️ We re-implement things packages offer (regex engine, 9P). Accepted: each is
  small, stable-spec'd, and central.
- ⚠️ No complex text shaping (bidi, ligatures, grapheme-cluster cursoring) without
  HarfBuzz-class machinery. Accepted for v1 (ACME itself never had it); recorded as a
  known limitation, revisit only with a real user need — would require an ADR amendment.
