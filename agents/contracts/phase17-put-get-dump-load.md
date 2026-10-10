# Phase 17 contract — `Put`, `Get` for files, `Putall`, name-change `Undo`, `Dump`/`Load`

Status: **binding once fable signs §3.** Branch `phase17-put-get-dump-load` (worktree
`../snarf-worktrees/phase17-put-get`), based on `main@cf9e30c` (16 merged: 712 tests, ABI v6,
fs-record v2). Requirements: **R-EDIT-15** (Get/Put/Putall through the namespace; a window's
name is a namespace path), **R-EDIT-16** (Dump/Load to a namespace file), R-EDIT-02 (live tag:
`Put` appears while modified, vanishes once written), R-EDIT-11 (undo kept across Put),
R-EDIT-20 (names resolve in the window's directory), R-EDIT-21 (errors to `+Errors`), R-9P-09
(OPFS), R-9P-13 (nothing blocks). Queue source: `agents/NEXT-PHASES.md` Tier 1 item 1 (user's
pick 2026-10-04). This wave is what makes Snarf edit the repository through `/n/origin/fs/`.

Pipeline: fable spec → **opus** codes §3 → **sonnet** writes §4 → **sonnet** runs the gate →
**fable** reviews → orchestrator applies nits → merge.

**Out of scope** (separate phases, do not touch): Zerox/Sort/Exit/Kill (Tier 1 item 3; `Exit`
will call this wave's `RowDump`), external commands (item 2), everything under NEXT-PHASES
"Parked", the Edit language's `w`/`r` file commands (`edit/cmd.zig:402` keeps refusing them;
they can reuse `Put.zig` later), `/mnt/host`, `/dev/storage`, auto-dump on `visibilitychange`.

## 1. Ground truth (`larryr/plan9port@337c6ac`, `src/cmd/acme/`)

| Item | Where | What |
|---|---|---|
| exectab rows | `exec.c:105` Dump `{dump, FALSE, TRUE, XXX}`; `:114` Load `{dump, FALSE, FALSE, XXX}`; `:120` Put `{put, FALSE, XXX, XXX}`; `:121` Putall `{putall, FALSE, XXX, XXX}` | none marks; Dump/Load share `dump()` with `isdump = flag1`. |
| `getname` | `exec.c:476-539` | `getarg(argt)`; no arg ⇒ promote; **for Put an arg WITHOUT a `/` is also promoted** (synthesize a name for a not-yet-existing file, :487-501) ⇒ `t = argt`. Promoted + `narg<=0` ⇒ the window's own name (:504-507); relative ⇒ `dirname(t)` + `/` + arg (:511-526); empty ⇒ nil. |
| `get` | `exec.c:589-669` | `winclean(TRUE)` two-strike unless dir/empty (:605); `getname(..., FALSE)`; nil ⇒ `"no file name\n"`; **TextAddr** capture `nlcount` of origin, q0, q1 (:623-630); `textreset` + `windirfree` (:632-637); `samename = runeeq(name, file->name)`; `textload(t, 0, name, samename)` (setqid = samename); `samename ⇒ mod=FALSE, dirty=FALSE` else `mod=TRUE, dirty=TRUE` (:640-648 — a Get of ANOTHER name fills this window and marks it modified; the window keeps its name); `winsettag`; `unread=FALSE`; tag caret to end; `samename ⇒` restore q0/q1 via `nlcounttopos` then origin (:656-664); `textscrdraw`. **`putseq` is NOT touched by Get** — `textreset` zeroes `file->seq`, so a window Put before (putseq≠0) shows ` Put` again after Get (wind.c:514). Port that; verify against the live acme (`~/proj/plan9port/bin/acme`) in review. |
| `nlcount` / `nlcounttopos` | `ecmd.c:664-690`, `addr.c:58-72` | lines in `[q0,q1)` + runes since the last `\n`; inverse: skip `nl` newlines from `q0`, then up to `nr` runes not crossing a `\n`. |
| `textreset` / `textload` file arm | `text.c:103-124`, `:249-284` | `file->seq = 0`, logs reset, buffer emptied, `org=q0=q1=0`; file arm: `isdir=FALSE`, `filemenu=TRUE`, `fileload` + sha1; **`setqid ⇒ file->sha1/dev/mtime/qidpath` recorded** (:277-284). |
| `putfile` | `exec.c:697-836` | `dirstat(name)`; if it exists AND `name == file->name`: dev/qid/mtime differ ⇒ `checksha1` (:672-694 re-reads the file, accepts if the hash matches); still differ ⇒ `unread ? "%s not written; file already exists\n" : "%s modified%s%s since last read\n\twas %t; now %t\n"` (muid arm), record the new identity, **abort** (:712-725). `create(name, OWRITE, 0666)` (:727) — Plan 9 `create` truncates an existing file; fail ⇒ `"can't create file %s: %r\n"`. `dirfstat(fd)`; `QTAPPEND && length>0` ⇒ `"%s not written; file is append only\n"` (:744-748). Write in `BUFSIZE/UTFmax` rune chunks as UTF-8, hashing (:750-761); any short write / flush / close failure ⇒ `"can't write file %s: %r\n"` (:757-773). **Then, only if `name == file->name`** (:774-810): whole-file write ⇒ re-stat, record `qidpath/dev/mtime/sha1`, `mod=FALSE`, `dirty=FALSE`, `unread=FALSE`; every text's window gets **`putseq = f->seq`** (:807) and `dirty`. `winsettag(w)` (:818). A `Put othername` writes a copy and changes NOTHING on the window. |
| `put` | `exec.c:898-925` | `et->w == nil || isdir ⇒ return` (silent); `getname(..., TRUE)`; nil ⇒ `"no file name\n"`; `autoindent ⇒ trimspaces` (n/a — Snarf has no autoindent, F-8); `putfile(f, 0, f->b.nc, name)`. |
| `putall` | `exec.c:1166-1201` | columns left→right, windows top→bottom; skip `isscratch || isdir || nname==0` and windows with an open `event` fid; `access(name, 0) < 0 && (mod || ncache)` ⇒ `"no auto-Put of %s: %r\n"`, else `wincommit` + `put(&w->body, nil, nil, …)`. **Putall never creates a file.** Failures do not stop the loop. |
| `dump` | `exec.c:928-945` | `narg ? arg : getbytearg(argt)`; `isdump ? rowdump : rowload(…, FALSE)`. |
| `rowdump` | `rows.c:465-512` | `ncol == 0 ⇒ return`; `file == nil ⇒ home == nil ? "can't find file for dump: $home not defined\n" : "$home/acme.dump"`; writes a temp file then `dirwstat` renames it over `file`; failures warn. |
| `rowdump1` format | `rows.c:317-462` | line 1 `wdir`; lines 2-3 the two global font names; line 4 column lefts as `%11.7f` percents of the row width, space-separated; `w <row tag first line>`; per column `c%11d <tag first line>` (the tag follows ONE space after the 11-wide index); per window: `wincommit(w, &w->tag)`; `x` (zerox, n/a), `e` (external, n/a), **`f%11d %11d %11d %11d %11.7f %s`** = col, id, q0, q1, y-percent of the column height, fontname when `(dirty==FALSE && access(name,0)==0) || isdir`, else **`F%11d %11d %11d %11d %11.7f %11d %s`** = col, j, q0, q1, y-percent, **rune count**, fontname (:406-420); then the `winctlprint(w, buf, 0)` line (five `%11d ` fields: id, tag nc, body nc, isdir, dirty) **immediately followed on the same line** by the tag text with `\n`→`0xff` (:423-438); then for `F` the body as text (:439-450). |
| `rowload` | `rows.c:559-844` | `file == nil ⇒ $home/acme.dump` (same warning); `Bopen` fail ⇒ `"can't open load file %s: %r\n"`; line 1 `chdir`; lines 2-3 fonts (`rfget`); if `initing && ncol==0` rowinit; column percents: `j = linelen/12`, `1..10` columns, each `0 ≤ p < 100`; existing columns get their borders moved (`colresize` pairs, `Dx ≥ 50`), extra ones `rowadd(row, nil, x)` (:607-640); `c`/`w` tag lines (:647-675: delete the whole tag, insert the saved text — for `c` the text after the first space of `l+12`); then window records: `f` (fontname at `l+61`, `ndumped=-1`), `F` (fontname at `l+73`, `ndumped = atoi(l+61)`), `x`, `e`; fields `i=col, j=id, q0, q1, percent` at `l+1+k*12`; `i>ncol ⇒ ncol`; `y` from the percent, out of range ⇒ `-1`; `coladd(c, nil, nil, y)`; next line = ctl+tag: `0xff`→`\n`, `r = runes from l+60`, name = up to the first space, `winsetname` (dumpid==0), text after the first `|` appended after `wincleartag`; `ndumped ≥ 0 ⇒` read exactly `ndumped` RUNES from the dump into the body, `mod=TRUE, dirty=TRUE`, `winsettag`; else if the name's last component does not start with `+`/`-` ⇒ `get(&w->body, …)`; clamp `q0/q1` to `nc` (else both 0); `textshow(q0, q1, 1)`. Any malformed line ⇒ `"bad load file %s:%d\n"`, return FALSE. |
| `winundo` | `wind.c:351-373` | `fileundo`; `textshow(body, q0, q1, 1)`; **`v->dirty = (f->seq != v->putseq)`** (:366); `winsettag`. |
| `winsetname` | `wind.c:376-398` | no-op if equal; `isscratch = name ends in "/guide" or "+Errors"`; `filesetname`; `winsettag` each text. |
| `filesetname` / `fileunsetname` | `file.c:139-164` | **`seq > 0 ⇒` push a `Filename` undo record** carrying the OLD name, `mod`, `seq`; set the name; `unread = TRUE`. |
| `fileundo` Filename arm | `file.c:259-271` | `f->seq = u.seq`; push the inverse onto the other stack; `mod = u.mod`; restore the old name; **`*q0p/*q1p` untouched**. |
| `winsettag1` Put arm | `wind.c:485-486`, `:514-518` | `tag.file->mod ⇒ wincommit(w, &w->tag)` first; **`dirty = nname && (ncache || file->seq != putseq)`; `!isdir && dirty ⇒ " Put"`** inside the `filemenu` block. |
| `wincommit` name half | `wind.c:594-618` | `parsetag`; name differs from `file->name` ⇒ `seq++`, `filemark`, `mod=TRUE`, `dirty=TRUE`, `winsetname`, `winsettag`. Call sites that matter here: **any button press in a text** (`acme.c:644-650`), the pointer leaving a text (`acme.c:583-588`), a `\n` typed in a tag (`text.c:938-939`), `typecommit` at run end / arrow keys (`text.c:414-419`), the 500 ms `KTimer` (`acme.c:470-479`), before dump (`rows.c:364`). |
| `winclean` | `wind.c:666-685` | `isscratch || isdir ⇒ TRUE`; two-strike otherwise. |
| ctl verbs | `xfid.c:770-777` | `get` ⇒ `get(&w->body, nil, nil, FALSE, XXX, nil, 0)`; `put` ⇒ `put(&w->body, nil, nil, XXX, XXX, nil, 0)`. (`dump`/`dumpdir` set `dumpstr` for external windows — n/a.) |
| `$home` | `acme.c:136` `home = getenv("HOME")`; `dat.h:547` | the ONLY use of `home` is the default dump path (and the `e` record's default dir). |

## 2. Merged reality (`main@cf9e30c`) — what exists, what is missing

**Exists (the Get read half, 13b):** `core/Load.zig` — the asynchronous `textload` (StatJob →
ListDirJob/ReadFileJob), `installFile` (`dirwin.resetText` = `textreset` incl. `file.reset()`,
`isdir=false`, `filemenu=true`, UTF-8 sanitation), `finishTail` (look.c:865-870 + the deferred
`:addr`), one load per window, tombstone-safe drop on window death. `exec/cmd_get.zig` — the
directory arm; the file arm warns `Get: files await the Put/Get wave`. `openfile.absName/
cleanName`, `errors.dirName`, `errors.lookFile`, `exec.getArg` (raw argt selection).
`File.zig` — undo/redo stacks with `mod_before`, `mod`, `setName` **without** an undo record
(R-P4-7 deferral), `reset`, `undoSeq/redoSeq`. `wintag.setTag1` — `Put` arm **deferred**
(`wintag.zig:152-154`), `sweep` keyed on `{undo, redo, mod}`, `tag_file.mod` cleared at the
end (wind.c:565). `Window` — `dirty`, `isdir`, `filemenu`, `clean` two-strike, `ctlPrint`;
**no `putseq`, no `isscratch`**. `cmd_edit.undo` — `w.dirty = f.mod` approximation.
Served `ctl`: `clean dirty delete del name`. Namespace: `nsjob.WalkJob`, `nsio.{StatJob,
ReadFileJob, ListDirJob}` on `tickets.begin/check`; **no write/create job** (the `nsjob.zig:38-43`
SEAM says: build them in this wave, on `tickets.begin`, in `nsio.zig`'s shape). `msg` has
`topen/twrite/tcreate/tclunk`, `OWRITE=1`, `OTRUNC=0x10`; `Client.ioMax()`.

**OPFS write path (16b item 4 — CONFIRMED LANDED):** `dev/opfs_io.zig:52-65` `write` = one
`fsOp{write, path, arg0=offset, payload}` per Twrite (parked, slot keyed `(fid, op, offset)`),
then `forgetStat(path)` and `markWriter(fid)`; `DevOpfs.clunkOp` (`opfs.zig:387-390`) issues a
fire-and-forget `close` (record **version 2**, `op=9`, ticket 0) for a fid that wrote.
`web/opfs.js:239-262` keeps ONE `FileSystemWritableFileStream` per PATH (`writables` map,
`keepExistingData: true`, positional writes) for the whole write sequence; `perform`
(`opfs.js:315-320`) **closes (= commits) that stream before any non-`write` op on the same
path**, and ops are serialized per path. `truncate` opens+closes its own stream. There is no
`rename` (R-P14b-4). Consequence for Put, stated as a rule in §3b.

**Origin (`/n/origin/fs`):** `tools/origin/tree.zig:61-70` `Ops` = attach, walk1, clone, open,
read, write, clunk, stat — **no `create`**. `open` honours `OTRUNC` on host files
(`tree.zig:239-241` → `hostfs.truncate`), `write` is positional. So today Put can rewrite an
EXISTING repo file but cannot create a new one. §3h adds `create`.

**Not built anywhere:** a `wincommit` analog — editing the name in a tag never renames the
window (Snarf has no `ncache`, tag edits land in `tag_file` directly; `tag_file.mod` is the
wind.c:485 condition). `Editor.home`. `nlcount`. `isscratch`.

## 3. CONTRACT

### 3a. `src/ninep/nswrite.zig` — NEW: `WriteFileJob` (+ re-export from `nsjob.zig`)
- `pub const WriteFileJob = struct { … }` on `tickets.begin/check` exactly like `nsio.Drain`:
  `init(allocator, ns, path, data: []const u8, opts: Options)` with `Options{ truncate: bool =
  true, create: bool = true, perm: u32 = 0o666, must_exist: bool = false }`. Phases:
  `walking` (union `WalkJob`) → on success `Topen(OWRITE | (truncate ? OTRUNC : 0))` →
  `writing` (Twrite loop, chunk = `min(data.len - off, client.ioMax() - msg.header_size - 23)`,
  advancing offset; an `Rwrite.count` short of the chunk ⇒ `error.ShortWrite`) → `clunking` →
  `done`. On `error.NotFound` from the walk and `create && !must_exist`: walk to the PARENT
  (`nspath` dirname; **first union member whose parent walk succeeds** — Plan 9 picks the member
  with `MCREATE`, `9/port/chan.c namec Acreate`; Snarf's table has no MCREATE flag, so bind
  order decides; only `/bin` is a union today), `Tcreate(fid, basename, perm, OWRITE)` (the
  fid now IS the new file, 5/create), then `writing`. `must_exist` ⇒ NotFound surfaces as
  `error.NotFound` (Putall's "no auto-Put"). Result fields: `qid: Qid` (from Ropen/Rcreate —
  carries `qtype.append`), `written: usize`. `deinit` is fire-and-forget on every path
  (`tickets.discardClunk`, the `Drain.deinit` rule). Replace the `nsjob.zig:38-43` SEAM with
  the re-export `pub const WriteFileJob = @import("nswrite.zig").WriteFileJob;`.
- No partial-range writes (`exec.c:775` arm) — Put always writes the whole buffer; cite and drop.

### 3b. `src/core/Put.zig` — NEW: one in-flight `putfile` (file-as-struct, the `Load.zig` shape)
- `Put{ allocator, w: ?*Window, name: []u8 (owned, absolute), bytes: []u8 (owned SNAPSHOT —
  `Buffer.writeRaw`, raw bytes so untouched invalid sequences survive, S-05 §1), seq_at: u32
  (the file's `seq` when issued), samename: bool, must_exist: bool, job: union(enum){ stat:
  StatJob, verify: ReadFileJob (+ `verify_buf`), write: WriteFileJob, restat: StatJob },
  finished }`. `Editor.puts: ArrayList(*Put)`, heap-pinned (jobs borrow their path — Load's
  rule). `pub fn start(ed, w, name, must_exist) Text.Error!void`; `stepAll(ed)` from
  `Editor.frameEnd` right after `Load.stepAll`; `dropWindow(ed, w)` sets `w = null` and lets the
  write FINISH (a half-written file is worse than a finished one; acme's synchronous `putfile`
  cannot be interrupted either) — the completion bookkeeping is skipped when `w == null`.
- **R-P17-1 (one Put per window):** a `Put` on a window with one already in flight warns
  `"{s}: Put already in progress\n"` and returns. Puts on DIFFERENT windows run concurrently.
- Sequence (exec.c:697-836 turned inside out):
  1. `StatJob(name)`. Exists AND `samename`: compare `file.disk` (`{qid.path, qid.vers, mtime}`)
     with the Rstat; differ ⇒ **sha1 arm**: `ReadFileJob` the file, `std.crypto.hash.Sha1` it,
     equal to `file.disk.sha1` ⇒ accept (update `disk`), else: `file.unread ⇒ "{s} not written;
     file already exists\n"` otherwise `"{s} modified{s}{s} since last read\n\twas {s}; now {s}\n"`
     (muid arm; times as UTC `YYYY-MM-DD HH:MM:SS` from `std.time.epoch` — acme's `%t`),
     record the new identity in `disk`, **abort**. NotFound ⇒ `must_exist ? "no auto-Put of
     {s}: file does not exist\n" + abort : continue`. Any other stat error ⇒ `"can't create
     file {s}: {s}\n"` + abort.
  2. `WriteFileJob(name, bytes, .{ .must_exist })`. Before writing, the Ropen/Rcreate qid:
     `qtype.append and stat.length > 0 ⇒ "{s} not written; file is append only\n"`, abort
     (clunk). Walk/open/create failure ⇒ `"can't create file {s}: {s}\n"`; a write failure ⇒
     `"can't write file {s}: {s}\n"`.
  3. `samename` ⇒ `restat` (exec.c:790-799: fresh identity) then the tail; else finish.
  4. Tail (exec.c:774-818), only when `w != null and samename`: `file.disk = {qid, mtime,
     length, sha1(bytes)}`; `w.putseq = seq_at`; **`file.mod = false` and `w.dirty = false`
     only if `file.seq == seq_at`** (nothing was typed since the snapshot — if something was,
     `seq != putseq` keeps the window dirty and the `Put` word stays, which is exactly
     wind.c:514's rule); `file.unread = false`; `w.setTag()`; `ed.needs_flush = true`.
     `!samename` (a `Put other`) changes nothing on the window (exec.c:774).
- **R-P17-2 (OPFS write discipline):** Put issues its Twrites on ONE fid, back to back, with
  nothing else on that path in between, then Tclunk — so `/mnt/opfs` sees one `createWritable`
  per Put (`web/opfs.js` per-path stream, closed by the `close` the clunk sends). The `restat`
  AFTER the clunk is what commits the stream if the fire-and-forget `close` has not landed yet
  (`opfs.js:319` closes before any non-write op), so the identity it records is the committed
  file's. Never interleave a stat/read on the path between the writes. `Twrite` chunking
  follows `ioMax`, not 8 KiB — the quadratic swap-file cost 16b removed stays removed.
- All warnings go through `ed.warning` (→ `+Errors`, R-EDIT-21), never silently (Plan 9 rule).

### 3c. `src/core/exec/cmd_put.zig` — NEW: `getName`, `put`, `putall`
- `pub fn getName(ed, t: *Text, argt: ?*Text, arg: []const u8, isput: bool) !?[]u8`
  (exec.c:476-539): `exec.getArg(argt)` first; promotion rules verbatim incl. the Put
  no-slash rule; relative ⇒ `errors.dirName(w)` + `/` + arg; cleaned via `openfile.cleanName`;
  empty ⇒ null. Owned result. `cmd_get.zig` imports it (its header's "dropped `getname`" note
  goes away).
- `put` (exec.c:898-925): `et.w == null or isdir ⇒ return`; **`wintag.commit(w)` first** (the
  B2 press already did it — acme.c:649 — this is the served-`ctl put` safety net); `getName(…,
  true)` ⇒ null ⇒ `"no file name\n"`; `Put.start(ed, w, name, false)`.
- `putall` (exec.c:1166-1201): columns in order, windows in order; skip `isscratch or isdir or
  name.len == 0` (the `nopen[QWevent]` skip is n/a until `event` is served — cite); for `file.mod`
  windows: `wintag.commit(w)` then `Put.start(ed, w, name, true)` (`must_exist` = the
  `access()` check made asynchronous — **R-P17-3**). Continue past every failure; each failure
  is its own warning on completion.

### 3d. Live tag, `putseq`, `isscratch`, the `wincommit` analog
- `Window`: `putseq: u32 = 0` (dat.h:260), `isscratch: bool = false` (dat.h:240),
  `tag_state` gains `put: bool`. `clean` passes `isscratch` (wind.c:669).
- `wintag.setTag1`: the Put arm goes LIVE (wind.c:514-518): `dirty = name.len != 0 and
  f.seq != w.putseq; if (!w.isdir and dirty) " Put"` inside the `filemenu` block; at entry,
  `if (w.tag_file.mod) try commit(w)` (wind.c:485-486). `sweep` compares `put` too (`filemenu and
  !isdir and name.len != 0 and f.seq != w.putseq`), so a Put completing or a Get resetting
  `seq` recomposes the tag within the frame.
- `wintag.setName(w, name)` = `winsetname` (wind.c:376-398): equal ⇒ return; `isscratch` by
  suffix; `w.body.file.setName(name)` (now recording, §3e); `setTag1`. Route the Window-level
  callers through it: `openfile.openFile:95`, `place.mintWindow:75`, `dirwin.applyListing:179`,
  served `cmdName` (xfid.c:699-702 marks first, then `winsetname` — keep that order so the
  rename IS undoable), `errors.errorWin` (gets `isscratch` for free: `+Errors`). `boot.zig:116`
  may keep the raw `File.setName` (seq 0, no window yet).
- `wintag.commit(w)` = `wincommit`'s name half (wind.c:608-616): `parseTag`; name half ≠
  `file.name` ⇒ `ed.seq += 1; file.mark(ed.seq); file.mod = true; w.dirty = true; setName;
  setTag1`. Needs `ed`: signature `commit(ed, w)`. **Call sites:** (1) `Gesture.handleMouse`'s
  button-down into a Text that is a window TAG (acme.c:644-650 — before `textselect.run`, so a
  B2 on `Put` sees the committed name); (2) `typing.zig`: a `\n` typed in a tag (text.c:938-939)
  and every `typecommit` arm (`in_typing_run = false` sites) when `t` is a tag; (3)
  `RowDump` before serializing each window (rows.c:364). The pointer-leaves-text commit
  (acme.c:583-588) and the 500 ms `KTimer` are NOT ported (no timer in the core; the button-down
  commit covers the gesture that matters) — record as a divergence in S-05 §2.
- `cmd_edit.undo`: `w.dirty = (f.seq != w.putseq)` (wind.c:366) replaces the approximation; a
  `null` range (a Filename-only transaction) skips `show` and keeps dot; always `w.setTag()`
  (wind.c:372).

### 3e. `src/core/File.zig` — the Filename undo record, `unread`, disk identity
- `Delta.filename: struct { seq: u32, mod_before: bool, name: []u8 (owned, the OLD name) }`.
  `setName` records it when `seq > 0` (file.c:139-148) and sets `unread = true`; `unwind`'s
  filename arm (file.c:259-271): push the inverse (current name) onto `dst`, `mod = mod_before`,
  restore the name, **leave `result` unchanged**. `freeTexts` frees `.filename.name`.
- `unread: bool = false` (dat.h `File.unread`): set by `setName`, cleared by a successful Load
  (text.c `unread=FALSE` via `openfile`/`get`) and Put.
- `disk: ?Disk = null`, `Disk = struct { qid: ninep.qid.Qid, mtime: u32, length: u64, sha1: [20]u8 }`
  (dat.h `qidpath/dev/mtime/sha1`; `dev` has no 9P analog — the qid carries it). Written by
  `Load` (file arm, `samename`/`setqid`) and `Put`'s tail; read by `Put`'s stale check and by
  `RowDump`'s existence test (§3g). `reset()` leaves `disk`, `unread`, `name` alone.

### 3f. `Get` for files — `cmd_get.zig`, `core/getaddr.zig` (NEW), `Load.zig`
- `core/getaddr.zig` (~120): `TextAddr{ lorigin, rorigin, lq0, rq0, lq1, rq1 }`, `nlCount(t, q0,
  q1) struct{nl, nr}` (ecmd.c:664-690), `nlCountToPos(t, q0, nl, nr)` (addr.c:58-72),
  `capture(t) TextAddr` (exec.c:624-630), `restore(t, a)` (exec.c:659-665: `setSelect(q0, q1)`,
  `setOrigin(q0, false)`, scrollbar redraw).
- `cmd_get.get` file arm: `getName(…, false)`; `samename = eql(name, file.name)`; `addr =
  getaddr.capture(&w.body)`; `Load.start` now RETURNS `?*Load` (null when it refused); set
  `ld.get = .{ .samename, .addr }`. The dir arm is unchanged.
- `Load`: new field `get: ?struct { samename: bool, addr: getaddr.TextAddr } = null`. File arm:
  copy `qid/mtime/length` out of the StatJob BEFORE `deinit` (its strings alias the job) into
  `self.stat_copy`; after `installFile`, when `get == null or get.samename` set `file.disk` with
  `sha1(data)` (text.c:277-284 `setqid`), `file.unread = false`. `finishTail`: when `get != null`
  apply exec.c:640-666 — `samename ⇒ mod=false, dirty=false, restore(addr)` else `mod=true,
  dirty=true`; `putseq` untouched (see §1 `get`). The existing look.c tail stays for `get ==
  null`. **Cap:** `Load.zig` is 404 pre-test already; **pure-move** `addressAndShow`,
  `applyAddress` and their 16b tests to `core/loadaddr.zig` (forwarders `Load.addressAndShow`
  kept; test names identical) so `Load.zig` lands ≤ ~380.

### 3g. `Dump` / `Load` — `exec/cmd_dump.zig`, `core/Session.zig`, `core/RowDump.zig`, `core/RowLoad.zig`, `core/dumpfmt.zig` (all NEW)
- **Format = acme's `rowdump1` verbatim** (§1), so a dump reads like an acme one: line 1 `wdir`
  = `/` (R-P13b-3); lines 2-3 = the font name (`draw.Font` default name, twice; one font —
  ignored on load); the percent line; `w`, `c`, then `f`/`F` + ctl/tag (+ body) records. `x`/`e`
  records are never written (no Zerox, no external windows) and are **skipped with a warning**
  on load (`"load: external/zerox record skipped\n"`, consume their extra lines per rows.c:686-714).
  **R-P17-4 (existence without `access()`):** `f` when `(!w.dirty and file.disk != null) or isdir`,
  else `F` with the body (a window loaded or Put successfully has `disk`; an unread or dirty one
  is dumped inline — the same information acme gets from `access()`, available synchronously).
- **R-P17-5 (`$home`):** `Session.home: ?[]const u8` is set by the HOST entry point:
  `wasm_boot.zig` sets `"/mnt/opfs"` (the browser's home — NEXT-PHASES item 1; R-9P-09 "the
  always-available private area"); `main_native.zig` sets the real `$HOME` (`std.process` env;
  null if unset). Nothing is mounted at `$HOME` natively until Tier 2 item 4, so a native `Dump`
  today warns `can't create file /Users/…/acme.dump: NotMounted` — honest, and the path is right
  the day the host file server mounts at `/`. Default file = `home/acme.dump`; `home == null ⇒
  "can't find file for dump: $home not defined\n"` / `"… for load …"` (rows.c:477-478, :574-575).
  Document the asymmetry in S-02 §4 and S-05 §8; it must not get lost.
- `cmd_dump.dump(ed, et, t, argt, isdump=flag1, …)` (exec.c:928-945): `arg.len != 0 ? arg :
  exec.getArg(argt)`; relative ⇒ `openfile.absName`; `Session.startDump`/`startLoad`.
- `Session` (~90): `home`, `dump: ?*RowDump`, `load: ?*RowLoad`, `dumpPath(a, arg) !?[]u8`,
  `step(ed)` (one state per frame, from `frameEnd`), `deinit`. One dump and one load at a time;
  a second `Dump`/`Load` while one runs warns and returns.
- `RowDump` (~330): `start(ed, path)`; serialize into an owned buffer (`dumpfmt`), **after
  `wintag.commit(ed, w)` for every window** (rows.c:364), `ncol == 0 ⇒` return silently
  (rows.c:472); then `WriteFileJob(path, buf, .{ .truncate = true })`. **No temp-file + rename**
  (R-P14b-4: OPFS has no rename) — the dump is written in place; failure ⇒ `"can't create temp
  file for {s}: {s}\n"` reworded to `"can't write dump {s}: {s}\n"`. Fields: `%11d` right-aligned
  decimals, `%11.7f` percents, `w.ctlPrint`'s five fields, tag `\n` → byte `0xff`, `F` count =
  **runes** (`buffer.len()`), body via `Buffer.writeRaw`.
- `RowLoad` (~380) + `dumpfmt` (~150, the line codecs shared with `RowDump`): `start(ed, path)`
  ⇒ `ReadFileJob` (cap `nsjob.max_file_bytes`), then parse per rows.c:586-833 in ONE frame (no
  I/O inside): `wdir` line (no `chdir` — ignored, must exist), two font lines (ignored), percents
  (`1..10`, `0 ≤ p < 100`; existing columns resized in pairs via `Column.resize` when both stay
  ≥ 50 px; extra columns `Row.add(x)`), `c`/`w` tag lines (replace the whole tag), window records:
  `Column.add`/`place.mintWindow(c, y, "")` at `y` from the percent (out of range ⇒ `-1`), name
  from the ctl/tag line (`wintag.setName`), tag suffix after `|` appended after a `wincleartag`
  analog (wind.c:413-435, add to `wintag.zig`), `F ⇒` insert exactly `ndumped` runes from the
  dump text into the body (no temp file — insert directly; `mod=true, dirty=true`, `setTag`),
  `f` and last component not `+`/`-` ⇒ `Load.start(ed, w, name, …)` (the asynchronous `get`,
  rows.c:820 — the dot restore below therefore runs on the EMPTY body for `f` records; acme's
  `textshow(q0,q1)` ran after a synchronous `get`, so hand `q0/q1` to the `Load` as a deferred
  show: reuse `Load.addr`? No — add `Load.show_range: ?Range` consumed in `finishTail`), clamp
  `q0/q1` (rows.c:826-828), `textshow`. Malformed ⇒ `"bad load file {s}:{d}\n"` and STOP, keeping
  whatever was built (acme returns FALSE the same way). Loading never clears existing windows
  (`initing = FALSE`, rows.c:605).
- `builtins.exectab` rows (exec.c:105/114/120/121): `Dump {cmd_dump.dump, mark=false, flag1=true}`,
  `Load {cmd_dump.dump, false, flag1=false}`, `Put {cmd_put.put, false, false, false}`, `Putall
  {cmd_put.putall, false, false, false}` — alphabetical; table 14 → 18; shape test updated.
- Served `ctl`: `get` and `put` verbs (xfid.c:770-777) in `xfid.zig`'s `ctltab` → `cmd_get.get`
  / `cmd_put.put` with `argt = null`. (`xfid.zig` is over the cap already — two rows + two
  thunks ≤ 15 lines; a split is NOT this wave's.)

### 3h. Origin: `create` for the export (`tools/origin/tree.zig`, `hostfs.zig`)
- `Ops.create` for `.host` DIRECTORY fids: files only (`perm & DMDIR ⇒ "permission denied"`),
  `hostfs.createFile(rel/name)` via `std.Io.Dir.createFile` exclusive (exists ⇒ `"file already
  exists"`), the fid re-pointed to the new file (14a `CreateResult{qid, iounit}`), ops-level log
  line `create <path>`. Nothing else (`remove`/`wstat` stay absent). This is what lets `Put` make a
  NEW file under `/n/origin/fs/`; rewriting an existing one works today. `tools/origin/accept.zig`
  gains the create case.

### 3i. Entry points, docs
- `Editor.zig` (380 pre-test): fields `puts`, `session`; `frameEnd` gains `Put.stepAll(ed)` and
  `ed.session.step(ed)` after `Load.stepAll`; `dropTextRefs` → `Put.dropWindow`; `deinit` →
  `Put.deinitAll`, `session.deinit`. ≤ 8 lines total; nothing else lands here.
- `wasm_boot.zig`: `a.editor.session.home = "/mnt/opfs"`. `main_native.zig`: `$HOME`.
- Docs: S-05 §4 (Put/Get/Putall/Dump/Load now real; the async Put rule R-P17-1; the
  button-down tag commit divergence), §8 rewritten (acme format, `acme.dump`, `$home` per host —
  supersedes "`/dev/storage/snarf.dump` … versioned text format"); S-02 §4 (`/mnt/opfs` is the
  browser `$home`; native = `$HOME`), §6 (ctl `get`/`put`); R-02 revision log **v7** (R-EDIT-15
  delivered; R-EDIT-16 target note → `/mnt/opfs` browser / `$HOME` native; no IDs change);
  `nsjob.zig` SEAM text; HANDOFF; REVIEW-NOTES.

### 3j. Rulings
- **R-P17-1** Asynchronous Put: snapshot + `seq_at`; one per window; clean only if `seq` is unchanged at completion; a Put outlives its window.
- **R-P17-2** OPFS write discipline: one fid, back-to-back Twrites, clunk, THEN restat.
- **R-P17-3** Putall's `access()` becomes `must_exist` on the write job; it never creates.
- **R-P17-4** Dump's `access()` becomes `file.disk != null`.
- **R-P17-5** `$home`: `/mnt/opfs` in the browser, `$HOME` natively (unmounted until Tier 2); default dump `home/acme.dump`; acme's two "$home not defined" warnings verbatim.
- **R-P17-6** Dump format is acme's `rowdump1`, written in place (no rename); `x`/`e` skipped on load with a warning.
- **R-P17-7** Tag-name commit fires on button-down in a tag, `\n`/typecommit in a tag, and before dump; no timer, no pointer-leave commit (documented divergence).
- **R-P17-8** `Get` leaves `putseq` alone (acme does); verify the resulting `Put`-after-`Get` tag against the live acme binary in review and record the result.
- **R-P17-9** Goldens: the ONLY expected moves are scenes whose window is NAMED and has a recorded edit (the tag gains ` Put`); spot-check per R-P2-7 that only the tag line changed, record old/new hashes. Unnamed windows never show `Put`. FROZEN-ACCEPT-13B must not move.
- **R-P17-10** Caps: every NEW file ≤ ~400 pre-test; `Load.zig` via the `loadaddr.zig` pure move; `Editor.zig` ≤ 8 lines; `core` imports `std`/`draw`/`ninep`/siblings only (S-07 §6 — never `dev`/`shim`); `/dev*`, `/mnt/opfs`, `/n/origin` reached by jobs only.

## 4. Named tests (sonnet)

| # | Where | Test |
|---|---|---|
| T1 | `nswrite.zig` | `WriteFileJob` over a `FakeServer`/served tree: existing file ⇒ Twalk, Topen(OWRITE\|OTRUNC), N Twrites at advancing offsets, Tclunk; raw frames read back prove the order and that chunks follow `ioMax`. |
| T2 | `nswrite.zig` | NotFound + `create` ⇒ parent walk + Tcreate(name, 0o666, OWRITE) then writes; `must_exist` ⇒ `error.NotFound` and NO Tcreate; a union parent ⇒ the first member whose parent walk succeeds gets the create. |
| T3 | `nswrite.zig` | deinit mid-write is fire-and-forget (Tflush then Tclunk on the wire, no pump — the T8 pattern); a fresh ticket afterwards still resolves. |
| T4 | `File.zig` | `setName` with `seq>0` records a `filename` delta; `undo` restores the old name and `mod_before`, returns `null` range, pushes the inverse; `redo` re-applies; `seq==0` records nothing; `reset` keeps `disk`/`unread`. |
| T5 | `wintag.zig` | Tag composition: named + edited ⇒ `… Del Snarf Undo Put \| Look `; after `putseq = seq` ⇒ no `Put`; unnamed edited ⇒ no `Put`; dir ⇒ never. `sweep` recomposes when `putseq` changes. |
| T6 | `wintag.zig` | `commit`: edit the tag's name half, click (button-down) ⇒ `file.name` changes, `seq` bumped, `Undo`+`Put` appear, `isscratch` follows the `+Errors`/`/guide` suffix; editing right of `\|` never renames; `Undo` restores the old name in the tag. |
| T7 | `Put.zig` | Put a dirty window named under a served in-memory tree: after stepping, the server holds the exact bytes (raw, incl. an invalid-UTF-8 run preserved), `putseq == seq`, `mod/dirty` false, tag loses `Put`, `disk` recorded, `unread` false. |
| T8 | `Put.zig` | Typing DURING the put (bump `seq` between steps) ⇒ bytes written are the snapshot, window stays dirty, `Put` stays (R-P17-1); a second `Put` while pending warns `Put already in progress`. |
| T9 | `Put.zig` | Stale check: change the served file's mtime/vers after load ⇒ `"<name> modified since last read"` warning, nothing written, `disk` updated, a SECOND Put then succeeds; same mtime but identical content via the sha1 arm ⇒ accepted; `unread` ⇒ `"not written; file already exists"`. |
| T10 | `Put.zig` | Failure paths each warn exactly acme's text into `+Errors`: open refused (`can't create file`), short write (`can't write file`), QTAPPEND (`append only`); the window stays dirty. Window deleted mid-put ⇒ write completes, no bookkeeping, no trap. |
| T11 | `cmd_put.zig` | `getName`: no arg ⇒ own name; `Put foo` ⇒ `<dir>/foo`; `Put /a/b` ⇒ as is; `Put` with a 2-1 chord arg; `Put other` writes a copy and leaves the window dirty/named (exec.c:774). Unnamed ⇒ `no file name`. Dir window ⇒ silent return. |
| T12 | `cmd_put.zig` | `Putall`: three dirty windows (one unnamed, one `+Errors`/`isscratch`, one whose file does not exist) ⇒ only the eligible existing ones are written, the missing one warns `no auto-Put of … file does not exist`, the loop continues, order left→right/top→bottom. |
| T13 | `cmd_get.zig` / `getaddr.zig` | `nlCount`/`nlCountToPos` round-trip on a multi-line body; `Get` on a modified file window reloads the served content, restores dot and origin by line+rune, `mod/dirty` false; `Get other` fills the window and marks it modified; two-strike on a dirty window; `putseq` untouched (R-P17-8). |
| T14 | `cmd_edit.zig` | `undo` after Put: `dirty = (seq != putseq)` — undo past the put re-dirties, redo back to the put state cleans; a Filename-only undo keeps dot and retags. |
| T15 | `dumpfmt.zig` | Field codecs: `%11d`, `%11.7f`, `0xff` tag newline both ways, `F` rune count; a hand-written acme-shaped dump (from §1) parses to the expected records. |
| T16 | `RowDump.zig` / `RowLoad.zig` | Dump a two-column scene (one clean loaded file ⇒ `f`, one dirty ⇒ `F` with body, one dir) to `/mnt/x/acme.dump` on a served tree; the bytes match a golden text; `Load` it into a fresh tree ⇒ same columns (percents), tags, names, the `F` body present and dirty, the `f` window reloaded via `Load`, dot restored. |
| T17 | `Session.zig` | `home == null` ⇒ both `$home not defined` warnings; `home = "/mnt/x"` ⇒ default path `/mnt/x/acme.dump`; `Dump foo` relative ⇒ `/foo`; a second Dump while one runs warns; bad load file ⇒ `bad load file <path>:<line>` and partial state kept. |
| T18 | `served` | ctl `put` writes the file and clears the tag's `Put`; ctl `get` reloads; `index`/`ctl` dirty column follows. |
| T19 | `tools/origin` | `create` under `fs/` makes a real file, exclusive (`file already exists`), refuses `DMDIR`, logs; a Put-shaped sequence (walk fail → parent walk → create → writes → clunk) lands the bytes on disk. |
| T20 | `accept.zig` | Per R-P17-9: list every scene with a named edited window, re-freeze with pixel evidence (tag line only); all others unchanged; FROZEN-ACCEPT-13B unchanged. |
| T21 | `tools/smoke_wasm.mjs` | Through the real module + opfs stub: B3-open a stub file, type, B2 on `Put` in the tag (coordinates from the tag text; the 14b probe knows the geometry) ⇒ the stub log shows exactly one `write` burst, one `close`, then a `stat`; the tag redraw no longer contains `Put`. Then `Dump` ⇒ the stub holds `/acme.dump` starting with `/\n`. |

## 5. Gate (fable)
1. Suite to a file, `$?==0`, 0 failures, twice; `zig fmt`; wasm; `zig build native`; smoke;
   boundary greps (`core` never imports `dev`/`shim`; `nswrite` imports only `ninep` siblings);
   goldens per R-P17-9 with the spot-check evidence; test-name list ⊇ main's; caps table.
2. Manual (Larry): `make run` + `zig build serve` in a repo dir — B3 `n/` → `origin/` → `fs/` →
   a file; edit; `Put` (word vanishes; file changed on disk); edit the tag's name to a NEW path
   under `fs/`, click, `Put` ⇒ the new file exists; `Undo` twice ⇒ name back; `Dump`; reload
   the page; `Load` ⇒ the layout returns. Native: `zig build run-native`, `Dump` ⇒ the honest
   `NotMounted` warning naming `$HOME/acme.dump`.
3. Report `agents/reports/phase17-put-get-dump-load.md`; HANDOFF (R-EDIT-15/16 DONE, `$home`
   closed per R-P17-5, origin `create`, debt: `xfid.zig` cap, timer-less tag commit, no
   rename-safe dump); REVIEW-NOTES entry ("for you: edit the repo through `/n/origin/fs/`").

## 6. Decisions recorded for Larry (no stop required unless he objects)
- **`$home`** closes as NEXT-PHASES stated: `/mnt/opfs` (browser) / real `$HOME` (native);
  dump file `acme.dump` in acme's own format. This supersedes S-05 §8's older
  `/dev/storage/snarf.dump` + "versioned text format" wording (R-02 v7 revision-log line).
- **Origin `create`** widens the origin's trust surface from "rewrite existing files under the
  export" to "create files under the export" (still confined to `fs/`). Not the host-command
  allow-list ADR's territory; flagged so it is not silent.
- Everything else here is implementation under the standing authorization.
