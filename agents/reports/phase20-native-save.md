# Phase 20 — native file save: as-built report

## Test stage (sonnet)

TDD stage one: tests only, no feature code. Baseline `zig build test`: 793 tests, 777 pass, 16 skip.
After this commit: 811 tests, 792 pass, 16 skip, **3 fail (all new)**. `zig fmt --check src build.zig tools` clean; `smoke_wasm` 40/40.

### Harness choice

`src/accept_hostfs.zig` (hooked into `src/accept.zig` beside `accept_colors.zig`; no build.zig change).
`tools/origin/hostfs.zig` cannot be imported from the accept root: Zig forbids one file in two modules and
`tools/origin/accept.zig` already owns it, and S-07 section 6 bars the edge anyway. So the file serves a
`std.testing.tmpDir` through a small in-file 9P ops table (`TmpFs`, plain open(OTRUNC)/write/clunk, same
semantics as HostFs today), mounted at `/` and `/mnt/host`. Also mounted: a MemTree at `/dev` and the real
`ns_boot.SelfTree` at `/mnt/snarf-self`. The editor-level tests therefore pin editor behavior over a host-fs
mount. Hostfs-side atomicity is pinned file-level (Q5). The harness steps `Editor.frameEnd` plus server polls
until `ed.loads`/`ed.puts` drain (bounded at 20000 ticks).

### Failure-mode table

| Test | Today |
|------|-------|
| NFS-01w (source pin: `main_native.zig` has `HostFs.open(`, `"/mnt/host"`, `.mount("/"`) | FAILS: `TestUnexpectedResult` (main_native wires no hostfs) |
| Q5-a atomic replace, old bytes until clunk | FAILS at `expectDisk` right after `open(OWRITE\|OTRUNC)`: file already truncated |
| Q5-b failure before clunk keeps old file | FAILS at final `expectDisk`: old bytes gone (failure injection itself works: a Twrite at offset 2^62 errors) |
| NFS-01..10, 14, 16, Q5-c, Q5-d, Q5-d2 | PASS today (see below) |

### Why most pass today (honest finding)

The harness builds its own namespace, so the mount exists from the start; `Namespace.mount("/", ...)` and
longest-prefix already work, and Put/Get/Putall/ctl work over any 9P server. The contract's expected
`error.NotMounted` appears only if the harness lacked the mount, which would make the tests meaningless. The
real RED for R-P20-2 is NFS-01w. The remaining tests are regression guards the implementation must keep green.
Q5-c (no litter), Q5-d (create mode) and Q5-d2 (replace preserves mode 0640) can only go red once temp+rename
exists and leaks or loses mode; NFS-10 (read-only file, no litter) likewise goes red if rename-over silently
succeeds on a 0444 file.

### Untestable as specified / notes for the implementer

- NFS-02 and the open tests use `openfile.readFile` (acme.c readfile). B3 look is not exercised.
- Q5-b defines "failure before clunk" as a failed Twrite followed by Tclunk, since the ops `clunk` hook cannot
  report errors. The impl must discard the temp when any write on that fid failed.
- The existing `xfail` test "NFS-10b" (OTRUNC-open then clunk with NO write must keep the old file) conflicts
  with rename-on-clunk unless the impl discards a temp that was never written. Decide, and flip or adjust that
  flag deliberately.
- NFS-11..13 (Dump/Load, `$home`) are not written (contract R-P20-5 defers them).
- NFS-17 is the normal gate.
