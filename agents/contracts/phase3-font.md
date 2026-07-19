# Phase 3 contract — fonts (glyph/string on the headless display)

Master reconciliation for outline contracts O5 (client — `phase3-font-client.md`) and
O6 (device — `phase3-font-device.md`). Build agents read the master FIRST, then their
side file. Rulings here override anything contrary in the side files. Hard gates
unchanged from phases 1-2 (in-worktree `zig build test --summary all` green +
`zig fmt --check build.zig src/ tools/` clean; named tests exact; cite pinned C;
~400-line impl caps; STOP on unimplementable signatures).

## Cross-check verdict

The two contracts byte-agree on all shared wire items: 'i' 10B, 'l' 37B (left is i8
@35), 's' 47+2·ni (ni u16 @45), 'y' 21+Dy·bpl with the same bytesperline formula
(byte-aligned, absolute-x-anchored, negative-min branch) and payload-advance rule;
sub-byte bit order MSB-first-leftmost; wire pixel order low-byte-first (RGBA32 =
[a,b,g,r]). Both cite the same devdraw.c/libmemdraw/bytesperline.c lines.

## Rulings

- **R-P3-1 (asset, OQ-GFX-2 resolved)**: embed `fixed/9x18.0000` verbatim (public
  domain; Lucida is encumbered — never embed it). DONE by orchestrator:
  `assets/fonts/fixed/{9x18.0000,README.md}`, build.zig `font_fixed9x18` file-module
  wired into the draw module + draw/accept test roots; S-03 §4 + ADR-0002 amended with
  revision notes. Agents use `@embedFile("font_fixed9x18")`; do NOT touch build.zig.
- **R-P3-2 (granted)**: `Display.Error` grows `proto.EncodeError`; `emit` gains the
  oversized-op guard (`size > buf_size ⇒ error.ShortBuffer`); `doFlush` promoted to
  pub (flush-without-'v' for error attribution). This retires the phase-2 deferred
  hazard on `emit`'s `catch unreachable`.
- **R-P3-3**: `drawString` takes UTF-8 `[]const u8` (libdraw `string()` shape); invalid
  sequences map to cache slot 0.
- **R-P3-4 (granted, applied)**: `ninep/errors.zig` gained NotFont/BadIndex/
  WriteOutside/BadWriteImage with the exact devdraw.c strings. 'i'-specific kernel
  strings ("cannot use display as font", "bad font size...") collapse to BadDraw (O6
  OQ-2 accepted).
- **R-P3-5**: identity cache layout (no slot repacking) — cache image has the strip's
  rect; 'l' r/sp are strip coordinates (client §4). Server records metrics verbatim.
- **R-P3-6**: GREY storage rule UNCHANGED from phase 2; mask alpha computed at read
  (device §1). No phase-2 frozen hash may change — if one does, the change is wrong.
- **R-P3-7**: dirty-rect on 's' is per-glyph union — 's' tests must not pin `hb.dirty`.
- **R-P3-8**: 'x'/'n'/'N'/ctl-writes/'Y' stay out of phase 3; repl tiling and repl
  non-solid masks stay Unsupported.
- **R-P3-9 (amendment, during 3a)**: growing `draw_backend.Error` breaks dev/draw.zig's
  exhaustive `opError` switch, so 3a/A2 ALSO carries exactly two arms in that switch
  (`WriteOutside => WriteOutside`, `ShortData => BadWriteImage`). B1 (3b) will find
  them present; the rest of §3 remains B1's.

## Sub-wave assignments

- **3a (concurrent):** A1 sonnet — `src/draw/proto.zig` extensions per client §2
  (4 new Op variants + chanDepth/bytesPerLine + 7 named tests). A2 opus —
  `src/dev/draw_backend.zig` extensions per device §2 (Error members, 4 vtable fns,
  general-mask draw(), loadPixels decode, 10 named tests incl. the CALC12 pin).
  Disjoint files; no shared edits (dev.zig/draw.zig untouched in 3a).
- **3b (after 3a merges, concurrent):** B1 opus — `src/dev/draw.zig` verbs per device
  §3 + tests 11-16 (FROZEN-D per R-P2-7). B2 opus — client: `src/draw/Display.zig` +
  `Image.zig` deltas (R-P3-2), `src/draw/Font.zig` (client §4), `src/draw/draw.zig`
  re-export `pub const Font = @import("Font.zig");` + the fake-devdraw tests. B1 and
  B2 own disjoint directories.
- **Wave C (orchestrator):** acceptance scene in `src/accept.zig` — full stack draws
  "hello, acme" (embedded fixed font, black on white, top-left (20,20)) over 9P onto
  the 640×480 headless display; client-side stringWidth cross-check (11 glyphs × 9 =
  99 px); FROZEN-ACCEPT-2 per R-P2-7. Report + spec-trace + merge to main.
