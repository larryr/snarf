# Acme-related manual pages — Plan 9 and plan9port

The manual pages for Acme and the programs and interfaces it depends on, from both
pinned forks. `acme(1)` is the user-level command reference (mouse language, tag
commands, `win`); `acme(4)` is the normative description of the file-server interface
(`/mnt/acme/N/{addr,body,ctl,data,event,tag,xdata,...}`) that this port re-exposes over
9P. `sam(1)` documents the `Edit` command language; `plumb(6)`/`plumber(4)` the plumbing
messages and rules; `rio`, `draw(3)`, `mouse(3)`, `cons(3)`, `keyboard(6)` the device
files Acme reads and writes; `frame(2)` and `event(2)` the libraries `libframe` and
`libevent` that Acme is built on.

**Status: supplementary — not definitive.** Manual pages carry no author byline; they
were written and maintained by the Plan 9 team (largely Pike for the Acme/sam pages, but
also Presotto, Cox and others over the years) and the plan9port pages were revised by
Russ Cox. Use them as the precise reference for *interfaces* (file names, message
formats, command names); where a page and the Acme paper disagree about *behavior*, the
paper plus the pinned source settle it.

## Files

### `plan9/` — Plan 9 4th Edition (`larryr/plan9@ed1a9c2`), `sys/man/<section>/<name>`

