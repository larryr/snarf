# Phase 13a contract — asynchronous 9P tickets, namespace jobs, the editor's namespace handle, and a real boot namespace

Status: **binding once fable signs §3.** Branch `phase13a` (worktree `../snarf-wt/phase13a`),
based on `main@8088803`. This is the enabling half of the user-queued **directory windows**
wave (13b follows). Requirements: R-9P-13 (non-blocking reads — extended here to every
9P op the editor issues), R-9P-12/R-EDIT-17 (`/mnt/snarf-self` reachable at runtime),
R-EDIT-03/07/13 (what 13b builds on). Lifts the HANDOFF gates "ninep.Client has NO async
ticket for walk/open/clunk (Get/Put + origin file reads BLOCKED on it)" and "Editor has no
namespace handle (blocked `/dev/ns`, blocks directory windows)".

Pipeline: fable spec → **opus** codes §3 → **sonnet** writes §4 → **sonnet** runs the gate →
**fable** reviews → loop.

## 1. Ground truth

| Item | Where | What |
|---|---|---|
| Ticket API today | `src/ninep/client.zig:48-58 PendingRead`, `:229-246 dispatch`, `:511-560 beginRead/checkRead/cancelRead`, `:189-215 rpc` | Only **Tread** can be issued without waiting. `dispatch` routes an out-of-order reply by tag into a `PendingRead` slot, copying the Rread payload into the caller's buffer; any other reply type for a ticket tag is `ProtocolError`. `rpc` is synchronous: it spins on `readFrame`, which pumps (`Pump`) on `WouldBlock` or surfaces `WouldBlock` with no pump. The doc at `:196-199` forbids `rpc` on parkable files. |
| Why it matters | `src/origin/handshake.zig` (12e) | The origin's `Client` has NO pump (frames arrive via `wsPush` on later ticks), so the handshake hand-drives every RPC. Anything the editor wants to read from `/n/origin` needs tickets for walk/open/read/clunk/stat. |
| Transport | `src/ninep/transport.zig:26-33` | `WouldBlock` = no frame available; in-memory `chan.Pipe` transports are pumped by `srv.poll` (`main_wasm.zig:82 pumpServer`). |
| Namespace ops today | `src/ninep/nsdir.zig` (12d) | `walk`/`DirReader` are **synchronous** — built on `Client.walk/open/read/clunk` (`rpc`) — correct for pumped transports, unusable against the origin. |
| Boot namespace today | `src/main_wasm.zig:122-131, 230` | `App.ns` is EMPTY at boot except `/n/origin` (+ `/bin`) when the origin attaches. The draw device (`a.cl` over `a.pipe`, root = the draw dir), the input device (`a.cl_input`, root dir "input" with `mouse kbd ctl`), and the served tree (`core/served/fsys.zig Fsys.init(ed)`, `ops`) exist but are NOT in the table; the served tree is not even served at runtime ("runtime mounting waits for the first in-editor client", R-P10-E). S-02 §1.3 already documents the intended boot table. |
| Plan 9 precedent | `9/port/sysfile.c` (syscalls are synchronous over a kernel that blocks the proc) | acme itself blocks in `textload`/`dirread`; the browser main thread cannot. The job/ticket shape here is the S-01 §3.2 / R-9P-13 answer. |

## 2. Merged reality (`main@8088803`)

575 tests, 26 smoke checks, `client.zig` 672 pre-test lines (over cap — this wave MOVES ticket
code out of it rather than adding), `nsdir.zig` ≈ 280 code lines. `Editor` imports `ninep`
already (`Editor.zig:20`), so a `*Namespace` field is legal under S-07 §6.

## 3. CONTRACT

### 3a. Generic tickets — NEW `src/ninep/tickets.zig`, `client.zig` shrinks

```zig
pub const Ticket = struct { tag: u16 };
/// Send `t` without waiting. `buf` receives the RAW reply frame (any R-type) when it
/// arrives; sized by the caller (Rwalk ≤ 7+16*13 B, Ropen/Rclunk tiny, Rstat/Rread ≤ msize).
pub fn begin(c: *Client, t: Message, buf: []u8) Client.Error!Ticket
/// Drain every frame the transport has RIGHT NOW (no pump, no blocking): each reply is
/// routed by tag into its slot (or, with an in-flight `rpc`, left for it). Then report the
/// ticket: `null` = still pending; a decoded reply (aliasing `buf`) = done; Rerror ⇒ the
/// mapped error (Interrupted for a flushed ticket).
pub fn check(c: *Client, t: Ticket) Client.Error!?Message
/// Tflush the ticket (existing cancelRead semantics), consume the ticket.
/// AS BUILT: asynchronous — the Tflush goes out on a TOMBSTONE slot and the
/// flushed tag is tombstoned rather than removed, so the two replies the server
/// still owes are dropped on arrival instead of poisoning a later `check` (a
/// synchronous `rpc` here would pump, and on an un-pumped client would fail
/// WouldBlock after sending). Mid-flight clunks in job `deinit`s use the same
/// mechanism: `beginDiscard(Tclunk)` + an immediate local `freeFid`.
pub fn cancel(c: *Client, t: Ticket) Client.Error!void
```
- `PendingRead` → `Pending{ buf, state: waiting | done: usize (bytes of raw frame) | failed }`.
  `dispatch` copies the WHOLE reply frame into the slot for any R-type; `check` decodes it.
  `rpc`'s loop keeps routing foreign tags through `dispatch` (unchanged behavior for the
  synchronous path).
