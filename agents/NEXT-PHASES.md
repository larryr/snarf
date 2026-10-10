# Recommended next phases (proposal for Larry, 2026-09-14, revised 2026-10-03 — after phases
12b–16; `main` = `f51e4a0`)

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
   `fs/`'s directory with output streamed. This is the paper's whole coupling story. When this
   ADR gets written, add one sentence on trust-by-origin-locality ("a loopback/in-process
   origin may be configured as fully trusted") so the parked webview-shell idea below doesn't
   later force a rewrite — its whole premise is that the allow-list question collapses for a
   local origin.
3. **Zerox, Sort, Exit, Kill** — the remaining builtins (Zerox needs multi-Text-per-File;
   Sort is trivial; Exit needs Dump).

## Tier 2 — the native host becomes the daily editor (ADR-0005 phase 2)

4. **Native file server**: the host file system as a 9P tree at `/` (or `/n/local`) in the
   native host — `tools/origin/hostfs.zig` already is that server; run it in-process. Then Put/
   Get work on real files natively with no origin.
5. **Native process service**: `/bin` union member backed by `std.process.Child` with the
   paper's semantics (`dir/+Errors`, stdin `/dev/null`); `win` (OQ-EDIT-3) becomes possible
   here. Plumber (OQ-EDIT-2) fits the same host.
6. **Native polish**: `Conn` reader on `std.Io` when 0.16's threading stabilizes; `/dev/snarf`
   wired to the editor's snarf buffer (ADR-0005 "still open"); window title; `-b` flag.
   (`Kdown` translation shipped in 16b — removed from this list.)

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
    Sub-item: a **headless scripted driver** for the native host (`src/host/frame/
    headless.zig` or similar — not rhun-specific despite the name's origin; ~150 lines,
    platform-free) reading `key`/`click`/`move`/`resize`/`shot`/`hash` commands over
    `DevInput.push*` + `HeadlessBackend`, giving `zig build native` the same scripted UI
    tests the browser gets from `smoke_wasm.mjs`, with zero windowing — runs in CI as-is.
12. **Size**: `zig build small` artifact (16d) → decide the deploy mode when a remote deploy
    exists; ReleaseSafe panic-path audit if it matters.
13. **Spec/requirement hygiene**: fold the HANDOFF design notes (touch warp semantics,
    hybrid tablets) into R-05 v3 / S-04; R-02 v7 collapsing the browser-host notes into a
    per-host table; retire OQs answered by ADR-0005.

## Parked — rhun spike, 2026-10-03 (see `agents/reports/spike-rhun-self-drawn-frame.md`)

A feasibility spike (comparing the [rhun](https://github.com/vshvedov/rhun) self-drawn-frame
display-server model against devdraw) surfaced three ideas beyond the tiers above. None is
architecturally significant (none touch `core`/`draw`/`ninep`'s boundary; the two-hosts-one-
core shape of ADR-0005 is unchanged either way), so Tier 1 runs first, unchanged, and these
wait. Each line below carries the decision it is gated on, so picking one back up is a
decision, not a re-read of the spike report.

- **Pointer Lock spike** (browser-host mouse warping, R-EDIT-25/R-IN-10). Gated on: nothing
  further — the Esc/Pointer-Lock conflict is resolved in principle (don't rebind Esc; treat
  unrequested Pointer-Lock-loss, guarded by `document.hasFocus()`, as the Esc signal; don't
  forward Esc as `Kesc` while locked — see `notes/claude/phase-review-2026-10-03.md`
  Decision 2). Still needs: a timeboxed prototype in both Safari and Chromium before
  promising anything (Safari has no Keyboard Lock fallback and its Pointer Lock banner/
  re-lock behavior differs from Chromium's).
- **devdraw built in-tree** (spike Addendum A; removes the plan9port install requirement,
  ~570 KiB / ~240 files from the pinned `larryr/plan9port@337c6ac`, built as an unmodified
  sibling executable, never linked). Gated on: a Larry decision between fetching the pinned
  source as a `.lazy` `build.zig.zon` dependency vs. vendoring it into `third_party/`
  (license note either way — plan9port is mixed MIT/LPL); this is the **first ADR-0002
  amendment**, narrowly worded to "the pinned reference implementation, used solely to build
  the `devdraw` peer executable; nothing from it is linked into snarf," plus a small
  ADR-0005 §3 wording tweak ("not a build dependency" → "may be built from the pinned source,
  never linked") and an R-BLD-02 note scoping new per-OS header prerequisites (macOS SDK /
  X11 dev headers) to `zig build native` only, not the default build.
- **Webview shell** (ADR-0005 option 2, revisited after phases 11–12 built the origin
  bridges it would need). A Zig shell over the system webview (`WKWebView`/WebKitGTK/
  WebView2) pointed at an in-process origin server — keeps real warp via a 9P bridge, unlike
  the browser host. Gated on: Tier 2 items 4+5 existing first (it is "those servers plus a
  webview," cheaper to build after); the same ADR-0002 "OS frameworks are the platform, not
  dependencies" clarification the native frame idea would also need; no wave proposed by
  anyone who has looked at it.
- **Native frame** (TL;DR of the spike itself — a self-drawn native display server, borrowing
  rhun's present/input-loop shape, replacing devdraw entirely). Backlog only, ~30–35% likely
  within a year per the spike's own estimate, lower still once devdraw-in-tree removes its
  main selling point (the install). No wave proposed.

## Suggested order
1 → 2 → 4 → 5 (the editor edits real files, runs real commands, on both hosts), then 3, 7, 8,
11 as filler waves. Each is one pipeline run except 2 (needs the allow-list ADR first — a
one-question decision for you) and 5 (two waves). The parked items above are not in this
order; each needs its own gating decision from Larry before it enters the queue.
