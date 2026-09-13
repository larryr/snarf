# Acme papers — index

Every publication about Acme (or its immediate ancestry) that was found while assembling
this archive, whether or not it was copied. Rules applied:

- **Copied** only from the project's two pinned, MIT-licensed forks
  (`larryr/plan9@ed1a9c21e3297d7497a48053d33683375c75fbb4`,
  `larryr/plan9port@337c6acbfed51d8d9f08598c6cd398f53abcca7d`), verbatim, one
  subdirectory per publication, each with its own `README.md` giving provenance and
  byte sizes. Nothing was copied from journal/conference publishers or personal web
  pages: those carry publisher or author copyright with no redistribution grant we can
  cite.
- **Status.** *Definitive* is reserved for writings authored by Rob Pike; they may be
  used as authoritative behavioral references alongside the main Acme paper. Everything
  by other authors — Cox, Presotto, Winterbottom, Peppé, Capell, Jones, unattributed
  manual pages — is *supplementary — not definitive*: useful for interfaces and
  context, but never the tie-breaker on behavior.
- Precedence when references disagree about *Acme* behavior: the Acme paper, then the
  pinned Acme source, then the other definitive papers, then supplementary material.

## Copied

| # | Title | Author(s) | Year | Where | Status |
|--:|-------|-----------|-----:|-------|--------|
| 1 | *Acme: A User Interface for Programmers* (Plan 9 `sys/doc/acme`; published *Proc. Winter 1994 USENIX Conf.*, pp. 223–234) | Rob Pike | 1994 | [`./`](README.md) (`acme.ms`, `.html`, `.pdf`, `.md`) | **definitive (Pike)** — primary reference |
| 2 | *The Text Editor sam* (reprinted from *Software—Practice and Experience* 17(11), pp. 813–845) | Rob Pike | 1987 | [`sam/`](sam/README.md) (`sam.ms`, `.html`, `.pdf`, figures) | **definitive (Pike)** — `Edit` language, text model |
| 3 | *A tutorial for the sam command language* | Rob Pike | n.d. (Plan 9 distribution) | [`sam/sam.tut`](sam/README.md) | **definitive (Pike)** |
| 4 | *Plumbing and Other Utilities* (published *Proc. 2000 USENIX Technical Conf.*, pp. 159–170) | Rob Pike | 2000 | [`plumb/`](plumb/README.md) (`plumb.ms`, `.ps`) | **definitive (Pike)** — look/plumb escalation, message and rule formats |
| 5 | *8½, the Plan 9 Window System* (a variant appeared as *A Minimalist Global User Interface*, *Proc. Summer 1991 USENIX Conf.*) | Rob Pike | 1991 | [`8half/`](8half/README.md) (`8half.ms`, `.ps`) | **definitive (Pike)** for the device-file environment model; not about Acme itself |
| 6 | Plan 9 manual pages: acme(1), acme(4), sam(1), plumb(1), plumb(2), plumber(4), plumb(6), rio(1), rio(4), draw(3), mouse(3), cons(3), keyboard(6), frame(2), event(2), regexp(6), regexp(2) | Plan 9 team (unattributed) | 2002 (4th Ed.), fork snapshot 2025 | [`man/plan9/`](man/README.md) | supplementary — not definitive (normative for *interfaces*) |
| 7 | plan9port manual pages: acme(1), acme(4), acme(3), acmeevent(1), sam(1), ssam(1), plumb(1), plumb(3), plumber(4), plumb(7), 9term(1) | Russ Cox et al. (revisions of the Plan 9 pages) | 2003– (fork snapshot 2026) | [`man/plan9port/`](man/README.md) | supplementary — not definitive |

Total added: ≈ 2.2 MiB (`sam/` 660 KiB, `8half/` 812 KiB — 779 KiB of it PostScript, the
only rendering in the fork — `plumb/` 440 KiB, `man/` 290 KiB).

## Found but not copied

