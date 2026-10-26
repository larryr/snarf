# Phase 20 — native file save: host fs at `/` (issue #11, the save half and its free riders)

Binding contract (fable, 2026-10-26). Worktree `.worktrees/phase20-native-save`, branch
`phase20-native-save`. Implements GitHub issue #11 ("M1: Native file server") per the
SnarfDev2 test plan `notes/snarfdev2/test-plans/M1-11-native-fs.md` and the PM decisions
recorded in `notes/snarfdev2/test-plans/README.md` §"PM decisions" (Q1, Q5, Q6).

**Decisions already made — do not re-open:**
- **Mount policy (Larry, 2026-10-26, resolves the plan's Q1 TBD): acme-like root.** The
  host file system is served over 9P in-process and mounted at **`/`** in native's
  namespace. Longest-prefix resolve (`ninep/mount.zig:4-6`) keeps `/dev` and
  `/mnt/snarf-self` winning, so the root mount is the fallthrough. `/mnt/host` is ALSO
  mounted as an alias of the same server (S-02 §4 continuity). Tags show bare paths
  (`/Users/larry/notes.txt`); B3 on any absolute path resolves.
- **Atomicity (PM Q5): inside hostfs, not in core.** `Put` stays acme's
  open-OTRUNC/write/clunk; hostfs makes it atomic: an OTRUNC open of an existing file
  writes to a same-directory temp file and renames it over the original on clunk; any
  failure before clunk leaves the old file intact. New files are created
  `0666 & ~umask`. Core `Put.zig` is NOT modified.
- **`$home` (PM Q6 / R-P17-5): the real `$HOME`**, resolved through the root mount
  (`Dump` writes `$HOME/acme.dump`). `main_native.zig:126` already sets
  `editor.session.home` — verify it flows, don't re-plumb.
- **Browser host untouched** (ADR-0005 freeze): no change to `/mnt/opfs`,
  `/mnt/host`-browser, origin, or any `src/shim`/`src/dev` browser path.

## Rulings

- **R-P20-1 — in-process hostfs server on native.** Reuse `tools/origin/hostfs.zig`
  (NEXT-PHASES Tier 2 #4's own words: "reused in-process") following main_native's
  existing pipe/server/client pump pattern (`DevInput9` wiring, `main_native.zig:213+`).
  Expose it to `main_native` as a build-graph module WITHOUT letting `src/core` or
  `src/ninep` import it (S-07 §6; they must stay browser-free AND hostfs-free). Moving
  the file (e.g. to `src/host/`) is allowed if `docs/spec/07-source-layout.md` moves
  with it; either way `snarf-origin` keeps working.
- **R-P20-2 — namespace wiring.** In `main_native.zig`: `HostFs.open(io, "/")`, serve,
  `ns.mount("/", …)` AND `ns.mount("/mnt/host", …)` (same client+root fid). `/dev` and
  `/mnt/snarf-self` mounts unchanged. The boot directory window (`openfile.readFile(…,
  "/")`, `main_native.zig:~238`) now lists the real root — synthetic prefixes (`/dev`,
  `/mnt`) are NOT in that listing (they're ns prefixes, not hostfs entries); accept and
  document this in the as-built report.
- **R-P20-3 — hostfs grows what Q5 needs, nothing more.** Temp-file + rename-on-clunk
  for OTRUNC writes (and plain create for new files). Extend the FILE-LEVEL tests in
  `tools/origin/hostfs_native_test.zig`'s style for: atomic replace observed (old
  content readable until clunk), failure-before-clunk keeps old file, temp file cleaned
  up, create mode. Do not add rename-as-user-API/Twstat beyond what the atomic path
  needs.
- **R-P20-4 — spec paper trail.** `docs/spec/02-namespaces.md`: revision-log entry +
  §4 note — native root = host file system (decided 2026-10-26, Larry), `/mnt/host`
  alias kept, browser semantics unchanged. `docs/spec/07-source-layout.md` only if a
  file moves. No ADR: this implements S-02's existing native clause plus a recorded
  product decision; the mount-at-root choice is captured here and in the S-02 note.
- **R-P20-5 — scope.** IN: everything needed for NFS-01..10, 14, 16, 17 (below) plus
  the Q5 file-level tests. Dump/Load session tests (NFS-11..13) are IN only if they
  pass with zero extra plumbing once `$home` resolves; if they need real work, mark
  the tests `error.SkipZigTest` with a `// phase 20 deferred:` comment and list it in
  the report — do not silently grow the phase. NFS-15 (escape paths): with the mount
  rooted at the REAL `/`, there is no sub-root to escape; the test instead pins that
  `..` is cleaned by `openfile.cleanName` and never panics. NFS-18 is Larry's manual
  checklist — out.
- **R-P20-6 — TDD order is binding.** The TEST agent lands the editor-level tests
  FIRST, in their own commit, each failing for the RIGHT reason against today's main
  (e.g. `error.NotMounted`) — the failure mode per test goes in a table in the as-built
  report. The IMPLEMENTATION agent then makes them pass without editing the tests
  (test edits after that point need an orchestrator-visible justification in the
  report; "the test was wrong about the contract" is valid, "inconvenient" is not).
- **R-P20-7 — the test matrix** (editor-level unless marked file-level; new file
  `src/accept_hostfs.zig` pulled into the accept root the way `accept_colors.zig` is;
  harness = headless boot + `ninep.mount.Namespace` with an in-process hostfs rooted at
  a `std.testing.tmpDir`, mounted at `/` — so `/f.txt` is `tmp/f.txt`; never any real
  `$HOME`/filesystem writes outside tmp):

  | ID | Scenario | Expected |
  |----|----------|----------|
  | NFS-01 | boot ns with root mount | `/dev/...` and `/mnt/snarf-self/...` still resolve (longest prefix); `/f.txt` resolves into tmp |
  | NFS-02 | B3/open absolute path of existing file | window opens, content byte-exact (UTF-8 multibyte; no trailing NL; CRLF preserved as bytes) |
  | NFS-03 | open a directory path | dirwin listing with `/` suffix on subdirs |
  | NFS-04 | open nonexistent path | error surfaces (per look/openfile contract), no window pretending success, no crash |
  | NFS-05 | edit window named `/f.txt`, execute Put | tmp file bytes == buffer; window clean (dirty-button off); `putseq` advanced |
  | NFS-06 | undo after Put | undo reverts the buffer; window dirty again; disk file still holds the Put'ed content |
  | NFS-07 | change file on disk, execute Get | buffer reloads disk content; Get on a DIRTY window follows the two-strike warning (first Get warns, second loads — R-P17-8 as already implemented) |
  | NFS-08 | Putall with 2 dirty + 1 clean window | exactly the 2 dirty files written; the clean file's bytes (and mtime if cheaply observable) untouched |
  | NFS-09 | Put to a NEW path (setName to unseen `/new.txt`) | file created, content exact, mode `0666 & ~umask` |
  | NFS-10 | Put onto a read-only file (chmod 0444 in tmp) | 9P error surfaces in `+Errors`; window STAYS dirty; original file bytes intact (atomicity); no temp litter |
  | NFS-14 | `/mnt/snarf-self` ctl `put` verb | same disk effect as tag Put (phase 17 ctl path over the new mount) |
  | NFS-16 | open a 5 MB generated file | loads without pathological time (assert < 5 s wall as a smoke bound, generous for CI) |
  | NFS-17 | `tools/origin` acceptance suite | still green (run as part of the normal gates — no browser-path change) |
  | Q5-a/b/c/d (file-level) | atomic replace / failure keeps old / temp cleanup / create mode | per R-P20-3 |

- **R-P20-8 — gates** (all green at phase end, in the worktree): `zig fmt --check src
  build.zig` · `zig build` · `zig build test --summary all` 0 fail · `node
  tools/smoke_wasm.mjs` 40/40 · `zig build native` · a 2s `snarf-native` launch (alive,
  devdraw child, killed by recorded PID) · file caps (~400 soft; new files comfortably
  under; files already over may not grow by more than the feature demands) · no edits
  to `agents/HANDOFF.md`, `agents/NEXT-PHASES.md`, goldens (FROZEN-*), `select.zig`,
  or anything under `web/`/`src/shim`.
- **R-P20-9 — citations.** Acme behavior claims cite the pinned C (`exec.c` putfile
  :697-836, `look.c`, `acme.c`); namespace claims cite S-02 §/line. When the C and a PM
  decision conflict (atomic Put), the PM decision wins and the divergence is a
  DIVERGENCE comment citing this contract.

## Acceptance

Commits in TDD order (tests → feature → docs), as-built report
`agents/reports/phase20-native-save.md` (failure-mode table from R-P20-6, gate
transcript, deviations, deferred list), every commit message ending exactly:

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

No pushes, no PRs — the orchestrator reviews, then the independent gate runs.
