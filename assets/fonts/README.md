# Fonts

Subfont assets embedded into the WASM build (S-03 §4). ADR-0002 permits embedded font
assets with license notes; it does not permit external packages.

- `fixed/9x18.0000` — v1 default font (public domain, XFree86 misc-fixed; see
  `fixed/README.md` for provenance + license text). **OQ-GFX-2 resolved** (phase 3):
  Lucida families are license-encumbered and must never be embedded; Go Regular/Go Mono
  remain the target faces, deferred until an offline TTF→subfont conversion tool exists
  (never a build dependency). See S-03 §4 (as amended) and
  agents/contracts/phase3-font.md.
