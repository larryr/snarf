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

## Implementation (opus)

### What changed, per area

- **hostfs module (R-P20-1).** `tools/origin/hostfs.zig` → `src/hostfs/HostFs.zig`
  (file-as-struct) and `tools/origin/dirread.zig` → `src/hostfs/dirread.zig`, in a new
  `hostfs` build module (root `src/hostfs/root.zig`; imports `ninep` only). Consumed by
  `snarf-origin`, `snarf-native`, the `tools/origin/accept.zig` test root and the
  `src/accept.zig` test root; has its own test root in `zig build test`. `core`/`ninep`
  cannot see it (build graph). Root is `root.zig`, not `hostfs.zig`: on macOS's
  case-insensitive FS `hostfs.zig` and `HostFs.zig` are the same file. S-07 §4/§6 updated.
- **Atomic Put (Q5, R-P20-3)** — `src/hostfs/Replace.zig`, used by BOTH trees:
  OTRUNC open of an existing file → open the original `read_write` (a 0444 file fails
  HERE with `permission denied`, as acme's `create` would), then exclusive-create
  `<dir>/.<base>.snarf-put.<n>` with the original's mode (re-`fchmod`ed past the umask);
  writes go to the temp; clunk renames over the original. Rulings as landed:
  failed Twrite poisons the fid → clunk deletes the temp, original untouched (Q5-b);
  OTRUNC + clean clunk with zero writes = empty Put → empty file; mode preserved (Q5-d2);
  new files via Tcreate stay `0666 & ~umask`; no litter on success / failure / early
  clunk (Q5-c, NFS-10). The target is the original's realpath, so Put through a symlink
  replaces the linked file and keeps the link. Writable file in an unwritable directory
  (no temp possible) falls back to acme's in-place truncate. A failed rename at clunk
  deletes the temp (clunk can't report errors). DIVERGENCE comment cites exec.c:727 and
  the contract.
- **`src/hostfs/HostTree.zig`**: a `ninep.server.Ops` with the export dir as the root
  (`..` at root stays at root). This is what native mounts.
- **`tools/origin/tree.zig`**: new `Node.host_put` variant routes OTRUNC opens through
  `Replace` (401 → 430 lines; the growth is exactly the new variant's switch arms).
- **Native wiring (R-P20-2)**: `main_native.zig` opens `HostFs.open(io, "/")`, serves
  `HostTree` over a Pipe/Server/Client with the DevInput9 pump, mounts the one root fid at
  `/` and `/mnt/host` after `/dev` and `/mnt/snarf-self` and before the boot directory
  window; `tick` polls the server. `io` is threaded from `init` into `boot`. The boot
  window now lists the real `/`; `dev/`/`mnt/` are not in it (they are ns prefixes).
- Docs: S-02 §1.3 revision log + §4 native note; S-07 §4 tree, §6 rule, revision log.
  `core/Session.zig` doc comment no longer says native `Dump` warns NotMounted.

### Test edits and justifications (R-P20-6)

1. `hostfs_native_test.zig` **NFS-10b** rewritten: it asserted that OTRUNC-open + clunk
   with no writes keeps the old file. The orchestrator's ruling (contract clarification)
   is that this is an empty Put and leaves an empty file. **The test was wrong about the
   contract.** It now asserts the original is untouched until clunk, then empty. The
   unused `xfail`/`native_fs_landed` machinery (only NFS-10b used it) is removed.
2. `accept_hostfs.zig` harness: the in-file `TmpFs` stand-in is replaced by the real
   `hostfs.HostTree` over `HostFs` on the tmp dir. Its only reason to exist was that
   hostfs wasn't a module. No assertion changed; the editor-level tests now also exercise
   the atomic Put and the read-only refusal through the real code.
3. `Rig.busy` also waits for `session.dump`/`session.load` (needed for the new tests).
4. **NFS-11..13 added** (R-P20-5): they passed with zero extra plumbing. NFS-11 checks
   that Dump writes `$home/acme.dump` (`$home` = `/home` = tmp/home). NFS-12: a fresh
   editor's Load restores `/f.txt` and `/g.txt` with their contents. Load adds on top,
   as rows.c:559 with `initing=FALSE` does, so the count is before+3 (the dump also holds
   the scratch window). NFS-13: a missing dump and a truncated dump both warn and add no
   window.

### Gates

| Gate | Result |
|------|--------|
| `zig fmt --check src build.zig tools` | clean |
| `zig build` | ok |
| `zig build test --summary all` | 24/24 steps; **817 tests, 802 pass, 15 skip, 0 fail** (stage one: 811 / 792 / 16 / 3). NFS-10b is no longer a skip. New: Replace, HostTree, hostfs root, NFS-11..13 |
| `node tools/smoke_wasm.mjs` | 40 pass, 0 fail |
| `zig build native` | ok |
| 2 s `snarf-native` launch | alive at 2 s; bundled devdraw child spawned; both killed by recorded PID; nothing left running. Normal `$HOME`; no `acme.dump` and no `.snarf-put.*` created. The launch only reads `/`. |

### Deviations / notes

- The origin's `fs/` export now has the atomic Put too: the Q5 tests drive it through
  `tools/origin/tree.zig`, and the contract puts atomicity "inside hostfs". The browser
  wasm and `src/dev`/`src/shim` are untouched. A stale comment path in
  `src/dev/opfs.zig:37` (`tools/origin/hostfs.zig`) is left as-is because `src/dev` is
  frozen for this phase.
- Commit split: the module move and the atomic Put are one commit, because the Q5 code
  lives in the moved files.

## Gate (sonnet, 2026-10-26)

**Verdict: PASS WITH NOTES.** Everything reproduced fresh in the worktree; the notes are
accepted-risk documentation items, not contract failures.

| Check | Result |
|-------|--------|
| Tree clean; forbidden files | clean. Diff vs merge-base touches none of HANDOFF/NEXT-PHASES/FROZEN-*/`select.zig`/`web/`/`src/shim` (a HANDOFF delta against `origin/main` tip is main moving, not this branch) |
| `src/core`, `src/ninep` vs hostfs | `grep -rn hostfs src/core src/ninep` empty; build.zig gives `hostfs` only to native/origin/accept/test roots (lines 78-266) |
| TDD integrity | `git diff b3fb3e0..HEAD` on `accept_hostfs.zig` + `hostfs_native_test.zig`: TmpFs to HostTree swap with no assertion edits; `Rig.busy` widened; NFS-10b rewritten per the documented ruling (xfail machinery removed); NFS-11..13 added. No undocumented weakening found. Q5-a/b/c/d tests unchanged since the test stage |
| `zig fmt --check src build.zig tools` | clean |
| `zig build` | ok |
| `zig build test --summary all` | 24/24 steps; **817 tests, 802 pass, 15 skip, 0 fail** (matches report); origin acceptance suite included and green |
| `node tools/smoke_wasm.mjs` | 40 pass / 0 fail |
| `zig build native` | ok |
| 2 s launch | alive at 2 s, devdraw child present, killed by my recorded PID, child gone |
| Docs | S-02 revision entry (root mount, Larry 2026-10-26, `/mnt/host` alias) and §4 note accurate; S-07 §4/§6 list `src/hostfs/` accurately |

### Behavioral probes (throwaway tests, reverted, nothing committed)
- **Editor-level Put on real HostTree:** content exact, mode 0751 preserved, directory listing only `m.txt` (no temp siblings).
- **Silent-rename-failure window (dir made 0555 after OTRUNC open + write, before clunk):** Tclunk returns Rclunk (success); old file content stays ("old\n"); **the temp `.f.txt.snarf-put.0` is LEFT BEHIND**, because the cleanup `deleteFile` fails in the same locked directory. So the user loses the Put silently AND gets litter, which is worse than the report states ("deletes the temp"). Can the framework return Rerror for Tclunk? **No**: `Ops.clunk` is `void` (`src/ninep/server.zig:97`) and `clunkFid` always replies `.rclunk` (`src/ninep/server_mut.zig:178-185`). ACCEPTED RISK; window is narrow (dir perms must change mid-Put).
- **Symlink:** Put to `link.txt -> real.txt` writes through: `real.txt` has new bytes, `link.txt` is still a symlink. Matches acme/plan9port; no divergence.
- **`..` paths:** `/a/../f.txt` and `/../../f.txt` clean to `/f.txt`; `/../etc/passwd` cleans to `/etc/passwd` and, with a tmp root, simply does not exist there (no escape). `HostTree` pins `..` at the export root.

### Freeze-adjacent note (for the orchestrator)
The origin server's `fs/` export now has atomic Put via shared `Replace` (`tools/origin/tree.zig` new `host_put` variant). Origin acceptance tests pass. Browser wasm and `src/dev`/`src/shim` untouched. Orchestrator to accept or reject this behavior change.

### Discrepancies
1. Report claims "A failed rename at clunk deletes the temp"; true only when the delete itself can succeed (see dirlock probe: litter remains).
2. `tools/origin/tree.zig` grew 401 to 430 lines (over the ~400 soft cap, justified in the report as the new variant's arms only).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## Orchestrator verify (fable, 2026-10-26)

Accepted the gate's PASS WITH NOTES and closed its one real finding:

- **Dirlock fix applied** (`Replace.end` + `copyInPlace`): a rename that fails at
  clunk no longer loses the Put silently — the temp's bytes are streamed over the
  original in place (non-atomic, but saved; the file is usually still writable
  when only the directory is locked). Temp delete stays best-effort; in a locked
  directory a `.name.snarf-put.N` file can linger — accepted, documented in the
  code. Regression test `Q5-e` (dirlock mid-Put → content saved) is red without
  the fix, green with it. Residual silent-loss window: rename AND in-place copy
  both fail (e.g. file also unwritable) — accepted; the 9P framework cannot
  return Rerror for Tclunk (server.zig:97, server_mut.zig:178-185).
- **Freeze-adjacent change accepted**: the origin server's `fs/` export shares
  `Replace` and gains atomic Put. It is a robustness change to shared host-side
  code, not a browser feature; origin acceptance tests green (same reasoning as
  the shared-core palette default under ADR-0005's freeze).
- Final gates after the fix: 818 tests / 803 pass / 15 skip / 0 fail ·
  fmt clean · smoke 40/40 · wasm + native build clean.
