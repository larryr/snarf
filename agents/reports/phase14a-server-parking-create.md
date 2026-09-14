# Phase 14a report — 9P server framework: parked operations for every op; create / remove / wstat

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 639/639 (620 + 19), run twice ·
node smoke 30/30 (unchanged — no ABI change) · `zig fmt` clean · `ninep` imports std + itself ·
**no golden moved** · **Contract:** `agents/contracts/phase14a-server-parking-create.md`
(rulings R-P14a-1..5) · **wasm:** ≈ 2089 KiB (+52 KiB ReleaseSafe: codec + handlers).

First half of phase 14 (OPFS). Lifts phase-1 ruling R5 (no create/remove) and generalizes
the phase-6 parked-read mechanism to every operation, so a device that must ask the
browser (OPFS, 14b) can answer any 9P request asynchronously.

## What works now (framework)
- **Codec** (`msg_mut.zig` + `msg.zig`): Tcreate/Rcreate, Tremove/Rremove, Twstat/Rwstat per
  `5/open`, `5/remove`, `5/stat`; only Tauth/Rauth remain Unsupported.
- **Parking for any op** (NEW `park.zig`): `Ops` fns may return `park.WouldBlock`; the server
  stores the raw T-frame (owned copy, FIFO, bound 64 ⇒ `"too many parked requests"`) and
  `retryParked()` re-dispatches in order, re-parking in place on a repeat block (no duplicate
  reply). Tflush = `Rerror interrupted` then `Rflush` (phase-6 R-P6-5 kept); clunk sweeps the
  fid's parked requests; version reset clears. `WouldBlockRead`/`ReadError`/
  `completeReads(path)` survive as aliases — `dev/input`, `fsys`, `tools/origin`, `dev/draw`
  changed by **zero lines**.
- **create / remove / wstat** (NEW `server_mut.zig`): optional `Ops` slots with lib9p's
  strings as defaults (`create prohibited`, `remove prohibited`, `wstat prohibited`,
  `lib9p/srv.c:18,20,24`); `handleCreate` checks unknown-fid → open → non-dir → name syntax,
  re-points the fid to the new qid and opens it, `iounit` default msize−24; `handleRemove`
  clunks the fid unconditionally (`5/remove`); `handleWstat` decodes the double-length stat,
  honours "don't touch", refuses type/dev/qid/muid/DMDIR changes.
- **Client** sync helpers `create/remove/wstat` (+ `stat.dontTouch()`); tickets can carry the
  new T-messages for free (T4).
- **`server.zig` 780 → 433 pre-test lines**: parking → `park.zig`, fid-lifecycle handlers
  (`open/create/remove/wstat/clunk`) → `server_mut.zig`, the shared test harness → `testsrv.zig`
  (test-only; not linked into the wasm).
- Docs: S-01 §2 (subset complete minus auth), §4/§5 (any op may park, the bound); phase-1
  contract "R5 LIFTED"; R-03 v5.

## Deviations (accepted in review)
1. Three existing test BODIES changed, names kept — each forced by the contract: 114/122/126
   are now implemented (a 7-byte frame is a truncation), the defaults test needs well-formed
   bodies, and the version-reset test preloaded the abolished `Parked` struct.
2. `5/open` perm masking is the device's job (`~0666`/`0666` files, `~0777`/`0777` dirs) — the
   framework cannot know `dir.perm`; lib9p does the same.
3. Tflush keeps `interrupted` + `Rflush`; `sweepFid` makes "unknown fid after clunk"
   unreachable via Tclunk (T9 removes the fid directly).
4. `Ops.clunk` returns `void` — "clunk cannot park" is a compile-time property (T6 proves it
   with `@typeInfo`).
5. `testsrv.zig` (not in the contract): 234 harness lines had to leave `server.zig` to reach
   the cap. `client.zig` +50 (three documented helpers; still over the cap — known debt).
6. Orchestrator after review: lib9p cite lines corrected (Enocreate 18, Enowstat 24, Ebotch
   13, Ecreatenondir 14); `Client.wstat` blob 1024 → 1100 (a legal max stat is 1069 B);
   `retryFiltered` nested-retry skip documented (an entry can be retried one pass late,
   never twice, never lost).

## Debt
`client.zig` 635 pre-test lines; the nested-retry index skip (harmless) could track by tag.

## Pipeline
fable spec → opus (7 commits) → sonnet T1–T10 (+T11 evidence) ∥ fable review PASS (3 nits,
applied by the orchestrator) → sonnet gate → merge.
