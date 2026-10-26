# ADR-0007 — Snarf's own color schemes, selectable with `-colors=name`

Status: **Accepted (2026-10-26, Larry's direction in session) · implementation: phase 19
(agents/contracts/phase19-colors.md)** · Supersedes: nothing — this is a new decision. The
port's prior practice of carrying acme's palette verbatim was fidelity convention
(`Chrome.zig`'s DIVERGENCE comments), not an ADR. Related: ADR-0003 (all drawing stays
draw-protocol writes — unchanged), ADR-0005 (browser freeze — constrains how the browser
host takes this change).

Design record: `notes/claude/snarf-color-scheme-proposal-2026-10-26.md` (candidates,
WCAG contrast math, migration table) grounded in
`notes/claude/acme-color-research-2026-10-26.md` (the verified acme palette record).
Visual comparison: https://claude.ai/artifact/EMLYDChSLzr9p6J5MGhr9S

## Context

Snarf has so far reproduced acme's palette exactly (`src/core/Chrome.zig`, citing
`acme.c:1036-1086`). Research into why acme's colors are what they are found **no primary
statement by Pike or Cox** — the "best colors to stare at all day" story is unsourced
folklore (research notes §2). What the artifacts do show, and what snarf keeps as design
principles, is structural: black text everywhere; backgrounds as ~25% tints of a saturated
nominal (`allocimagemix`); hue encodes region kind (body vs. tag), lightness encodes state
(rest vs. selected, a darker tint of the same hue); saturation reserved for transient or
exceptional state (B2/B3 sweeps, the dirty button). Larry wants snarf to have its own
visual identity within those principles, with the original available by name, and the
schemes named after New Hampshire mountains.

## Decision

1. **Four named schemes ship**, selected at `snarf-native` startup with **`-colors=name`**:

   | Name | Was (proposal) | Character | body BACK | tag BACK |
   |------|----------------|-----------|-----------|----------|
   | `chocorua` | A — "Manila" | **default** — manila-paper body, periwinkle tag; warm granite and alpenglow | `FFF2E5` (mix of `FFCC99`) | `EEEEFF` (mix of `BBBBFF`) |
   | `whiteface` | B — "Rio" | rio's greys verbatim, white body, rio's title-bar tag family | `FFFFFF` | `E7FAFA` (mix of `9EEEEE`) |
   | `monadnock` | C — "Dusk" | dark; the burned-bare summit | `22201C` | `1C2228` |
   | `acme` | baseline | the original, byte-exact (`acme.c:1044-1085`) | `FFFFEA` | `EAFFFF` |

   The full per-slot token tables, contrast ratios, and the B2/B3-sweep/dirty-button
   invariants are in the proposal's §2–3; this ADR fixes the scheme **names, count,
   selection mechanism, and default**. Slot-level values are normative in
   `src/core/Palette.zig` (the proposal is their design record); tuning a value after the
   first native screenshot is implementation under this ADR, not a new decision — a new
   decision is adding/removing a scheme's *structure* (new slots, per-window palettes,
   runtime switching).

2. **Selection is a startup flag, native only.** `-colors=name` (exact form, `=`
   required); an unknown name fails fast listing the valid names. No environment
   variable, no runtime switching, no per-window palettes — all deferrable later without
   superseding this ADR.

3. **The default is `chocorua`, on both hosts.** The palette constants live in shared
   core, so the frozen browser host (ADR-0005) takes the new default as a core value
   change — but it does **not** grow the `-colors` selector (that would be a new browser
   feature, which the freeze forbids). `web/index.html`'s page ground (`#ffffea`) follows
   the default.

4. **The palette becomes data.** `Chrome.zig`'s comptime `palette` namespace becomes a
   `Palette` value struct in a new `src/core/Palette.zig` (file-as-struct, S-07), with
   the four schemes as named constants and a name-lookup function. It gains `text`,
   `ground`, and `rule` fields for what today is hard-wired `display.black`/
   `display.white` — this is what makes `monadnock` pure data. `Chrome.init` takes the
   selected palette.

5. **Goldens re-freeze once, against `chocorua`**: FROZEN-ACCEPT-8, -9, -10, -12B, -13B
   (orchestrator-authorized in the phase 19 contract, with per-scene pixel spot-checks
   required before accepting each new hash, per R-P2-7). The palette-independent fixture
   tests (ACCEPT-6a/6b/7) allocate their own colors and stay untouched.

## Consequences

- Deliberate, recorded divergence from acme.c color fidelity; `Chrome.zig`'s palette
  DIVERGENCE comment points here. `-colors=acme` preserves byte-exact fidelity for
  comparison screenshots and paper-matching.
- Contrast is documented, not folklore: every text pair in every scheme ≥ 7:1 (AAA);
  `chocorua` is the only light scheme whose both scrollbars clear WCAG 1.4.11's 3:1
  (acme: 3.0/3.1). `whiteface`'s 2.5:1 tag scrollbar is accepted as the price of rio
  verbatim. (Proposal §3.)
- A future scheme is a `Palette` constant plus a name — no new ADR unless slot structure
  changes.
- The B2 red / B3 green sweeps and the dirty-button square are invariant across light
  schemes (muscle memory); `monadnock` recolors the dirty square (`E8B04A`) because
  `000099` fails on a dark tag.
