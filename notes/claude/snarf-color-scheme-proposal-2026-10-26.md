# Snarf color scheme proposal — 2026-10-26

**ADOPTED 2026-10-26 as ADR-0007** (`docs/spec/adr/0007-snarf-colors.md`) with Larry's
renames — the schemes are named after New Hampshire mountains: A "Manila" → **`sunapee`**
(default; renamed from the initial pick "chocorua" on 2026-10-26), B "Rio" →
**`whiteface`**, C "Dusk" → **`monadnock`** (no longer deferred — it
ships), and the original is **`-colors=acme`**. Selection is a native startup flag,
`-colors=name`. The open questions in §7 are resolved by the ADR. This file remains the
design record (token derivations, contrast math, migration table); the candidate letters
and working names below are historical.

Recommendation document only; no code changed. Ground truth for every Acme value and slot
below is `notes/claude/acme-color-research-2026-10-26.md` ("the research notes"); citations
of the form §1.2 point there. Snarf's live palette is `src/core/Chrome.zig:41-63`.
Aesthetic claims are marked **(judgment)**. Contrast ratios are WCAG 2.x, computed by script
(method in §4), rounded to one decimal.

## 1. Philosophy — derived from the artifacts, not folklore

The research notes found **no** Pike or Cox statement explaining the palette (§2); the
eye-strain story and the "triad" claim are unsourced folklore and are not used here. What
follows is read off the code itself:

1. **Text is the content; chrome recedes.** Every TEXT and HTEXT slot is black, there is no
   syntax coloring (§1.2), and both backgrounds are saturated constants knocked back toward
   white by `allocimagemix` (acme.c:1044, 1051): about 25% color, 75% white (§1.2; the
   "tint, don't color" reading is the research notes' labelled inference).
2. **Hue = region kind, lightness = state.** Body slots are all one hue (yellow, HSV 60°:
   FFFFEA / EEEE9E / 99994C); tag slots are a different hue (cyan 180°, with a purple-blue
   240° border). Selection is a *darker tint of the region's own hue* (HIGH), not a foreign
   color, and the text stays black (text.c:1170, 1188).
3. **Saturation is for transient or exceptional state only.** The only saturated fills are
   the B2/B3 sweeps (AA0000, 006600; acme.c:1084-1085), drawn with *white* text
   (text.c:1294-1307), and the dirty-button center (DMedblue; acme.c:1077).
4. **Solid fills only.** Snarf allocates pre-mixed 1x1 solids (`Chrome.zig:12-14`); no
   gradients, no alpha. Any scheme must therefore be expressible as opaque RGBA32 constants.
5. **Structure is fixed.** Five slots per frame (BACK, HIGH, BORD, TEXT, HTEXT), scrollbar =
   BORD track + BACK thumb (scrl.c:73-76), tag/body rule = tag BORD (wind.c:74), black rules
   and white ground between columns (cols.c:32, 45; rows.c:31, 45). Only values change.

Acme's measured hue spread: body 60°, tag 180°, tag BORD 240°. That is not a triad (that
would need 60/180/300); it is a warm/cool pair 120° apart. Nothing in the record says the
spacing was chosen on purpose.

## 2. Candidate schemes

Column legend: values are `0xRRGGBB` (append `FF` for snarf's `Color`). "=" means unchanged
from Acme. Acme's values are repeated for reference.

### Candidate A — "Manila" (lineage scheme) — **recommended**

Keep Acme's construction (a nominal saturated pastel, mixed 63/255 toward white with the
same `mix()`) but move the hue pair: a **warm manila/paper body** (nominal `FFCC99` →
`FFF2E5`, HSV 30°) and a **cool periwinkle tag** (nominal `BBBBFF` → `EEEEFF`, 240°).
Rationale **(judgment)**: "snarf" is Plan 9's clipboard; manila paper is the ownable,
non-yellow reading of "a page you write on", and periwinkle extends the libdraw
`DPurpleblue` that Acme already uses for tag borders and the column button, so the tag
looks like Acme's family while the body no longer looks like Acme. The hues are 150° apart:
a warm/cool split close to Acme's 120°, deliberately *not* claimed as complementary or
triadic. Body and tag remain distinguishable in peripheral vision because they sit on
opposite sides of the warm/cool divide.

