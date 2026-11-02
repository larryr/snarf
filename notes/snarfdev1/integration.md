# snarfdev1/integration — M0/M1 integration branch

Base: origin/main @ 9a49627 (2026-11-02, after Larry merged #63/#64/#65/#68/#69/#71/#72/#73;
tagged v0.M0-dev.2). One commit (or small series) per issue, reviewed together in one PR.

Order (SnarfProdd, updated 2026-11-02): #70 → #12+#31 → #13 → snarf rename fix → command-line
file arguments → #60 (interim ruling: host fs at `/`; was on hold earlier the same day).
M2 (#21, #14, …) held until Larry reviews. Next batch (not here): #77 (--help/--version
without devdraw), #78 (skip a non-executable bundled devdraw, ruling in
notes/snarfprod/decisions/README.md @ 1e6e1cc), #79 check during #60.

Gates after each issue: `zig fmt --check src build.zig tools`, `zig build`,
`zig build test --summary all`, `zig build native`, `node tools/smoke_wasm.mjs` (Node 22: 40/0).

## #70 — Put of a NEW file cut off at exit (P1, finishes M0)

Commit `3b73116` (pushed, gates green: 897/906, 9 skipped; smoke 40/0). Fixes #70.

#73 did not touch the Tcreate path (checked). Fix in `src/hostfs`:
- `Replace.beginNew`: Tcreate = exclusive create of an empty placeholder (reserves the name,
  keeps `file already exists`, mode `0666 & ~umask`) + the same temp-and-rename Put as an
  existing file. `HostTree.create` now gives the fid a `Replace`, so the cut-off path
  (`keepPartial`) reports it and saves the recovery file.
- Discard (exit or failed write) of a created Put deletes the placeholder if still empty →
  no file under the real name.
- Stray temp (directory read-only mid-Put; rename and delete refused): truncated to 0 bytes,
  remembered in `HostTree.strays`, delete retried after every later Put and at endSession.
  Silent (no third stderr line) — see open question.
- Wording: identical two lines to the existing-file case ("file left unchanged"), per the
  ruling "handled the same way … both notice lines print". Open question below.
- Not changed: `tools/origin/tree.zig` (frozen secondary; no exit-discard path there).

