# Phase 14a contract — server framework: parked operations for every op, plus create / remove / wstat

Status: **binding once fable signs §3.** Branch `phase14a` (worktree `../snarf-wt/phase14a`),
based on `main@f8fdfe8`. First half of phase 14 (OPFS, `agents/contracts/phase14-opfs.md`
DRAFT — its B1 seam). Requirements: R-9P-01 (9P2000 mandatory subset — create/remove/wstat
were "Unsupported"), R-9P-09 (a writable, creatable browser-local tree needs them), R-9P-13
(non-blocking: a device that must ask the browser cannot answer a 9P op synchronously).
Lifts phase-1 ruling R5 ("no create/remove ops") and generalizes the phase-6 parked-read
mechanism (R-P6-2) to every operation.

Pipeline: fable spec → **opus** codes §3 → **sonnet** writes §4 → **sonnet** runs the gate →
**fable** reviews → loop.

## 1. Ground truth

| Item | Where | What |
|---|---|---|
| Wire formats | `larryr/plan9@ed1a9c2` `sys/man/5/open` (Tcreate/Rcreate: `fid[4] name[s] perm[4] mode[1]` → `qid[13] iounit[4]`), `sys/man/5/remove` (Tremove `fid[4]` → Rremove; **the fid is clunked even on error**), `sys/man/5/stat` (Twstat `fid[4] stat[n]` → Rwstat; "don't touch" values: `~0` for numeric fields, empty strings), `sys/man/5/0intro` (size/tag framing) | Read them; cite `5/open`, `5/remove`, `5/stat`. |
| create semantics | `5/open` | the fid must be an open-able DIRECTORY, unopened; on success the fid now refers to the NEW file, opened with `mode`; `perm` is ANDed with the parent's per `5/open` (`perm & (~0777 \| (dir.perm & 0777))` for files, `perm & (~0777 \| (dir.perm & 0777))` with DMDIR for dirs); a create of an existing name fails; `.`/`..`/empty/with-`/` names fail. |
| Current codec | `src/ninep/msg.zig:48-61, :223` | tags exist for `tcreate/rcreate/tremove/rremove/twstat/rwstat`; `decode` returns `error.Unsupported`; no `Body` members. |
| Current server | `src/ninep/server.zig` (1459 lines, **780 pre-test — over cap**) | `Ops{attach, walk1, clone?, open, read (ReadError = OpError ‖ WouldBlockRead), write, clunk?, stat, flush?}`; `handleUnsupported` (:270) answers `Rerror` for the three; parking is READ-only: `Parked{tag, fid, offset, count}` FIFO (:96-100), `park` (:391), `completeReads` re-runs `ops.read`; Tflush drops a parked read. |
| Client | `src/ninep/client.zig`, `src/ninep/tickets.zig` (13a) | `begin(c, Message, buf)` can send ANY T-message once the codec can encode it. No `create/remove/wstat` helpers. |
| Consumers | `src/core/served/fsys.zig`, `tools/origin/tree.zig`+`hostfs.zig`, `src/dev/input.zig`, `src/dev/draw.zig` | all must stay behavior-identical (default "prohibited" errors; existing parked-read tests). |

## 2. Merged reality
620 tests, `server.zig` 780 pre-test lines. Parking stores four ints, so only `read` can park.
OPFS (14b) needs walk/open/read/write/create/remove/stat to park while the browser answers.

## 3. CONTRACT

### 3a. Codec — `src/ninep/msg.zig`
- `Body` gains `tcreate: {fid, name: []const u8, perm: u32, mode: u8}`, `rcreate: {qid, iounit}`,
  `tremove: {fid}`, `rremove`, `twstat: {fid, stat: []const u8 (raw stat bytes, nstat-prefixed
  per 5/stat)}`, `rwstat`; `encode`/`decode` both directions, bounds-checked like the rest;
  `kind()` mapping; the `.tauth/.rauth` pair stays Unsupported. If `msg.zig` would cross ~400
  pre-test lines, split the codec table into `msg_mut.zig` (create/remove/wstat) with
  re-exports.