### Candidate B — "Rio" (quiet greys + one accent)

Acme's sibling rather than its child: rio's real palette (§3 —
`rio/wind.c:43-56`, `data.c:178-179`) for the body, and rio's title-bar accent family for
the tag. Body is rio's white text area with rio's 0xCCCCCC selection and 0x999999 border;
the tag is `mix(DPalegreygreen)` = `E7FAFA` with `DPalegreygreen` selection and
`DGreygreen` border. Every value is either a rio grey (multiple of 0x11) or an existing
libdraw constant. Rationale **(judgment)**: the most "Plan 9" option and the least
ownable; a pure-white body is the highest-glare choice of the three.

### Candidate C — "Dusk" (dark) — **FUTURE / secondary variant only**

Edwood's `vampira` palette shows demand for a dark Acme (§4). Near-black warm body,
near-black cool tag, light warm/cool text. It cannot be done by value changes alone: TEXT
and HTEXT are hard-wired to `display.black` (`Chrome.zig:125-126`) and inter-column ground
is `display.white` (Column.zig:68, 218; Row.zig:62, 129, 187, 203; RowLoad.zig:181;
boot.zig:182). Snarf's near-term default stays light.

### Token table (every §1.2 slot)

| Slot | Acme (today) | A — Manila | B — Rio | C — Dusk (future) |
|------|--------------|------------|---------|-------------------|
| body BACK | FFFFEA (mix FFFFAA) | **FFF2E5** (mix FFCC99) | FFFFFF | 22201C |
| body HIGH | EEEE9E | **F2D2A8** | CCCCCC | 4A4436 |
| body BORD (track, thumb edge) | 99994C | **A47F54** | 999999 | 7A7258 |
| body TEXT / HTEXT | 000000 / 000000 | = | = | E6E2D6 / E6E2D6 |
| tag BACK | EAFFFF (mix AAFFFF) | **EEEEFF** (mix BBBBFF) | E7FAFA (mix 9EEEEE) | 1C2228 |
| tag HIGH | 9EEEEE | **CCCCEE** | 9EEEEE | 3A4654 |
| tag BORD (track, sep. line) | 8888CC | **7C7CC4** | 55AAAA | 707A94 |
| tag TEXT / HTEXT | 000000 / 000000 | = | = | DCE4EE / DCE4EE |
| col/row header box (`colbutton`) | 8888CC | **7C7CC4** | 55AAAA | 707A94 |
| window button, clean | tag BACK + tag BORD ring | = (EEEEFF + 7C7CC4) | = (E7FAFA + 55AAAA) | = (1C2228 + 707A94) |
| window button, dirty inner square | 000099 | = 000099 | = 000099 | E8B04A |
| B2 sweep (white text on) | AA0000 | = | = | = |
| B3 sweep (white text on) | 006600 | = | = | = |
| body scrollbar track / thumb | 99994C / FFFFEA | A47F54 / FFF2E5 | 999999 / FFFFFF | 7A7258 / 22201C |
| tag scrollbar track / thumb | 8888CC / EAFFFF | 7C7CC4 / EEEEFF | 55AAAA / E7FAFA | 707A94 / 1C2228 |
| tag/body separator line | tag BORD | = (7C7CC4) | = (55AAAA) | = (707A94) |
| inter-column rules | 000000 | = | = | = |
| inter-column ground | FFFFFF | = | EEEEEE (rio grey) | 141414 |
| frame tick | TEXT over BACK | follows | follows | follows |

Measured HSV hues — A: body 30-34°, tag 240° (all three slots). B: body 0° (achromatic), tag
180°. C: body 40-46°, tag 210-223°. A and C keep "one hue per region" exactly.

