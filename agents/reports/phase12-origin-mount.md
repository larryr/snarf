# Phase 12 report — origin mount, browser side ("origin wave 2")

Merged to `main` 2026-09-05. Contract: `agents/contracts/phase12-origin-mount.md`
(now AS BUILT, rulings R-P12-1..8 + B1-1..4, B2-1..4, O1). Pipeline: 2 sequential
build agents (opus, isolated worktrees) + orchestrator; B2 depended on B1's merged
transport.

## What Snarf can do now

The editor dials `ws://<origin>/9p` at boot and mounts the origin's 9P tree at
`/mnt/origin` (version + attach negotiated asynchronously, one step per tick; the
negotiated msize adopted). Origin down = mount absent after a 10 s deadline, boot
otherwise byte-identical. A dropped socket kills the mount and its fids with
"websocket closed" warnings; the new `Reconnect` builtin (exectab row 8, between
Paste and Redo — Snarf-only, acme has no such verb) re-dials/re-attaches/re-binds.
The origin server pings each session every 30 s and drops it after two missed pongs.

## Numbers

522/522 native tests (was 485 pre-phase); smoke 20/20 (was 14) including the new
origin battery; `zig fmt` clean; wasm 1554.1 KiB (watch: was 1506 before the phase).

## Key as-built decisions (details in the contract)

- ABI v4: `wsOpen(id)`/`wsSend`/`wsClose` imports (URL derived shim-side, same-origin
  only — S-06 §4 revision logged); inbound via `wsStage`/`wsPush` exports, pushEvent
  pattern, kinds open/data/close/err.
- `WsTransport` (src/shim) implements ninep's vtable via a comptime-generic
  `transport(T)` — shim keeps its std-only import set (R-P12-B1-1).
- `src/origin/OriginMount.zig` is a NEW module (imports ninep+shim, layer of dev):
  the tick-driven mount state machine, natively tested. `tick(now_ms)` is now the
  module's only clock; the dial deadline arms on first poll, wrap-safe.
- `Reconnect` reaches the transport through `Editor.OriginHook` (erased-ctx fn ptr
  installed by main_wasm; null in native harnesses) — core still imports only
  draw+ninep, verified at merge.
- Server keepalive is a second thread per session sharing only the mutex-guarded
  writer; teardown via `shutdown(.both)` (reader owns the fd). `readAnyMessage`
  added because std's `readSmallMessage` silently eats pongs.

## Acceptance evidence

Smoke (tools/smoke_wasm.mjs, manual tool): instance 1 boots with ws stubbed —
green through a 15 s tick crossing the dial deadline. Instance 2, against a real
spawned `snarf-origin` over real node WebSockets: Tversion/Tattach observed on the
wire AND `9p attach /` in the server's phase-11.5 access log; SIGKILL absorbed;
server restarted and `Reconnect` executed as a real user gesture (B1 click → typed
word → B2 click via pushEvent) → fresh attach logged by the new server process.
MANUAL STEP for Larry: restart `zig build serve`, reload the browser — expect the
`/mnt/origin: mounted` warning path exercised for real (watch the server's stdout
access log); kill/restart the server and middle-click `Reconnect`.

## Gaps handed to the next wave (recorded in the contract)

1. `ninep.Client` has NO async ticket API for walk/open/clunk — Get/Put and any
   file read on `/mnt/origin` are blocked on it (R-P12-O1 narrowed acceptance).
2. `ninep.mount.Namespace` lacks `unmount(prefix)` — OriginMount reaches through
   public fields; grow the framework before a second runtime-managed mount (OPFS!).
3. `ed.warnings` still has no on-screen surface (+Errors window pending) — mount
   outcomes are invisible in the UI today except via devtools/console paths.

## Debt / watch

wasm grew 48 KiB this phase (1554.1 KiB). `src/shim/WsTransport.zig` 590 and
`src/origin/OriginMount.zig` 650 lines are over the soft cap but are ~half
colocated tests (impl 288/357 — within spirit; split if they grow again).
