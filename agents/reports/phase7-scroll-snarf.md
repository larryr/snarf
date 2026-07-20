# Phase 7 report — scroll + snarf/chords/double-click

Merged to `main`. Contracts: agents/contracts/phase7-{scroll-snarf,scroll,snarf}.md
(rulings R-P7-1..8). Suite: **290/290**; boundary verified; FROZEN-ACCEPT-7.

## Delivered

The editor is now livable: mouse-wheel + full keyboard scrolling (textsetorigin's
three-case incremental scroll, textshow's maxlines/4 caret placement, Kup/Kdown
scrolling WITHOUT moving the caret — faithful), double-click word/bracket/line
selection (acme's tables; no triple-click — line select IS the newline rule), the
snarf buffer, and the classic acme chords: B1-sweep + B2 cuts, + B3 pastes (selected),
with in-gesture toggle-undo and one undo transaction per chord op.

## Fidelity notes

- O15 CORRECTED the orchestrator's prompt from the C: type-over-selection SNARFS the
  replaced text (text.c:823 dosnarf=TRUE); paste's self-cut is the FALSE case.
- Chord ops are edge-triggered on button-set changes (mechanism divergence from the
  blocking readmouse; behavioral identity, tested).
- Divergences (all in-code cited): press-time-only double-click trigger; same-q gate;
  double-click→drag re-anchors at press_pt; ASCII-only isalnum in bsWidth (v1);
  UTF-8 snarf vs the C's Rune buffer.

## Deferred

/dev/snarf + browser clipboard (misc-devices phase, R-EDIT-14); scrollbar strip +
scrl.c (windows phase — verified purely visual); Kcmd snarf keys, ^U/^W (bsWidth
pre-paid); textclickhtmlmatch (p9p-only); B2/B3 standalone exec/look (phase 9).
