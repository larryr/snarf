# The Text Editor `sam` — Rob Pike

Pike's paper on `sam`, Acme's direct predecessor, plus his tutorial for the `sam`
command language. Acme's `Edit` command *is* the `sam` command language (structural
regular expressions, addresses, `x`/`g`/`v`/`s` loops), and Acme's mouse language,
text model (`Rune` buffers, `Text`/`File` split) and multi-file window discipline all
descend from `sam`/`samterm`.

**Status: definitive (Pike).** Authoritative for the `Edit` command language and for
any behavior the Acme paper describes as inherited from `sam`. When it and the Acme
paper disagree about *Acme*, the Acme paper wins.

| File | What | Size |
|------|------|-----:|
| [`sam.ms`](sam.ms) | *The Text Editor sam*, troff `-ms` source — the authoritative text (reprinted from *Software—Practice and Experience*, Vol 17 no 11, Nov 1987, pp. 813–845) | 92 KiB |
| [`sam.html`](sam.html) | Same paper, HTML rendering (figures inline) | 246 KiB |
| [`sam.pdf`](sam.pdf) | Same paper, PDF | 152 KiB |
| [`refs`](refs) | Reference list, troff source included by `sam.ms` | 3 KiB |
| `fig1.gif` … `fig4.gif`, `sam0.png` … `sam4.png` | Figures referenced by `sam.html` | 93 KiB |
| [`sam.tut`](sam.tut) | *A tutorial for the sam command language*, troff `-ms` source | 40 KiB |

## Provenance

Copied verbatim from the Plan 9 4th Edition distribution, `sys/doc/sam/`, at the
project's pinned fork **`larryr/plan9@ed1a9c21e3297d7497a48053d33683375c75fbb4`**
(short: `ed1a9c2`). Byte sizes match the tree's blob sizes. Not copied: `sam.ps`
(691 KiB PostScript, redundant with the PDF), `fig*.bm`/`fig*.ps` (raw Plan 9 bitmaps
and PostScript figure sources; the GIF/PNG files are their renderings), `fig*.png`
(unreferenced duplicates of the GIFs), `fig5-7.pic` (pic sources rendered into the
PDF), `sam.tut.out` (sample transcript for the tutorial) and `mkfile`.

To re-fetch or verify:

```sh
B=https://raw.githubusercontent.com/larryr/plan9/ed1a9c21e3297d7497a48053d33683375c75fbb4/sys/doc/sam
for f in sam.ms sam.html sam.pdf sam.tut refs fig1.gif fig2.gif fig3.gif fig4.gif \
         sam0.png sam1.png sam2.png sam3.png sam4.png; do curl -sSLO "$B/$f"; done
```

## License

Part of the Plan 9 4th Edition release, whose rights were transferred to the Plan 9
Foundation and released under the MIT License (2021); the original Lucent Public
License also applies to the 2002 distribution. Copyright © Lucent Technologies /
Plan 9 Foundation. Redistributed unmodified.

## How we use it

- The structural-regexp engine and `Edit` command parser (written in-project per
  ADR-0002) follow `sam.ms` §"The command language" and `sam.tut`; cite as
  `sam paper §N` / `sam tutorial`.
- Pinned implementation reference remains `acme/edit.c`, `acme/ecmd.c`, `acme/regx.c`
  in `larryr/plan9port@337c6ac`.