B2/B3 are deliberately unchanged in A and B **(judgment)**: they already pass 7:1 with white
text, they are the only place saturation appears, and red = execute / green = look is
muscle memory for every Acme user. The dirty square stays `DMedblue` in A for the same
reason; it also sits naturally inside a periwinkle tag.

## 3. Contrast tables

Text pairs need ≥ 4.5:1 (AA) and ideally ≥ 7:1 (AAA). Non-text UI (thumb vs. track, button
ring vs. tag) uses the WCAG 1.4.11 3:1 target. Luminances L are shown for the background
(black has L = 0, white L = 1).

| Pair | Acme | A — Manila | B — Rio | C — Dusk |
|------|------|-----------|---------|----------|
| body TEXT on BACK | 20.7 (L .9872) | **19.1** (L .9042) | 21.0 (L 1.0) | 12.6 (E6E2D6 L .7607 on L .0146) |
| body HTEXT on HIGH | 17.4 (L .8179) | **14.6** (L .6780) | 13.1 (L .6038) | 7.5 (on L .0586) |
| tag TEXT on BACK | 20.2 (L .9623) | **18.3** (L .8655) | 19.5 (L .9226) | 12.5 (DCE4EE L .7688 on L .0154) |
| tag HTEXT on HIGH | 15.9 (L .7459) | **13.4** (L .6220) | 15.9 (L .7459) | 7.5 (on L .0592) |
| white on B2 AA0000 | 7.8 (L .0855) | 7.8 | 7.8 | 7.8 |
| white on B3 006600 | 7.2 (L .0950) | 7.2 | 7.2 | 7.2 |
| body thumb vs track | 3.0 (L .3008) | **3.3** (L .2371) | 2.8 (L .3185) | 3.4 (L .1688) |
| tag thumb vs track / ring vs tag | 3.1 (L .2720) | **3.3** (L .2269) | 2.5 (L .3358) | 3.7 (L .1950) |
| dirty square vs tag BACK | 13.9 (L .0230) | **12.5** | 13.3 | 8.2 (L .4870) |
| BACK vs HIGH (state visibility) | 1.2 body / 1.3 tag | 1.3 / 1.4 | 1.6 / 1.2 | 1.7 / 1.7 |

Worst text ratio per scheme: Acme 7.2, **A 7.2** (B3 sweep), B 7.2, C 7.2 (sweep) / 7.5
(selection). Every text pair in every scheme passes AAA (≥ 7:1). Non-text: A is the only
light scheme where both scrollbars clear 3:1; B's tag border (`DGreygreen`) misses at 2.5,
the price of using rio's constants verbatim. The last row is not a WCAG check: it shows
that HIGH is a *lightness* step of the same hue; Acme's own step is only 1.2-1.3, so the
schemes match it rather than exaggerate it **(judgment)**.

The tag BORD in A was darkened from `DPurpleblue` 8888CC (2.8:1 on EEEEFF) to 7C7CC4 to
clear 3:1; body BORD was tuned from a first draft B08A60 (2.9) to A47F54 likewise.

## 4. Method

WCAG 2.x relative luminance: each 8-bit channel c → s = c/255; linear = s/12.92 if
s ≤ 0.04045 else ((s + 0.055)/1.055)^2.4; L = 0.2126 R + 0.7152 G + 0.0722 B; ratio =
(L_light + 0.05)/(L_dark + 0.05). Worked example, A body text: FFF2E5 → R 1.0, G
(0.949+.055)/1.055 = 0.9517, ^2.4 = 0.8879; B (0.898+.055)/1.055 = 0.9034, ^2.4 = 0.7835;
L = 0.2126 + 0.6350 + 0.0566 = 0.9042; (0.9042 + 0.05)/0.05 = 19.1. Mixed backs use the same
integer formula as `Chrome.zig`'s test `mix()`: (c·63 + 255·192)/255 per channel, e.g.
0xCC → (204·63 + 48960)/255 = 242 = 0xF2.

