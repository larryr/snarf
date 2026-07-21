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
behavior. Directory windows (R-EDIT-03) render namespace `Tread`-of-directory results,
one entry per line, dirs suffixed `/`.

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
3. Origin commands: if `/mnt/origin/bin/<name>` exists → write `exec <args>` to its `ctl`,
   stream `output` into `+Errors` (or window per ACME `|<>` conventions where the origin
   service supports stdin: `|cmd` pipes the selection through `input`/`output`).
4. Otherwise: warning `no such command`.

I/O prefixes `<`, `>`, `|` are supported against origin commands only (no local shell,
R-NG-03).

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

## 7. Snarf buffer (R-EDIT-14)

One internal snarf buffer, synchronized with `/dev/snarf` (system clipboard): `Snarf`/`Cut`
write it out; `Paste` reads it in. Clipboard permission denial degrades to internal-only
with one-time warning. (This synchronization is the feature the project is named after.)

## 8. Session persistence (R-EDIT-16)

`Dump` serializes rows/cols/windows/names/unsaved bodies to a versioned text format at
`/dev/storage/snarf.dump` by default (arg overrides, e.g. `/mnt/host/proj/snarf.dump`);
`Load` restores. Auto-dump on `visibilitychange`-hidden is a `ctl`-settable option.

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