- **Existing API preserved as forwarders in `client.zig`**: `beginRead(fid, offset, buf) ReadTicket`,
  `checkRead(t) ?usize`, `cancelRead(t)` — implemented over `tickets.begin/check/cancel`
  (checkRead decodes the Rread and returns `data.len` after moving the payload to the
  front of `buf`, so callers' byte-exact expectations hold). `ReadTicket` stays a distinct
  type (or `= Ticket`) so `dev/input` and `main_wasm`/`input_pump` compile unchanged.
- Net effect on `client.zig`: the ticket bodies leave; it must end **≤ its current 672**
  pre-test lines and preferably ≤ 600. `tickets.zig` ≤ ~400.
- `check` must never call the pump and must never block: it loops `tport.readMsg` until
  `WouldBlock`, dispatching each frame. A frame whose tag matches neither a slot nor an
  in-flight `rpc` tag is `ProtocolError` as today.

### 3b. Asynchronous namespace jobs — NEW `src/ninep/nsjob.zig`

State machines driven by `step()`, one 9P message in flight per job, built ONLY on
`tickets.begin/check`. Every job: `init(allocator, ns, …)`, `step() Error!Status` with
`Status = enum { pending, done }`, results in fields, `deinit()` clunks anything it opened
and cancels an in-flight ticket.

```zig
pub const WalkJob    // chan.c:1020-1043 over tickets: members tried in order, one Twalk at a time;
                     // Rerror ⇒ next member; all fail ⇒ error.NotFound (or .dir for a synthetic prefix).
    result: nsdir.Handle
pub const StatJob    // WalkJob then Tstat then Tclunk: result: Stat (for 13b's "does this file exist / is it a dir")
pub const ReadFileJob// WalkJob then Topen(OREAD) then Tread loop (offset advances, iounit-sized) until 0, then Tclunk;
                     // appends to a caller-owned ArrayList(u8); caps at a caller `max_bytes` (R-EDIT-10: 64 MiB).
pub const ListDirJob // sysfile.c:323-380 over tickets: synthetic children first (same rule as DirReader),
                     // then per member: WalkJob-to-dir, Topen, Tread loop; a member that fails is skipped;
                     // result: ArrayList(Stat) decoded (13b sorts/columnates)
pub fn runSync(job: anytype, pump: ?Pump) Error!void  // loops step()+pump until done — for tests and pumped transports
```
- **Equivalence ruling (R-P13a-2)**: over the 12d fixtures (`FakeTree`/`FakeServer`,
  `FailOpenTree`, `FailReadTree`), `runSync(ListDirJob)` yields the same names in the same
  order as `DirReader`, and `runSync(WalkJob)` lands on the same member as `walk`. The
  synchronous `walk`/`DirReader` stay as they are (used by tests and pumped paths); do not
  reimplement them this wave.
- A job holds at most ONE ticket; `deinit` mid-flight cancels it and clunks any fid it
  owns (walk fids are clunked on every failure path). AS BUILT: every step of that is
  fire-and-forget — `tickets.cancel` for the ticket, `tickets.discardClunk` for the fid
  (Tclunk on a tombstone slot + immediate `freeFid`; a Tclunk releases the fid
  server-side even when the reply is an Rerror, `5/clunk`). A job `deinit` NEVER calls
  `Client.clunk`/`rpc`: it may run on a client with no pump.

### 3c. The editor's namespace handle — `src/core/Editor.zig`

- Field `ns: ?*ninep.mount.Namespace = null` with a doc comment: "the session mount table
  (S-02 §1); null in headless unit tests that never touch the namespace. `core` reads files
  only through this — never through a device or the shim (R-OV-03)." Set in `main_wasm`
  (`a.editor.ns = &a.ns`) and in `boot.boot` when the caller passes one (add an optional
  `ns: ?*Namespace` to the boot options).
- Nothing in `core` USES it yet except a `/dev/ns` file: **if** `served/fsys.zig` can serve a
  read-only `ns` file at the served root (`/mnt/snarf-self/ns`) rendering `ed.ns.?.list()` in
  ≤ 30 lines, do it (S-02 §1 promised `/dev/ns`; S-02 must then say the file lives at
  `/mnt/snarf-self/ns` because Snarf has no `/dev` server of its own — ruling R-P13a-4).
  Otherwise leave the cited seam.

### 3d. A real boot namespace — `src/main_wasm.zig` / `src/origin_glue.zig` (or a new `src/ns_boot.zig`)

At boot, populate `a.ns` per S-02 §1.3 (verify that table and correct it to as-built):
- `mount("/dev/draw", &a.cl, draw_root_fid)` — the draw device tree.
- `mount("/dev", &a.cl_input, input_root_fid)` — the input device ("input" root: `mouse kbd ctl`);
  with `/dev/draw` mounted separately this is exactly 12d's T13 shape (synthesized `draw`
  child + device listing).
