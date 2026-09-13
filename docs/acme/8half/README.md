# 8½, the Plan 9 Window System — Rob Pike

Pike's paper on 8½, the Plan 9 window system that preceded `rio`. It establishes the
model Acme lives inside: windows are files (`/dev/cons`, `/dev/mouse`, `/dev/bitblt`,
later `/dev/draw`), the window system is a file server that multiplexes the display,
keyboard and mouse, and a client program (Acme included) sees only those files. This
port's device servers (`/dev/draw`, `/dev/mouse`, `/dev/kbd` per ADR-0003/0004) are
the browser-side stand-in for 8½/rio.

**Status: definitive (Pike).** Authoritative for the *device-file* model Acme assumes
of its environment (console, mouse, and screen as files; snarf buffer; the 3-button
mouse conventions of the era). Not about Acme itself — for Acme behavior, the Acme paper
governs.

| File | What | Size |
|------|------|-----:|
| [`8half.ms`](8half.ms) | The paper, troff `-ms` source — the authoritative text (a slightly different form appeared in *Proc. Summer 1991 USENIX Conf.*) | 31 KiB |
| [`8half.ps`](8half.ps) | The paper, PostScript rendering (only rendering in the distribution — no PDF/HTML exists there) | 779 KiB |

Files are renamed from `8½.ms`/`8½.ps` to `8half.ms`/`8half.ps` (ASCII path only; the
contents are byte-identical to the originals).

## Provenance

Copied verbatim from the Plan 9 4th Edition distribution, `sys/doc/8½/`, at the
project's pinned fork **`larryr/plan9@ed1a9c21e3297d7497a48053d33683375c75fbb4`**
(short: `ed1a9c2`). Byte sizes match the tree's blob sizes.

To re-fetch or verify:

```sh
B=https://raw.githubusercontent.com/larryr/plan9/ed1a9c21e3297d7497a48053d33683375c75fbb4/sys/doc/8%C2%BD
curl -sSL "$B/8%C2%BD.ms" -o 8half.ms; curl -sSL "$B/8%C2%BD.ps" -o 8half.ps
```

## License

Part of the Plan 9 4th Edition release, whose rights were transferred to the Plan 9
Foundation and released under the MIT License (2021); the original Lucent Public
License also applies to the 2002 distribution. Copyright © Lucent Technologies /
Plan 9 Foundation. Redistributed unmodified.

## How we use it

- Background for spec S-03/S-04 (draw and input device servers) and R-OV-03 (everything
  crosses a 9P namespace). For the *current* device semantics the pinned kernel source
  (`9/port/devdraw.c`, `devmouse.c`, `devcons.c`) and the `rio(1)`/`rio(4)`/`draw(3)`
  pages in [`../man/`](../man/README.md) supersede this paper.
- Cite as `8½ paper §N`.
