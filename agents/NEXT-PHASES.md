# Recommended next phases (proposal for Larry, 2026-09-14 — after phases 12b–16; `main` = `f51e4a0`)

Where Snarf stands: the paper's editing model is complete in the browser (mouse language,
chords, live tags, undo, Edit, `Look`, `+Errors`, placement, directory windows, B3 file
opening with addresses); the namespace has unions, a synthetic root, `/n/origin` + `/bin`,
`/mnt/snarf-self`, and a writable `/mnt/opfs`; every 9P op is asynchronous end to end; and
the native host runs the unchanged core in a `devdraw` window with real warping (ADR-0005
proven). What is missing is *files in and out* and *commands*.

## Tier 1 — the editor becomes usable for real work

1. **Put / Get / Putall for files** (R-EDIT-15). `Get` for files (the dir half exists), `Put`
   through the namespace with `putseq`/`Undo` tag bookkeeping (wind.c:514-518), `Putall`,
   name-change `Undo`, `Dump`/`Load` to `/mnt/opfs/acme.dump` (R-EDIT-16; `$home` decision
   closes here: `/mnt/opfs` is the browser's home, real `$HOME` natively). Unblocks editing
   the repo through `/n/origin/fs/`. Needs OPFS "one writable per fid" (16b item 4).
2. **External commands via `/bin`** (R-EDIT-06/18/20/21). Executing non-builtin text resolves
   `window dir → /bin` union (12d), writes `exec args` to `<cmd>/ctl`, streams `output` into
   `dir/+Errors`; `|`, `<`, `>` against the selection. Origin side: the built-ins today
   (`echo`, `date`) plus **an allow-list of real host commands — needs the ADR HANDOFF names**
   ("host-command allow-list (ADR)"): `mk`, `grep`, `go`, `zig` run by the origin server in
   `fs/`'s directory with output streamed. This is the paper's whole coupling story.
3. **Zerox, Sort, Exit, Kill** — the remaining builtins (Zerox needs multi-Text-per-File;
   Sort is trivial; Exit needs Dump).

## Tier 2 — the native host becomes the daily editor (ADR-0005 phase 2)

4. **Native file server**: the host file system as a 9P tree at `/` (or `/n/local`) in the
   native host — `tools/origin/hostfs.zig` already is that server; run it in-process. Then Put/
   Get work on real files natively with no origin.
5. **Native process service**: `/bin` union member backed by `std.process.Child` with the
   paper's semantics (`dir/+Errors`, stdin `/dev/null`); `win` (OQ-EDIT-3) becomes possible
   here. Plumber (OQ-EDIT-2) fits the same host.
6. **Native polish**: `Conn` reader on `std.Io` when 0.16's threading stabilizes; snarf ↔ OS
   clipboard already via devdraw; `Kdown` translation (16b); window title; `-b` flag.

## Tier 3 — browser host polish

7. **HiDPI 2× font** (R-GFX-05 second half): a 2× bitmap subfont asset + DPR-aware backing
   store; the native host gets it free from devdraw.
8. **Touch profile** (R-IN-06) with the hybrid pointer/focus model (HANDOFF design note,
   OQ-IN-4): last-touch focus, warps become focus moves — the one place the warp is fully
   honorable in a browser.
9. **`/mnt/host`** (File System Access picker, prompt → Rerror) and **`/dev/storage`**.
10. **Worker + SharedArrayBuffer** transport (R-P6-1): moves the module off the main thread;
    prerequisite for OPFS sync access handles and smoother input.

## Tier 4 — infrastructure

0. **Second structure pass**: sixteen files remain over the ~400-line cap (see the phase 16
   ledger); most are test harnesses declared above the first test — the `*_testsrv.zig`
   pattern from 16a clears them mechanically, hash-guarded, in one wave.


11. **CI** (S-06 §5): the suite + smoke + `zig build native` on push; goldens as the contract.
12. **Size**: `zig build small` artifact (16d) → decide the deploy mode when a remote deploy
    exists; ReleaseSafe panic-path audit if it matters.
13. **Spec/requirement hygiene**: fold the HANDOFF design notes (touch warp semantics,
    hybrid tablets) into R-05 v3 / S-04; R-02 v7 collapsing the browser-host notes into a
    per-host table; retire OQs answered by ADR-0005.

## Suggested order
1 → 2 → 4 → 5 (the editor edits real files, runs real commands, on both hosts), then 3, 7, 8,
11 as filler waves. Each is one pipeline run except 2 (needs the allow-list ADR first — a
one-question decision for you) and 5 (two waves).
