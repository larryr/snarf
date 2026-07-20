# Phase 7 contract — scroll + snarf/chords/double-click (master)

Side files: phase7-scroll.md (O14) + phase7-snarf.md (O15). Hard gates unchanged.
Sequencing: 7a (scroll, ONE opus agent) merges FIRST; 7b (snarf+chords+double-click,
ONE opus agent) builds on top — both touch typing.zig/Editor.zig.

## Rulings

- R-P7-1: scrollbar strip + scrl.c defer to the windows phase (O14 §0 verified safe;
  both textscrdraw call sites become FLAG comments).
- R-P7-2: wheel = synthetic Kscrollone{up,down} runes through typeRune (acme.c:618-628);
  1 line/notch (libdraw scroll.c default); wheel does NOT break the typing run.
- R-P7-3: Kup/Kdown SCROLL without moving the caret (text.c:694-727) — port faithfully.
- R-P7-4: type-over-selection = cut(dosnarf=TRUE, docut=TRUE) (text.c:823 — acme snarfs
  replaced text; corrects the F-6 placeholder). Paste's self-cut is dosnarf=FALSE
  (exec.c:1046).
- R-P7-5: snarf is Editor-owned UTF-8 (vs the C's Rune snarfbuf — benign divergence,
  captured via chunked Buffer.read so U+FFFD semantics match File.captureText).
  /dev/snarf + clipboard sync deferred (S-05 §7).
- R-P7-6: chord ops edge-triggered on button-set change (replaces blocking readmouse —
  behavioral identity, mechanism divergence, commented); gesture ends only when ALL
  buttons release; one seq/mark per chord op, re-armed after toggle-undo.
- R-P7-7: double-click = press-time expansion (the C's :1018-1034), incremental trigger
  via nullable Text.last_click; NO textclickhtmlmatch (p9p-only); no triple-click.
- R-P7-8: 7b is ONE agent covering O15's waves A+B+C (all share handleMouse/typing
  seams).
