# Plumbing and Other Utilities — Rob Pike

Pike's paper on the *plumber*: the Plan 9 message-passing service that lets Acme hand
a right-click ("look") on a file name, URL, compiler error, or mail reference to the
right program, and lets other programs open text in Acme windows. It defines the plumb
message format, the rules language, and the conventions (`edit`, `web`, `showmail`
ports) that Acme's look-and-jump behavior relies on.

**Status: definitive (Pike).** Authoritative for how Acme's button-3 *look* action
escalates to plumbing and for the message and rule formats.

| File | What | Size |
|------|------|-----:|
| [`plumb.ms`](plumb.ms) | The paper, troff `-ms` source — the authoritative text (the `.ms` names no venue; Pike's bibliography lists it as *Proc. 2000 USENIX Technical Conf.*, pp. 159–170) | 52 KiB |
| [`plumb.ps`](plumb.ps) | The paper, PostScript rendering (only rendering in the distribution — no PDF/HTML exists there) | 383 KiB |

## Provenance

Copied verbatim from the Plan 9 4th Edition distribution, `sys/doc/plumb.ms` and
`sys/doc/plumb.ps`, at the project's pinned fork
**`larryr/plan9@ed1a9c21e3297d7497a48053d33683375c75fbb4`** (short: `ed1a9c2`).
Byte sizes match the tree's blob sizes. The PostScript is kept because the fork ships
no PDF or HTML of this paper; `doc.cat-v.org` hosts a PDF conversion but we archive only
from the pinned fork.

To re-fetch or verify:

```sh
B=https://raw.githubusercontent.com/larryr/plan9/ed1a9c21e3297d7497a48053d33683375c75fbb4/sys/doc
for f in plumb.ms plumb.ps; do curl -sSLO "$B/$f"; done
```

## License

Part of the Plan 9 4th Edition release, whose rights were transferred to the Plan 9
Foundation and released under the MIT License (2021); the original Lucent Public
License also applies to the 2002 distribution. Copyright © Lucent Technologies /
Plan 9 Foundation. Redistributed unmodified.

## How we use it

- Plumbing in this port is a 9P file service in the browser namespace (see the
  requirements for *look* / plumbing); message and rule syntax follow this paper and
  `plumb(6)` / `plumber(4)` in [`../man/`](../man/README.md).
- Cite as `plumb paper §N` (section in `plumb.ms`).