## 5. Recommendation: A — Manila

Pitch: *Acme's construction, snarf's hues — a manila-paper body and a periwinkle tag, each
still only a quarter-strength tint, with black text everywhere and saturation reserved for
the sweeps and the dirty button.*

Why A over B and C **(judgment throughout)**:
- It is the only candidate that is both recognizably *not* Acme at a glance (the yellow
  body is the signature Cox describes, §2: "yellow windows and blue bars") and still
  obviously Acme's structure and philosophy.
- It keeps the provenance story intact: two nominal constants + the existing `mix()`
  derivation, testable the same way `Chrome.zig:177-182` tests Acme's today.
- It improves the non-text contrast (both scrollbars ≥ 3.3) while every text pair stays
  ≥ 13.4:1 except the unchanged sweeps (7.2/7.8).
- It is a pure value change: no new slots, no new `Chrome` fields, no new draw calls. B
  needs a new `ground` field (EEEEEE ground) and C needs new text and ground solids.
- Risk: manila is closer to Acme's yellow than periwinkle is to cyan; side by side, A's
  body reads as "peach paper", not "yellow" — the decisive check is a real screenshot
  on native (devdraw) before freezing, not this table.

## 6. Migration notes for A (sketch, not applied)

**`src/core/Chrome.zig`**
- `palette` (lines 41-63): `tag_back` 0xEAFFFFFF → 0xEEEEFFFF; `tag_high` 0x9EEEEEFF →
  0xCCCCEEFF; `tag_bord` 0x8888CCFF → 0x7C7CC4FF; `body_back` 0xFFFFEAFF → 0xFFF2E5FF;
  `body_high` 0xEEEE9EFF → 0xF2D2A8FF; `body_bord` 0x99994CFF → 0xA47F54FF; `col_button`
  0x8888CCFF → 0x7C7CC4FF. `mod_blue`, `but2`, `but3` unchanged.
- Add two nominal constants to `palette`, e.g. `body_tint: Color = 0xFFCC99FF` and
  `tag_tint: Color = 0xBBBBFFFF`, documented as "snarf palette; mixed like acme.c:1044/1051".
- **Keep `mix()`** (test-only, line 163) — it is now the proof that the snarf backs are
  quarter-strength tints, exactly as it proves Acme's today.
- Update doc comments: the header (lines 7-14) and `palette` comments currently cite
  acme.c:1044-1082 as the source of values; they become a recorded DIVERGENCE pointing at
  this proposal / its ADR, with the acme.c citations retained for the *slot structure*.
- No change to `init`, the slot arrays, or any draw code.

**`src/draw/proto.zig`** (line ~143): **no change recommended.** It carries libdraw's
`draw.h` names; snarf's tints are not libdraw constants and belong in `Chrome.palette`.
(If B were chosen, `DPalegreygreen`/`DGreygreen` would be added there as draw.h names.)

**Test assertions that must change (Chrome-driven):**

