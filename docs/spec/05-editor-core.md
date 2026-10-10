# S-05 — Editor Core Specification

Satisfies: R-EDIT-01..18, R-OV-01.

## 1. Text storage

- **Rune-addressed buffers** (ACME addresses text by code point). Storage: a **piece
  table** over two backing stores (original file bytes; append-only add buffer), with a
  line/rune index tree for O(log n) address→offset. Rationale: cheap undo (pieces are
  immutable), cheap large files (R-EDIT-10), simple `Dump` serialization.
- Undo/redo (R-EDIT-11): transaction log of piece-table deltas, unbounded, kept across
  `Put`; grouped by user action (a sweep-replace is one transaction).
- Files are UTF-8 on disk/namespace; invalid sequences load as replacement runes with a
  warning in `+Errors` (never data-destroying on `Put` — original bytes for untouched
  pieces are preserved verbatim by construction).

## 2. Object model

```
Row (screen) → Columns → Windows → { tag: Text, body: Text }
Text  = frame (visible) + buffer (piece table) + selection q0,q1
File  = buffer shared by windows (Zerox); name = namespace path
```

Layout math (column widths, window stacking, grow/shrink rules) ports ACME's `col.c`
behavior. Directory windows (R-EDIT-03) render namespace `Tread`-of-directory results
**columnated**, dirs suffixed `/` — not one entry per line. The layout is
`textcolumnate` (`acme/text.c:136-198`), implemented in `src/core/dirwin.zig`:

- entries are sorted rune-wise, then by length (`dircmp`, text.c:121-133);
- a directory window gets **narrower tabs** — `fr.maxtab = min(maxtab, TABDIR) *
  stringwidth("0")`, with `TABDIR = 3` (text.c:21) and `maxtab = 4` (acme.c:145-146),
  i.e. 27 px at the 9×18 font (text.c:148); an ordinary window gets
  `maxtab * stringwidth("0")` = **36 px** from `textinit`/`textredraw`
  (text.c:53-60), NOT libframe's `frinit` default of `8 * stringwidth("0")` = 72
  (frinit.c:12) — `Text.init` applies the override, phase 16c;
- each entry's width is its `stringwidth`, bumped by one `stringwidth("0")` when the
  remainder to the next tab stop is under one, then rounded up to a tab stop; the
  column width is the maximum of those;
- `ncol = max(1, Dx(fr.r) / colw)`, `nrow = ceil(n / ncol)`, and row *i* holds entries
  *i*, *i+nrow*, *i+2·nrow*, … — so the listing reads **down** the columns, tabs
  between entries and a newline per row.

The listing is built by an ASYNCHRONOUS `textload` (`src/core/Load.zig`): a `StatJob`,
then a `ListDirJob`, stepped one 9P state per frame from `Editor.frameEnd`. The window
exists immediately with an empty body; the entries arrive a frame or two later (a
mount reached over the network takes as long as its round trips). A failed load leaves
the window in place, empty and named, with `can't open <name>: …` in `+Errors`
(text.c:216).

**Renaming a window by editing its tag (phase 17, R-P17-7).** The tag's name half is
committed into the body file's name by `wintag.commit` (`wincommit`'s tag half,
wind.c:594-618): `seq++`, mark, `mod`/`dirty` set, `winsetname` — whose `filesetname`
records the old name, so `Undo` restores it (file.c:139-164, :259-271). acme commits from
many places; Snarf commits on a **button press in the tag** (acme.c:644-650 — before
`textselect`, so a B2 on `Put` sees the new name), on a **`\n` or `typecommit`** in the tag
(text.c:938-939, :414-419), **before a `Dump`** (rows.c:364), and when a tag is about to be
recomposed with uncommitted edits (`setTagCommit`, the wind.c:485-486 entry of
`winsettag1`). **Divergence:** acme's dominant commit site is **every keystroke in a
tag** — `rowtype` → `wintype` → `winsettag` (rows.c:289, wind.c:401-409) reaches the
wind.c:485-486 `wincommit`, so in acme ` Undo Put` appears *while* a new name is being
typed; Snarf retags lazily (the `frameEnd` sweep), so the rename lands only at the next
commit site above. There is also no 500 ms `KTimer` commit (acme.c:470-479; no timer in the
core) and no commit when the pointer leaves a text (acme.c:583-588) — the button-down
commit covers the gesture that matters, and a `Put` issued over the served `ctl` commits
first itself.

