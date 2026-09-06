# Phase 12 contract — origin mount, browser side ("origin wave 2")

Scope: the browser half of phase 11 (S-00 §4 step 2, S-06 §4, R-9P-10): a wasm-side
WebSocket 9P transport, the shim `ws` import surface, `/mnt/origin` mounted at boot with
absence tolerance, a `Reconnect` builtin, and connection keepalive. After this phase the
editor's namespace reaches real origin files; *using* them from the UI (Get/Put, look on
paths) is the NEXT wave — this one proves the plumbing end-to-end.

Status: DRAFT for user review — rulings below are pre-agreed design; amend as built.

## Rulings (proposed)

- **R-P12-1 — URL.** The dial string is same-origin only (R-9P-15): scheme from
  `location.protocol` (`http:`→`ws:`, `https:`→`wss:`), host from `location.host`,
  path `/9p`. The shim computes it; the wasm side never sees a URL, only `wsOpen`
  with connection id. No third-party endpoints, no override knob in v1.
- **R-P12-2 — ABI v4.** New imports per S-06 §4: `wsOpen(id)`, `wsSend(id, ptr, len)`,
  `wsClose(id)` (S-06 §4 shows `wsOpen(urlPtr,len,id)`; per R-P12-1 the URL argument is
  DROPPED — amend S-06 §4 with a revision-log entry). Inbound data follows the
  phase-6 pushEvent pattern, not a ring: new exports `wsStage(len) → ptr` (module-side
  staging buffer) and `wsPush(id, kind, ptr, len)` where kind ∈ {open, data, close,
  error}. JS copies the frame into the staged buffer via the exported memory, then
  calls `wsPush`. No JS→WASM re-entrancy: `wsPush` only queues; the module drains on
  `tick()`/`wake()`. Bump `src/shim/abi.zig` version 3→4 + the `web/shim.js` mirror.
- **R-P12-3 — transport placement.** `src/ninep/transport.zig` stays untouched. The new
  `WsTransport` lives in `src/shim/` (it is glue between the browser boundary and
  `ninep` — core never imports it; S-07 §6). It implements the existing
  `transport.Transport` vtable over a receive queue fed by `wsPush`. Framing rules
  mirror R-P11-3: binary frames only, `size[4]` must equal payload length, one 9P
  message per WebSocket message; violations poison the connection (`BadFrame` → close).
- **R-P12-4 — non-blocking discipline.** Main-thread v1 (Worker+SAB still deferred):
  `readMsg` must NEVER park. The transport is used only through the phase-6 async
  client (tickets, R-P6-1); a would-block read returns the transport's queue-empty
  signal and the pump retries on the next tick. Nothing in this phase may spin-wait.
- **R-P12-5 — boot mount + tolerance (R-9P-10).** `init()` kicks off the dial and boot
  CONTINUES immediately; the editor never waits on the socket. On successful
  version+attach, bind `/mnt/origin` into the namespace (`ninep.mount.Namespace`).
  On failure or timeout (10 s), the mount is simply absent — one warning line, no
  retry loop, boot otherwise identical. Everything else (draw, input, snarf-self)
  must be indistinguishable with the origin down: that is the acceptance bar.
- **R-P12-6 — disconnect semantics.** A closed/errored socket fails all outstanding
  tickets on that mount with Rerror `"websocket closed"`, marks every origin fid dead
  (subsequent ops → same Rerror), and unbinds `/mnt/origin`. No automatic reconnect
  (a background redial loop against a down server is noise; acme's answer to stale
  mounts is an error, not magic).
- **R-P12-7 — Reconnect builtin.** Exectab grows entry #11: `Reconnect` closes any
  live origin connection, re-dials, re-attaches, re-binds `/mnt/origin`; fresh fids,
  old ones stay dead (R-P12-6). Success/failure is one warning line. This is the
  user-visible surface of the whole phase.
- **R-P12-8 — keepalive is SERVER-initiated.** Browsers cannot send WebSocket ping
  frames from JS, so the handoff's "30 s shim ping" is impossible as sketched:
  `tools/origin` pings each connection every 30 s (browser auto-pongs; two missed
  pongs → server drops the connection). The only origin-side change in this phase.
  Client-side liveness comes for free: a dead TCP surfaces as WS close → R-P12-6.
- **R-P12-9 — acceptance.** (a) Native: `WsTransport` unit tests over a scripted
  queue (framing, would-block, poison, fid-death) — no browser, no socket.
  (b) End-to-end: extend `tools/smoke_wasm.mjs` — node ≥ 22 has a WebSocket client —
  to spawn the real `snarf-origin` on an ephemeral port, boot the real `snarf.wasm`
  with the shim's import object, and prove: mount appears, read of
  `/mnt/origin/version` round-trips, server kill → fids die with the right error,
  restart + `Reconnect` → reads work again, origin-absent boot stays green.
  (c) Manual (Larry): `zig build serve`, browser, execute `Reconnect`, watch warnings.

### Rulings added while building B2 (amend-as-built)

