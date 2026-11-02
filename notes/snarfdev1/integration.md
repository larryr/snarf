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
  after Put takes a strike.
- ctl verbs `sort`, `kill <names>`, `exit` (port names; acme has none).

## #13 part 2 — Zerox (Fixes #13)

Commit `2d686d1` (pushed, gates green: 939/940, 1 skipped; smoke 40/0). `File.texts`
(f->text[]) with addText/delText; the last view frees an owned File. Fan-out at every acme
ntext>1 site, guarded by `File.shared()`: insert/delete (text.c:381/477), Undo/Redo
(wind.c:355-372), settag/setname (wind.c:393/577), Del (exec.c:408), Put commit
(exec.c:807), Get dir refusal + dirty (exec.c:614/647), Edit's settag (edit.c:134).
Zerox builtin (exec.c:540-577) + ctl `zerox`. Divergences: Dump writes each Zerox view as
its own window (acme's `x` records, rows.c:371-415/727-758, not ported); Edit `D` is not
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
even while snarf's own connection is open; Plan 9 would list `new` and `1/`. Not changed.

## #77 — --help / --version (Fixes #77)

Commit `296162f` (gates green: 964/966; smoke 40/0). `native_args.infoFlag` (flags only;
`-h` = `--help`); handled before devdraw lookup/spawn; stdout, exit 0. Version =
`-Dversion=` or `git describe --tags --always --dirty` at build time ("unknown" outside a
checkout), via a `native_options` build module. release.yml unchanged.

## #78 — non-runnable bundled devdraw (Fixes #78)

Commit `899d2fa` (gates green: 965/967; smoke 40/0). `DevdrawPath.Probe` returns a
`Verdict`; a bundled/`$PLAN9` candidate that exists but isn't a runnable regular file is
recorded in `skipped` and logged (`snarf: devdraw: skipping <path> (<source>): <reason>`),
then lookup falls through. Checked by hand with a 0644 `devdraw` beside the binary.
