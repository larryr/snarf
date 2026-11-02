# snarfdev1/integration — M0/M1 integration branch

Base: origin/main @ 9a49627 (2026-11-02, after Larry merged #63/#64/#65/#68/#69/#71/#72/#73;
tagged v0.M0-dev.2). One commit (or small series) per issue, reviewed together in one PR.

Order (SnarfProdd, 2026-11-02): #70 → #12+#31 → #13 → #60 (interim ruling: host fs at `/`).
M2 (#21, #14, …) held until Larry reviews.

Gates after each issue: `zig fmt --check src build.zig tools`, `zig build`,
`zig build test --summary all`, `zig build native`, `node tools/smoke_wasm.mjs` (Node 22: 40/0).

## #70 — Put of a NEW file cut off at exit (P1, finishes M0)

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
