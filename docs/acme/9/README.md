# Plan 9 from Bell Labs — Pike, Presotto, Dorward, Flandrena, Thompson, Trickey, Winterbottom

The Plan 9 system overview paper. Places 8½/`rio` and Acme in the whole-system
context (per-process name spaces, 9P, the device-file model). Acme is mentioned only in
passing.

**Status: supplementary — not definitive.** (Pike is one of seven authors; it is a
system overview, not a statement about Acme.)

| File | What | Size |
|------|------|-----:|
| [`9.ms`](9.ms) | The paper, troff `-ms` source — the authoritative text | 84662 bytes |
| [`9.ps`](9.ps) | PostScript rendering (the only rendering in the fork; no PDF/HTML) | 508352 bytes |

## Provenance

Copied verbatim from `sys/doc/9.ms` and `sys/doc/9.ps` at the project's pinned fork
**`larryr/plan9@ed1a9c21e3297d7497a48053d33683375c75fbb4`** (short: `ed1a9c2`). Byte
sizes match the tree's blob sizes (GitHub contents API). No conversion applied.

```sh
B=https://raw.githubusercontent.com/larryr/plan9/ed1a9c21e3297d7497a48053d33683375c75fbb4/sys/doc
curl -sSLO "$B/9.ms"; curl -sSLO "$B/9.ps"
```

## License

Part of the Plan 9 4th Edition release, whose rights were transferred to the Plan 9
Foundation and released under the MIT License (2021); the original Lucent Public
License also applies to the 2002 distribution. Copyright © Lucent Technologies /
Plan 9 Foundation. Redistributed unmodified.
