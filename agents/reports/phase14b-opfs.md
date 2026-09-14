# Phase 14b report — `/mnt/opfs`: the Origin Private File System as an in-module 9P device (ABI v6)

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 665/665 (639 + 26), run twice ·
node smoke **40/40** (+10: ABI 6, JS-mirror codec check, the B3 drive `mnt/` → `opfs/` →
file open → `Get` re-list through the real module with an in-memory `fsOp` stub) · `zig fmt`
clean · **`src/core` untouched** · no golden moved (FROZEN-ACCEPT-13B still `0x35f686fc5162d2cf`,
`/` still `dev/ mnt/`) · **Contract:** `agents/contracts/phase14b-opfs.md` (supersedes the
2026-09-02 draft `phase14-opfs.md`; rulings R-P14b-1..6) · **ABI v6** · **wasm:** ≈ 2186 KiB
(+97 KiB ReleaseSafe).

R-9P-09's OPFS half is delivered: an always-available, writable, browser-local tree at
`/mnt/opfs`, no permission prompts, browsable with B3 today, the natural home for `Dump`
and for `Put` when those waves land.

## What works now
- **ABI v6**: `env.fsOp(ptr, len, ticket)` import behind the `is_wasm` gate (+ `test_fs_op`
  seam); op records `op[1] pathlen[2] path arg0[8] arg1[4] payloadlen[4] payload` (LE,
  `FsRecord.zig`, version 1, JS mirror in `web/opfs.js` checked by the smoke); completions
  come back through `fsStage`/`fsPush` (a second staging pair beside `wsStage`/`wsPush`).
- **The device** (`dev/opfs.zig` + `opfs_tree.zig` + `opfs_slots.zig`): every 9P op that needs
  the browser issues an `fsOp` and parks (14a); completions land in a slot table keyed by
  `(fid, op, offset-or-path-hash)` with states pending → ready → taken, so a re-dispatched
  T-frame re-consumes cached answers and never issues duplicates; one op may need several
  round trips (a 2-element walk = 2 stats; open+OTRUNC = stat then truncate). Walk rules as
  hostfs; perm masking per `5/open`; remove clunks either way (`5/remove`); wstat = length
  only; directory reads serve a cached `list` as a whole-record stat stream. qid.path =
  FNV-1a64(path) — name-stable, so no per-fid heap node is needed (the framework discards
  tentative walk fids without `clunk`). Status → Rerror: `file does not exist`, `file
  already exists`, `not a directory`, `file is a directory` (kernel `Eisdir`), `permission
  denied`, `no space on device`, `directory not empty`, `i/o error`, `wstat prohibited`.
- **JS side** (`web/opfs.js`, imported by `shim.js`, same-origin): per-path serialization,
  cross-path parallelism, completions from microtasks (never re-entrant), DOMException →
  status mapping, `getDirectory` missing ⇒ every ticket `io` + one console line.
- **Boot**: a fourth pipe/server/client, `/mnt/opfs` mounted unconditionally (absence surfaces
  as `i/o error` on first use, R-P14b-2); polled each tick; `retryParked` after each push.
- Docs: S-02 §4 as-built (formats, error table, qid caveat, no rename, jobs-only, deferred
  list), §1.3 row; S-06 §4 ABI v6; R-03 v6.

## Deviations (accepted in review)
1. `is_dir` ⇒ `file is a directory` (kernel `Eisdir`, already in `errors.zig`). 2. Five additive
`OpError` members (`FileExists`, `NotADirectory`, `DirNotEmpty`, `NoSpace`, `WstatProhibited`).
3. Codec in `shim/FsRecord.zig` (file-as-struct), re-exported from `abi.zig`. 4. No `Ops.clone`
(see above). 5. `open` on a directory issues no fsOp. 6. Misaligned directory offset ⇒
`bad message` (lib9p says `bad offset` — debt pass). 7. Listing entries carry length 0 /
mtime 0 (one round trip, not N). 8. `main_wasm.zig` 458 pre-test lines — over the cap (debt:
`App` + `boot()` → `wasm_boot.zig`). 9. One test renamed per the ABI-bump convention.

## Debt (all recorded for the debt pass)
- **Tentative-newfid slot leak**: a parked Twalk on `newfid ≠ fid` that is Tflushed leaves a
  `pending` slot — the framework discards a never-established newfid without `Ops.clunk`.
  Fix is framework-side (`handleWalk` should `ops.clunk` the discarded newfid).
- Six `stat` fsOps per file open (expand's existence check, Load's StatJob, per-element walk
  stats, ReadFileJob's walk, the open confirm) — a per-path `StatReply` memo in
  `DevOpfs.request`, invalidated by mutations on the path or its parent.
- `writeOf`/`truncateOf` open+close an OPFS writable per 8 KiB chunk (O(n²) large writes) —
  keep one writable per open fid, close on clunk (Put wave).
- `bad offset` string; non-atomic exists-then-create (only an out-of-band writer can race).
- `main_wasm.zig` 458; `opfs.zig` ≈ 440 pre-test with tests appended.

## Pipeline
fable spec → opus (6 commits) → sonnet T1–T14 (wire-level `Wire`/`drive` harness — no
`Client` because a blocking rpc on a parkable tree never returns) ∥ fable review PASS →
sonnet gate → merge.