## 3. The mouse language interpreter

Consumes `/dev/mouse` records (S-04). Implements ACME rules: click vs sweep threshold,
double-click expansion (word / line / `()[]{}""` pairs / whole body between newlines),
B2 sweep = execute exact swept text, B3 sweep = look exact text, chords per R-EDIT-08.
Scrollbar interactions per R-EDIT-04. Because chords arrive as ordinary button bitmasks,
this module is identical in spirit to `acme/text.c` — no emulation awareness (R-IN-02).

## 4. Execute (B2) resolution order (R-EDIT-06, R-EDIT-18)

1. Built-ins (table): `New Newcol Del Delcol Cut Paste Snarf Get Put Putall Undo Redo
   Zerox Look Edit Exit Dump Load Sort Tab Font Reconnect ...`
2. `Edit <cmd>` → structural-regexp engine (§5).
3. Origin commands: if `/bin/<name>` exists (the union `/n/origin/bin` is bound into with
   `-a`, S-02 §1.1) → write `exec <args>` to its `ctl`,
   stream `output` into `+Errors` (or window per ACME `|<>` conventions where the origin
   service supports stdin: `|cmd` pipes the selection through `input`/`output`).
4. Otherwise: warning `no such command`.

I/O prefixes `<`, `>`, `|` are supported against origin commands only (no local shell,
R-NG-03).

**Files (phase 17, R-EDIT-15).** `Get`, `Put`, `Putall`, `Dump` and `Load` are real
builtins (exec.c:105/:109/:114/:120/:121). `Put`/`Get` name a file per `getname`
(exec.c:476-539: own name, `Put foo` relative to the window's directory, or a 2-1 chord —
a slash-less chord argument is promoted for `Put`). The tag shows ` Put` while a named,
non-directory window's `seq != putseq` (wind.c:514-518). `Get` of the window's own name
restores dot and origin by line+rune (`getaddr.zig`); `Get` of another name fills the
window and leaves it modified, and `Get` leaves `putseq` alone (R-P17-8).

