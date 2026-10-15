# Proposal: Markdown editing and rendered preview

**Status: PROPOSED** (three points decided by Larry 2026-10-14; see §8). Scheduled after M3. This is a SnarfProdd working note, not a requirement. It would reach `docs/product/` only via a PR once Larry agrees.
**Author:** SnarfProdd (PM). **Date:** 2026-10-14.

## 1. Editing: plain text in normal windows

- Markdown is edited as **plain text in ordinary snarf windows**. There is no special mode and no WYSIWYG.
- Light affordances at most, each one optional:
  - B3 on `[text](path)` or `path#anchor` opens the target through normal look and plumbing.
  - Possibly a helper for heading and list indentation.
- No syntax colouring is promised. That would be a separate decision.

## 2. Preview: a `Markdown` command opening a sibling window

- `Markdown`, as a tag word or a plumb action, renders the current window's file into a **preview window**.
- The preview opens as a **sibling in a side column**. It reuses the existing column if one is already there; otherwise it creates one at the right edge.
- The preview window:
  - is read-only;
  - is named after its source (see §7, file names);
  - has a tag carrying `Markdown` (refresh) and `Del`.
- **Decided (Larry, 2026-10-14):** running `Markdown` again on the same source re-renders into the existing preview window. There is **one preview per source file**, never a second copy.
- **Decided (Larry, 2026-10-14): the preview renders styled text from the start** (see §8).

## 3. Lineage: what acme does and doesn't do

- **acme has no renderer and no timed preview.** Everything it shows is text, and windows change only when someone writes to them.
- The closest precedent is **plumbing derived text into a new window**:
  - `plumb -d edit` sends data straight to acme;
  - a rule with `attr add action=showdata` makes acme open the message's data in a fresh window instead of opening a file.
- **Multi-column layout** is acme's native way to put related views side by side, e.g. source on the left and output or `+Errors` on the right.
- **Plumbing HTML to an external browser** (`plumb to web` / `plumb client $browser`) is the standard acme answer for "show it rendered". §5 option C keeps that path.
- Snarf's preview is therefore **acme-shaped**: a derived, read-only window written by a command. It is not a new kind of window.

## 4. Update policy (agreed with Larry)

| Trigger | Default? | Where | Notes |
|---|---|---|---|
| **`Put` on the source** | **On (default)** | Source window | The preview re-renders after a successful save. It is predictable and matches acme's "nothing changes until you act" model |
| **B2 click on the preview body** | On | Preview window | Manual refresh from the current (possibly unsaved) source buffer. The preview body is read-only, so B2 there has no other meaning |
| `Markdown` tag word | On | Either tag | Explicit refresh, and it opens the preview if none exists |
| Timed / debounced refresh | **Off (opt-in only)** | Per preview | e.g. `Markdown -live` or a ctl message. Debounced, roughly 500 ms after the last edit. Never the default |
| Chord in the source, e.g. B1-hold + B2 | Optional | Source window | Only if it doesn't collide with acme's B1-B2 cut chord. It needs a distinct gesture or modifier, to be decided with R-IN-06 |
| 2-finger swipe on the preview | Optional | Preview window | Only if the active trackpad profile delivers swipes (see the input mapping guide) |
| 3-finger gestures | **Never** | — | Larry uses three-finger drag |

## 5. Options considered

| Option | Verdict |
|---|---|
| A. **Timer refresh as the default** | Rejected as the default. Surprise redraws while typing, wasted renders, and un-acme-like. Kept only as an opt-in |
| B. **Live render on every keystroke / split WYSIWYG** | Rejected. It is costly, couples the editor to a renderer, and breaks the plain-text model |
| C. **External browser only** (render to HTML, plumb it to Safari) | **Decided (Larry, 2026-10-14): kept** as a complement: `Markdown -web` plumbs rendered HTML to the external browser for full fidelity (images, tables, math). On its own it fails the "stay in snarf" goal |
| D. **Sibling preview window, refreshed on Put or B2** (chosen) | It is acme-shaped, cheap, and readable by agents |

## 6. Fit with the architecture

- **Native-primary via devdraw** (ADR-0005 amendment). The preview is an ordinary snarf window drawn through devdraw, so it needs no new host capability. devdraw already supports multiple fonts and colours. The limit is acme's one-font-per-frame layout, so the preview needs its own multi-font renderer (§8).
- **Frozen WASM target.** No browser-specific work. The renderer must stay core-side and pure Zig (or a sidecar process), so it doesn't break the "WASM still compiles" CI check (#8). Browser parity is not a goal.
- **M5 agents.** The preview is **a file in snarf's 9P tree** (e.g. the window's `body`, plus a rendered-text file). Agents can then:
  - read rendered output the same way they read any window;
  - trigger a refresh by writing to `ctl`.

  This fits the M5 draft (agents as namespace clients). It depends on the M4 served tree.
- **Process service (M2).** If the renderer is external (`cmark` or `pandoc`), it runs through the M2 native process service, local and trusted per the 2026-10-11 decision.

## 7. Open questions

1. **Renderer:** `cmark` (C, CommonMark, small) vs `pandoc` (huge, very capable, external) vs a **Zig CommonMark parser** in core (WASM-safe and dependency-free, but there is work to do).
2. **Links:** do coloured links stay B3-able in the preview (open the target or plumb the URL)? Images, tables and math go via `-web` (decided); the open part is how the styled preview should mark where they were left out.
3. **Local-only security:** the renderer must never fetch remote URLs (images, includes) by default. Raw HTML is passed through or stripped? What happens when the source is on a **remote 9P mount**?
4. **Preview names in the 9P tree:**
   - `+Markdown` beside the file (like `+Errors`), or `file.md+preview`?
   - Is there a per-window `rendered` file under `/mnt/snarf/<id>/` for agents?

## 8. Decisions (Larry, 2026-10-14)

| # | Decision |
|---|---|
| D1 | **One preview per source file.** Re-running `Markdown` reuses the existing preview window |
| D2 | **`Markdown -web` is kept.** It plumbs rendered HTML to the external browser, for full fidelity |
| D3 | **The preview shows styled text from the start, not plain reflow.** See below |

**D3 in detail:**
- devdraw already supports multiple fonts and colours. The limit is acme's **one-font-per-frame** text layout.
- The preview therefore gets its **own multi-font renderer**:
  - bold, larger headings;
  - italics;
  - code in a fixed-width font;
  - coloured links.
- **Edit windows stay single-font**, as in acme.
- **Tables, images and math go via `-web`**, not the in-snarf preview.
- This is a new core capability: a multi-font frame for read-only preview windows. It needs an architect review, and probably an ADR.

## Revision log

| Date | Change |
|---|---|
| 2026-10-14 | v0.1 created (SnarfProdd). Records the update policy agreed with Larry; status PROPOSED, scheduled after M3 |
| 2026-10-14 | v0.2: Larry's decisions recorded (§8). D1: one preview per source. D2: `Markdown -web` kept. D3: styled multi-font preview from the start, edit windows stay single-font, tables/images/math via `-web`. These were removed from the open questions, which are renumbered |
