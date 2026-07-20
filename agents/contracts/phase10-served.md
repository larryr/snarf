# Phase 10 side contract (O22) — /mnt/snarf-self served tree (START)

All C cites `larryr/plan9port@337c6ac`; Zig cites current main. Rulings R-P10-A..J
are adopted by the master verbatim (this file is their normative text).

## 1. C ground truth (line-cited)

### 1.1 Qid scheme and Dirtab layout

- Q enum: `dat.h:1-26` — global files `Qdir(0) Qacme Qcons Qconsctl Qdraw Qeditout
  Qindex Qlabel Qlog Qnew`, then per-window `QWaddr QWbody QWctl QWdata QWeditout
  QWerrors QWevent QWrdsel QWwrsel QWtag QWxdata QMAX`.
- Path packing: `dat.h:481-483` — `QID(w,q) = (w<<8)|q`, `WIN(q) = (path>>8)&0xFFFFFF`,
  `FILE(q) = path&0xFF`. Window id 0 = the global level.
- Root table `dirtab[]`: `fsys.c:65-78` — `acme`(QTDIR 0500|DMDIR), `cons` 0600,
  `consctl` 0000, `draw`(dir 0000), `editout` 0200, `index` 0400, `label` 0600,
  `log` 0400, **`new` is a DIRECTORY** (QTDIR 0500|DMDIR).
- Per-window table `dirtabw[]`: `fsys.c:80-95` — `addr` 0600, `body` QTAPPEND
  0600|DMAPPEND, `ctl` 0600, `data` 0600, `editout` 0200, `errors` 0200, `event`
  0600, `rdsel` 0400, `wrsel` 0200, `tag` QTAPPEND 0600|DMAPPEND, `xdata` 0600.
- `Fid` struct: `dat.h:384-396` — fid, busy, open, qid, `Window *w`, `Dirtab *dir`,
  `Mntdir *mntdir`, `nrpart`+`rpart[UTFmax]` (partial-rune write carry,
  `fullrunewrite` xfid.c:415-443).

### 1.2 Dispatch and per-message behavior

- `fsysproc` loop `fsys.c:136-190`: one 9P message -> `Xfid` worker -> `fcall[]`
  table (`fsys.c:44-58`).
- **attach** `fsys.c:342-377`: uname must match, qid = `Qdir` QTDIR, `aname` is a
  Mntdir id.
- **walk** `fsys.c:379-522`: clone semantics with incref (`:400-411`); `".."` ->
  root (`:426-433`); an all-digit name is a window dir — `lookid(id)` under
  `row.lk`, incref (`:446-464`; lookid look.c:789); **`"new"` walks by CREATING a
  window**: `cnewwindow` signal, qid `QID(w->id, Qdir)` (`:466-476`; served by
  `newwindowthread` acme.c:866-882 -> `makenewwindow` util.c:449-469, column
  heuristic: activecol -> seltext's col -> t's col -> last/new column). Otherwise
  linear dirtab/dirtabw scan skipping "." (`:478-490`). On failure the tentative
  newfid is unwound (`:500-505`); leftover `w` ref dropped via winclose (`:517-518`).
- **open** `fsys.c:524-560`: strips OTRUNC/OCEXEC, denies OEXEC/ORCLOSE, checks mode
  against `dir->perm`; real work in xfidopen.
- **read** `fsys.c:576-651`: DIRECTORY reads answered inline — dirtab entries then
  (root only) one numeric dir per window, ids **qsort'ed** (`:611-637`, idcmp :569);
  entries included once cumulative offset `i >= o` (entry-boundary offsets,
  `:598-608`). `Qacme` reads empty (`:585-590`). File reads -> xfidread.
- **stat** `fsys.c:676-687` / `dostat` `:733-748`: qid from `QID(id, dir->qid)`,
  `length = 0` always (`:739`), uid/gid/muid = user.
- **clunk** `fsys.c:661-668`: fsysdelid + xfidclose. create/remove/wstat -> Eperm.
- **Mntdir** `fsys.c:99-110, 192-259`: per-command namespace for EXTERNAL programs —
  single-threaded snarf with no external processes: **collapses entirely** (R-P10-D).

### 1.3 xfid — open/close/read/write per Q

- `xfidopen` `xfid.c:93-208`: per-Q open counters `w->nopen[q]` (dat.h:248) — QWaddr
  resets `w->addr/limit` on first open (`:107-111`); QWevent flips filemenu
  (`:118-124`); rdsel/wrsel/editout arms v1-deferred.
