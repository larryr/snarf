# Hello World or Καλημέρα κόσμε or こんにちは 世界 — Rob Pike and Ken Thompson

The UTF-8 paper (published *Proc. Winter 1993 USENIX Conf.*, pp. 43–50): how Plan 9
adopted Unicode with the UTF-8 encoding, and the `Rune` type used throughout `sam`, 8½
and Acme (Acme's buffers are arrays of runes; `acme/buff.c`, `acme/disk.c`).

**Status: definitive (Pike, co-author)** for the text encoding; not about Acme behavior.

| File | What | Size |
|------|------|-----:|
| [`utf.ms`](utf.ms) | The paper, troff `-ms` source — the authoritative text | 42072 bytes |
| [`utf.ps`](utf.ps) | PostScript rendering (the only rendering in the fork; no PDF/HTML) | 363839 bytes |

## Provenance

Copied verbatim from `sys/doc/utf.ms` and `sys/doc/utf.ps` at the project's pinned fork
**`larryr/plan9@ed1a9c21e3297d7497a48053d33683375c75fbb4`** (short: `ed1a9c2`). Byte
sizes match the tree's blob sizes (GitHub contents API). No conversion applied.

```sh
B=https://raw.githubusercontent.com/larryr/plan9/ed1a9c21e3297d7497a48053d33683375c75fbb4/sys/doc
curl -sSLO "$B/utf.ms"; curl -sSLO "$B/utf.ps"
```

## License

Part of the Plan 9 4th Edition release, whose rights were transferred to the Plan 9
Foundation and released under the MIT License (2021); the original Lucent Public
License also applies to the 2002 distribution. Copyright © Lucent Technologies /
Plan 9 Foundation. Redistributed unmodified.
