# Phase 11 contract — origin server (tools/origin)

Scope: morph `tools/serve.zig` into the origin server (S-02 §5, S-01 §3.2, S-06 §3):
static `zig-out/www` + 9P2000 over WebSocket at `/9p` serving a base tree. Browser-side
mounting of `/mnt/origin` is explicitly OUT of this phase (see Deferred).

## Rulings (as built)

- **R-P11-1 — placement.** Everything lives in `tools/origin/` (host dev tool, outside
  the editor module graph). Imports: `ninep` + `build_options` only. `src/ninep` is
  untouched: the WebSocket carrier is a `transport.Transport` implementation on the tools
  side, the existing `ninep.server.Server` is the 9P engine unchanged.
- **R-P11-2 — concurrency.** Thread per connection (`std.Thread`, detached), shared
  `std.Io.Threaded`. The 9P transport is *blocking*: `readMsg` parks in the socket read
  and never returns `WouldBlock`; `Server.step` therefore never reports idle and the pump
  is `while (true) step()` until `Closed`. Transport guarantee 3 (oversized frame stays
  queued) cannot hold over a stream — such a frame is consumed and `FrameTooBig` returned.
- **R-P11-3 — framing.** Binary WebSocket messages only; `size[4]` must equal the payload
  length; text frames and fragmented frames → `BadFrame` (connection dropped). Pings are
  answered inside the transport. Handshake and frame codec are `std.http.Server`'s.
- **R-P11-4 — tree.** `/` → `version`, `bin/`, `fs/`. Qids: synthetic nodes fixed small
  paths (root 1, version 2, bin 3, `bin/<i>` 0x100+i, ctl 0x200+i, output 0x300+i); host
  nodes `(1<<40) | inode`, `vers` = mtime seconds. Per-fid state is a heap `Node`
  (tagged union) in `fid.ctx`, allocated from a **per-session arena** so a peer that
  vanishes without clunking leaks nothing.
- **R-P11-5 — services are built-ins only.** `bin/<name>/ctl` accepts exactly
  `exec [args]` (else `BadCtl`); output is per connection. NO host process is spawned —
  arbitrary exec over a socket is remote code execution. v1 table: `echo`, `date`
  (epoch seconds). Host commands need an allow-list design and an ADR-0002-adjacent
  decision → open question.
- **R-P11-6 — fs/ semantics.** Plain files and directories only (symlinks/devices are
  invisible). Read/write + OTRUNC; **no create/remove/wstat** (framework ruling R5).
  Directory reads regenerate the stat stream and skip to `offset` (read(5) offsets are
  record boundaries). Every op re-opens the path — no host fds pinned by fids.
- **R-P11-7 — walk semantics.** Names never contain `/`; `.`/`..`-in-name refused;
  walking through a plain file is `WalkNoDir`; `..` from `fs/` returns to root. A partial
  multi-element walk is a short `Rwalk` (client sees `FileDoesNotExist`) — only a failing
  first element carries the specific Rerror. Acceptance test pins this.
- **R-P11-8 — shutdown.** `Origin.shutdown()` flags, pokes its own port to unblock
  `accept`, then waits for live connection threads (atomic counter) — needed for
  leak-clean tests; `deinit` closes the listener.
- **R-P11-9 — build.** Exe `snarf-origin`, step `serve` (name kept), new `-Dexport`
  (default `b.build_root`). Tests rooted at `tools/origin/accept.zig` (pulls every
  file's unit tests + two loopback acceptance tests: 9P over WS, static HTTP headers).

## Ground truth used

- walk(5)/read(5) via `larryr/plan9@ed1a9c2` `sys/man/5/*`; RFC 6455 framing rules.
- Zig 0.16 std: `std.http.Server.Request.upgradeRequested/respondWebSocket`,
  `std.http.Server.WebSocket.readSmallMessage/writeMessage`, `std.Io.Dir` (openDir with
  `.iterate`, `statFile`, `readPositionalAll`, `writePositionalAll`, `setLength`),
  `std.Io.net` (`IpAddress.listen/connect`, `Server.socket.address` for the ephemeral
  port), `std.Io.sleep`, `std.mem.trimEnd` (renamed from trimRight).

## Deferred (next wave, coordinate with the input claim — it fences web/shim.js)

1. Browser wiring: shim WebSocket import surface (S-06 §4), wasm-side WS transport,
   `/mnt/origin` mount at boot with absence tolerance (R-9P-10), `Reconnect` command,
   30 s ping keepalive in the shim.
2. `fs/` create/remove/wstat — requires framework `Ops` growth (lifts phase-1 R5).
3. Host commands with an allow-list; `bin/<name>` streaming output for long runs.
4. `Tauth` (OQ-9P-3) — loopback-only today; any non-loopback bind must come with auth.