| # | Title | Author(s) | Year | Status | Why not copied / where to find it |
|--:|-------|-----------|-----:|--------|-----------------------------------|
| 8 | *Structural Regular Expressions* (*Proc. EUUG Spring 1987 Conf.*, pp. 21–28, Helsinki) | Rob Pike | 1987 | definitive (Pike) — for the `x`/`y`/`g`/`v` model underlying `Edit` | Not in either pinned fork. Publisher (EUUG) copyright; the copy at `http://doc.cat-v.org/bell_labs/structural_regexps/` (`se.pdf`) carries no license statement. The same model is fully described in the `sam` paper (#2), which we do hold. |
| 9 | *Window Systems Should Be Transparent* (*Computing Systems* 1(3), pp. 279–296) | Rob Pike | 1988 | definitive (Pike) — background only (mux, Blit; pre-Plan 9) | Not in either fork; USENIX copyright. `https://www.usenix.org/legacy/publications/compsystems/1988/sum_pike.pdf`, mirror at `doc.cat-v.org/bell_labs/transparent_wsys/`. Superseded for our purposes by #5. |
| 10 | *A Minimalist Global User Interface* (USENIX Summer 1991, pp. 267–279; revised *Graphics Interface '92*, pp. 282–293) | Rob Pike | 1991/92 | definitive (Pike) | Publisher copyright. The Plan 9 distribution's `8½.ms` (#5) is Pike's own later form of the same paper and is what we archive. |
| 11 | *Hello World or Καλημέρα κόσμε or こんにちは 世界* (Plan 9 `sys/doc/utf.ms`; *Proc. Winter 1993 USENIX Conf.*, pp. 43–50) | Rob Pike, Ken Thompson | 1993 | co-authored by Pike; background (UTF-8, Runes in sam/8½) — not about Acme | Peripheral to Acme behavior; left out to keep the archive focused. Copyable at any time from the pinned fork (MIT): `sys/doc/utf.ms` (42 KiB). |
| 12 | *Plan 9 from Bell Labs* (Plan 9 `sys/doc/9.ms`) | Pike, Presotto, Dorward, Flandrena, Thompson, Trickey, Winterbottom | 1995 | supplementary — system overview; mentions Acme only in passing | Peripheral. Copyable from the pinned fork (MIT), `sys/doc/9.ms` (85 KiB), if ever wanted. |
| 13 | *A Tour of Acme* (blog post + 23-min screencast) | Russ Cox | 2012 | supplementary — not definitive | Personal site `https://research.swtch.com/acme` and YouTube; no license statement; the substance is a video. Excellent orientation for newcomers; not a reference. |
| 14 | Inferno manual pages acme(1), acme(4) (Limbo re-implementation of Acme) | Vita Nuova / Bell Labs (unattributed) | 1996– | supplementary — not definitive (describes a *different* implementation) | Not in our pinned forks. `inferno-os/inferno-os` is MIT-licensed (`man/1/acme`, 29 KiB), so it *could* be copied on request; `https://www.vitanuova.com/inferno/man/4/acme.html`, `https://man.cat-v.org/inferno/1/acme`. |
| 15 | *Program Development under Inferno* | Roger Peppé (Vita Nuova) | c. 2000 | supplementary — not definitive | Vita Nuova paper, Acme covered as the Inferno IDE; `https://inferno-os.org/inferno/papers/dev.pdf`; no explicit license found. |
| 16 | Acme SAC (Acme Stand Alone Complex) — README and lab notes | Caerwyn Jones | 2006– | supplementary — not definitive | Derivative Inferno-hosted Acme, not Bell Labs authorship; `https://github.com/caerwynj/acme-sac`, `http://ipn.caerwyn.com/2006/03/lab-59-acme-sac.html`. |
| 17 | Wily — user guide and *Acme vs. Wily* notes | Gary Capell (Univ. of Sydney) | 1995–98 | supplementary — not definitive | Not Bell Labs; an X11 work-alike whose behavior deliberately differs. Artistic License per `https://github.com/9wm/wily` (`Doc/`); `http://www.cs.yorku.ca/~oz/wily/AcmeVsWily.html`. Noted for contrast only. |
| 18 | `acme.cat-v.org` — community collection of Acme links, tips and mailing-list lore | various | ongoing | supplementary — not definitive | Aggregator, not a publication; no license. |
| 19 | Acme `Mail` client documentation | — | — | — | No paper or manual page exists in either fork: the client is documented only by its source (`sys/src/cmd/acme/mail/`, `src/cmd/acme/mail/`) and the two-line `mail/guide`. The Plan 9 `mail(1)`, `nedmail(1)`, `faces(1)` pages were read and do not describe it. |

## Licensing notes

- Everything copied is covered by the Plan 9 Foundation's 2021 MIT relicensing of
  Plan 9 (`LICENSE`/`NOTICE` at the plan9 fork root) and plan9port's MIT `LICENSE`
  (Plan 9 Foundation, Russ Cox, Google). Both permit verbatim redistribution with the
  notice retained; each subdirectory README carries the attribution.
- The published (USENIX/EUUG/Wiley) forms of #1, #2, #4, #5, #8, #9, #10 are *not*
  covered by that grant; we hold Pike's Plan 9-distribution forms of #1, #2, #4, #5,
  which are what the copyright transfer to the Foundation covered.
- The `8½` files are renamed `8half.*` (ASCII path); contents are byte-identical.