- **Serve `/mnt/snarf-self` at runtime**: a third `chan.Pipe` + `ninep.server.Server` over
  `Fsys.ops` with `Fsys.init(&a.editor)` + a `ninep.Client` with `pump = srv.poll`, attached,
  `mount("/mnt/snarf-self", …)`. Poll that server in `tick` alongside the others. R-P10-E is
  thereby retired — say so in the code comment and S-02 §6.
- `/n/origin` and `/bin` keep arriving via `OriginMount` (unchanged).
- Result (13b's boot window will show it): `ListDirJob("/")` ⇒ `dev/ mnt/` (+ `n/ bin/` once
  the origin attaches).
- The smoke script gains a check that `init` + a few `tick`s still trap nothing and that the
  module still emits the same exports (no export change here). If a cheap export exists to
  read the namespace listing, do NOT add one — no ABI change this wave (R-P13a-5).

### 3e. Docs
- S-01 §3.2 (or wherever the ticket API is described): the generic ticket + job model, "never
  pumps, never blocks", one message per job. S-02 §1.3: boot table as built; §6: runtime
  serving of `/mnt/snarf-self`, `/mnt/snarf-self/ns` if built. R-03: R-9P-13 wording extended
  from "blocking reads" to "every 9P operation the editor issues" (revision-log line, v4).
  HANDOFF gaps struck.

### 3f. Rulings
- **R-P13a-1** Zero change to the synchronous paths' behavior; every existing test passes
  unchanged (names identical); no golden moves.
- **R-P13a-2** Job/sync equivalence as in §3b, pinned by tests.
- **R-P13a-3** `check` never pumps or blocks; `begin` may pump only for the SEND (as
  `beginRead` does today via `sendFrame`).
- **R-P13a-4** `/dev/ns` → `/mnt/snarf-self/ns` (Snarf has no `/dev` server); optional.
- **R-P13a-5** No ABI change; `core` imports nothing from `dev`/`shim`/`origin`; `ninep`
  imports std + itself; `zig fmt` clean; `client.zig` shrinks, new files ≤ ~400 pre-test lines.

## 4. Named tests (sonnet)

| # | Where | Test |
|---|---|---|
| T1 | `tickets.zig` | Two `begin`s (Twalk, Tstat) on one client over a fake transport; replies delivered in REVERSE order; each `check` returns its own decoded reply; a third tag ⇒ `ProtocolError`. |
| T2 | `tickets.zig` | `check` on a transport with no frames returns `null` without invoking the pump (assert the pump counter is 0). |
| T3 | `tickets.zig` | Rerror reply ⇒ `check` returns the mapped error; `cancel` sends Tflush and frees the slot (a later reply for that tag is ignored). |
| T4 | `client.zig` | Existing `beginRead/checkRead/cancelRead` tests unchanged and green; `checkRead` still returns the payload at `buf[0..n]` byte-exactly. |
| T5 | `nsjob.zig` | `runSync(WalkJob)` == `nsdir.walk` member choice over the 12d union fixture (first-wins, second-only, NotFound, NotMounted, synthetic `.dir`). |
| T6 | `nsjob.zig` | `runSync(ListDirJob)` names/order == `DirReader` over `/`, `/n`, a union `/bin`, an exact mount with a deeper synthetic child, and with a `FailOpenTree`/`FailReadTree` member. |
| T7 | `nsjob.zig` | `ReadFileJob` reads a multi-chunk file (> iounit) byte-exactly; `max_bytes` cap stops early with `error.TooBig` (or the chosen name) and clunks. |
| T8 | `nsjob.zig` | Un-pumped transport: `step()` returns `.pending` repeatedly with no frames; feeding one frame per `step` advances exactly one state; `deinit` mid-walk cancels the ticket and clunks the fid (assert the fake server saw Tflush + Tclunk). |
| T9 | `nsjob.zig` | `StatJob` on a dir and on a file reports DMDIR correctly; on a missing name ⇒ `NotFound`. |
| T10 | `boot.zig`/`accept.zig` | Booting with an `ns` option sets `ed.ns`; a scene mounts the served tree + a fake `/dev` and `runSync(ListDirJob("/"))` lists `dev mnt`. |
| T11 | `served` tests | If §3c's `ns` file was built: reading `/mnt/snarf-self/ns` yields `Namespace.list` text; else N/A (say so). |
| T12 | `tools/smoke_wasm.mjs` | Boot + ticks still trap nothing; exports unchanged (`abi_version() === 5`). |

## 5. Gate (fable)
1. `zig build test` to a file, `$?==0`, 0 failures, twice; `zig fmt --check`; `zig build`;
   `node tools/smoke_wasm.mjs`; boundary greps empty; no FROZEN literal changed; test-name
   list ⊇ main's.
2. Pre-test line counts: `client.zig` ≤ 672 (report the number), `tickets.zig`/`nsjob.zig` ≤ 400.
3. Report `agents/reports/phase13a-async-namespace.md`; HANDOFF gates struck; 13b next.