- `xfidclose` `xfid.c:210-288`: releases per-Q state, then winclose(w) — the walk ref.
- `xfidread` `xfid.c:289-403`: windowless qids: `Qcons/Qlabel` read empty, `Qindex`
  -> xfidindexread, `Qlog` -> xfidlogread (`:300-317`). With a window: winlock then
  **`w->col == nil` => respond `Edel` "deleted window"** (`:320-323`, string `:20`).
  `QWctl` -> `winctlprint(w, buf, 1)` sliced by offset/count (`:336-354`);
  `QWbody`/`QWtag` -> xfidutfread over `t->file->b.nc` (`:332-334`, `:379-381`);
  `QWaddr` prints `"%11d %11d "` of `w->addr` (`:327-330`); `QWdata/QWxdata` ->
  xfidruneread at `w->addr.q0` advancing addr (`:359-376`).
- `xfidwrite` `xfid.c:447-620`: same `w->col==nil` => Edel guard (`:465-467`);
  `QWctl` -> xfidctlwrite; `QWbody/QWtag` append at end via fullrunewrite (partial-
  rune carry) + textinsert/textbsinsert, winsettag after (`:577-608`).
- **ctl command table** `xfidctlwrite` `xfid.c:622-844` — commands packed back-to-
  back in one write, each advancing m, trailing `'\n'`s skipped (`:826-827`); first
  error stops with `Ebadctl` "ill-formed control message" (`:21`): `lock`, `unlock`,
  `clean` (eq0=~0, filereset, mod=FALSE, dirty=FALSE, settag — `:633-641`), `dirty`
  (mod=TRUE, dirty=TRUE, settag — `:643-650`), `show`, `name <s>\n` (validate no
  NUL/ctrl, seq++, filemark, winsetname — `:657-681`), `font <s>\n`, `dump <s>\n`,
  `dumpdir <s>\n`, `delete` (unconditional colclose — `:750-753`), `del`
  (`winclean(w,TRUE)` else "file dirty"; colclose — `:754-761`), `get`, `put`,
  `dot=addr`, `addr=dot`, `limit=addr`, `nomark`, `mark`, `nomenu`, `menu`,
  `cleartag`.
- **index** `xfidindexread` `xfid.c:1090-1147`: per column, per window **in tree
  order** (NOT sorted; only the active curtext of a File set, `:1119-1120`), each
  line = `winctlprint(w, b+n, 0)` — exactly `Ctlsize = 5*12 = 60` bytes (`:17`) —
  then the tag's first line (up to first `'\n'`) + `'\n'` (`:1121-1128`). Whole blob
  rebuilt per read, then offset/count sliced (`:1131-1140`).
- **ctl line** `winctlprint` `wind.c:688-696`: `sprint(buf, "%11d %11d %11d %11d
  %11d ", w->id, tag-nc-runes, body-nc-runes, w->isdir, w->dirty)` — five 12-byte
  columns = 60 bytes. `fonts=1` appends `"%11d %q %11d %11d %11d "`: body width
  `Dx(w->body.fr.r)`, font name (%q-quoted), `fr.maxtab`, `seqof(w,1)!=0` (undo
  pending), `seqof(w,0)!=0` (redo pending) (seqof exec.c:427).
- **utf read discipline** `xfidutfread` `xfid.c:934-996`: Tread offsets are **byte**
  offsets of the UTF-8 stream; the buffer is **rune**-indexed. Scan from rune 0 in
  chunks, converting and accumulating byte length; copy the byte window
  `[off, off+count)` — a read boundary may fall MID-RUNE and that's fine, bytes are
  sliced raw (`:978-986`). The per-window `{utflastqid, utflastboff, utflastq}`
  cache (dat.h:269-271) resumes forward scans; the C's own fallback is "BUG: stupid
  code: scan from beginning" (`:955`). `xfidruneread` (`:999-1051`, QWdata) is the
  rune-count variant that never splits a rune (`:1024-1037`).
- **event** `xfid.c:1053-1088` + winevent wind.c:698-726 — blocking read parked on
  `w->eventx`; DEFER (the natural `WouldBlockRead` customer later).

### 1.4 Lifetime: fid <-> window