Tests: 8 new in `src/hostfs/recovery_test.zig` (#70: …); SnarfDev2's
`create_put_notice_fixed` flipped to true. Mutations checked: dropping the placeholder
removal → 10 failures; dropping the sweep → stray test fails.

Open product questions (for SnarfProdd):
1. First line for a NEW file: keep "file left unchanged" (as now) or a variant such as
   "file not created"?
2. A stray temp that still can't be removed at exit: stay silent (as now) or print a third
   line naming it?

## #12 + #31 — native system clipboard via /dev/snarf

Commit `17b8d16` (pushed, gates green: 911/917, 6 skipped; smoke 40/0). Fixes #31, Refs #12
(test-plan step 22 needs a real Mac run).
- `core/clipboard.zig`: `put` (acmeputsnarf: OWRITE|OTRUNC, ioMax chunks, stop at NUL, skip
  empty) after Snarf/Cut; `get` (acmegetsnarf: read to EOF, 64 MB cap, stop at NUL, invalid
  UTF-8 → U+FFFD, replace the internal buffer only when non-empty) before Paste.
- `dev_input.zig`: /dev/snarf buffers writes until clunk → one Twrsnarf per Snarf.
- Tests: 2 unit + 6 end-to-end in `src/main_native_clipboard_test.zig` (FakeDevdraw
  pasteboard). Mutations: no get → 3 failures; no put → 4.
- FLAG for SnarfDev2: buffer-until-clunk broke CB-03/06/08 as written (they expected a
  write-through); adapted minimally in `clipboard_test.zig`.

## fix — the native binary is `snarf` (Larry 2026-11-02; scope by SnarfProdd)

Commit `3e40341` (pushed, gates green: 911/917; smoke 40/0). build.zig artifact `snarf`
(wasm keeps `snarf` too: zig-out/www/snarf.wasm vs zig-out/bin/snarf, no collision, wasm
outputs unchanged); release tarballs ship `snarf` (+ devdraw on macOS) with a tarball
content check; ci.yml tests zig-out/bin/snarf; Makefile install without the mv (uninstall
still removes a stale snarf-native); README/CLAUDE.md/roadmap say snarf. Bundled devdraw
lookup is by executable directory, name-independent (checked: "(bundled)"). macOS devdraw
placement is verified by CI only (devdraw does not build on Linux).

## #13 — Sort, Kill, Exit (+ ctl verbs); Zerox pending

Commit `a465ea7` (pushed, gates green: 925/928, 3 skipped = the Zerox tests; smoke 40/0).
Refs #13 (Zerox still to come).
- Sort: `core/colsort.zig` (cols.c:293-331), colcmp = byte order on UTF-8 names, stable.
- Kill: each name → "Kill: no process <name>" (no external commands yet, #17).
- Exit: rowclean → `Editor.exit_requested`; native loop `running()` stops once Exit is
  accepted and no Put/Dump is in flight (acme's are synchronous), then the #58/#68
  shutdown. Divergence: async Put leaves the window dirty until commit, so Exit right
  after Put takes a strike. **Superseded by `aecb0bd`** (Exit waits for the Put; PR #74 Q4).
- ctl verbs `sort`, `kill <names>`, `exit` (port names; acme has none). **Removed in
  `05db334`** (PR #74 Q3: ctl keeps acme's set only).

## #13 part 2 — Zerox (Fixes #13)

Commit `2d686d1` (pushed, gates green: 939/940, 1 skipped; smoke 40/0). `File.texts`
(f->text[]) with addText/delText; the last view frees an owned File. Fan-out at every acme
ntext>1 site, guarded by `File.shared()`: insert/delete (text.c:381/477), Undo/Redo
(wind.c:355-372), settag/setname (wind.c:393/577), Del (exec.c:408), Put commit
(exec.c:807), Get dir refusal + dirty (exec.c:614/647), Edit's settag (edit.c:134).
Zerox builtin (exec.c:540-577) + ctl `zerox` (ctl verb removed in `05db334`). Divergences: Dump writes each Zerox view as
its own window (acme's `x` records, rows.c:371-415/727-758, not ported; filed as #81); Edit `D` is not
implemented, so its ntext>1 arm (ecmd.c:236) is moot; no autoindent in v1. The commit
message's last paragraph lost a line in an amend after the push (only "dump has no zerox
record either way in the port yet)." is left); the correct text is here. I didn't
force-push to fix it.

## Command-line file arguments (SnarfProdd P1 ruling; issue not filed yet)

Commit `c1d13ea` (pushed, gates green: 932/935, 3 skipped; smoke 40/0). acme.c:241-266 +
readfile: a window per named file/dir (WPERCOL 8 per column, guide → last column), a
missing file → empty named window (+ acme's "can't open" line in +Errors), relative names
rooted at the process cwd; ARGBEGIN split (flags end at first non-flag or `--`).

## #60 — union directories at native `/` (Fixes #60)

Commit `7a2d7fe` (pushed, gates green: 963/965, 2 skipped = UD-22 root-only + 1 existing;
smoke 40/0), on top of SnarfDev2's UD suite from PR #75 cherry-picked as `a61b4f8` and
`9263591`; `union_dir_landed = true`. Per the SnarfProdd rulings of 2026-11-02:
- `nsdir.shadowFall`: a name under the `/dev` mount that snarf doesn't serve falls through to
  the host at `/` (snarf's members first → snarf wins a collision; host kbd/mouse only via
  `/mnt/host`). Not for `/dev/draw` (no nested union) or any other prefix.
- `nsdir.dedupScope`: exactly `/`, `/dev`, `/mnt` (the ruling's list, `shadow_dirs`), only
  while the host is at `/`. Other unions keep R-9P-03 (UD-18). DirReader and ListDirJob both
  dedup (R-P13a-2); windows keep dircmp order.
- Create in a shadowed folder → host (`WalkJob.initPreferHost` for the parent walk).
- hostfs: device nodes/fifos/sockets listed + stat-able with host permission bits; open →
  new `OpError.NotSupported` ("not supported"). Load's "can't open" prints the wire string.
- `Client.lastErrorString` now keeps every Rerror's text (was error.Other only).
- ListDirJob: nothing read + a member failure other than "does not exist" → that error, so
  B3 on an unreadable host dir warns (UD-16). `DirReader` still skips silently (raw 9P).
- S-02 (docs/spec/02-namespaces.md) phase-20 revision-log line corrected + a #60 entry.

**#79 check** (draw connection under `/dev/draw/`): not a listing/union problem. The native
`/dev/draw` server (`src/host/devdraw/dev_draw.zig:233`) returns 0 bytes for every directory
read (`.root, .conn => return 0`), although walk resolves `new` and the live connection
directory (`isConnName`, = the editor's own connection). So B3 on `/dev/draw/` is empty
even while snarf's own connection is open; Plan 9 would list `new` and `1/`. Fixed in
`e663a00` (PR #74 Q6).

## #77 — --help / --version (Fixes #77)

Commit `296162f` (gates green: 964/966; smoke 40/0). `native_args.infoFlag` (flags only;
`-h` = `--help`); handled before devdraw lookup/spawn; stdout, exit 0. Version =
`-Dversion=` or (until `690827d`, PR #74 Q8) `git describe --tags --always --dirty` at build time ("unknown" outside a
checkout), via a `native_options` build module. release.yml unchanged.

## #78 — non-runnable bundled devdraw (Fixes #78)

Commit `899d2fa` (gates green: 965/967; smoke 40/0). `DevdrawPath.Probe` returns a
`Verdict`; a bundled/`$PLAN9` candidate that exists but isn't a runnable regular file is
recorded in `skipped` and logged (`snarf: devdraw: skipping <path> (<source>): <reason>`),
then lookup falls through. Checked by hand with a 0644 `devdraw` beside the binary.

## PR #74 rulings (SnarfProdd, issuecomment-6576974694)

Small commits on top, no force-push; the 2d686d1 message stays as is (ruling).
- Q1 `0229e08` (Refs #70): a cut-off Put of a NEW file says `file not created`
  (`HostTree.keepPartial`, `Replace.created`); an existing file still says `file left unchanged`.
- Q2 `632f7bc` (Refs #70): `HostTree.reportStrays` after `sweepStrays` prints
  `snarf: could not remove temp file /<ns path>` per leftover (namespace path = realpath
  minus the export root). New recovery test; three expectations gained the line, one in
  SnarfDev2's `recovery_snarfdev2_test.zig` (`expectTmpFallbackToSlashTmp`), flagged to them.
- Q3 `05db334` (Refs #13): ctl verbs sort/kill/exit/zerox and their handlers removed; one test
  checks all four are "ill-formed control message". Tag/B2 commands unchanged. SnarfDev2's
  plan `M1-13-builtins.md` BI-12 still lists them (theirs to update).
- Q4 `aecb0bd` (Refs #13): Exit during a Put/Dump waits (`Editor.exit_waiting`), then
  `cmd_session.exitStep` runs rowclean from `frameEnd`; a second Exit while waiting sets
  `exit_now` → loop stops → #58/#68 shutdown. Tests: wait-then-clean (one Exit), dirty after
  the wait → strike, second Exit cuts a 1 MiB Put mid-write.
- Q5: filed #81 (P3, M2, type:feature); not implemented. `8cd24a3` points RowDump's header at it.
- Q6 `e663a00` (Fixes #79): `/dev/draw` dir reads list `new` + the conn folder, and
  ctl/data/refresh inside it; whole stat records per read, BadOffset inside a record.
  statOp's conn name no longer points at a dead stack buffer.
- Q7: no change.
- Q8 `690827d` (Refs #77): `build/version.zig` — `<latest tag> (<short hash>[-dirty])`, or the
  tag alone for a clean build exactly at a non-`-dev` tag; `untagged (<hash>)` with no tag.
  `-Dversion=` still wins.
- Gates after `8cd24a3`: fmt ok, build 0, tests 969/971 (2 skipped), native 0, smoke 40/0.

## #82 + #84 — file-argument follow-ups (SnarfProdd 8:12 AM, one mergeable branch)

Work was done in the worktree `/workspace/snarfdev1-wt-integration`. `/workspace/snarfdev1`
is on snarfdev1/load-typing and may be in use elsewhere. Gates script: `~/snarf-gates.sh`.
- #82 `01621fb` (Fixes #82): `main_native.boot` runs each file argument's load to the end
  (`loadNow`: Load.stepAll plus the draw, self and host-fs polls until `ed.loads` is empty)
  before the next `readFile`. This is acme's synchronous `textload` in readfile
  (acme.c:292-304). The next coladd's shrink (cols.c:117, Column.zig:162) then sees the
  loaded nlines, not 0. Load.stepAll is untouched because #85 changes it. Red before: a
  2-line file had nlines 0. Side effect: a huge file argument holds the first draw until
  it is loaded, as acme does.
- #84 `aac4ebe` (Fixes #84): boot takes `cwd` and the args as typed. `openfile.readFileAs`
  and `Load.startAs` carry the typed name (`Load.shown`) for the warnings (acme.c:299
  passes `s`). `Load.errstr` maps NotFound/NotMounted to "file does not exist" and the
  other namespace/transport errors to Plan 9 kernel text. `Rig.bootIn(cwd, files)` is new.
  Red before: the `/sub/../new.txt` expectation and the errstr test.
- `git merge-tree --write-tree origin/snarfdev1/load-typing HEAD` is clean (exit 0). The
  merged tree builds and tests 976/978 (2 skipped).
- Gates after `aac4ebe`: fmt ok, build 0, tests 972/974 (2 skipped), native 0, smoke 40/0.

## SnarfDev2 review round (8:51 AM)

- #74 (issuecomment-6578852205) `bd67076` (Refs #84): `cwd` was typed `[]u8`, which
  dropped currentPathAlloc's sentinel, so DebugAllocator reported a size mismatch at every
  exit with file arguments. Now `main_native.ArgsDir { path: [:0]u8 }` (dupeZ "/" when there
  are no args) with init/deinit. Test under std.testing.allocator plus a source pin. The
  mutation `path: []u8` is killed (Invalid free). exe_path, Replace.target and
  HostTree.reportStrays checked: all keep [:0]u8.
- #85 (issuecomment-6578851752) `d64dabf` on snarfdev1/load-typing, pushed from a detached
  worktree `/workspace/snarfdev1-wt-load-typing` because `/workspace/snarfdev1` holds the
  branch. hold() merges only a bare move (no buttons, and the previous queued mouse sample
  had none). Tests: B1 click + move, B2 Newcol + move, B1 drag, release kept. All are red
  with the old hold(). The mutation "merge moves while a button is held" is killed by the
  drag test.
- Not folded together yet (SnarfDev2 re-passes #85 first).
