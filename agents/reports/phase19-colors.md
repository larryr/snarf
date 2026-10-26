# Phase 19 — named color schemes, `-colors=NAME` (as-built)

Contract: `agents/contracts/phase19-colors.md` · Decision: ADR-0007 · Branch
`phase19-colors` (commits 596e31e, 8ec5c24, 619573e + this report).

## What landed

- `src/core/Palette.zig` (new, 222 lines): 14 `Color` fields; `chocorua` (default),
  `whiteface`, `monadnock`, `acme` with the R-P19-1 values; `default`, `names` (sorted),
  `fromName`. It also holds the pure flag parser: `Palette.parseFlag(arg) Flag`, where
  `Flag` is `{ other, palette, unknown }`. The `mix()` helper moved here, and its tests
  prove the tint derivations.
- `Chrome.zig`: the comptime `palette` namespace is deleted.
  `init(allocator, display, font, pal)` stores `pal` and owns four new solids
  (`tag_text`, `body_text`, `ground`, `rule`). `tag_cols[3..4]` and `body_cols[3..4]`
  point at the region's text solid. The true `black`/`white` handles are kept.
- `boot.Options.palette: *const Palette = Palette.default` goes to `Chrome.init`.
  `main_native` passes the parsed palette and `wasm_boot` passes `core.Palette.default`
  explicitly.
- `main_native.colorsFromArgs`: the last `-colors=NAME` wins. If NAME is unknown or
  empty, or the arg is a bare `-colors`, it prints one stderr line with the four names
  and calls `exit(2)` before the devdraw path is resolved or spawned. Other args are
  ignored, as before.
- `web/index.html` `#ffffea` → `#fff2e5`. `core.zig` exports `Palette`.
- Docs: the S-07 §4 tree and §6 deps now list `Palette.zig`, the README's native section
  has a `-colors=` line, and the Chrome.zig header DIVERGENCE paragraph cites ADR-0007.

## R-P19-2 classification (pre-phase file:line)

| Site | Was | C cite | Class | Now |
|------|-----|--------|-------|-----|
| Chrome.zig:125 `tag_cols[3]`,`[4]` | `c.black` | acme.c:1047-1048 | text | `&tag_text_img` |
| Chrome.zig:126 `body_cols[3]`,`[4]` | `c.black` | acme.c:1054-1055 | text | `&body_text_img` |
| Column.zig:68 | white | cols.c:32 | ground | `chrome.ground` |
| Column.zig:81 | black | cols.c:45 | rule | `chrome.rule` |
| Column.zig:162 | black | cols.c:119-120 | rule | `chrome.rule` |
| Column.zig:218 | white | cols.c:184-187 | ground | `chrome.ground` |
| Column.zig:266 | black | cols.c:249 | rule | `chrome.rule` |
| Column.zig:286 | black | cols.c:267 | rule | `chrome.rule` |
| Row.zig:62 | white | rows.c:31 | ground | `chrome.ground` |
| Row.zig:75 | black | rows.c:45 | rule | `chrome.rule` |
| Row.zig:129 | white | rows.c:76 | ground | `chrome.ground` |
| Row.zig:137 | black | rows.c:82-84 | rule | `chrome.rule` |
| Row.zig:187 | white | rows.c:223-225 | ground | `chrome.ground` |
| Row.zig:203 | white | rows.c:235 | ground | `chrome.ground` |
| Row.zig:257 | black | rows.c:118 | rule | `chrome.rule` |
| Row.zig:274 | black | rows.c:118-ish band | rule | `chrome.rule` |
| RowLoad.zig:181 | white | rows.c:629 | ground | `chrome.ground` |
| RowLoad.zig:186 | black | rows.c:632-634 | rule | `chrome.rule` |
| colgrow.zig:118 | black | cols.c:419 | rule | `chrome.rule` |
| colgrow.zig:148 | black | cols.c (colgrow band) | rule | `chrome.rule` |
| colgrow.zig:166 | black | cols.c (colgrow band) | rule | `chrome.rule` |
| boot.zig:182 | white | acme.c:551 | ground | `chrome.ground` |

These 22 sites are every `chrome.black`/`chrome.white` consumer in the tree. None of
them is true-white or true-black, so `Chrome.black`/`white` now have no in-tree readers.
They are kept as R-P19-2 directs.

- **The "wind-cited window-border fills" in the contract do not exist as black uses.**
  `Window.zig:126` draws the tag/body divider in `tagcols[BORD]` (wind.c:72-74). The C's
  other window-border redraws use BORD and body BACK (wind.c:233, 238; research §1.2).
  Nothing changed there.
- **The B2/B3 sweep text** comes from `f.display.white` in `draw/frame/select.zig:167`
  (text.c:1294), not from Chrome. It therefore stays true white in every scheme with no
  code change.
- **The frame tick** draws in `f.col(.text)` (Frame.zig:233-235), so in monadnock it
  follows the light text automatically.

## Golden re-freeze (R-P19-6)

