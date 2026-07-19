# Phase 1 report — ninep (9P2000 core)

Merged to `main` as `f5da818` (user-approved interactively). Revert = revert that one
merge commit. Contract + as-built rulings: `agents/contracts/phase1-ninep.md`.

## Delivered

Full std-only 9P2000 core, +4,171 lines / 13 files, **84/84 tests**:

- `qid.zig`, `msg.zig`, `wire.zig` — wire codec, all 19 mandatory messages, zero-copy
  decode, grounded in `fcall.h`/`convM2S.c`/`convS2M.c` at the pinned SHA.
- `stat.zig` — stat(5) codec. `transport.zig` — keystone vtable. `errors.zig` —
  canonical Rerror strings (lib9p-extended).
- `chan.zig` — SPSC ring + Pipe loopback (frame-atomic; SAB-ready layout).
- `server.zig` — lib9p-shaped Srv: fid table, walk1/clone with partial-Rwalk semantics,
  version/flush per the man pages, R5 unsupported-message handling.
- `client.zig` — synchronous client: tag/fid allocators, pump hook, walk chunking.
- `mount.zig` — ordered longest-prefix table, component-boundary matching.
- Acceptance test in `ninep.zig`: client walks/opens/reads/writes a served tree over a
  Pipe with mount resolve on top. Passed on first composition.

## Pipeline stats

2 outline agents (fable) → 1 reconciled contract (4 pre-code conflicts resolved);
5 build agents (opus: msg/server/client; sonnet: chan/mount) in isolated worktrees;
orchestrator inspected every diff and re-ran every gate.

**Wave C catches (bugs that shipped green from build agents):**
1. B2 `walk()` multi-chunk partial leaked a server-established newfid AND recycled its
   number (future "fid in use" collisions). Fixed clunk-or-burn + wire-level regression.
2. B2 infallible `Pump.run` would hang (not fail) on a broken server. Now
   `anyerror!void` → `error.IoError`.
3. B1 `handleStat` `catch unreachable` on op-controlled stat size. Patched to degrade to
   `Rerror "i/o error"` + regression test.
4. B1 dropped `Ops.attach`'s uname param without flagging — accepted (available as
   `fid.uname`), recorded as ruling R8.

**Process fixes (recorded in HANDOFF learnings):** stale-worktree rebase step; per-agent
re-export lines (else in-worktree test gates pass vacuously); type-only imports still
sequence builds (mount after client).

## Deferred (tracked in contract R7)

ws.zig transport; Tcreate/Tremove/Twstat/Tauth arms; blocking-read wait queue + real
Tflush interruption; zero-copy Rread views; union mounts; dir-read stat streams.