### 3b. Generalized parking — NEW `src/ninep/park.zig`; `server.zig` shrinks
- `pub const WouldBlock = error.WouldBlock` as THE framework signal: any of `walk1`, `open`,
  `read`, `write`, `create`, `remove`, `stat`, `wstat` may return it ("I asked someone; ask me
  again later"). `clunk`, `flush`, `attach`, `version` may not.
- `Parked{ tag: u16, frame: []u8 (owned copy of the whole T-frame) }` FIFO (bounded:
  `max_parked = 64`, beyond ⇒ `Rerror "too many parked requests"` — cite that Plan 9 has no
  such limit; ours is the server's memory budget, S-01 §3).
- `pub fn retryParked(srv) Error!usize`: re-dispatch every parked frame in FIFO order through
  the normal handler; a handler that returns `WouldBlock` again re-parks it (same position,
  no duplicate reply); returns the number that completed. Tflush of a parked tag: reply
  `Rflush`, drop the frame (5/flush). A parked request whose fid is clunked meanwhile ⇒ the
  retry replies `Rerror "fid not found"`/`unknown fid` exactly as a fresh op would.
- **Compatibility (R-P14a-1)**: `ReadError`, `error.WouldBlockRead`, and `completeReads` remain
  as thin aliases over the general mechanism — `WouldBlockRead` ⇒ park; `completeReads()` ⇒
  `retryParked()`. Every existing input-device / served-tree parked-read test passes
  unchanged, byte-for-byte replies. Reads keep their `count` clamp on retry (decode the
  frame again).
- Move the parking code out of `server.zig` into `park.zig` and the create/remove/wstat
  handlers into NEW `src/ninep/server_mut.zig` (fields are accessible across files); target
  `server.zig` ≤ ~450 pre-test lines (it starts at 780 — the structural debt is paid here
  because this wave owns the file; a pure move for the untouched handlers, cited).

### 3c. `Ops.create / remove / wstat` — `src/ninep/server_mut.zig`
```zig
create: ?*const fn (ctx, srv, fid: *Fid, name: []const u8, perm: u32, mode: u8) OpError!CreateResult = null, // CreateResult{qid, iounit}
remove: ?*const fn (ctx, srv, fid: *Fid) OpError!void = null,
wstat:  ?*const fn (ctx, srv, fid: *Fid, st: stat) OpError!void = null,
```
- Defaults: `null` ⇒ `Rerror "create prohibited"`, `"remove prohibited"`, `"wstat prohibited"`
  (the strings Plan 9 servers use, e.g. `devroot`/`exportfs`; cite one).
- `handleCreate`: fid must exist, be a directory, and be unopened, else `Rerror` per 5/open;
  validate the name (no `/`, not `.`/`..`/empty — mirror `nspath`'s rules); call `ops.create`;
  on success the fid's qid becomes the new qid and the fid is marked open with `mode`;
  reply `Rcreate{qid, iounit}` (iounit 0 ⇒ msize−IOHDRSZ as `open` does).
- `handleRemove`: call `ops.remove` then **clunk the fid unconditionally** (5/remove), reply
  `Rremove` or `Rerror`.
- `handleWstat`: decode the stat; "don't touch" detection per 5/stat; call `ops.wstat`;
  `Rwstat`/`Rerror`. All three may `WouldBlock` (parked).
- `Fid` gains whatever `create` needs (an `open` flag already exists — verify).

### 3d. Client helpers — `src/ninep/client.zig` (≤ +30 lines) and jobs
- `Client.create(fid, name, perm, mode) Error!CreateResult`, `Client.remove(fid)`,
  `Client.wstat(fid, st)` — synchronous `rpc` wrappers for pumped transports/tests; the
  ticket path works for free once the codec encodes the T-messages (T4 pins it).
- No new jobs this wave (Put's `CreateJob`/`WriteJob` belong to the Put/Get wave); note the
  seam in `nsjob.zig`'s header.

### 3e. Docs
- S-01 §2 (mandatory message subset): create/remove/wstat now supported, `tauth` remains
  the only Unsupported pair; §3 parking generalized ("any op may park"; bound); revision
  log. `agents/contracts/phase1-ninep.md`: one amendment line "R5 lifted by 14a". R-03:
  R-9P-01 revision-log line (v5) noting the subset is now complete minus auth.

### 3f. Rulings
- **R-P14a-1** Every existing test passes unchanged (names + bodies); `fsys`, `tools/origin`,
  `dev/input`, `dev/draw` behavior identical (defaults = prohibited).
- **R-P14a-2** Parking stores the raw frame and re-dispatches — no per-op parked structs.
- **R-P14a-3** `remove` clunks the fid even on error (5/remove); `create` re-points the fid.
- **R-P14a-4** `ninep` imports std + itself only; new files ≤ ~400 pre-test lines; `server.zig`
  ≤ ~450 after the move; `zig fmt` clean; no golden moves (none involved).
- **R-P14a-5** No ABI change (14b bumps to v6).

## 4. Named tests (sonnet)

| # | Where | Test |
|---|---|---|
| T1 | `msg.zig` | Round-trip encode/decode for Tcreate/Rcreate/Tremove/Rremove/Twstat/Rwstat incl. a max-length name and an empty-string wstat; a truncated Tcreate ⇒ `BadMessage`. |
| T2 | `server_mut.zig` | With `create/remove/wstat = null`: Tcreate ⇒ `Rerror "create prohibited"`, Tremove ⇒ `"remove prohibited"` AND the fid is gone afterwards (a following Tstat on it ⇒ unknown fid), Twstat ⇒ `"wstat prohibited"`. |
| T3 | `server_mut.zig` | A `FakeOps` with `create`: Tcreate on an open fid ⇒ error; on a non-dir ⇒ error; bad names (`/`, `.`, `..`, ``) ⇒ error; success ⇒ `Rcreate` with the new qid, the fid now stats as the new file and is open (a Twrite works); `iounit` default = msize−24. |
| T4 | `tickets.zig`/`client.zig` | `tickets.begin` with a Tcreate and a Tremove decodes their R-replies via `check`; `Client.create/remove/wstat` sync helpers work over a pumped pipe. |
| T5 | `park.zig` | `FakeOps.stat` returns `WouldBlock` until a flag flips: Tstat gets NO reply; `retryParked` with the flag still down ⇒ still parked, 0 completed; flag up ⇒ exactly one `Rstat`, 1 completed, parked list empty. |
| T6 | `park.zig` | Every parkable op parks and completes: walk1, open, read, write, create, remove, wstat (each once, via the fake) — and `clunk` returning WouldBlock is a `ProtocolError`-class defect (assert the framework treats it as a plain error, no park). |
| T7 | `park.zig` | FIFO order: three parked ops complete in arrival order across two retries; a Tflush for the middle one ⇒ `Rflush`, the other two still complete. |
| T8 | `park.zig` | Bound: `max_parked + 1` parked ops ⇒ the last gets `Rerror "too many parked requests"`; after completing one, a new op parks fine. |
| T9 | `park.zig` | Parked op whose fid is clunked before retry ⇒ retry replies the same error a fresh op on an unknown fid would. |
| T10 | `dev/input.zig`, `served` | Existing parked-read tests unchanged and green (`completeReads` alias); one new test calls `completeReads` and `retryParked` interchangeably on a parked read and gets identical bytes. |
| T11 | gate | `server.zig` pre-test ≤ 450; `park.zig`, `server_mut.zig`, `msg*.zig` ≤ 400; test-name list ⊇ main's; boundary greps. |

## 5. Gate (fable)
1. Suite to a file twice, `$?==0`; fmt; wasm build (no ABI change); smoke unchanged 30/30;
   boundaries; no FROZEN change.
2. Report `agents/reports/phase14a-server-parking-create.md`; HANDOFF: R5 lifted; 14b next.
