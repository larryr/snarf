# Phase 8 contract — windows & chrome (master)

Side files: phase8-chrome.md (O16 — types/geometry/scrollbar/colors) +
phase8-routing.md (O17 — Editor routing/boot). Hard gates unchanged. THREE
SEQUENTIAL waves (type deps): W1 → W2 → W3.

## Rulings

- R-P8-1..8: as O16 proposed (scrollbar direct-draw, taglines=1, colgrow deferred,
  N-column math with 1-column boot, drag-resize deferred phase-9-adjacent, mouse
  warping PERMANENTLY divergent (browsers can't warp), full 4-value What enum,
  scrollbar click-actions replacing the drag loop).
- R-P8-9 (FOCUS POLICY — orchestrator override of O17): POINT-TO-TYPE, acme's default
  (rows.c:279-282): keys route to hitTest(ed.mouse_pt) (fallback ed.text). O16 concurs.
  Click-to-type (acme -b/bartflag) noted as a future preference. `focus` field is
  bookkeeping (argtext/typetext analog) only.
- R-P8-10 (hit regions): Row/Column.which return ?*Text (acme-shaped, per O16);
  Editor.hitTest wraps: region = scrollbar iff ptInRect(t.scrollr, pt) (acme.c:603),
  else tag/body per t.what. Region enum lives in Editor.
- R-P8-11: gesture_text pins sweeps/chords to their Text (textselect blocking-loop
  identity); wheel = text under pointer with the w != null guard (acme.c:618-629).
- R-P8-12: the phase-7 frozen write-stream hash (Editor.zig, 0xc06586b7b6a07f73)
  legitimately breaks (scrollbar backfill in Text.init) — orchestrator re-freezes in
  Wave C after re-verifying that test's spot-checks. Harness rects shift
  (20,...)→(4,...) so frame math stays byte-identical (O16 §2).
- R-P8-13: boot.zig is born (S-07 §4): assembles Chrome+Row(Column(Window)) with the
  cited literal tag strings; main_wasm and acceptance both use it. Chrome.zig is an
  S-07 tree addition (flag in report). body_bord changes to 0x99994CFF.

## Waves (each ONE opus agent, sequential)

- W1: Text.zig deltas (What/w/all/scrollr/lastsr + acme-faithful init + resize) +
  core/text/scroll.zig (scrPos/scrDraw/scrollClick) + core/Window.zig + the harness
  rect shift. Per phase8-chrome.md §2-§4.
- W2: core/Chrome.zig + core/Column.zig + core/Row.zig + layout tests. Per
  phase8-chrome.md §1, §5-§6.
- W3: Editor routing (row/focus/gesture_text/mouse_pt/hitTest + rules) + core/boot.zig
  + core.zig exports + main_wasm rewiring (+ wheel keeps mouse_pt fallback). Per
  phase8-routing.md.
- Wave C (orchestrator): re-freeze phase-7 stream hash; phase-8 acceptance scenes
  (boot chrome + two-window) with FROZEN-ACCEPT-8; smoke update; report; merge.
