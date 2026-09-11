# Acme: A User Interface for Programmers — Rob Pike

The original paper describing ACME, archived here as the project's primary
*behavioral* reference (the pinned C sources are the *implementation* reference —
see [`../spec/07-source-layout.md`](../spec/07-source-layout.md) §1).

| File | What | Size |
|------|------|-----:|
| [`acme.html`](acme.html) | The paper, HTML rendering (figures inline) | 100 KiB |
| [`acme.pdf`](acme.pdf) | The paper, 10-page PDF | 114 KiB |
| [`acme.ms`](acme.ms) | troff `-ms` source — the authoritative text | 49 KiB |
| `acme.fig1.gif`, `acme.fig2.gif` | Figures 1–2 (screen shots) referenced by the HTML | 31 KiB |

## Provenance

Copied verbatim from the Plan 9 4th Edition distribution, `sys/doc/acme/`, at the
project's pinned fork **`larryr/plan9@ed1a9c21e3297d7497a48053d33683375c75fbb4`**
(short: `ed1a9c2`). Byte sizes match the tree's blob sizes. The same rendering is what
`doc.cat-v.org/plan_9/4th_edition/papers/acme/` mirrors; we archive from the fork so the
reference cannot rot and needs no external host (that site is unreachable from some of
our build sandboxes). Not copied: `acme.ps` (600 KiB PostScript, redundant with the PDF)
and the raw Plan 9 `acme.fig1`/`acme.fig2` image files (the GIFs are their renderings).

To re-fetch or verify:

```sh
B=https://raw.githubusercontent.com/larryr/plan9/ed1a9c21e3297d7497a48053d33683375c75fbb4/sys/doc/acme
for f in acme.html acme.pdf acme.ms acme.fig1.gif acme.fig2.gif; do curl -sSLO "$B/$f"; done
```

## License

Part of the Plan 9 4th Edition release, whose rights were transferred to the Plan 9
Foundation and released under the MIT License (2021); the original Lucent Public
License also applies to the 2002 distribution. Copyright © Lucent Technologies /
Plan 9 Foundation. Redistributed unmodified.

## How we use it

- Requirements in [`../requirements/02-editor-functional.md`](../requirements/02-editor-functional.md)
  paraphrase behaviors this paper defines (mouse language, tags, execute/look,
  the file server interface). When a requirement and the code disagree, the paper
  plus the pinned source settle it.
- Cite as `acme paper §N` (section number in `acme.ms`) alongside the usual
  `acme/file.c:line` source citations.