The C reference-counts (walk increfs fsys.c:409/459/476; clunk/error winclose,
wind.c:317-334). A deleted window is kept ALIVE by fid refs but DETACHED — `w->col ==
nil` — and every read/write answers Edel (xfid.c:320-323, 465-467); a fresh walk to
its id fails (fsys.c:454-458, 498-500). **Single-threaded snarf ruling (R-P10-C)**:
no refcount — fids store the window **id** (inside `qid.path`) and re-resolve
`id -> *Window` through `ed.row` on every op; a miss is the exact analog of the C's
two failure modes.

## 2. Snarf reality (verified)

- `ninep.server.Ops` vtable + `WouldBlockRead` park FIFO + `completeReads`:
  src/ninep/server.zig:39-100 (Ops :61-87; `Fid` has qid/omode/ctx :45-55). The
  framework does NOT compose directory reads — `Ops.read` gets dir reads too; fsys
  composes stat blobs itself via `stat.encode` (src/ninep/stat.zig:40).
- **Rerror strings are a closed set**: src/ninep/errors.zig:15-69. R-P10-B adds two.
- Ops template: src/dev/input.zig (:135-151 qid enum, :327-334 ops, :378-460
  dispatch, :452-460 statOp). DevDraw same shape.
- Pumping: main_wasm.zig:75-77/139/167/241; native acceptance src/accept.zig:13-35.
  **v1 client of the served tree = tests only.**
