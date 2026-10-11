# Recommended next phases (proposal for Larry, 2026-09-14, revised 2026-10-03 after phases
12b–16, revised 2026-10-11 for the ADR-0005 amendment — native primary, browser frozen)

Where Snarf stands: the paper's editing model is complete in the browser (mouse language,
chords, live tags, undo, Edit, `Look`, `+Errors`, placement, directory windows, B3 file
opening with addresses); the namespace has unions, a synthetic root, `/n/origin` + `/bin`,
`/mnt/snarf-self`, and a writable `/mnt/opfs`; every 9P op is asynchronous end to end; the
native host runs the unchanged core in a `devdraw` window with real warping (ADR-0005
proven); and Put/Get/Putall/Dump/Load are shipped (phase 17, browser/origin path).

**Native host is now primary; browser is a frozen secondary** (ADR-0005 amendment, accepted
2026-10-11 — `docs/spec/adr/0005-two-hosts-one-core.md`). Per that amendment's item 1, the
tiers below are reordered: what used to be Tier 2 (native host work) now runs ahead of the
remaining browser-only items from the old Tier 1. Tier 3 (browser polish) is frozen — bug
fixes and structure passes only, no new features, until the amendment is reversed.

## Tier 1 — the native host becomes the daily editor (ADR-0005 phase 2) — runs first

0. **Return-after-`Del` warp (`savemouse`/`restoremouse`, R-EDIT-25)**. Host-agnostic,
   headless-testable through the `MouseSink` `/dev/mouse` stand-in (`src/core/warp.zig`) —
   unblocked, schedulable independent of everything else here. Last unported paper warp site
   (`util.c:384-408`, `cols.c:150/178`). ~40 lines on `Editor`. (Fable Finding 4,
   `notes/claude/roadmap-review-2026-10-10.md`.)
