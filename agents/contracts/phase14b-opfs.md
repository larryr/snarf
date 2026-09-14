# Phase 14b contract — `/mnt/opfs`: the Origin Private File System as an in-module 9P device (ABI v6)

Status: **binding once fable signs §3.** Branch `phase14b` (worktree `../snarf-wt/phase14b`),
based on `main@511f87d` (14a merged: `park.WouldBlock`, `OpBlockError`, `Ops.create/remove/wstat`,
`CreateResult{qid, iounit}`, `retryParked`, `Fid{qid, omode: ?u8, aux}`). Requirements: R-9P-09 (OPFS half: "always-available private area"), R-9P-13
(non-blocking), R-9P-14 (documented formats), R-EDIT-16 (a place for `Dump` later). The
2026-09-02 draft `agents/contracts/phase14-opfs.md` (rulings R-P13-1..9 there) is the design
source; this contract supersedes its numbering and fixes: ABI is **v6** (v5 = 12c), parking is
14a's generalized `park.WouldBlock`, create/remove exist (14a), staging follows 12e's
`origin_glue` shape.

## 1. Ground truth
| Item | Where | What |
|---|---|---|
| OPFS API | MDN/WHATWG File System: `navigator.storage.getDirectory()`, `dir.getFileHandle(name,{create})`, `dir.getDirectoryHandle(name,{create})`, `dir.removeEntry(name,{recursive:false})`, `for await (const [name, h] of dir.entries())`, `fh.getFile()` → `File{size,lastModified}`, `fh.createWritable({keepExistingData})` → `write(data)`/`truncate(n)`/`close()`; `move()` Chromium-only (no rename, R-P14b-6); sync access handles worker-only (not now). All main-thread calls are async ⇒ every 9P op that touches OPFS must park (14a). |
| Server framework (14a) | `src/ninep/park.zig` (`WouldBlock`, `OpBlockError`, `retryParked`), `src/ninep/server_mut.zig` (`Ops.create/remove/wstat`, `CreateResult{qid, iounit}`), `5/open` perm masking is the device's job (`~0666`/`0666` files, `~0777`/`0777` dirs). |
| Shim ↔ module pattern | `web/shim.js` `wsStage`/`wsPushRecord` + `src/origin_glue.zig` (`stage`/`push` over `Devices`), `src/shim/abi.zig` `is_wasm` gate + `test_ws_*` seams, `WsKind` mirror in JS | a JS→module completion is: module `stage(len)` → JS copies bytes → module `push(id, kind, ptr, len)`; no re-entrancy; drained on `tick`. |
| Device pattern | `src/dev/input.zig` (`Ops` over a `chan.Pipe`, parked reads, adapter re-runs via `completeReads`), `tools/origin/hostfs.zig` (a real-FS 9P tree: walk rules, dir stat streams, OTRUNC) | copy `hostfs`'s tree logic, replace the synchronous `std.Io.Dir` calls with parked `fsOp` round trips. |
| qid/stat rules | draft R-P13-7 | `qid.path` = FNV-1a64(abs path) (name-stable, not identity-stable — caveat), `vers` = lastModified/1000, modes 0644 / 0755\|DMDIR, uid/gid `"opfs"`, dir mtime 0. |

## 2. Merged reality (after 14a)
Any `Ops` fn may return `park.WouldBlock`; `retryParked` re-dispatches. `Ops.create/remove/wstat`
exist. Boot namespace has `/dev`, `/dev/draw`, `/mnt/snarf-self`, `/n/origin`, `/bin`. The `/`
directory window lists mount-point children, so `/mnt/opfs/` will show up as `opfs/` under
`/mnt/` and be browsable with B3 the moment it is mounted; `Get`/`Put` for files are a later
wave, so v1 exercises OPFS through the served 9P interface, tests, and directory windows.

## 3. CONTRACT

### 3a. ABI v6 — `src/shim/abi.zig`, `web/shim.js`
- One new import `fsOp(ptr: [*]const u8, len: u32, ticket: u32)` (S-06 §4 reserved name) behind
  the `is_wasm` gate with a `test_fs_op` seam like `test_ws_*`. Op record (little-endian,
  versioned `fs_op_version = 1` in `abi.zig`, mirrored in JS):
  `op[1] pathlen[2] path[pathlen] arg0[8] arg1[4] payloadlen[4] payload[…]` with
  `op ∈ {stat=1, list=2, read=3, write=4, create_file=5, create_dir=6, remove=7, truncate=8}`;
  `read`: arg0=offset, arg1=count; `write`: arg0=offset, payload=data, arg1=flags (bit0 =
  truncate-first); `truncate`: arg0=length.
