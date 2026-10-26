# Phase 19 — named color schemes, `-colors=name` (ADR-0007)

Binding contract (fable, 2026-10-26). Implements `docs/spec/adr/0007-snarf-colors.md`.
Value provenance: `notes/claude/snarf-color-scheme-proposal-2026-10-26.md` §2 (token
tables) and §6 (migration table); acme facts:
`notes/claude/acme-color-research-2026-10-26.md`. Branch `phase19-colors`, worktree
`.worktrees/phase19-colors`, stacked on `adr-0007-snarf-colors` (PR #37).

## Rulings

- **R-P19-1 — `src/core/Palette.zig`, new file, file-as-struct.** Fields (all
  `draw.proto.Color`): `body_back, body_high, body_bord, body_text, tag_back, tag_high,
  tag_bord, tag_text, mod, col_button, but2, but3, ground, rule`. Decls: the four preset
  constants, `pub const default: *const Palette = &chocorua;`, `pub const names` (the
  four names, sorted), and `pub fn fromName([]const u8) ?*const Palette`. Values
  (0xRRGGBBFF; per ADR-0007 / proposal §2):

  | field | chocorua | whiteface | monadnock | acme |
  |-------|----------|-----------|-----------|------|
  | body_back | FFF2E5 | FFFFFF | 22201C | FFFFEA |
  | body_high | F2D2A8 | CCCCCC | 4A4436 | EEEE9E |
  | body_bord | A47F54 | 999999 | 7A7258 | 99994C |
  | body_text | 000000 | 000000 | E6E2D6 | 000000 |
  | tag_back | EEEEFF | E7FAFA | 1C2228 | EAFFFF |
  | tag_high | CCCCEE | 9EEEEE | 3A4654 | 9EEEEE |
  | tag_bord | 7C7CC4 | 55AAAA | 707A94 | 8888CC |
  | tag_text | 000000 | 000000 | DCE4EE | 000000 |
  | mod | 000099 | 000099 | E8B04A | 000099 |
  | col_button | 7C7CC4 | 55AAAA | 707A94 | 8888CC |
  | but2 / but3 | AA0000 / 006600 | same | same | same |
  | ground | FFFFFF | EEEEEE | 141414 | FFFFFF |
  | rule | 000000 | 000000 | 000000 | 000000 |

  HTEXT = TEXT in every scheme (one `*_text` per region covers slots 3 and 4).

- **R-P19-2 — classify every `chrome.black` / `chrome.white` consumer.** Chrome KEEPS
  `black`/`white` as true display-black/white handles (the B2/B3 sweep text must stay
  white in every scheme — `select.zig:410,484,528` area; verify what those actually
  reference). Chrome GAINS `ground: *Image` and `rule: *Image` handles plus per-region
  text solids wired into `tag_cols[3..4]`/`body_cols[3..4]`. Re-point: ground fills
  (`Column.zig:68,218`, `Row.zig:62,129,187,203`, `RowLoad.zig:181`, `boot.zig:182`) →
  `chrome.ground`; black separator rules (`cols.c`/`rows.c`-cited draws) →
  `chrome.rule`; window-border fills (wind-cited) → `chrome.rule`. The as-built report
  MUST list every former black/white use with file:line and its classification
  {text, rule, ground, true-white, true-black}. When in doubt, match what acme does with
  the slot (research notes §1.2) and say so.

- **R-P19-3 — `Chrome.init(allocator, display, font, pal: *const Palette)`.** The
  comptime `palette` namespace in `Chrome.zig` is DELETED (moves to `Palette.zig`).
  Chrome stores `pal` and allocates solids from it (including the two text solids and
  ground/rule solids — rule may alias `display.black` when `pal.rule == black`, but a
  plain owned solid everywhere is simpler and fine). All existing `Chrome.init` call
  sites (grep found 9 besides Chrome's own tests: look.zig:345, errors.zig:360,
  boot.zig:215, Column.zig:358, Window.zig:379, Row.zig:344, cmd_edit.zig:145,
  cmd_look.zig:117, plus Chrome.zig tests) pass `core.Palette.default` unless a test
  specifically exercises another scheme. `boot`'s assemble path takes the palette as a
  parameter and threads it to `Chrome.init`.

- **R-P19-4 — native flag.** `snarf-native` accepts `-colors=NAME` (exact `=` form) at
  startup. Unknown or empty NAME: print to stderr one error line plus the valid names
  (use `Palette.names`), exit nonzero, never spawn devdraw. No env var, no other flag
  forms. Default (flag absent) is `Palette.default`.

- **R-P19-5 — browser host.** Frozen (ADR-0005): takes the new DEFAULT only — no
  selector of any kind. `web/index.html` page ground `#ffffea` → `#fff2e5` (currently
  line 17). `main_wasm`/browser boot path uses `Palette.default` explicitly.

- **R-P19-6 — goldens.** FROZEN-ACCEPT-8 (accept.zig:581), -9 (:690), -10 (:1063),
  -12B (:866), -13B (:1328) re-freeze ONCE against chocorua. Pre-authorized by the
  orchestrator **only after** each scene gains (or already has) at least 3 permanent
  pixel assertions proving the new palette is actually in the frame (body back
  0xFFF2E5FF, tag back 0xEEEEFFFF, and one of high/bord where the scene shows one) —
  the spot checks land in the same commit as the new hash. Line numbers above are
  pre-phase values; re-locate by the FROZEN-* comment markers.

- **R-P19-7 — untouched.** `accept.zig`'s self-allocating fixture tests (ACCEPT-6a/6b/7,
  local solids at ~:355,:449) and `select.zig`'s local B2/B3 solids stay byte-identical.
  `agents/HANDOFF.md` and `agents/NEXT-PHASES.md` are off-limits to pipeline agents.

