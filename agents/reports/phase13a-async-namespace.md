# Phase 13a report — asynchronous 9P tickets, namespace jobs, `Editor.ns`, a real boot namespace

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 592/592 (575 + 17), run twice,
≈3 s · node smoke 29/29 (+3) · `zig fmt` clean · boundaries clean · **no golden moved, no test
renamed** · **Contract:** `agents/contracts/phase13a-async-namespace.md` (rulings R-P13a-1..5) ·
**wasm:** 1788746 B = 1746.8 KiB (**+137 KiB**: the served tree `core/served/*` plus a third
pipe/server/client are linked into the module for the first time — the cost of retiring
R-P10-E; the ReleaseSmall figure will have moved accordingly).

This is the enabling half of directory windows (13b). It lifts two standing HANDOFF gates:
"ninep.Client has NO async ticket for walk/open/clunk" and "Editor has no namespace handle".

## What works now

- **Generic tickets** (NEW `ninep/tickets.zig`; `client.zig` 672 → 585 pre-test lines): any
  T-message can be issued without waiting (`begin`), polled without pumping or blocking
  (`check` drains ready frames only), and abandoned (`cancel`). Two slot modes: `.frame`
  (raw reply) and `.payload` (byte-identical to the phase-6 read tickets — a 49-byte
  `/dev/mouse` buffer proves the whole-frame design could not carry Rread). **Tombstones**
  (`.discard`, added after review): abandoning a request keeps its tag booked; the late
  reply — and the Rflush — are dropped on arrival instead of poisoning an unrelated
  ticket's `check`. Mid-job clunks use `discardClunk` (Tclunk on a tombstone + immediate
  `freeFid`; in-order peers assumed, documented).
- **Namespace jobs** (NEW `ninep/nsjob.zig` + `ninep/nsio.zig`): `WalkJob` (chan.c:1020-1043
  member order, first success), `StatJob`, `ReadFileJob` (iounit chunks, 64 MiB cap →
  `TooBig`), `ListDirJob` (unionread semantics; `.data` byte-identical to `DirReader`); one
  message in flight per job; `runSync(job, pump)` + `Pumps{srvs}` for tests/pumped paths —
  **the pump must drive every reachable server** (documented; a one-server pump wedges a
  union). Equivalence with the synchronous `walk`/`DirReader` pinned by T5/T6.
- **`Editor.ns`** (+ `boot.Options.ns`, `Tree.bind(ed)`): the core's only door to files.
- **A real boot namespace** (NEW `src/ns_boot.zig`): `/dev` (input: `mouse kbd ctl`),
  `/dev/draw`, and **`/mnt/snarf-self` served at runtime** (third pipe, polled each tick —
  R-P10-E retired); `/n/origin` + `/bin` via `OriginMount`. `ListDirJob("/")` ⇒ `dev/ mnt/`
  (+ `bin/ n/` once the origin attaches). `/dev` and `/dev/draw` must be reached ONLY via
  jobs (their clients carry standing parked reads — warning in `ns_boot.mountDevices`).
- **Docs**: S-01 §4.1 tickets + jobs ("abandoning a request keeps its tag"); S-02 §1.3
  as-built boot table, §6 R-P10-E retired, `/dev/ns` → `/mnt/snarf-self/ns` (R-P13a-4);
  R-03 v4 (R-9P-13 widened to every 9P op).

## Deviations (all accepted in review)
1. Two slot modes (R-P13a-1 forces it). 2. `nsjob`/`nsio` split (cap). 3. Non-uniform job
`init` (no dead allocator params). 4. `/mnt/snarf-self/ns` verified at ~20 lines but NOT
built: a served-root dirtab row changes the root listing and would break an existing test —
deferred to 13b, which changes served listings anyway (`SEAM(ns)` in `fsys.zig`).

## Review loop
First review: FAIL — `cancel` and job `deinit` clunks were synchronous `rpc`s; on the
un-pumped origin client the Tflush/Tclunk went out, `WouldBlock` came back, the slot was
dropped, and the late replies became unknown tags. Fix: tombstones (above) + `.cleanup`
`freeFid` on every path + `StatJob` buffers to `read_chunk` + the `/dev` jobs-only warning.
Regression T8b (two tests) written by sonnet and reasoned to fail on the old code. Second
review: PASS; nit A (in-order-peer assumption on `discardClunk`) recorded in code.

## Debt
`nsio.zig` 451 raw pre-test lines (~330 code + cited rationale); `Editor.zig` 396 (under, barely
— 13b's Load driver must live in its own file); `discardClunk` fid reuse hardening for a
reordering server (ADR-0005 native host); wasm size watch (+137 KiB).