- Completion travels back through **one new export pair** `fsStage(len) → ptr` /
  `fsPush(ticket, status, ptr, len)` (mirror of `wsStage`/`wsPush`; kept separate so the two
  record streams cannot interleave). `status` = `0 ok`, else a small enum mirrored in JS:
  `1 not found`, `2 exists`, `3 not a directory`, `4 is a directory`, `5 permission`,
  `6 quota` ("no space on device"), `7 not empty`, `8 io`. Payload: `stat` ⇒
  `isdir[1] size[8] mtime_ms[8]`; `list` ⇒ repeated `isdir[1] namelen[2] name[…]`; `read` ⇒
  bytes; `write` ⇒ `count[4]`; others empty.
- JS side (`web/shim.js` or a new `web/opfs.js` loaded by the page — keep everything same-
  origin, no CDN): a queue processing one `fsOp` at a time PER PATH but many in parallel
  overall; every completion is `fsPush`ed from a microtask, never re-entrantly inside `fsOp`.
  If `navigator.storage?.getDirectory` is missing, `fsOp` completes every ticket with status
  `8` and the module logs `/mnt/opfs: unavailable` once (R-9P-10-style absence).
- `ABI_VERSION = 6`; smoke checks `abi_version() === 6`.

### 3b. Device — NEW `src/dev/opfs.zig` (+ `opfs_ops.zig` / `opfs_tree.zig` as the cap needs)
- `pub const DevOpfs = struct { … }` with `pub const ops: ninep.server.Ops` implementing
  attach, walk1, open, read, write, create, remove, stat, clunk (+ `wstat`: length/truncate
  only; name/mode changes ⇒ `"wstat prohibited"`). Every op that needs the browser:
  1. look up a **per-fid pending slot** keyed by (fid, op, offset); if a completion is cached,
     consume it and reply; else issue `fsOp` with a fresh ticket, record the slot, return
     `park.WouldBlock`.
  2. `pub fn complete(self, ticket, status, payload)` (called from `main_wasm`'s `fsPush`
     export via the glue) stores the completion; the glue then calls `srv.retryParked()`.
- Walk: hostfs rules (no `.`/`..`, no `/` in names, partial multi-element walk ⇒ short
  Rwalk); a walk to a name = a `stat` fsOp. Open: files ⇒ `stat` to confirm; OTRUNC ⇒ a
  `truncate 0` fsOp. Read on a dir: a `list` fsOp once per open, then serve the stat stream
  from the cached listing (offset-addressed, whole records, `read(5)`). Read on a file:
  `read` fsOps chunked by count. Write: `write` fsOp. Create: `create_file`/`create_dir` with
  the perm mask (`5/open`), then re-point the fid (the framework does that from
  `CreateResult`). Remove: `remove` (dirs must be empty ⇒ status 7 → `Rerror "directory not
  empty"`). Stat: `stat`. Clunk: drop slots.
- Error mapping (draft R-P13-9): status → Plan 9 strings `"file does not exist"`, `"file
  already exists"`, `"not a directory"`, `"is a directory"`, `"permission denied"`, `"no space
  on device"`, `"directory not empty"`, `"i/o error"`.
- Native testability: `DevOpfs` never calls the import directly — it calls a `Requester`
  vtable (`issue(ticket, record)`) so tests plug a scripted queue that answers completions in
  any order and exercises parking end-to-end over a `chan.Pipe` + `Client`/tickets.

### 3c. Glue — `src/opfs_glue.zig` (mirror of `origin_glue.zig`), `src/main_wasm.zig`, `src/ns_boot.zig`
- `fsStage`/`fsPush` exports as two-line trampolines in `main_wasm` (root holds `app`); the
  glue owns the staging buffer and calls `dev_opfs.complete` then `srv_opfs.retryParked()`.