| Site | Old → new | Note |
|------|-----------|------|
| Chrome.zig:179 | `0xEAFFFFFF == mix(0xAAFFFFFF)` → `0xEEEEFFFF == mix(0xBBBBFFFF)` | |
| Chrome.zig:180 | `palette.tag_back == mix(0xAAFFFFFF)` → `mix(palette.tag_tint)` | |
| Chrome.zig:181 | `0xFFFFEAFF == mix(0xFFFFAAFF)` → `0xFFF2E5FF == mix(0xFFCC99FF)` | |
| Chrome.zig:182 | `palette.body_back == mix(0xFFFFAAFF)` → `mix(palette.body_tint)` | |
| Chrome.zig:185 | 0x9EEEEEFF → 0xCCCCEEFF (tag_high) | comment `DPalegreygreen` dropped |
| Chrome.zig:186 | 0x8888CCFF → 0x7C7CC4FF (tag_bord) | |
| Chrome.zig:187 | 0xEEEE9EFF → 0xF2D2A8FF (body_high) | |
| Chrome.zig:188 | 0x99994CFF → 0xA47F54FF (body_bord) | |
| Chrome.zig:190 | 0x8888CCFF → 0x7C7CC4FF (col_button) | |
| accept.zig:536 | pixel (30,2) 0xEAFFFFFF → 0xEEEEFFFF | row tag; fix comment at 533-534 ("pale blue", "ivory", "yellowgreen") |
| accept.zig:1303 | pixel (30,2) 0xEAFFFFFF → 0xEEEEFFFF | row tag, phase-13b |
| accept.zig:581 | FROZEN-ACCEPT-8 hash → re-freeze | phase-8 boot chrome scene |
| accept.zig:690 | FROZEN-ACCEPT-9 hash → re-freeze | phase-9 B2 exec scene |
| accept.zig:866 | FROZEN-ACCEPT-12B hash → re-freeze | +Errors scene |
| accept.zig:1063 | FROZEN-ACCEPT-10 hash → re-freeze | Edit via B2 scene |
| accept.zig:1328 | FROZEN-ACCEPT-13B hash → re-freeze | acme boot scene |

Unchanged (verify, not edit): Chrome.zig:189, 222-223 (mod_blue, but2, but3);
accept.zig:538 (black band); select.zig:410, 484, 528 (local B2/B3 solids).

**Local-allocation sites (pass unchanged; recommend leaving them):** accept.zig:355-356 and
449-450 allocate their own 0xFFFFEAFF/0xEEEE9EFF solids, so assertions 384, 385, 386, 409,
490 and FROZEN-ACCEPT-6a/6b/7 hashes (390, 413, 425, 502) do not depend on `Chrome`. They test
the frame, not the palette; switching them to the new values would force four needless
re-freezes. Optionally reword their "acme palette" comments.

**Possibly affected, verify by running:** Editor.zig:496 write-stream hash — the scroll
harness appears to use fixture images, not `Chrome`, so it should not move.

**Outside `src/`:** `web/index.html:17` sets the page background `#ffffea` around the canvas;
it becomes `#fff2e5` if the browser host adopts the new palette (see Q2).

Re-freezing five goldens needs orchestrator sign-off per R-P2-7 (as recorded in the
`FROZEN-*` comments, e.g. accept.zig:263, Editor.zig:496-502). Do the spot-check updates
first, confirm on a native screenshot, then re-freeze in one commit.

## 7. Open questions for Larry (product decisions)

1. **Fixed vs. configurable.** Should the palette be fixed (like acme) or build-time
   selectable (like acme3k, §4)? *Recommend:* fixed now, one palette, but keep every value in
   `Chrome.palette` so a later `-Dpalette=` build option (or a `/dev`-file override) is a
   small change. Defer runtime theming until the dark variant (C) is actually wanted.
2. **Browser host (frozen per ADR-0005 amendment).** `Chrome.zig` is in `src/core`, shared by
   both hosts, so by default *both* change. *Recommend:* change both — it is a core value
   change, not a browser feature, and a per-host palette would add a build fork to a frozen
   host just to preserve old colors. Update `web/index.html:17` with it. The alternative
   (browser keeps Acme colors) needs a build-time switch and two sets of goldens.
3. **Does this need an ADR?** The palette is not one of the binding source choices in
   `CLAUDE.md`, but it is a deliberate divergence from acme.c fidelity and re-freezes five
   goldens. *Recommend:* a short numbered ADR ("snarf palette") so the divergence has a
   home the `Chrome.zig` DIVERGENCE comment can cite.
4. **Keep an "acme" palette at all?** If Q1 lands on configurable, *recommend* keeping
   Acme's exact values as a named alternative, for users and for paper-fidelity screenshots.
5. **Hue choice sign-off.** Manila/periwinkle is a taste call **(judgment)**; approve on a
   native screenshot, not on hex. B (Rio) is the fallback if the goal shifts from "ownable"
   to "most Plan 9".
