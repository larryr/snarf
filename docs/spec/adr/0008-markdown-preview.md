# ADR-0008 — Markdown preview uses its own read-only multi-font frame

Status: **Accepted (2026-11-26, Larry: implement on a branch)** · Supersedes: nothing. Edit windows stay on acme's one-font frame. Related: ADR-0002 (no linked markdown library), ADR-0003 (drawing stays draw-protocol writes), ADR-0005 (native primary, browser frozen).

Product record: `notes/snarfprod/proposals/markdown-edit-and-preview.md` (D1–D7).

## Context

Markdown is edited as plain text in an ordinary window. `Markdown` opens one read-only preview per source file, named `<path>+Markdown`, drawn with headings, emphasis, code, and coloured links. Images, tables, math, and raw HTML are markers in that preview. `Markdown -web` writes HTML for a browser.

`Frame` holds one `*Font` and one line height (`src/draw/frame/Frame.zig`). The only embedded face was `fixed/9x18`. Putting several faces into that frame would change layout, hit testing, and the frozen goldens for every edit window. devdraw already draws any number of fonts; the limit is the frame, not the device.

ADR-0002 forbids linking cmark or pandoc. A Zig parser in the module is the path that keeps the WASM build a pure Zig module.

## Decision

1. **Edit windows keep the one-font frame.** No field on `Frame` gains a per-run face. Goldens of ordinary text do not move because of this ADR.
2. **A markdown preview window owns a separate read-only layout.** It is drawn with draw-protocol fills and `Font.drawString` into the body rectangle. The body `File` holds the plain rendered text so a 9P reader sees it. Typing, Cut, and Paste in that body do nothing. B2 refreshes it. B3 on a link uses the editor's existing look path.
3. **Faces come from the embedded misc-fixed fonts plus synthesis.** Body, emphasis, strong, and code are `fixed/9x18`: emphasis is an oblique of that strip, strong is a bold of it, code is the same face on a tinted ground. Headings use `fixed/10x20` (h2) and a bold of it (h1); h3 and below use the 9x18 bold. Both strips are the public-domain XFree86 misc-fixed subfonts already documented under `assets/fonts/`. Synthesis runs at preview open, in memory, and embeds nothing new except `10x20.0000`.
4. **The renderer is a pure function of the window buffer.** It is a Zig subset of CommonMark covering headings, emphasis, code, links, lists, quotes, and rules, and it recognizes images, tables, raw HTML, and math well enough to mark them. It does not fetch and does not follow includes. `Markdown -web` escapes raw HTML and passes image `src` through for the browser.
5. **Opening that HTML is a host hook.** The core calls `Editor.open_html` when it is set. The native host writes a file and hands it to `open` or `xdg-open`. The frozen browser host leaves the hook null and the command warns.
6. **There is no separate rendered file.** Agents read the preview window's body. A `markdown` ctl verb on the source arrives with this builtin when the served-tree ctl can carry a verb. It is not invented here.
7. **`-live` has no timer.** wasm32-freestanding has no reliable clock for this, so an opted-in preview is marked stale by a source-body edit and refreshed from `Editor.frameEnd`. That per-frame pass is the stand-in for the 500 ms debounce.

## Consequences

- Preview layout can use a taller heading line without touching edit-window metrics.
- Bold and oblique are bitmap synthesis, not designed faces. They share the source advance plus one pixel (bold) or a small shear (oblique).
- `10x20` is only two pixels taller than `9x18`. That is the larger public-domain fixed face we can embed without a TTF conversion tool.
- The preview is not a disk file and is scratch, like `+Errors` and `+Help`.
- A full CommonMark compliance suite is not claimed. The subset is the one the preview draws, and it is tested.