- Mount table: src/ninep/mount.zig `Namespace` has no runtime consumer (only
  ninep.zig:170's test). Acceptance becomes the second consumer; live boot wiring
  deferred (R-P10-E).
- Core surfaces: Editor.row/warnings/seq; Row.col + Row.winid (Row.zig:41-45);
  Column.w, Column.close(ed,w,dofree) (Column.zig:47,193); Window.id/dirty/tag/
  body/col (Window.zig:38-51), Window.clean(ed, conservative) (Window.zig:399-408);
  File.mod (File.zig:58), File.reset() (File.zig:253), File.setName (File.zig:80),
  undoSeq/redoSeq (File.zig:239-246); Buffer.len() runes, Buffer.read rune-addressed
  -> UTF-8 with U+FFFD, dest.len >= 4*nrunes (Buffer.zig:84,169-211); Frame.maxtab
  (frame/Frame.zig:94). Phase-9: exectab comptime pattern (exec/builtins.zig:31-60);
  `cmd_window.makeWindow(c, name)` private today, documented as the seam
  (cmd_window.zig:7-10, :51); cmd_window.del uses w.clean + c.close (:75-89).
- **Placement**: src/core/served/{fsys,xfid}.zig per the plan (S-07 §4,
  07-source-layout.md:138-141, :196). `core` imports the whole `ninep` module
  (build.zig:34-39) — compiles. Spec nit: S-07 §6 (:216) omits `server` from core's
  ninep list, contradicting §4's own plan — one-line amendment (master R-P10-9b).

## 3. Contract

### 3.1 Rulings — R-P10-A..J (normative)

- **R-P10-A (qid scheme)**: `path = (win_id << 8) | @intFromEnum(Q)` (dat.h:481-483).
  `pub const Q = enum(u8) { dir, index, new, w_addr, w_body, w_ctl, w_data, w_event,
  w_tag, w_xdata }` — v1 walks/serves ONLY `dir, index, new, w_body, w_ctl, w_tag`;
  the enum reserves the rest so paths never renumber. `vers = 0`.
- **R-P10-B**: errors.zig grows `DeletedWindow => "deleted window"` (xfid.c:20),
  `BadCtl => "ill-formed control message"` (xfid.c:21) — OpError, errorString,
  fromString.
- **R-P10-C (no refcount)**: fid->window BY ID via qid.path; every Ops callback
  re-resolves (lookid analog over ed.row). Dead window => error.DeletedWindow on
  open-fid read/write (xfid.c:320-323), error.FileDoesNotExist on fresh walk
  (fsys.c:498-500). Fid.ctx stays null.
- **R-P10-D**: Mntdir collapses; attach accepts any aname (fsys.c:192-259 is
  external-command plumbing; DEFER).
- **R-P10-E (mount wiring, honest)**: v1 does NOT mount anything at runtime. The
  acceptance test builds `Namespace`, mounts at "/mnt/snarf-self", resolves through
  it. main_wasm wiring waits for the first in-editor 9P client consumer.
- **R-P10-F (ctl line fonts arm)**: font name literal `"fixed9x18"` (snarf Font has
  no name field — FLAG divergence), width = Dx(w.body.fr.r), maxtab =
  w.body.fr.maxtab, undo/redo flags = undoSeq()!=0 / redoSeq()!=0. isdir = 0.
- **R-P10-G (utf read, no cache)**: v1 utfRead rescans from rune 0 each call (the
  C's own fallback, xfid.c:955); the utflast* cache is a FLAGGED seam on Window.
  Byte-window slicing may split runes — exactly like the C.
- **R-P10-H (ctl write subset)**: `clean`, `dirty`, `del`, `delete`, `name <s>\n` —
  all nearly free against phase-9 surfaces. Everything else => error.BadCtl;
  multiple commands per write with '\n' skipping per xfid.c:801-827. dot=addr/
  addr=dot/limit=addr wait for addr (O21 seam). **"delete" MUST precede "del"**
  (prefix match order, xfid.c:750-761). ctl `del` passes conservative=TRUE
  (xfid.c:755) vs B2 Del's FALSE.
- **R-P10-I (makeWindow pub)**: cmd_window.makeWindow becomes pub; walk-to-new calls
  it; column = ed.seltext's column, else first column of ed.row, else error (no
  column creation from a 9P walk in v1). No cnewwindow channel — direct call.
- **R-P10-J (DEFERRED, cites)**: event (xfid.c:846-932, 1053-1088); addr/data/xdata
  (xfid.c:483-502, 534-576 — `// SEAM(O21)` markers in walk; QWdata read is
  Buffer.read almost verbatim once address() exists); cons/consctl/label/log/
  editout; rdsel/wrsel (tempfile machinery xfid.c:128-171); lock/unlock + w->ctlfid
  exclusivity (xfid.c:645-655).

### 3.2 Files and frozen signatures

**`src/core/served/fsys.zig`** (~250) — qid scheme, dirtabs, attach/walk/open/
dir-read/stat/clunk; delegates file reads/writes to xfid.zig.

```zig
pub const Q = enum(u8) { dir, index, new, w_addr, w_body, w_ctl, w_data, w_event, w_tag, w_xdata };
pub fn qpath(win: u32, q: Q) u64;          // (win<<8)|q  [dat.h:481]
pub fn qwin(path: u64) u32;                 // [dat.h:482]
pub fn qfile(path: u64) Q;                  // [dat.h:483]

pub const Fsys = struct {
    ed: *Editor,
    allocator: std.mem.Allocator,
    pub const ops: ninep.server.Ops = .{ ... };
    pub fn init(ed: *Editor) Fsys;
    fn lookid(self: *Fsys, id: u32) ?*Window;              // row->col->w scan [look.c:789]
};
const DirEnt = struct { name: []const u8, q: Q, dir: bool, perm: u32 };
const dirtab  = [_]DirEnt{ .{...index 0o400...}, .{...new dir 0o500...} };
const dirtabw = [_]DirEnt{ .{...body 0o600 append...}, .{...ctl 0o600...}, .{...tag...} };
```

Walk rules (fsys.c:379-522 reduced): ".." -> parent; all-digits -> window dir via
lookid else FileDoesNotExist; "new" at root -> cmd_window.makeWindow + qid of the new
window dir; else dirtab/dirtabw scan. Dir READ composes stat entries (root: dirtab
rows then window dirs **sorted by id**, fsys.c:611-637; window dir: dirtabw rows) at
entry-boundary offsets; stat.length = 0 (fsys.c:739).

**`src/core/served/xfid.zig`** (~250) — per-file read/write:

```zig
pub fn read(f: *Fsys, w: ?*Window, q: Q, offset: u64, buf: []u8) OpError!usize;
pub fn write(f: *Fsys, w: ?*Window, q: Q, offset: u64, data: []const u8) OpError!usize;
pub fn utfRead(t: *Text, offset: u64, buf: []u8, scratch_alloc: Allocator) OpError!usize; // xfid.c:934
pub fn indexRead(ed: *Editor, offset: u64, buf: []u8, alloc: Allocator) OpError!usize;    // xfid.c:1090
fn ctlWrite(f: *Fsys, w: *Window, data: []const u8) OpError!usize;                        // xfid.c:622
const CtlCmd = struct { name: []const u8, takes_arg: bool,
    run: *const fn (f: *Fsys, w: *Window, arg: []const u8) OpError!void };
const ctltab = [_]CtlCmd{ .{"clean"...}, .{"dirty"...}, .{"delete"...}, .{"del"...}, .{"name"...} };
```

**`src/core/Window.zig`** gains (wind.c:688-696):

```zig
pub const ctl_size: usize = 60; // Ctlsize = 5*12 [xfid.c:17]
pub fn ctlPrint(w: *Window, buf: []u8, fonts: bool) []u8; // %11d columns; fonts arm per R-P10-F
```

Body/tag ctl-write appends and `name` reuse Text.insertAt + File.setName + w.setTag();
del/delete reuse Window.clean + Column.close — NO duplication of cmd_window logic.

**`src/ninep/errors.zig`**: +DeletedWindow, +BadCtl (R-P10-B).

**Acceptance**: Pipe + Server.init(alloc, pipe.serverEnd(), &Fsys.ops, &fsys, 8192) +
ninep.Client, mounted in a Namespace at "/mnt/snarf-self" — client walks, reads
index/<id>/ctl/<id>/body, writes ctl, sees the tree mutate. No browser wiring.

### 3.3 Ownership/lifetime

- Fsys borrows *Editor; owns nothing in the tree. Fids carry only qid; Fid.ctx null.
- Window deleted while a fid is open: read/write => DeletedWindow; walk to its
  number => FileDoesNotExist; clunk always clean (no per-window open-count state in
  v1 — nopen[] comes with QWevent/QWaddr).
- `new` during walk mutates the tree immediately (window exists even if the client
  abandons the walk — same as C, fsys.c:466-476).

## 4. Named tests (hand-derived)

1. **`served: index two windows`** — boot windows ids 1,2 named "one","two" (tags 21
   runes each). Exact bytes: line = fmt("{d:>11} {d:>11} {d:>11} {d:>11} {d:>11} ",
   .{id, 21, 0, 0, 0}) (60 bytes) ++ tag-first-line ++ "\n". Tree order, not sorted.
2. **`served: ctl line exact`** — read 1/ctl: 60-byte prefix ++ fmt("{d:>11}
   fixed9x18 {d:>11} {d:>11} {d:>11} ", .{dx, 72, 0, 0}), dx = Dx(w.body.fr.r),
   maxtab 72. After one undoable body insert, the undo flag column flips to 1.
3. **`served: body utf read across rune boundary`** — body "aé<-x" style (1+2+3+1
   bytes, 4 runes). read(0,7) = the 7 bytes; read(2,2) = the raw 2-byte window
   splitting runes; read(7) = 0 (EOF).
4. **`served: ctl write clean and del mutate`** — dirty window: "clean\n" => Rwrite
   6, w.dirty==false, file.mod==false. "del\n" clean => window gone; "del\n" dirty
   => Rerror "file dirty" first strike (two-strike, xfid.c:754-758 + wind.c:666-685).
5. **`served: dead window fid`** — open 1/body, delete window 1 via ctl on another
   fid: read on the open body fid => "deleted window"; fresh walk "1" => "file does
   not exist".
6. **`served: walk new creates window`** — walk new/ctl from root: column.w grew;
   Rwalk qids = [dir(new id), w_ctl]; ctl read shows the fresh id.
7. **`served: root dir read lists sorted window dirs`** — windows created 2 then 1
   (del/new churn): dir entries index, new, then 1, 2 sorted; entry-boundary offset
   continuation works.

## 5. Seams

- O20/O21: Q.w_addr/w_data/w_xdata enum slots + walk arms stubbed FileDoesNotExist
  with `// SEAM(O21): needs address() — xfid.c:483-502`.
- phase-9 cmd_window: makeWindow pub (R-P10-I); ctl del/delete call the same
  Window.clean + Column.close — never re-implement the two-strike.
- dev servers: same Ops shape; fsys is the first real dir-read implementation —
  consider a shared ninep dirRead helper LATER (flag only).
- warnings: +Errors rewiring needs Qcons/QWerrors — both deferred; ed.warnings
  stays.

## 6. Wave split (master mapping)

- 10a-A3 (opus): errors.zig, served/fsys.zig, Window.ctlPrint, makeWindow pub +
  tests 1, 2, 5, 6, 7.
- 10b-B3 (sonnet): served/xfid.zig (utfRead/indexRead/ctlWrite), S-07 revision
  lines, acceptance through Client+Namespace + tests 3, 4.
