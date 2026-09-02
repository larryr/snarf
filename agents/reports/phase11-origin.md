# Phase 11 report — origin server

**Merged to main:** (this commit's merge) · **Tests:** 485/485 (`zig build test`,
verified with an explicit exit-code check, no leaks) · **Contract:**
`agents/contracts/phase11-origin.md` (R-P11-1..9) · **fmt:** clean · **Boundary:**
tools import `ninep` + `build_options` only; `src/` untouched.

## What works now

- `zig build serve` runs **`snarf-origin`**: the old static dev server (unchanged
  behaviour — `application/wasm`, COOP/COEP, `no-store`, 426 on a plain GET of `/9p`)
  **plus** a 9P2000 session on any WebSocket upgrade of `/9p`.
- **The exported tree** (S-02 §5, v1): `version` → `snarf-origin 0.1\n`;
  `bin/{echo,date}/{ctl,output}` — write `exec <args>`, read the result (per connection);
  `fs/` → the `-Dexport` directory (default: the repo root), read/write with OTRUNC,
  directory listings as proper stat(5) streams resumable by offset.
- **Proven end-to-end natively**: `tools/origin/accept.zig` starts a real listener on an
  ephemeral loopback port, connects a real WebSocket client (`ws_client.zig`, RFC 6455
  masking), and drives the real `ninep.Client` through version → attach → walk (incl.
  multi-element, `..`, partial-walk and not-a-directory errors) → open/read/write/stat →
  bin/echo exec → root/bin/fs listings. A second test checks the static HTTP headers over
  a raw socket. Manual curl smoke: 200 with headers, 426, and a 101 handshake with the
  correct `sec-websocket-accept`.

## Files (all ≤ 300 lines, S-07 P-2)

`main.zig` 176 (listener, thread-per-connection, dispatch, 9P pump) · `http.zig` 98
(static) · `ws_transport.zig` 88 (server WS ↔ 9P frames) · `ws_client.zig` 180 (client
WS, test support) · `tree.zig` 285 (`Ops`: root/version/bin/fs routing, per-fid nodes) ·
`hostfs.zig` 155 (host directory export) · `services.zig` 100 (built-in table + per-
connection outputs) · `dirread.zig` 59 (offset-addressed stat streams) · `accept.zig` 215
(test root). `tools/serve.zig` removed (its code is `http.zig`).

## Findings worth keeping

- **Zig in the remote sandbox**: `pip install ziglang==0.16.0` works (PyPI is proxy-
  allowed; ziglang.org is not). `zig build test` ≈ 12 s.
- Zig 0.16 `std.http.Server` has a complete server-side WebSocket (`upgradeRequested`,
  `respondWebSocket`, `WebSocket.readSmallMessage`) — no protocol code of our own needed.
  `std.mem.trimRight` → `trimEnd`. `realPathFileAlloc` returns `[:0]u8`; store it as such
  or the DebugAllocator reports a size mismatch on free.
- **9P walk semantics bit the test, not the server**: a partial multi-element walk is a
  short Rwalk → client `FileDoesNotExist`; the specific `WalkNoDir` only appears when the
  FIRST element fails. Also: you cannot walk from an open fid (`FidOpen`) — clone first.
- Server-side fid nodes must come from a per-session arena; peers that vanish never
  clunk, and the framework's `deinit` does not call `Ops.clunk`.

## Open questions raised

- Host command execution policy (allow-list? per-command ADR?) — built-ins only until
  decided (R-P11-5).
- `fs/` create/remove needs framework `Ops` growth (lifts phase-1 R5) — small, but touches
  `src/ninep/server.zig`, so it is its own wave.
- Non-loopback binds (`-Dbind=0.0.0.0`) currently expose a read/write directory with no
  auth — acceptable for LAN dev only; `Tauth` (OQ-9P-3) before anything else.