- **R-P19-8 — new tests.** (a) `Palette.fromName`: all four names resolve, a bogus name
  is null, `default == &chocorua`. (b) Value tests: chocorua/acme backs equal
  `mix(nominal)` with the existing `mix()` helper (move it with the values or keep in
  Chrome tests — either, but it must still prove the tint derivation:
  chocorua body = mix(0xFFCC99FF), tag = mix(0xBBBBFFFF); acme body = mix(0xFFFFAAFF),
  tag = mix(0xAAFFFFFF)); whiteface tag_back = mix(0x9EEEEEFF) = 0xE7FAFAFF. (c) A
  monadnock smoke: assemble the boot scene with `&Palette.monadnock`, spot-check ≥4
  pixels (body back, tag back, ground, one text pixel ≠ black-on-dark). No golden hash
  for monadnock. (d) `-colors` parsing unit test if the parser is a pure function
  (make it one: `parseColors([]const u8) ?*const Palette` or similar seam).

- **R-P19-9 — docs.** `docs/spec/07-source-layout.md`: §4 tree + §6 import notes gain
  `Palette.zig`. `README.md` native section: one line for `-colors=name` with the four
  names. `Chrome.zig` header: palette DIVERGENCE paragraph now cites ADR-0007 (keep the
  acme.c citations for slot STRUCTURE). Update `accept.zig:533-534`-area comments that
  say "pale blue"/"ivory".

- **R-P19-10 — gates.** All must pass in the worktree: `zig fmt --check src build.zig`,
  `zig build`, `zig build test --summary all` (0 fail), `node tools/smoke_wasm.mjs`
  (40/40 — note: if the smoke script asserts the old row-tag color anywhere, update it;
  report which), `zig build native` then a 2-second launch each of: no flag,
  `-colors=acme`, `-colors=monadnock` (process alive, devdraw spawned, startup line
  printed), and `-colors=bogus` (nonzero exit, name list on stderr). File caps: every
  touched file ≤ ~400 lines or no worse than before.

## Acceptance

Implementation commits + `agents/reports/phase19-colors.md` (as-built: the R-P19-2
classification table, gate transcript summary, golden hash old→new table, deviations).
Commit trailer, every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
No pushes, no PRs — the orchestrator reviews first.
