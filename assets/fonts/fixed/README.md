# fixed/9x18.0000 — embedded subfont (public domain)

`9x18.0000` is the 0x0000–0x00FF (ASCII + latin1) subfont of Plan 9's
`fixed/unicode.9x18` bitmap font, copied **unmodified** from the pinned reference tree
`larryr/plan9@ed1a9c2`, path `lib/font/bit/fixed/9x18.0000`.

sha256: `ac0b4bccf24c92471b0aab8e025fe56c1dcb58f5b8c27c32bf6a1dd49b589481`

`10x20.0000` is the same family's 0x0000–0x00FF subfont, copied unmodified from
`lib/font/bit/fixed/10x20.0000` in that tree. The markdown preview uses it for
headings (ADR-0008). sha256:
`ac85ca1e10e2331052bb1648a752e70cf7f4b1154ba7b7e106395b45415fb889`.

## License

The controlling notice is `lib/font/bit/fixed/README` in that tree (same text in
plan9port `font/fixed/README`), quoted in full:

> These fonts are converted from the BDFs in the XFree86 distribution.
> They were all marked as public domain.
>
> Russ Cox <rsc@swtch.com> July 2005

These are the X11 "misc-fixed" bitmap fonts, whose public-domain dedication is
independently established. Embedding satisfies ADR-0002 ("embedded assets are fine with
license notes"). Note: the Lucida families in the same tree (`lucida/`, `lucidasans/`,
`lucm/`) carry Bigelow & Holmes notices that prohibit redistribution outside Plan 9 —
they must never be embedded here (see agents/reports/phase3-font.md).

Format: compressed image(6) GREY1 strip 1728×18 followed by a font(6) subfont trailer
(n=256, height=18, ascent=13, 257 six-byte Fontchars). Parsed by `src/draw/Font.zig`.