1. **devdraw built in-tree** — **IN PROGRESS, pipeline dispatched 2026-10-11**. ADR-0006
   (`docs/spec/adr/0006-devdraw-fetch-dependency.md`), accepted: fetch the pinned
   `larryr/plan9port@337c6ac` via one `build.zig.zon` entry, build just the `devdraw` closure
   (~240 files, ~570 KiB) unmodified into a sibling `zig-out/bin/devdraw` via a new
   `zig build native` step. `Conn.devdrawPath` resolution order: `$DEVDRAW` → bundled
   (relative to `snarf-native`'s own executable path) → `$PLAN9/bin/devdraw` → bare `devdraw`
   on `$PATH`, with a startup print of which one resolved. Removes the native host's last
   separate-install requirement. macOS only for now (Linux X11 path needs its own file-list
   pass, Addendum A).
2. **Native file server**: the host file system as a 9P tree at `/` (or `/n/local`) in the
   native host — `tools/origin/hostfs.zig` already is that server; run it in-process. Then
   Put/Get/Putall/Dump/Load work on real files natively with no origin — closes native's
   `NotMounted` gap from phase 17.
3. **Native process service**: `/bin` union member backed by `std.process.Child` with the
   paper's semantics (`dir/+Errors`, stdin `/dev/null`); `win` (OQ-EDIT-3) becomes possible
   here. Plumber (OQ-EDIT-2) fits the same host. Pairs with the host-command allow-list below
   (local execution is fully trusted per the 2026-10-11 decision — see item 5 — so this is
   *not* gated on that ADR landing first).
4. **Native polish**: `Conn` reader on `std.Io` when 0.16's threading stabilizes; `/dev/snarf`
   wired to the editor's snarf buffer; window title; `-b` flag.

## Tier 2 — the editor gains commands and remaining builtins (host-agnostic / browser-path)

5. **Host-command allow-list ADR, remote scope only** (R-EDIT-06/18/20/21, R-NG-03). Decided
   2026-10-11: local native commands are fully trusted, run as the logged-in user, no silent
   identity switch (elevation only via user-invoked `sudo`); the allow-list applies only to
   **remote** 9P servers. Under the immutable-ADR convention this is a new ADR, not an
   amendment to an existing one. Needs the R-NG-03/R-EDIT-18 local-vs-remote revision-log line
   on acceptance (ADR-0005 amendment item 4, still pending).
6. **External commands via `/bin`** (origin/browser path): executing non-builtin text resolves
   `window dir → /bin` union (12d), writes `exec args` to `<cmd>/ctl`, streams `output` into
   `dir/+Errors`; `|`, `<`, `>` against the selection. Lower priority now that native's process
   service (Tier 1 #3) is the primary command path; still needed for the frozen browser host
   to keep passing its own tests meaningfully.
7. **Zerox, Sort, Exit, Kill** — the remaining builtins (Zerox needs multi-Text-per-File;
   Sort is trivial; Exit needs Dump; Kill pairs with either process service).

## Tier 3 — browser host polish — **FROZEN** (ADR-0005 amendment item 2: bug fixes and
structure-pass participation only; no new features until the amendment is reversed)

8. HiDPI 2× font (R-GFX-05 second half).
9. Touch profile (R-IN-06) with the hybrid pointer/focus model (HANDOFF design note, OQ-IN-4).
10. `/mnt/host` (File System Access picker) and `/dev/storage`.
11. Worker + SharedArrayBuffer transport (R-P6-1).

## Tier 4 — infrastructure

0. **Second structure pass**: sixteen files remain over the ~400-line cap (see the phase 16
   ledger); most are test harnesses declared above the first test — the `*_testsrv.zig`
   pattern from 16a clears them mechanically, hash-guarded, in one wave.
12. **CI** (S-06 §5): the suite + smoke + `zig build native` on push, including a
    WASM-still-builds check. **A precondition of the browser freeze actually holding**
    (ADR-0005 amendment Risks — "frozen" is unenforceable without it). Sub-item: a
    **headless scripted driver** for the native host (`src/host/frame/headless.zig` or
    similar; ~150 lines, platform-free) reading `key`/`click`/`move`/`resize`/`shot`/`hash`
    commands over `DevInput.push*` + `HeadlessBackend`, giving `zig build native` the same
    scripted UI tests the browser gets from `smoke_wasm.mjs`, with zero windowing — runs in
    CI as-is.
13. **Size**: `zig build small` artifact (16d) → decide the deploy mode when a remote deploy
    exists; ReleaseSafe panic-path audit if it matters.
14. **Spec/requirement hygiene**: fold the HANDOFF design notes (touch warp semantics, hybrid
    tablets) into R-05 v3 / S-04; R-02 v7 collapsing the browser-host notes into a per-host
    table; retire OQs answered by ADR-0005.
15. **`agents/NEXT-PHASES.md` ↔ `docs/product/roadmap.md` M-numbering**: this file's tiers and
    the roadmap's M0-M5 milestones overlap but don't map 1:1 (by design — they coexist, see
    roadmap v0.2's Process rule). Worth a cross-reference pass once Tier 1 lands, not before.

## Parked

- **Pointer Lock spike** (browser-host mouse warping, R-EDIT-25/R-IN-10). **Parked by the
  ADR-0005 amendment** — only relevant again if the browser host un-freezes. Esc/Pointer-Lock
  conflict already resolved in principle if picked back up (see
  `agents/reports/phase-review-2026-10-03.md` Decision 2); still needs a timeboxed Safari +
  Chromium prototype before promising anything.
- **Webview shell** (ADR-0005 option 2). A Zig shell over the system webview
  (`WKWebView`/WebKitGTK/WebView2) pointed at an in-process origin server — keeps real warp
  via a 9P bridge, unlike the browser host. Gated on: Tier 1 items 2+3 existing first (it is
  "those servers plus a webview," cheaper to build after). No wave proposed by anyone who has
  looked at it.
- **Native frame** (self-drawn native display server, replacing `devdraw` entirely — the
  rhun-spike TL;DR). **Deprioritized by the ADR-0005 amendment item 3**: `devdraw` is the
  native rendering/input module indefinitely, not provisionally. Revisit only given a concrete
  forcing reason (e.g. Wayland), not on a timer.
- **Dual Magic Trackpad chord pad** (touchpad D5, roadmap v0.2). Revisit only if multitouch
  clearly adds something a modifier key can't, given the cost of both hands off the keyboard.
- **macOS `.app` packaging**. Deferred (2026-10-11, roadmap v0.2) — `zig-out/bin/devdraw`
  sitting next to `snarf-native` is sufficient for now; Tier 1 item 1's resolution rule
  (bundled devdraw relative to the running executable's own path) is written so a future
  `.app` layout needs no new ADR.

## Suggested order
0 → 1 → 2 → 3 → 4 (native becomes a real daily editor with no install and no origin
dependency), then 5 → 6 → 7 (commands and remaining builtins), then 12 as a parallel-track
filler (CI has no code dependency on the above and should land soon regardless — it's what
makes the browser freeze real). Tier 3 does not run unless the ADR-0005 amendment is
reversed. The Parked items each need their own gating decision from Larry before they enter
the queue.
