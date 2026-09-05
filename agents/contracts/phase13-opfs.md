# Phase 13 contract — /mnt/opfs: browser-local filesystem mount ("OPFS wave")

Scope: a browser-local filesystem in the namespace (R-9P-09 OPFS half, S-02 "/mnt/opfs",
S-06 §4 `host: fsOp` import): an in-module 9P device server backed by the Origin Private
File System, mounted read/write at `/mnt/opfs` at boot, always available, no permission
prompts. This is the first *creatable* tree, so it also grows the ninep server framework
with create/remove (lifting phase-1 ruling R5). Sequenced AFTER phase 12 (both edit
`web/shim.js` + `abi.zig`; ABI 4→5 here). `/mnt/host` (user-picked real directory,
prompt-gated) and `/dev/storage` (localStorage) are explicitly OUT — separate waves.

Status: DRAFT for user review — rulings below are pre-agreed design; amend as built.

## Rulings (proposed)

- **R-P13-1 — backing store.** OPFS via `navigator.storage.getDirectory()`, main-thread
  *async* handles (`getFile()`, `createWritable()`); `createSyncAccessHandle` is
  worker-only and arrives free with the Worker+SAB move — do not design around it now.
  If OPFS is unavailable (old browser, `file://`), the mount is simply absent,
  R-9P-10-style: one warning, boot otherwise identical.
- **R-P13-2 — placement.** Device server `src/dev/opfs.zig` (+ split files as needed):
  an `Ops` tree on the existing `ninep.server.Server`, exactly like origin's
  `tools/origin/tree.zig` but in-module. Browser calls live behind the shim import
  only; `src/core` never knows OPFS exists (R-OV-03). Mounted at `/mnt/opfs` via
  `ninep.mount.Namespace` at boot.
- **R-P13-3 — ABI v5.** One import: `fsOp(opPtr, len, ticket)` (S-06 §4, reserved
  since phase 5). The op buffer is a small tagged binary record (op code + path +
  offset/count + payload), versioned next to `abi.zig`. Completions reuse the
  phase-12 staging mechanism (`wsStage`/`wsPush` generalized to `stage`/`complete`
  if phase 12 hasn't already — coordinate; the push carries ticket id, status,
  payload). No JS→WASM re-entrancy; drain on `tick()`/`wake()`.
- **R-P13-4 — async serving = parked ops.** Every 9P op that needs the browser parks
  its response on the phase-6 parking mechanism until the `fsOp` ticket completes.
  Nothing blocks, nothing spins. Multiple in-flight ops on different fids proceed
  independently; per-fid ops stay ordered.
- **R-P13-5 — framework growth: create/remove (lifts R5).** `ninep.server.Ops` gains
  `create` and `remove` (Tcreate/Tremove per create(5), remove(5) — pinned manuals).
  Default = `Rerror "create prohibited"` / `"remove prohibited"` so every existing
  tree (snarf-self, origin) is behavior-identical. This touches `src/ninep/server.zig`
  — its own build seam with its own tests, kept mergeable independently.
- **R-P13-6 — filesystem semantics.** Plain files and directories only. Read/write +
  OTRUNC; create (files and dirs, DMDIR honored); remove (empty dirs only — 9P has no
  recursive remove). **No rename in v1**: `FileSystemHandle.move()` is Chromium-only,
  so wstat name → `"wstat prohibited"`; rename = create+copy+remove by the client,
  later. Names: UTF-8, no `/`, `.`/`..` refused (mirror R-P11-7 walk rules; partial
  multi-element walk = short Rwalk).
- **R-P13-7 — qids and stat.** OPFS exposes no inode: `qid.path` = FNV-1a64 of the
  absolute path (stable per *name*, not per identity — a remove+recreate keeps the
  qid; recorded caveat), `qid.vers` = `lastModified` ms truncated to seconds. stat:
  length from `getFile().size`, mtime from `lastModified`, dirs mtime 0, modes
  0644/dirs 0755|DMDIR, uid/gid `"opfs"`.
- **R-P13-8 — acceptance.** (a) Native: framework create/remove tests (served tree +
  client, over Pipe — extends the phase-1 acceptance pattern); opfs `Ops` tests over a
  scripted fsOp completion queue (park/complete ordering, error mapping, walk rules).
  (b) Smoke: `tools/smoke_wasm.mjs` gets an in-memory JS `fsOp` stub implementing the
  op contract — proves ABI plumbing + mount + create/write/read/remove round-trip
  through the real wasm. (c) Manual (Larry, real OPFS): browser boot, then the
  namespace smoke command we wire in phase 14 (until then: devtools
  `navigator.storage.getDirectory()` inspection after a scripted write via smoke
  instructions in the report).
- **R-P13-9 — quota and errors.** Write failures (`QuotaExceededError`, others) map to
  Plan 9-style Rerrors (`"no space on device"`, `"i/o error"` + console detail via
  `consoleLog`). No quota pre-checks; fail on the browser's word.

## Ground truth

- create(5), remove(5), wstat(5): `larryr/plan9@ed1a9c2` `sys/man/5/*` — read before
  implementing R-P13-5/6.
- OPFS API: `navigator.storage.getDirectory()`, `getFileHandle/getDirectoryHandle
  ({create})`, `removeEntry()`, async `entries()`, `getFile()`, `createWritable()`
  (write/truncate/close). `move()` non-portable. All evergreen browsers ship OPFS;
  sync access handles are worker-only.
- Phase-6 parking (served tree parked reads) and phase-12 staging exports.

## Work breakdown (3 build seams + orchestrator)

1. **B1 framework**: Ops.create/remove in `src/ninep/server.zig` + msg codec if
   Tcreate/Rcreate aren't wired + tests. Fences: `src/ninep/`.
2. **B2 device**: `src/dev/opfs.zig` Ops tree, qid/stat mapping, parked-op machinery,
   scripted-queue tests. Fences: `src/dev/opfs*`.
3. **B3 shim**: `fsOp` import + op-record codec + completion push, ABI v5, boot mount.
   Fences: `web/shim.js`, `src/shim/`, `src/main_wasm.zig`.
4. Orchestrator: smoke fsOp stub + end-to-end round-trip, boundary check, merge.

## Deferred

`/mnt/host` (showDirectoryPicker, permission-prompt→Rerror mapping — R-9P-09's other
half); `/dev/storage` (localStorage, R-9P-08); rename via `move()` where available;
sync access handles (Worker move); **exporting /mnt/opfs over 9P to other machines**
(the reverse of phase 12 — architecture already permits serving any in-module tree
over a transport; needs `Tauth` (OQ-9P-3) first); Dump/Load persistence targeting
`/mnt/opfs` (natural first consumer).
