# #58 — shutdown teardown (SnarfDev1)

Branch `snarfdev1/shutdown-teardown`. Written 2026-10-31 (America/New_York).

## Cause (measured, not assumed)
Debug repro on main (Xvfb + plan9port devdraw, close window): 69 `leaked` lines.
**Zero** leak frames came from `src/core`: the window tree and Editor were
already freed. What leaked was everything `boot` builds *around* them:
- the four in-process 9P stacks (draw, input, `/mnt/snarf-self`, hostfs):
  Pipe/Server/Client never deinit'd; Display, Font and the Namespace too;
- `HostTree`'s per-fid `Node`s, which only `ops.clunk` frees, and
  `Server.deinit` (`clearFids`) never calls `ops.clunk`.

## Fix shape
- `ninep.Server.releaseFids`: lib9p `freefidpool` → `destroyfid` for every
  live fid (plan9port src/lib9p/fid.c:29-33, :63-76), then drop parked reqs.
- `HostTree.endSession`: `hung_up` flag → a Put still writing its temp file
  is DISCARDED, never committed (releasing fids through plain clunk would
  have committed a half-written file).
- `ns_boot.SelfTree.stop` + errdefers in `start`.
- `core.shutdown.teardown(ed, tree)`: Editor first (jobs hold *Window),
  then tree (Chrome solids free through the still-live display).
- `native_shutdown.shutdown(a)` + `App.built` flags: frees exactly what
  `boot` built (partial boot safe). `main` does `defer shutdown(a)` right
  after spawn, so it runs before `conn.deinit`.
- No `std.process.exit` fallback was needed.
- PM ruling 2026-10-31 (SnarfProdd): a Put discarded at shutdown prints one
  stderr line, `snarf: Put of /path not finished at exit; file left
  unchanged`. Decided in `HostTree.clunk` (hung_up && !p.failed), written
  to the writer passed to `endSession`; native routes it via `App.exit_log`
  (tests) or collects then `std.debug.print`s (no stderr lock held during
  the fid release). Nothing printed when nothing is discarded.

## Open / for later
- `Server`'s Tversion path also `clearFids()` without `ops.clunk` — same
  latent leak shape for a client that re-versions. Out of scope here.
- The origin server tree does not run per-connection cleanup on drop.
- #13 `Exit`: call `shutdown(a)` (via a host hook), then leave the loop.
