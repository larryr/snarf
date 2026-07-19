# Phase 3 report — fonts (glyph/string on the headless display)

Merged to `main` (revert = revert the one merge commit). Contracts:
`agents/contracts/phase3-font{,-client,-device}.md`. Suite: **148/148**; boundary
negative-check verified; wasm builds.

## Delivered

Snarf renders text. `"hello, acme"` travels: embedded subfont → image(6) LZ77
decompress → strip 'y' upload → font cache 'b'/'i'/'l' preload → `drawString` 's' →
9P → devdraw → general-mask compositor → verified pixels (FROZEN-ACCEPT-2
`0x4389e512acce6f36`). Composed **first-try**, like both phases before it.

- `draw/proto.zig` — verbs 'i'/'l'/'s'/'y' with golden bytes; `chanDepth` +
  `bytesPerLine` (both branches of the absolute-x-anchored formula).
- `dev/draw_backend.zig` — the general-mask compositor: GREY1/GREY8 masks with
  kernel-exact CALC12 arithmetic (pinned by a hand-derived test), RGB2K grey→alpha at
  read time, `loadPixels` wire decode (MSB-first sub-byte, low-byte-first pixels),
  `copy`/`setClipr`/`imageInfo`. Phase-2 storage rule and frozen hashes untouched.
- `dev/draw.zig` — 'y'/'i'/'l'/'s' dispatch: per-font FChar tables, drawchar geometry,
  wire-clipr save/restore on every exit path, two-stage 's' length check. FROZEN-D.
- `draw/Font.zig` — subfont parse (image(6) header + compressed blocks + font(6)
  trailer), the ~50-line cload.c decompressor (doubles as future 'Y' machinery),
  identity cache preload, UTF-8 `drawString`/`stringWidth` with 100-index chunking.
- `draw/Display.zig`/`Image.zig` — the R-P3-2 hardening (oversized-op guard retiring
  the phase-2 `catch unreachable` hazard) + chunked `Image.load`.

## The font asset decision (FLAG FOR LARRY — reviewable, on main with this phase)

**OQ-GFX-2 resolved.** Evidence-based ruling:
- **Lucida families are license-encumbered** (B&H notices; `lucida/NOTICE` forbids
  redistribution outside Plan 9) — permanently ruled out, recorded in the asset README.
- **`fixed/` is public domain** (XFree86 misc-fixed; controlling README in both pinned
  trees). Embedded `fixed/9x18.0000` **verbatim** (sha256
  `ac0b4bccf24c92471b0aab8e025fe56c1dcb58f5b8c27c32bf6a1dd49b589481`), license note at
  `assets/fonts/fixed/README.md`; a test pins the parsed asset's shape against silent
  replacement.
- **S-03 §4 amended with a revision log**: "ships Go fonts pre-converted" required a
  TTF rasterizer (not std-only-feasible); v1 ships misc-fixed, Go fonts deferred to an
  offline conversion tool. ADR-0002's parenthetical updated. Also corrected S-03 §2's
  fictional 'k' verb (real font verbs are 'i'/'l'/'s').

## Pipeline notes

- **The honest-stop worked**: A2 discovered my sub-wave partition was contradictory
  (growing the backend error set breaks devdraw's exhaustive switch in the neighboring
  file), proved its work with a temporary probe, reverted, refused to commit, and
  escalated. Resolved as contract amendment R-P3-9 (two authorized arms). This is the
  strongest evidence yet that the hard gates + stop-and-report rule produce trustworthy
  agent output.
- O6's standout ground-truth catch: the mask blend is **CALC12** (single combined
  rounding), not two CALC11s — would have silently skewed every antialiased pixel.
- R-P2-3 (test-only ninep.server in draw) was exercised in Font.zig's test block too —
  same spirit, recorded here.

## Deferred

Multi-subfont .font files; runes beyond latin1 (→ slot 0 box glyph); cache
eviction/aging (v1 preloads everything); Go fonts (offline tool); 'Y' compressed
server load; 'x' stringbg; 'n'/'N' named images; repl tiling; repl non-solid masks;
GREY-as-source colored-fill deviation (doc-commented).