| File | Page | What | Size |
|------|------|------|-----:|
| [`acme.1`](plan9/acme.1) | acme(1) | acme, win, awd — interactive text windows | 18.1 KiB |
| [`acme.4`](plan9/acme.4) | acme(4) | control files for text windows (the file-server interface) | 10.2 KiB |
| [`sam.1`](plan9/sam.1) | sam(1) | screen editor with structural regular expressions (Acme's `Edit` language) | 17.9 KiB |
| [`plumb.1`](plan9/plumb.1) | plumb(1) | send message to plumber | 1.3 KiB |
| [`plumb.2`](plan9/plumb.2) | plumb(2) | plumb messages library | 4.7 KiB |
| [`plumber.4`](plan9/plumber.4) | plumber(4) | file system for interprocess messaging | 2.7 KiB |
| [`plumb.6`](plan9/plumb.6) | plumb(6) | format of plumb messages and rules | 10.7 KiB |
| [`rio.1`](plan9/rio.1) | rio(1) | window system (8½'s successor; Acme's host) | 14.4 KiB |
| [`rio.4`](plan9/rio.4) | rio(4) | window system files (`/dev/cons`, `/dev/mouse`, `/dev/snarf`, …) | 8.5 KiB |
| [`draw.3`](plan9/draw.3) | draw(3) | screen graphics device (`/dev/draw` protocol) | 13.5 KiB |
| [`mouse.3`](plan9/mouse.3) | mouse(3) | kernel mouse interface (`/dev/mouse` format) | 4.2 KiB |
| [`cons.3`](plan9/cons.3) | cons(3) | console device (`/dev/cons`, `/dev/kbd` semantics) | 9.1 KiB |
| [`keyboard.6`](plan9/keyboard.6) | keyboard(6) | how to type characters (compose sequences Acme honours) | 4.4 KiB |
| [`frame.2`](plan9/frame.2) | frame(2) | libframe — frames of text (Acme's text-drawing layer) | 7.7 KiB |
| [`event.2`](plan9/event.2) | event(2) | libevent — graphics events | 7.3 KiB |
| [`regexp.6`](plan9/regexp.6) | regexp(6) | regular expression notation | 2.0 KiB |
| [`regexp.2`](plan9/regexp.2) | regexp(2) | regular expression library | 3.5 KiB |

### `plan9port/` — Plan 9 from User Space (`larryr/plan9port@337c6ac`), `man/man<section>/<name>.<section>`

| File | Page | What | Size |
|------|------|------|-----:|
| [`acme.1`](plan9port/acme.1) | acme(1) | acme, win, awd — interactive text windows (Unix revisions: `$` env, `-f`/`-F` fonts, …) | 20.1 KiB |
| [`acme.4`](plan9port/acme.4) | acme(4) | control files for text windows | 10.3 KiB |
| [`acme.3`](plan9port/acme.3) | acme(3) | libacme — C interface to acme windows and events | 6.6 KiB |
| [`acmeevent.1`](plan9port/acmeevent.1) | acmeevent(1) | shell-script support for acme clients (event-file format worked example) | 6.6 KiB |
| [`sam.1`](plan9port/sam.1) | sam(1) | screen editor with structural regular expressions | 18.6 KiB |
| [`ssam.1`](plan9port/ssam.1) | ssam(1) | stream interface to sam | 1.1 KiB |
| [`plumb.1`](plan9port/plumb.1) | plumb(1) | send message to plumber | 1.2 KiB |
| [`plumb.3`](plan9port/plumb.3) | plumb(3) | plumb messages library | 5.9 KiB |
| [`plumber.4`](plan9port/plumber.4) | plumber(4) | file system for interprocess messaging | 2.6 KiB |
| [`plumb.7`](plan9port/plumb.7) | plumb(7) | format of plumb messages and rules | 10.7 KiB |
| [`9term.1`](plan9port/9term.1) | 9term(1) | terminal windows (the `win`-like terminal; documents the Unix chording emulation) | 10.3 KiB |

Total: about 300 KiB. The Plan 9 `mail(1)`, `nedmail(1)` and `faces(1)` pages were
examined and not copied — Acme's `Mail` client is documented only in its source
(`sys/src/cmd/acme/mail/`, `src/cmd/acme/mail/`), not in a manual page, in either fork.

## Provenance

Copied verbatim (troff `-man` source) from:

- **`larryr/plan9@ed1a9c21e3297d7497a48053d33683375c75fbb4`** — `sys/man/1/acme`,
  `sys/man/4/acme`, `sys/man/1/sam`, `sys/man/1/plumb`, `sys/man/2/plumb`,
  `sys/man/4/plumber`, `sys/man/6/plumb`, `sys/man/1/rio`, `sys/man/4/rio`,
  `sys/man/3/draw`, `sys/man/3/mouse`, `sys/man/3/cons`, `sys/man/6/keyboard`,
  `sys/man/2/frame`, `sys/man/2/event`, `sys/man/6/regexp`, `sys/man/2/regexp`.
  Renamed `<section>/<name>` → `<name>.<section>` for convenience; contents unchanged.
- **`larryr/plan9port@337c6acbfed51d8d9f08598c6cd398f53abcca7d`** — `man/man1/acme.1`,
  `man/man4/acme.4`, `man/man3/acme.3`, `man/man1/acmeevent.1`, `man/man1/sam.1`,
  `man/man1/ssam.1`, `man/man1/plumb.1`, `man/man3/plumb.3`, `man/man4/plumber.4`,
  `man/man7/plumb.7`, `man/man1/9term.1`.

Byte sizes match the trees' blob sizes. To re-fetch or verify:

```sh
B=https://raw.githubusercontent.com/larryr/plan9/ed1a9c21e3297d7497a48053d33683375c75fbb4/sys/man
for p in 1/acme 4/acme 1/sam 1/plumb 2/plumb 4/plumber 6/plumb 1/rio 4/rio 3/draw 3/mouse \
         3/cons 6/keyboard 2/frame 2/event 6/regexp 2/regexp; do
  curl -sSL "$B/$p" -o "plan9/${p#*/}.${p%/*}"; done
P=https://raw.githubusercontent.com/larryr/plan9port/337c6acbfed51d8d9f08598c6cd398f53abcca7d/man
for f in man1/acme.1 man4/acme.4 man3/acme.3 man1/acmeevent.1 man1/sam.1 man1/ssam.1 \
         man1/plumb.1 man3/plumb.3 man4/plumber.4 man7/plumb.7 man1/9term.1; do
  curl -sSL "$P/$f" -o "plan9port/${f#*/}"; done
```

Render locally with `man -l plan9port/acme.4` (or `nroff -man`); the Plan 9 pages use
the same `-man` macros.

## License

Plan 9 pages: part of the Plan 9 4th Edition release, whose rights were transferred to
the Plan 9 Foundation and released under the MIT License (2021); the original Lucent
Public License also applies to the 2002 distribution. plan9port pages: MIT License
(Copyright © 2021 Plan 9 Foundation; portions © 2001–2008 Russ Cox, © 2008–2009 Google
Inc.), per that repository's `LICENSE`. Redistributed unmodified.

## How we use it

- `acme(4)` is the contract for the port's file-server interface (R-CON-*, spec S-05);
  cite as `acme(4)` with the file name, e.g. `acme(4) ctl: "dump"`.
- `plumb(6)`/`plumb(7)` for message format; `draw(3)`, `mouse(3)`, `cons(3)` alongside
  the pinned kernel sources for spec S-03/S-04.