- Boot: a fourth pipe/server/client for `DevOpfs`, polled in `tick`; `ns.mount("/mnt/opfs",
  …)` unconditionally (absence surfaces as `i/o error` on first use plus the one console
  line — a mount that exists but errors is simpler than a conditional mount; ruling
  R-P14b-2). `/dev` + `/dev/draw` jobs-only warning extends to `/mnt/opfs` (parked ops).

### 3d. Smoke — `tools/smoke_wasm.mjs`
- An in-memory JS `fsOp` stub implementing the record contract; checks: ABI 6; boot issues
  no fsOp (lazy); B3 on `mnt/` then on `opfs/` in the module (drive via `pushEvent` at the
  listing's coordinates — the 13b probe knows the right column geometry) ⇒ the stub sees a
  `list /` op and the module blits a `/mnt/opfs/` window; a scripted `create_file`+`write`
  through the stub's own API followed by `Get` re-lists and the name appears. If driving B3
  by pixel coordinates is too brittle, fall back to asserting the `list /` op after a
  `Get`-free path: mount + `nsjob.ListDirJob` is not reachable from JS — so the B3 route is
  the honest one; make it robust by computing coordinates from the known layout (right
  column, first body line, x of the `mnt/` entry = scrollbar 16 + 0).

### 3e. Docs
- S-02 §4 `/mnt/opfs` as built (record formats, error mapping, qid caveat, no rename, sync
  handles deferred); S-06 §4 ABI v6 (`fsOp`, `fsStage`/`fsPush`, record version 1); R-03
  revision-log v6 line (R-9P-09 OPFS half delivered); HANDOFF.

### 3f. Rulings
- **R-P14b-1** No golden moves (the `/` boot window lists `dev/ mnt/` unchanged — `/mnt/opfs`
  sits under `mnt/`; FROZEN-ACCEPT-13B must not move). If the `/mnt/` listing scene exists
  with a hash, it gains `opfs/` — check before coding; there is none as of 13b.
- **R-P14b-2** Unconditional mount; absence = errors + one console line.
- **R-P14b-3** One `fsOp` in flight per (fid, op, offset) slot; completions may arrive in any
  order; a clunked fid's late completion is dropped.
- **R-P14b-4** No rename; `wstat` supports length only. Names: UTF-8, no `/`, not `.`/`..`.
- **R-P14b-5** `core` untouched except nothing; `dev/opfs*` imports std + `ninep` + `shim/abi`;
  files ≤ ~400 pre-test lines.
- **R-P14b-6** ABI v6; the op-record codec has its own round-trip tests and a JS mirror
  comment block like `WS_KIND`.

## 4. Named tests (sonnet)
T1 record codec round-trips (all ops, max path, empty payload) + JS mirror constants in the
smoke; T2 `DevOpfs` over a pipe with a scripted `Requester`: walk to `a/b.txt` issues one
`stat`, parks, completes on the answer; T3 out-of-order completions (two fids) each land on
their own slot; T4 read of a 20 000-byte file via chunked `read` ops byte-exact; T5 write +
OTRUNC issues `truncate 0` then `write`; T6 create file/dir with perm masking and the fid
re-pointed (a following Twrite works); T7 remove: ok, not-empty ⇒ `"directory not empty"`,
fid clunked either way; T8 dir read = stat stream of the cached `list`, offset continuation
+ BadOffset; T9 every status code maps to its exact Rerror string; T10 unavailable backend
(`status 8` for everything) ⇒ `i/o error` and one console line; T11 clunk mid-flight drops the
late completion silently; T12 boot: `/mnt/` lists `opfs/` (ListDirJob) and FROZEN-ACCEPT-13B
unchanged; T13 smoke per §3d; T14 `abi_version() === 6` everywhere the shim checks.

## 5. Gate (fable)
Pipeline: fable spec → **opus** codes §3 → **sonnet** writes §4 → **sonnet** runs the gate →
**fable** reviews → loop.
Suite ×2; fmt; wasm; smoke (ABI 6 + opfs stub checks); boundaries (`core` untouched;
`dev/opfs*` imports); no FROZEN change; report + HANDOFF (R-9P-09 OPFS half done; `/mnt/host`
and `/dev/storage` remain); REVIEW-NOTES entry ("for you: B3 `mnt/` → `opfs/` — empty until
Put exists; nothing to try beyond browsing; devtools `navigator.storage.getDirectory()`").