**The asynchronous Put (R-P17-1).** acme's `putfile` blocks; Snarf's (`src/core/Put.zig`)
is a chain of `nsjob` jobs — stat, (re-read + SHA-1 when the identity moved), write
(open-truncate or create; Twrites back to back on one fid; clunk), restat — one 9P state
per frame. The body is **snapshot** when `Put` runs, with its `seq`; the window is marked
clean on completion only if nothing was typed meanwhile, else ` Put` stays (that is
wind.c:514's own rule). One Put per window at a time (a second warns `… Put already in
progress`); a Put outlives its window. A `Put other` writes a copy and changes nothing on
the window (exec.c:774). `Putall` never creates a file: its `access()` check becomes the
write job's `must_exist` (R-P17-3, `no auto-Put of …`). Every failure is acme's own
warning text in `+Errors`.

## 5. Edit language (R-EDIT-12)

Full ACME `Edit`: addresses (`#n`, `n`, `/re/`, `$`, `.`, `+ -`, `,` `;`), commands
`a c i d s m t` `x y` `g v` `X Y` `b B D e r w f` `p =` `u` (undo), grouping `{ }`.
Regexps: Plan 9 syntax (`sam(1)`); implementation is a port of the structural regexp
engine over rune buffers — std-only, no external regex lib (R-CON-01; Zig std has no
regex, so this is written in-project as in every ACME port).

## 6. Look (B3) & plumbing subset (R-EDIT-07, R-EDIT-13)

Resolution order: (1) `name:line`/`name:/re/` address syntax → open window at address;
(2) existing window whose name matches → jump; (3) namespace path (relative to window dir,
then absolute) → open file/dir; (4) `http(s)://` → `/dev/location`-adjacent open in new
tab (`window.open` via devmisc, popup-blocker caveat surfaced in `+Errors`); (5) literal
text search in body (wrapping, highlighting next match).

**Asynchronous existence check (R-P13b-2, browser host).** ACME decides between (3) and
(5) with a synchronous `access()` inside `look3` (`acme/look.c:706`). Snarf cannot: the
answer lives behind a 9P walk whose reply may only arrive on a later browser tick
(R-9P-13), and the main thread must not block. So a B3 look splits in two:

1. `src/core/expand.zig` expands TEXTUALLY (`expandfile`, look.c:592-729 minus its I/O)
   and, for a file-shaped candidate, resolves it to an absolute name and parks a
   `StatJob` as `Editor.pending_look` — **one at a time**; a newer B3 cancels the older.
2. `Editor.frameEnd` steps it. Success ⇒ `openfile.openFile`; any failure (the
   `access()` failure) ⇒ the literal search of (5), run on the original expansion.

The only observable difference from ACME is timing: both outcomes land a frame or two
late. Unrooted names resolve against the window's own directory (R-EDIT-20) and then
against `wdir`, which is `/` (R-P13b-3 — the port has no process working directory).
URLs currently warn instead of opening (R-EDIT-13, backlog); `<include>` names fall
through to the literal search (no include list in v1).

## 7. Snarf buffer (R-EDIT-14)

One internal snarf buffer, synchronized with `/dev/snarf` (system clipboard): `Snarf`/`Cut`
write it out; `Paste` reads it in. Clipboard permission denial degrades to internal-only
with one-time warning. (This synchronization is the feature the project is named after.)

## 8. Session persistence (R-EDIT-16)

`Dump` writes the row — column positions, column and row tags, every window's name, tag,
dot and position, and the bodies of windows that are dirty or never read — in **acme's own
`rowdump1` format** (rows.c:317-462; R-P17-6, `src/core/dumpfmt.zig`), so a Snarf dump
reads like an acme one; `Load` rebuilds it (rows.c:559-844) on top of the existing windows,
re-reading `f`-record files through ordinary asynchronous loads. With no argument the
file is **`$home/acme.dump`**, where `$home` is set by the host (R-P17-5): **`/mnt/opfs`
in the browser** (the always-available private area, R-9P-09) and the **real `$HOME`
natively** (unmounted until the native host file server mounts at `/`, so a native `Dump`
today warns `NotMounted` at the right path). No `$home` ⇒ acme's `can't find file for
dump: $home not defined`. An argument (or 2-1 chord) names another file, relative names
resolving against `wdir`.

Divergences: the dump is written **in place** (truncate + write) instead of to a temp
file renamed over the old one — `/mnt/opfs` has no rename (R-P14b-4); `access()` in the
`f`-vs-`F` choice is "the file has a disk identity" (R-P17-4); `x`/`e` records are never
written and are skipped with a warning on load; the two font lines carry the one font.
This supersedes the earlier `/dev/storage/snarf.dump` + "versioned text format" plan
(R-02 v7). Auto-dump on `visibilitychange` stays deferred.

## 9. Served interface (R-EDIT-17)

The `/mnt/snarf-self` tree (S-02 §6) is served by the core itself on the in-memory
transport; `event` file delivery follows acme(4): text deltas and B2/B3 events offered to
the client with the same `K`/`M` origin runes and built-in fallback on clunk-without-read.
The deferred `kbd hold` extension (S-02 §6) hooks in here; until it is implemented, `K`
events remain report-only exactly as in acme(4). Selection movement of every kind resolves
through the address engine per the dot-transformer principle (R-EDIT-19).

## 10. Trace

| Requirement | Section |
|-------------|---------|
| R-EDIT-01..04 | §2 |
| R-EDIT-05, 08, 09 | §3 |
| R-EDIT-06, 18 | §4 |
| R-EDIT-12 | §5 |
| R-EDIT-07, 13 | §6 |
| R-EDIT-10, 11 | §1 |
| R-EDIT-14 | §7 |
| R-EDIT-15 | §4 (Get/Put via namespace), §2 (names are paths) |
| R-EDIT-16 | §8 |
| R-EDIT-17 | §9 |
| R-EDIT-19 | §3, §6, §9 (all selection movement via address engine) |