| Golden | Old | New |
|--------|-----|-----|
| FROZEN-ACCEPT-8 | 0xfd8b232d77d1f0bd | 0x50f4088420177753 |
| FROZEN-ACCEPT-9 | 0x8ca565d7961f44cf | 0xed519e1281abe53d |
| FROZEN-ACCEPT-12B | 0x86a3f4679b1b8d21 | 0xa60814356ac917d4 |
| FROZEN-ACCEPT-10 | 0xe9014ecfa82cbc4b | 0x2e5d14f8ee16c0be |
| FROZEN-ACCEPT-13B | 0x35f686fc5162d2cf | 0x3b4981b48586f66c |

**Spot checks.** Each new hash landed in the same commit (8ec5c24) as its spot checks.
`expectChocorua(hb, w)` asserts three pixels for a window: the tag back `EEEEFF`
(tag-frame top-right), the body back `FFF2E5` (body-frame bottom-right), and the body
scrollbar BORD `A47F54` (the strip's rightmost column, scrl.c:73-76). Each scene calls it
as follows:

| Scene | Windows checked | Extra pixel checks |
|-------|-----------------|--------------------|
| 8 | w1, win2 | (30,2) = `EEEEFF`; the existing rule-band check is unchanged |
| 9 | w1, `+Errors` | none |
| 12B | w1, `+Errors` | none |
| 10 | w | none |
| 13B | `/` dir window | (30,2) = `EEEEFF` |

**Byte-exactness proof (not committed).** I temporarily set
`Palette.default = &acme` and stubbed the chocorua checks. All five OLD hashes then
passed, and the only failure was the default-is-chocorua unit test. So the refactor
itself is draw-stream-identical, and the palette values are the only change.

Untouched, as R-P19-7 requires: ACCEPT-6a/6b/7 and their local solids in `accept.zig`,
and all of `select.zig`. The `Editor.zig` write-stream hash did not move.

## Tests added (R-P19-8)

- **Palette.zig:**
  - `fromName`: all four names resolve; bogus, empty and wrong-case names give null;
    `default == &chocorua`; `names` is sorted.
  - `mix` derivations: chocorua body = `mix(FFCC99)` and tag = `mix(BBBBFF)`; acme
    body = `mix(FFFFAA)` and tag = `mix(AAFFFF)`; whiteface tag = `mix(9EEEEE)` =
    `E7FAFA`.
  - acme's draw.h values, and the but2/but3/rule values that are the same in every
    scheme.
  - `parseFlag`: the accepted form, empty and bare names, and the `--colors=` and
    `-colorsX` forms that must be rejected.
- **Chrome.zig:** slot wiring (text solids in slots 3–4, ground/rule handles, true
  black/white are still the display's) and a monadnock init.
- **`src/accept_colors.zig` (new, pulled in from `accept.zig`'s test block):** the
  monadnock smoke. It boots one window, then adds an empty second column so the ground
  is visible.
  - Pixels checked: row tag back, the rule band, the ground, body back, body BORD, and
    the window's tag back.
  - Text checks: `body_text` and `tag_text` pixels are present, and no `000000` appears
    in the body or tag frames.
  - There is no golden hash for this scene.

## Gates (R-P19-10)

| Gate | Result |
|------|--------|
| `zig fmt --check src build.zig` | clean |
| `zig build` | ok |
| `zig build test --summary all` | 22/22 steps; 776/792 passed, 16 skipped, 0 failed |
| `node tools/smoke_wasm.mjs` | 40/40 |
| `zig build native` | ok |

**Smoke script.** `smoke_wasm.mjs` asserted the old row-tag color in two checks: lines
175-178, "pixel (0,0) …", and 261-265, "resized display still draws …". Both now expect
`EEEEFF` (238, 238, 255).

**2-second native launches.** No flag, `-colors=acme`, `-colors=monadnock` and
`-colors=whiteface` each stayed alive with a bundled `devdraw` child, printed the startup
line, and were killed by recorded PID. Afterwards no stray process remained.

**Failure launches.** `-colors=bogus`, `-colors=` and `-colors` each exit 2 with:
`snarf-native: unknown color scheme "…"; -colors= takes one of: acme chocorua monadnock whiteface`.

No native screenshot was taken; pixel correctness rests on the headless spot checks.

## Deviations / notes

1. **Palette is threaded through `boot.Options.palette` (defaulted), not a new
   positional `boot()` parameter.** There are about 30 test `boot()` callers. Both hosts
   set the field explicitly, which satisfies "the hosts pass it explicitly".
2. **The flag parser lives in `Palette.zig` (`parseFlag`), not `main_native.zig`.**
   `main_native.zig` has no test root and the `host` module does not import `core`, so
   core is the only place the pure parser gets unit-tested.
3. **`accept.zig` grew from 1329 to 1364 lines.** It was already over the cap as the
   orchestrator-owned test root. The monadnock smoke went to a new file to limit growth,
   and the re-freeze notes are 2 lines each.
4. **The contract's "wind-cited window-border → rule" class is empty** (see the R-P19-2
   notes above).
5. **Pre-existing, not palette-related, not fixed.** The first smoke draft booted with
   `dir_boot` and then called `Tree.addWindow`. In that state the new window's body
   scrollbar is never painted: it stays body BACK under `Palette.acme` too. The
   production paths (`readFile` in 13B, the non-dir boot) paint it correctly. The cause
   may be a stale `lastsr` memo, or a `coladd` back-fill after `scrDraw`, on the
   test-only `addWindow` path. It is worth a ticket. The smoke uses the non-dir boot
   plus `row.add` instead.