- **R-P12-B2-1 — the origin handshake is hand-driven.** `ninep.Client`'s RPCs are
  synchronous: they send a T-message then loop on `readMsg`, resolving
  `WouldBlock` through the client `Pump`. Over a browser WebSocket no pump can
  produce a reply (frames arrive only after the module returns to the JS event
  loop) and R-P12-4 forbids spinning, so `version`+`attach` are driven one step
  per `tick` at the FRAME level in `src/origin/OriginMount.zig`
  (`ninep.msg.encode`/`decode` straight onto `WsTransport`). On Rattach the
  negotiated msize is written into the `Client` and `/mnt/origin` is bound; from
  then on the `Client` owns the transport. `src/ninep/*` is untouched.
- **R-P12-B2-2 — the keepalive is a second thread per connection.** The 9P
  connection thread parks in `readMsg` and `std.http.Server.WebSocket` has no
  read deadline to hang a timer off, so `tools/origin` spawns one `Keepalive`
  thread per session. It shares exactly one thing with the reader — the
  `Writer` — guarded by `WsTransport.write_mu` (`std.Io.Mutex`). The 30 s
  interval is slept in 100 ms slices so a closing session joins promptly. Two
  consecutive unanswered pings ⇒ `Io.net.Stream.shutdown(.both)`, which unblocks
  the parked read and lets the session tear itself down through its normal path
  (the connection thread still owns the descriptor).
- **R-P12-B2-3 — `Reconnect` inverts through `Editor.OriginHook`.** `core` may
  not import `shim`/`origin` (R-OV-03, S-07 §6), so the builtin reaches the
  transport through one erased-ctx function pointer that `src/main_wasm.zig`
  installs at boot: `origin: ?OriginHook`, `redial: *const fn (ctx: *anyopaque)
  void`. Null in every native harness ⇒ `Reconnect` is one warning line. The
  builtin itself prints NOTHING on the happy path: the dial is asynchronous, so
  R-P12-7's "one warning line" is the outcome line the tick-driven poll emits.
- **R-P12-B2-4 — the mount lives in its own module.** `src/origin/` (imports
  `ninep` + `shim`, same layer as `dev`) rather than inside `src/main_wasm.zig`,
  so the mount state machine is exercised natively by `zig build test` with no
  browser (R-P12-9a). `core` never imports it.

### Gaps found, reported not patched

- **`ninep.mount.Namespace` has no `unmount`.** R-P12-6 requires unbinding
  `/mnt/origin`; `mount.zig` offers only `mount`/`bind`. `OriginMount.unbind`
  drops the row through the table's public fields (free the owned prefix,
  `orderedRemove`) — exactly what the missing method would do. The framework
  should grow `Namespace.unmount(prefix)` before a SECOND runtime-managed mount
  exists.
- **`ninep.Client` has no async ticket for walk/open/clunk** — only `beginRead`/
  `checkRead`. Nothing but a read can therefore be driven over the WebSocket
  transport. The next wave (Get/Put, look on `/mnt/origin` paths) needs either
  that ticket API or a resumable RPC state machine in `client.zig`.
- **R-P12-6's Rerror text is a warning, not a wire reply.** There is no server
  left to send `Rerror "websocket closed"`, so outstanding tickets and stale
  fids surface `error.Closed` from the transport; the phrase appears in the
  warning line (`OriginMount.closed_text`) and in `reasonText()`.
- **`std.http.Server.WebSocket.readSmallMessage` silently skips pong frames**
  (`std/http/Server.zig`, "// Skip pongs."), which makes R-P12-8's missed-pong
  rule unobservable. `tools/origin/ws_transport.zig` therefore carries
  `readAnyMessage`: the same RFC 6455 §5.2 decode over the same public
  `Io.Reader` API, with pongs surfaced instead of swallowed.

## Ground truth

- Phase-11 server behavior: `agents/contracts/phase11-origin.md` R-P11-2/3 (blocking
  server transport, framing), `tools/origin/ws_transport.zig` for the frame codec.
- Phase-6 async client tickets: R-P6-1, `src/ninep/client.zig` pump.
- Browser WS API: no JS-initiated pings; `binaryType = "arraybuffer"`; close codes
  surface in `onclose` — map code+reason into the `wsPush` close record.

## Work breakdown (small phase — 2 build seams + orchestrator)

1. **B1 shim+ABI**: `web/shim.js` ws imports + staging exports, `src/shim/abi.zig` v4,
   `WsTransport` + unit tests. Fences: `web/shim.js`, `src/shim/*`.
2. **B2 mount+builtin+server-ping**: boot dial/mount (main_wasm), R-P12-6 fid death,
   `Reconnect` in the Exectab, 30 s ping in `tools/origin/main.zig`. Fences:
   `src/main_wasm.zig`, `src/core/exec.zig`-adjacent, `tools/origin/`.
3. Orchestrator: smoke extension (R-P12-9b), S-06 §4 revision log, boundary check
   (core imports unchanged), merge.

## Deferred (unchanged from phase 11 list)

Get/Put + look on `/mnt/origin` paths (next wave); `fs/` create/remove (Ops growth,
lifts R5); host-command allow-list (ADR); `Tauth` before any non-loopback bind;
Worker+SAB transport swap (R-P6-1 says this is a transport move, not a redesign).
