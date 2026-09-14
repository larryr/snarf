# Phase 13b contract — directory windows, `openfile`, `expandfile`, `Get` for directories, and the acme boot layout

Status: **binding once fable signs §3.** Branch `phase13b` (worktree `../snarf-wt/phase13b`),
based on `main@af51e2a` (13a merged). Requirements: R-EDIT-03 (directory windows), R-EDIT-07
(look: file first, then literal), R-EDIT-13 (`path`, `path:line`, `path:/re/`), R-EDIT-20
(directory context), R-EDIT-23 (auto-created windows via `makeNewWindow`), R-EDIT-25 (no
warp), R-9P-16 (synthetic dirs listable). Paper §User interface: "the columnated display of
files", "If a window represents a directory, the name in the tag ends with a slash and the
body contains a list of the names of the files in the directory." User-queued 2026-09-14.

Pipeline: fable spec → **opus** codes §3 → **sonnet** writes §4 → **sonnet** runs the gate →
**fable** reviews → loop.

## 1. Ground truth (`larryr/plan9port@337c6ac`, `src/cmd/acme/`)

| Item | Where | What |
|---|---|---|
| `textload` dir arm | `text.c:200-275` | after `dirfstat`: QTDIR ⇒ `w->isdir = TRUE`, `w->filemenu = FALSE`, name gains a trailing `/` if missing (`winsetname`); `dirread` all entries; each name + `/` if QTDIR; `dl->wid = stringwidth(font, name)`; `qsort(dircmp)`; `w->dlp/ndl` kept; `textcolumnate`. File arm: `filemenu = TRUE`, `fileload`. Errors: `warning(nil, "can't open %s: %r\n")`, return −1 — the window stays, empty. `ismtpt` guard: "will not open self mount point". |
| `dircmp` | `text.c:121-133` | rune-wise `memcmp`, then length. |
| `textcolumnate` | `text.c:136-198`; `TABDIR = 3` (`text.c:21`); `maxtab = 4` default (acme.c:145-146) | `mint = stringwidth("0")`; **`t->fr.maxtab = min(maxtab, TABDIR)*mint`** (dir windows get narrower tabs); per entry `w = wid`, `+mint` if the remainder to the next tab stop is `< mint` or `w%maxt==0`, then round up to a tab stop; `colw = max`; `ncol = max(1, Dx(fr.r)/colw)`; `nrow = ceil(ndl/ncol)`; row `i` holds entries `i, i+nrow, i+2nrow…` (fills DOWN columns), tabs to `colw` between, `\n` per row; `if(t->file->ntext > 1) return` (skip when Zerox'd — N/A v1). |
| `openfile` | `look.c:810-905` | `e->nname==0` ⇒ the clicked window itself; else `lookfile(name)`; unrooted name ⇒ `wdir/name` + `cleanrname`; existing ⇒ reuse (`colgrow` if obscured — deferred); else `makenewwindow(t)`, `winsetname`, `textload(…, 1)`, `mod=FALSE`, `dirty=FALSE`, `winsettag`, tag caret to end; then `address(TRUE, t, …, e->a0, e->a1, …)`; `q0 > q1` ⇒ `warning "addresses out of order"`; `textshow(t, r.q0, r.q1, 1)`; `winsettag`; `seltext = t`; `moveto` (DROPPED, R-EDIT-25). |
| `readfile` | `acme.c:285-300` | boot helper: `coladd(c, nil, nil, -1)`, absolute name (`wdir/` if relative), `cleanrname`, `winsetname`, `textload`. |
| `expandfile` | `look.c:592-729` | forward over `isfilec` noting the first `:` not inside `http://`/`https://`; backward over `isfilec || isaddrc || isregexc`; `colon` ⇒ address chars after it (`isaddrc`), stopping at white space; `nname` = chars before the colon; URL ⇒ name = URL (13b: warning, deferred); `<name>` ⇒ include dirs (none ⇒ fail); `nname==0` with an address ⇒ the window's own file; relative ⇒ `dirname(t)`; existence: `access(bname, 0)` — **synchronous in acme, asynchronous here (§3d)**; `e->name/bname/a0/a1/jump`. `isaddrc`/`isregexc` at `look.c:430-441`. |
| `look3` | `look.c:83-240` | `expand` ⇒ file ⇒ `openfile`; else literal `search` (already `core/look.zig`). |
| Tag words | `wind.c:487-536` | inside `filemenu`: `Undo`/`Redo`; `Put` only when `!isdir && dirty`; **outside** that block: `if(w->isdir) "Get "` (wind.c:520-523) — so directory windows show `Del Snarf Get | Look`. `ctl` read reports `isdir` (wind.c:695); `winclean` (wind.c:666+): `isdir` never blocks `Del`. |
| `Get` for dirs | `exec.c` `get()` → `getname`/`textload` (verify lines) | re-reads the window's name into the body; for a dir the whole listing is rebuilt. |
| No-arg boot | `acme.c:242-260` | `ncol = 2`; `readfile(row.col[ncol-1], wdir)` — the cwd window goes in the **rightmost** column, the left one stays empty. |

## 2. Merged reality (`main@af51e2a`)
`Editor.ns`, `boot.Options.ns` + `Tree.bind(ed)`; `ninep.nsjob.{WalkJob,StatJob,ReadFileJob,ListDirJob}`,
`runSync`, `Pumps`; boot namespace `/dev`, `/dev/draw`, `/mnt/snarf-self` (+ `/n/origin`, `/bin`);
`errors.lookFile(row, name)`, `errors.dirName(w)`, `place.makeNewWindow(ed, t)`,
`place.mintWindow(c, y, name)`, `Window.filemenu`, `Text.insertAt(q0, bytes, tofile)`,
`Text.show(q0, q1, doselect)`, `Frame.maxtab` (set once in `frinit`), `Font.stringWidth`,
`edit/addr.zig` (`eval`, `nextMatch`, `mkAddr`), `core/look.zig` with the `expandfile` seam at
`:36-46`, served `ctlPrint` hard-codes `isdir 0` (`fsys.zig:594`), `SEAM(ns)` in `fsys.zig`.
`Editor.zig` 396 pre-test lines — **anything new goes in new files**. `/dev` and `/dev/draw`
must be reached by jobs only.

## 3. CONTRACT

### 3a. `src/core/dirwin.zig` — sorting, columnation, applying a listing
- `pub fn dirCmp(a: []const u21, b: []const u21) std.math.Order` (text.c:121-133).
- `pub const TABDIR = 3; pub const default_maxtab = 4;` (acme.c:145-146; a later `-t`/ctl
  option may override — cite).
- `pub fn columnate(t: *Text, entries: []const Entry) Text.Error!void` (text.c:136-198
  verbatim in Zig, `Entry{ name: []const u21, wid: i32 }`), **setting `t.fr.maxtab =
  min(default_maxtab, TABDIR) * mint` on the body frame** (verify how `Frame` consumes
  `maxtab` — `util.zig:134-135` — so a later `fill`/redraw honours it; if `Text.fill` resets
  it, add `Text.maxtab_override` consulted by the frame init path, cite).
- `pub fn applyListing(ed: *Editor, w: *Window, stats: []const Stat) Text.Error!void`: names
  (+`/` for `DMDIR`), `wid` via `w.body.fr.font.stringWidth`, sort, columnate into an emptied
  body; `w.isdir = true`, `w.filemenu = false`, name gains `/` if missing (`File.setName`);
  keep the sorted names on the window (`w.dirnames`, the C's `dlp/ndl`) for `Get`;
  `file.mod = false`, `w.dirty = false`, `setTag1`, tag caret at the end.
- `Window`: `isdir: bool = false`, `dirnames` storage (owned, freed in deinit); `setTag1`
  gains `" Get"` for `isdir` (wind.c:520-523, outside the filemenu arm) and keeps `Put` out for
  `isdir`; `winclean` `isdir` arm; served `ctlPrint` reports `isdir` (fsys.zig:594).

### 3b. `src/core/Load.zig` — one in-flight window load (the asynchronous `textload`)
- `Load{ w: *Window, job: union(enum){ stat: StatJob, file: ReadFileJob, dir: ListDirJob },
  name: []u8, addr: ?[]u21 (the `:addr` text), jump: bool, setqid: bool }`; sequence:
  `StatJob` ⇒ DMDIR ? `ListDirJob` : `ReadFileJob`; `Editor.loads: ArrayList(Load)` stepped
  once per frame from `frameEnd` BEFORE `flushWarnings` (so a load error's warning lands the
  same frame). On completion: file ⇒ empty body, `insertAt(0, bytes, true)` (invalid UTF-8 ⇒
  U+FFFD, one warning, S-05 §1), `filemenu = true`; dir ⇒ `dirwin.applyListing`; both ⇒
  `file.mod=false`, `w.dirty=false`, then the deferred address (§3c) and `Text.show`; on
  error ⇒ `ed.warning("can't open {s}: {s}\n", .{name, @errorName(e)})` (text.c:216), the
  window stays empty and named (acme leaves it so). A window deleted mid-load: `Load` is
  dropped and its job `deinit`ed (tombstones make that safe — 13a) — hook `dropTextRefs`.
- `ReadFileJob.max_bytes = nsjob.max_file_bytes` (R-EDIT-10).
- Cap `Load.zig` ≤ ~400; the stepping loop and completion handlers live here, not in
  `Editor.zig` (which only gains the `loads` field and one call).

### 3c. `src/core/openfile.zig` — `openfile` (look.c:810-905) + `readfile` (acme.c:285-300)
- `pub const Expand = struct { name: []const u8 (absolute, cleaned), addr: ?[]const u21,
  jump: bool, q0: usize, q1: usize }` (the C's `Expand` subset we need).
- `pub fn openFile(ed, t: ?*Text, e: Expand) Text.Error!*Window`: `errors.lookFile` (trailing
  `/` rule); relative name ⇒ `"/" ++ name` cleaned — **`wdir` = `/`** (R-P13b-3); existing ⇒
  reuse (no `colgrow`, deferred with cite); else `place.makeNewWindow(ed, t)` +
  `File.setName` + `setTag1` + start a `Load` carrying `e.addr`/`e.jump`; `ed.seltext =
  &w.body`; on load completion the address is evaluated via `edit/addr` against the body
  (`address(TRUE, …)` analog; "addresses out of order" on `q0 > q1`), then
  `Text.show(q0, q1, true)`. No `moveto` (R-EDIT-25; touch semantics are HANDOFF notes, not
  this wave).
- `pub fn readFile(ed, c: *Column, name: []const u8) Text.Error!*Window` (acme.c:285-300):
  `place.mintWindow(c, -1, abs_name)` + `Load` — used by boot.
- `ismtpt` (text.c:212): refuse to open `/mnt/snarf-self` itself with acme's warning text.

### 3d. `src/core/expand.zig` — `expandfile` (look.c:592-729) + the asynchronous existence check
- `pub fn expandFile(t: *Text, q0: usize, q1: usize) ?Candidate{ name_q0, name_q1, addr_q0,
  addr_q1, kind: .file | .url | .include }` — purely textual (`isfilec` from `exec.zig`,
  `isaddrc`, `isregexc`, the colon rule, the `http(s)://` exemption, `<…>`).
- **R-P13b-2 (async divergence)**: acme's `access()` is synchronous. Snarf: B3 look ⇒
  `expandFile`; a `.file` candidate resolves to an absolute name (relative ⇒
  `errors.dirName(w)` + `/` + name; `nname==0` ⇒ the window's own name) and starts a
  `StatJob`; the look is PARKED as `PendingLook{ t, q0, q1, e, job }` on the Editor (one at a
  time; a newer B3 cancels the older). On `.done` ⇒ `openFile(ed, t, e)`; on `NotFound`
  (or any error) ⇒ the literal-search arm exactly as today (`look.search` on the ORIGINAL
  expansion `e0..e1`). In-memory mounts complete within the same frame (their clients are
  pumped by `runSync`? — NO: use the job + `step` per frame uniformly; the served/draw/input
  pipes are polled every tick, so a StatJob completes on the next `frameEnd`). URL ⇒
  `warning("{s}: opening URLs is deferred (R-EDIT-13)\n")`; include ⇒ fail to literal.
  Document in `look.zig`'s header, R-02 revision log (v5, browser-host note under R-EDIT-07,
  no ID change) and S-05 §6.
- `look.zig:36-46` seam replaced by the call into `expand.zig`; `PendingLook` stepping lives
  in `Load.zig`'s frame loop or a small `core/pendinglook.zig` (caps).

### 3e. `Get` for directory windows only — `src/core/exec/cmd_get.zig` (R-P13b-5)
- exectab `Get` (exec.c, verify line): for `w.isdir` ⇒ start a `Load` (dir) that replaces the
  listing; for a file window ⇒ `warning("Get: files await the Put/Get wave\n")` — cite the
  deferral; the boot `/` window must be refreshable so `n/` and `bin/` appear after the
  origin attaches (the window does NOT auto-refresh; acme doesn't either).

### 3f. Boot layout — `core/boot.zig`, `main_wasm.zig` / `ns_boot.zig` (acme.c:242-260)
- **Two columns**; `openfile.readFile(ed, row.col[1], "/")` — the synthetic root in the
  RIGHTMOST column, the left empty. The `scratch` demo (`demo_body`) leaves `main_wasm`.
  `boot.boot()`'s `win_name/body` options STAY for the acceptance scenes (R-P13b-4: no
  golden moves); add `Options.dir_boot: bool` (or a separate `boot.bootAcme(...)`) used by
  `main_wasm`, plus a NEW frozen scene (FROZEN-ACCEPT-13B) after spot-checks: two columns,
  `/` window rightmost, body `dev/\tmnt/\n`-shaped, tag `/ Del Snarf Get | Look `.
- Boot must not block on the load: the `/` listing arrives on the first frames via the Load
  loop (in-memory pipes ⇒ within a frame or two).

### 3g. `/mnt/snarf-self/ns` (13a's deferred SEAM(ns))
- Add the read-only `ns` file at the served root rendering `ed.ns.?.list()`; update the
  existing root-listing test (`"served: root dir read lists sorted window dirs"`) — this
  wave is allowed to change served listings (the 13a ruling deferred exactly this here).

### 3h. Docs
- S-05 §2: replace "one entry per line" with the columnated layout (text.c:136-198, TABDIR,
  narrower tabs); §6: the async existence-check note. R-02 revision log v5. S-02 §6: `ctl`
  `isdir`, `ns` file. R-EDIT-03 unchanged. `git mv agents/contracts/phase13-opfs.md
  agents/contracts/phase14-opfs.md` (OPFS is phase 14 now; fix its header line).

### 3i. Rulings
- **R-P13b-1** No golden moves; FROZEN-ACCEPT-13B is the only new freeze.
- **R-P13b-2** Asynchronous existence check (above); one pending look at a time.
- **R-P13b-3** `wdir` = `/`.
- **R-P13b-4** Accept scenes keep `boot()`'s `win_name/body` path untouched.
- **R-P13b-5** `Get` for directory windows only.
- **R-P13b-6** No warp; touch semantics NOT implemented.
- **R-P13b-7** `Editor.zig` gains fields + ≤ 3 one-line calls; all logic in new files ≤ ~400
  pre-test lines; `core` imports nothing from `dev`/`shim`/`origin`; jobs only on `/dev*`.

## 4. Named tests (sonnet)

| # | Where | Test |
|---|---|---|
| T1 | `dirwin.zig` | `dirCmp`: `a < ab < b`; `foo/` vs `foo` by length; rune-wise not byte-wise for a non-ASCII pair. |
| T2 | `dirwin.zig` | `columnate` golden: 7 names into a 640-px body with the 9×18 font — hand-compute `mint=9`, `maxtab=27`, per-entry widths, `colw`, `ncol`, `nrow`, then the exact text with tabs and newlines (fills down columns). |
| T3 | `dirwin.zig` | `columnate` sets the body frame's `maxtab` to 27 and a normal window's stays 36 (4×9). |
| T4 | `dirwin.zig`/`Window.zig` | `applyListing`: tag ends `/`, `isdir`, `filemenu=false`, tag reads `<name>/ Del Snarf Get \| Look ` (no `Put`/`Undo`), `dirty=false`, `dirnames` sorted. |
| T5 | `openfile.zig` | `openFile("/")` over a booted tree + in-memory ns (served + fake `/dev`): after stepping loads, a window named `/` exists in `makeNewWindow`'s column with body listing `dev/` and `mnt/` columnated. |
| T6 | `openfile.zig` | `openFile` on an already-open name reuses the window (no second window); `lookFile`'s trailing-slash rule holds. |
| T7 | `expand.zig` | `expandFile` textual cases: `dat.h:27` ⇒ name `dat.h`, addr `27`; `:/^main/` ⇒ no name, addr `/^main/`; `http://x/y:80` ⇒ `.url` with no colon split; `<stdio.h>` ⇒ `.include`; `foo` ⇒ `.file` no addr; a click on whitespace ⇒ null. |
| T8 | `look.zig`/`expand.zig` | B3 on `mnt/` inside the `/` window ⇒ after the StatJob completes a `/mnt/` window opens listing `snarf-self/`; B3 on `zzz` (no such file) ⇒ literal search runs (selection moves to the next `zzz` or stays) and no window opens. |
| T9 | `openfile.zig` | `openFile` with addr `3` on a 5-line file selects line 3 after load; with `/re/` selects the match; out-of-order addr ⇒ "addresses out of order" warning, selection = whole/none per the C. |
| T10 | `openfile.zig` | Relative name from a window named `/mnt/snarf-self/` resolves to `/mnt/snarf-self/<name>`; from a rowtag/column tag (no window) ⇒ `/<name>`. |
| T11 | `Load.zig` | Missing file ⇒ `+Errors` gets `can't open <name>: …` and the window stays, empty, named. Deleting a window mid-load drops the Load without error (tombstoned ticket; server later replies harmlessly). |
| T12 | `cmd_get.zig` | `Get` on the `/` dir window after binding a new prefix (`ns.mount("/n/x", …)`) re-lists and now shows `n/`; `Get` on a file window warns and changes nothing. |
| T13 | `accept.zig` | Scene `phase-13b: acme boot — two columns, the root directory window rightmost`: after a few `frameEnd`s the right column holds `/`, body text `dev/\tmnt/\n` (verify the exact tabs per T2's method), tag as T4; FROZEN-ACCEPT-13B after spot-checks. Existing scenes unchanged. |
| T14 | `served` tests | `ctl` reports `isdir 1` for a dir window, `0` otherwise; `/mnt/snarf-self/ns` reads the `Namespace.list` text; root listing test updated. |
| T15 | `tools/smoke_wasm.mjs` | Boot + ticks no trap; the first blit is still pale-blue at (0,0); a later blit shows body text pixels in the right column (any non-background pixel at a probe point inside the right column's body) — proves the dir load ran in the real module. |

## 5. Gate (fable)
1. Suite to a file, `$?==0`, 0 failures, twice; fmt; wasm build; smoke; boundary greps; no
   FROZEN change except the new 13B constant; test-name list ⊇ main's.
2. Manual (Larry): `make run` — two columns, `/` window on the right listing `dev/ mnt/`
   (then `Get` after the origin attaches shows `n/ bin/`); B3 on `mnt/` → `snarf-self/` →
   `index` opens the served index as a file window.
3. Report `agents/reports/phase13b-directory-windows.md`; HANDOFF: directory windows DONE,
   R-EDIT-03 satisfied, `wdir`=`/`, async look note, phase 14 = OPFS, native-host spike next.
