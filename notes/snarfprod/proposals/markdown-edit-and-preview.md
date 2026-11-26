# Proposal: Markdown editing and rendered preview

**Status: PROPOSED** (product shape decided by Larry 2026-10-14 and 2026-11-26; see §8). The questions in §7 are closed. The multi-font preview frame is [ADR-0008](../../../docs/spec/adr/0008-markdown-preview.md). Scheduled after M3. This is a SnarfProdd working note, not a requirement. It would reach `docs/product/` only via a PR once Larry agrees.
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
  - is named `<source path>+Markdown` (D7);
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
- **Frozen WASM target.** No browser-specific work. The renderer stays core-side and pure Zig (D4), so the "WASM still compiles" CI check (#8) stays green. Browser parity is not a goal.
- **M5 agents.** The preview window's `body` is the rendered text (D7). Agents can then:
  - read rendered output the same way they read any window;
  - trigger a refresh by writing `markdown` to the source window's `ctl`, once ctl can carry that verb.

  This fits the M5 draft (agents as namespace clients). It depends on the M4 served tree.
- **Renderer.** A Zig CommonMark subset inside the module (D4). It does not shell out, so it does not wait on the M2 process service.

## 7. Open questions

None. The four questions that were here are D4–D7 in §8.

## 8. Decisions (Larry, 2026-10-14 and 2026-11-26)

| # | Decision |
|---|---|
| D1 | **One preview per source file.** Re-running `Markdown` reuses the existing preview window |
| D2 | **`Markdown -web` is kept.** It plumbs rendered HTML to the external browser, for full fidelity |
| D3 | **The preview shows styled text from the start, not plain reflow.** See below |
| D4 | **The renderer is a Zig CommonMark subset in core.** It draws headings, emphasis, code, links, lists, and quotes. It recognizes images, tables, raw HTML, and math well enough to mark them omitted. No cmark, no pandoc, no new dependency, no ADR. The same parse produces the `-web` HTML. The WASM build stays a pure Zig module |
| D5 | **Coloured links are B3-able through the editor's look path.** A relative path or `path#anchor` opens with look. An `http(s)` link uses the editor's URL path, which today warns that opening URLs is deferred (R-EDIT-13). An image, table, math construct, or raw HTML construct becomes a marker where it stood: `«image: alt»` (`«image»` when there is no alt), `«table»`, `«math»`, `«html»`. Inline where the construct was inline, on its own line where it was a block. The marker is not a link and does not fetch |
| D6 | **The renderer reads the window buffer and nothing else.** It never fetches a URL, never follows an include, and there is no flag to turn that on. `Markdown -web` emits the rendered constructs plus tables, math, and image tags whose `src` is passed through; the browser may load those images. Raw HTML is escaped text in that page, so a script in the file does not run. A file on a remote 9P mount gets the same result. Snarf does not read the mount to inline images, so a relative image may not resolve |
| D7 | **The preview window is named `<source path>+Markdown`.** Example: `/Users/larry/notes/foo.md+Markdown`. The tag carries `Markdown` and `Del`. It is not a disk file, and `Put` does not write it. Agents read that window's body. A `markdown` ctl verb on the source window arrives with the builtin, when ctl can carry it. There is no separate `rendered` file. `dir/+Markdown` was rejected: `+Errors` is one window per directory, and two sources in one directory would collide |

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
| 2026-11-26 | v0.3: Larry closed the four open questions (§8, D4–D7). Zig CommonMark subset in core; B3 links via look, with short omission markers; renderer is buffer-only and `-web` escapes raw HTML; window name is `<path>+Markdown`, no extra rendered file. §7 is empty. D3's multi-font frame is still an ADR gate |
