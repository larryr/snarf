# Session handoff — shared memory between agent sessions

Protocol: see `CLAUDE.md` §"Session handoff protocol". Read top-to-bottom; newest session
entry first. Any session may edit; commit to `main` with prefix `handoff:` (standing
authorization for this file only). Prune freely — git keeps history.

## ⚠ In-flight claims (check before touching these areas)

- *(none as of 2026-09-14 — phase 14a merged `afff8ac`; remote has only `main`)*
- *(phase 12b merged `96d7cb5` 2026-09-13; worktree removed)*

## Current state (update in place)

- **Phases 1–12, 12b–12e, 13a, 13b, 14a are MERGED to `main`; `main` is green.**
  639/639 tests (≈3.6 s), node smoke 30/30, `zig fmt` clean, Zig 0.16.0, **ABI v5**, wasm
  ≈ 2089 KiB ReleaseSafe (user keeps ReleaseSafe; size is a debt-pass item).
- **Phase 14a MERGED (`afff8ac`, 2026-09-14)** — see agents/reports/phase14a-server-parking-create.md:
  ANY `Ops` fn may return `park.WouldBlock` (NEW `ninep/park.zig`, raw-frame FIFO, bound 64,
  `retryParked`; `completeReads(path)` alias kept — `dev/input`/`fsys`/`origin` unchanged);
  Tcreate/Tremove/Twstat codec (`msg_mut.zig`) + handlers (`server_mut.zig`, lib9p default
  strings); `Client.create/remove/wstat`; `server.zig` 780→450 (harness → `testsrv.zig`,
  test-only). **Phase-1 R5 LIFTED.** Debt: `client.zig` 637, `msg.zig` 476 pre-test.
- **Phase 13b MERGED (`fd1abe0`, 2026-09-14) — DIRECTORY WINDOWS** — see
  agents/reports/phase13b-directory-windows.md and REVIEW-NOTES: acme boot (2 columns, `/`
  rightmost, scratch demo gone), `dirwin` (dircmp/columnate/TABDIR), `Load` (async textload),
  `openfile`, `expand` (expandfile + PARKED look — R-P13b-2 async existence check), `Get` for
  dirs, `isdir` tag/ctl, `/mnt/snarf-self/ns`, FROZEN-ACCEPT-13B. R-EDIT-03 DONE. Debt:
  `Window.zig` 559 / `Editor.zig` 414 / `expand.zig` 402 pre-test lines; normal-window
  `maxtab` 72 vs acme 36 (textinit never ported; moves FROZEN-ACCEPT-3); `applyAddress`
  parses the whole `:addr` run; `expandFile` lacks `reverse`.
- **Phase 13a MERGED (2026-09-14)** — see agents/reports/phase13a-async-namespace.md:
  generic async 9P tickets with TOMBSTONES (`ninep/tickets.zig`; `client.zig` 585 lines),
  namespace jobs (`ninep/nsjob.zig` Walk + `ninep/nsio.zig` Stat/ReadFile/ListDir, `runSync`
  + `Pumps` — pump EVERY reachable server or a union wedges), `Editor.ns` handle, and a REAL
  boot namespace (`src/ns_boot.zig`: `/dev`, `/dev/draw`, `/mnt/snarf-self` served at runtime
  — R-P10-E RETIRED; `/dev` + `/dev/draw` reachable via jobs ONLY). GAPS CLOSED: "no async
  ticket for walk/open/clunk" and "Editor has no namespace handle". `/mnt/snarf-self/ns`
  deferred to 13b (SEAM(ns) in fsys.zig). Review caught a real bug (sync cancel/clunk
  poisoning later tickets on the un-pumped origin client) → fixed + regression T8b.
- **Phase 12e MERGED (2026-09-14, structure-only)** — see agents/reports/phase12e-structure.md:
  `Editor.zig` 824→383 pre-test lines via NEW `core/Gesture.zig` (mousethread state+arms),
  `core/textselect.zig` (sweep/chord loop), `core/snarf.zig`; warning buckets in
  `errors.zig`; `origin/handshake.zig` split from `OriginMount.zig` (319); `Client.seedQid`;
  `origin_glue.zig` from `main_wasm.zig` (373). Pure move (540 test names identical, no
  golden moved). **Gesture carve-out debt CLOSED.** Remaining over-cap (untouched by design):
  `dev/draw.zig` 806, `ninep/client.zig` 672, `core/Window.zig` 536 — split when touched.
- **Phase 12d MERGED (`6d13dda`, 2026-09-14)** — see agents/reports/phase12d-unions.md:
  union mount table (`bind .before/.after/.replace`, `unmount`, `unbindTarget` — the phase-12
  GAP is CLOSED), NEW `ninep/nsdir.zig` (`walk` first-success over members, `DirReader`
  = unionread with synthetic root-device dirs for `/`, `/n`, `/mnt`), **`/mnt/origin` →
  `/n/origin`** everywhere (agents/ history excepted), origin `bin/` bound `-a` into `/bin`
  during a new `binding` handshake step; S-02 Host column; R-03 v3 (R-9P-16 new, OQ-9P-1
  RESOLVED). Debt: `OriginMount.zig` 419 pre-test lines (over cap; seam = handshake vs
  lifecycle); `Client.seedQid` wanted; T11 read-error arm untested.
- **Phase 12c MERGED (`e351203`, 2026-09-14)** — see agents/reports/phase12c-canvas-resize.md:
  the canvas fills the browser window at boot (`init(w,h)`) and follows resizes
  (`EventKind.resize=8` → backend resize → `refresh` exposure → `Display.getWindow` →
  `Tree.resize`/`Row.resize`, acme.c:548-555). DPR stays 1 (R-P12c-6: crisp Retina needs a
  2× font — REMAINING half of R-GFX-05). `Row.resize` floors columns at 34 px (libframe traps
  below ~25). MANUAL for Larry: reload, `make run`, drag the window edge.
- **Namespace decisions with the user (2026-09-14, one at a time)**: (1) origin mount
  moves `/mnt/origin` → **`/n/origin`** (Plan 9 network-mount idiom; do the rename in code,
  S-02 §5, R-9P-10, tests, HANDOFF together in the unions wave); (2) **`$home` DEFERRED**
  until unions exist — strict acme per-window directories meanwhile; (3) **unions
  (OQ-9P-1) = YES, own wave BEFORE directory windows**: `bind -a/-b` in the mount table +
  synthesized listings for mount-point dirs (`/`, `/n`, `/mnt`), origin `bin/` unioned into
  `/bin` so command lookup is acme's "window dir, then path"; (4) self mount stays
  **`/mnt/snarf-self`** (no /mnt/acme compatibility claim); (5) **`/dev/dom` kept,
  browser-host only, LOW priority** — no wave until someone needs to script the page from
  inside Snarf; S-02 gets a per-device "host" column (browser / native / both) in the
  unions wave's doc pass. Dump location follows $home (deferred). Round complete.
- **Phase 12b MERGED (`96d7cb5`, 2026-09-13)** — see agents/reports/phase12b-paper-fidelity.md:
  `Look` builtin; `activecol` + `makenewwindow` placement (new `core/place.zig`, wired to
  the served `new` walk; `New` unchanged, faithful); `+Errors` windows (new
  `core/errors.zig`, warnings flushed from `frameEnd` into `dir/+Errors` in the rightmost
  column — **ed.warnings is now visible in the UI**, two-strike Del shows its message).
  FROZEN-ACCEPT-9 re-frozen (spot-checked), FROZEN-ACCEPT-12B new. First full run of the
  user's pipeline: fable spec → opus code → sonnet tests → sonnet gate → fable review →
  orchestrator applies nits → merge. Worked first pass; keep it.
- **Phase 12 MERGED (`34bb36c`, 2026-09-05)** — see agents/reports/phase12-origin-mount.md:
  browser mounts the origin at `/mnt/origin` (ABI v4 ws imports, WsTransport,
  tick-driven OriginMount in NEW module `src/origin/`, 10 s absence tolerance,
  `Reconnect` builtin via Editor.OriginHook, server 30 s keepalive). Also that day:
  origin server logging (info→stdout, errors→stderr, ops-level 9p access log —
  `e69d451`, `cd0139f`). GAPS handed forward (in the as-built contract): ninep.Client
  has NO async ticket for walk/open/clunk (Get/Put + origin file reads BLOCKED on it);
  Namespace lacks `unmount(prefix)`; ed.warnings still invisible in the UI.
  (phase-12 gaps — async ticket, `unmount` — are CLOSED as of 12d/13a.)
  Snarf is a working browser editor: typing/selection/undo, scroll, snarf+chords, window
  and column management with live tags, B2 exec (10 builtins), B3 look, the Edit language
  (structural regexps), the `/mnt/snarf-self` served tree, and `snarf-origin`
  (`zig build serve`) speaking 9P2000 over WebSocket at `/9p` (server side only).
- **Per-phase detail lives in `agents/reports/phase*.md`** (results, frozen-golden
  hashes) **and `agents/contracts/`** (binding as-built rulings — read the contract
  before touching an area). Phases: 1 ninep · 2 draw · 3 fonts · 4 text/frame ·
  5 browser slice · 6 interactive input · 7 scroll+snarf · 8 windows · 9 exec+look ·
  10 Edit+served tree · 11 origin server. Recent merges: P11 `8154bd6`;
  input-modifier-boot `0bd405f` (boot in modifier profile: Option=B2, Cmd/Ctrl=B3,
  physical-button passthrough).
- **Manual browser verification (2026-09-05, Larry, Safari + real mice)**: confirmed
  working — boot render, B2 exec via physical middle button AND Option+click, executing
  commands typed in a body, Snarf/Paste, New, Newcol (borders/bands correct once
  multiple windows/columns exist), live tags (Undo appears only on dirty windows), line
  wrap. Not yet exercised: 1-2/1-3 chords, B3 look + green/red sweeps, Del two-strike,
  Delcol regrow, Edit language, Undo run-grouping. One unreproduced anomaly: a column
  tag once read `New Cut Paste ste ste ste…` (fragment of "Paste" repeated) — possibly
  a stray user edit; if it recurs unprompted, chase it. Known cosmetic gaps: canvas is
  fixed 640×480 (canvasResize + DPR, R-GFX-05, still deferred — `web/index.html:15`),
  so the editor occupies the top-left corner of the browser window; DPR=1 renders
  chunky on Retina. **(Fixed size RETIRED by phase 12c; the DPR half remains.)**
- **STANDING INSTRUCTION (user, 2026-09-14)**: "continue to execute on each planned phase in
  turn; keep notes after each phase for me to review; when all planned phases are complete
  recommend next phases." Planned queue: 13b directory windows → 14 OPFS → ADR-0005
  native-host spike → **then a debt-collection pass** (2026-09-14 addendum: "make another
  debt-collection pass if you are bored; then report on that") → recommendations. Every
  merge is pushed to GitHub immediately ("commit/push all to github when complete").
  Per-phase digest for Larry: `agents/REVIEW-NOTES.md` (newest first; update it with every
  merge, commit it with the merge or the handoff).
- **STANDING AUTHORIZATION (user, 2026-07-19)**: run phases autonomously — merge each
  phase to `main` WITHOUT per-phase sign-off once orchestrator-inspected + suite green +
  fmt clean + boundary check passes; leave a report per phase in `agents/reports/`
  (committed with the phase; `--no-ff` merge = one revertable commit). Still stop and
  ask for ADR-level changes or design forks the specs don't settle.
- **Pipeline pattern** (all phases so far): Outline → Build agents in isolated worktrees
  under per-agent contracts → orchestrator Inspect → merge. (The original plan file
  lived on a remote machine's `~/.claude/plans/` and is gone; the pattern, the contracts,
  and this file ARE the plan.)
- **NEXT: phase 14b OPFS device** (`dev/opfs.zig` over 14a's parked ops, `fsOp` import +
  `fsStage`/`fsPush` exports, **ABI v6**, `/mnt/opfs` mounted at boot, smoke stub; the
  2026-09-02 draft `agents/contracts/phase14-opfs.md` is superseded by
  `phase14b-opfs.md` when it lands). Then the ADR-0005 native-host spike, then the debt pass. — R-EDIT-03 + paper
  §User interface: a window named `/mnt/origin/` lists `bin/ fs/ version` (dirs `/`-suffixed,
  columnated, S-05 §2), B3 on an entry opens it (`openfile` via `place.makeNewWindow(t)`),
  `isdir` set (Del/Put semantics, wind.c). Prerequisites folded into the same wave:
  (a) ninep.Client async ticket for walk/open/read/clunk (the standing gate for reading
  through ANY mount); (b) `Namespace` must synthesize directory listings for mount-point
  directories (`/`, `/mnt`) — the kernel did this for acme, our mount table must.
  Then phase 13:
- **phase 13 (`agents/contracts/phase13-opfs.md`, DRAFT)**: `/mnt/opfs` — in-module
  9P device server over the Origin Private File System (R-9P-09), `fsOp` import (ABI v5),
  parked async ops; grows `ninep.server.Ops` with create/remove (lifts phase-1 R5).
  User's stated direction: later EXPORT `/mnt/opfs` over 9P to other machines (Tauth
  first). NOTE for the phase-13 outline: fold in the phase-12 gaps — grow
  `Namespace.unmount(prefix)` while touching the framework, and the async-RPC ticket
  API in `client.zig` is the gate for ANY wave that reads mounted files (Get/Put,
  origin file reads, and OPFS acceptance via the client all want it).
- **Backlog after 12/13** (unordered): canvasResize + DPR (R-GFX-05 — top user-felt
  gap); Get/Put via namespace (origin/opfs targets) + Dump/Load; `/mnt/host` picker +
  `/dev/storage`; Worker+SAB (transport swap, R-P6-1); touch profile; /dev/snarf
  clipboard; Zerox; Sort; Exit; Shift-B3 reverse look + dot=addr ctl (small
  integration wave); host-command allow-list
  (ADR); `Tauth` (OQ-9P-3); CI (S-06 §5); Editor.zig ~1800-line gesture-machine
  OQ-BLD-2 ABI codegen; `colgrow` (R-P12b-3, the `<2 lines` arm after
  makeNewWindow); `textbsinsert` backspace processing on +Errors output; ASCII-only
  `isalnum` (Plan 9 is Latin-1); `zig build small` artifact for size tracking.
- **COMMITTED, not optional — native host spike (ADR-0005, R-OV-09, 2026-09-14)**: the
  core natively + an adapter from our `/dev/draw`,`/dev/mouse`,`/dev/kbd` device files to
  plan9port `devdraw`'s pipe protocol (`include/drawfcall.h` at the pinned SHA), drawing
  the boot scene in a real window WITH `Tmoveto` warping. Spike first (proves the R-OV-03
  boundary), then native 9P servers for files + processes. Runs after 12c. Do not let
  this rot: if a session finds it still unstarted three phases from now, raise it.
- **Open questions**: OQ-IN-1 touch chord-paste; OQ-BLD-2 ABI codegen; OQ-EDIT-4
  vim-motion layer (design settled, S-02 §6 `kbd hold` — implementation DEFERRED by
  user, don't build unprompted).

## Environment & account facts

- **PR APIs are blocked in BOTH directions, remote and local** (re-verified 2026-09-05):
  the GitHub App token and larry's local `gh` (2.96.0, authed `larryr`) can push/fetch
  and read repos, but `gh pr list` returns `[]` even with a PR open, REST
  `repos/larryr/snarf/pulls` 404s, and `gh pr create` fails GraphQL permissions. PR
  state is checked in the browser (2026-09-05: a Claude Code Chrome-extension session
  read the /pulls page directly — works when the extension is connected). The user
  opens PRs in the UI; merges land by pushing a git merge commit. Re-test occasionally.
- **Local Mac permission note (2026-09-05)**: the Claude Code auto-mode classifier
  blocks `git push --delete` (remote branch deletion) and some compound git commands;
  the user runs those via `! <cmd>` in-session instead.
- **Remote sandbox git (2026-09-11)**: `git push --delete <branch>` is refused by the git
  proxy (HTTP 403) — merged branches must be deleted by the user/UI or a local session.
  Ordinary pushes print scary noise (`--negotiate-only … RPC failed; HTTP 403 …
  unexpected disconnect`) yet SUCCEED — always confirm with `git ls-remote --heads`
  before retrying or concluding a push failed.
- **Self-approval**: GitHub forbids approving your own PR; don't promise an "approve" step.
- **Remote-session repo scope**: only repos attached at start or via `add_repo`
  (same-owner-only v1; fork third-party repos to `larryr/` first).
- **The ACME paper is in-tree**: `docs/acme/` (HTML+PDF+troff source, from the pinned
  4e fork `sys/doc/acme/`; provenance/license in its README). Cite `acme paper §N`.
  doc.cat-v.org, 9p.io and plan9.io are proxy-blocked from remote sandboxes — use the
  fork (`raw.githubusercontent.com/larryr/plan9/<full-sha>/…`; short SHAs 404 there).
- **Reference forks** (pinned, cite by SHA — see CLAUDE.md): `larryr/plan9port@337c6ac`,
  `larryr/plan9@ed1a9c2`. Local full clones: `~/proj/plan9port`, `~/proj/plan9` (tips
  already AT the pinned SHAs; macOS case-collision dirty entries are harmless).
  **plan9port is BUILT on larry's Mac (2026-09-13, `./INSTALL`)**: `~/proj/plan9port/bin/`
  holds 267 binaries incl. `devdraw` and `acme` (arm64 Mach-O) at the pinned SHA — the
  peer for the ADR-0005 native-host spike and a live acme to compare behavior against.
  Use `PLAN9=~/proj/plan9port`, `PATH=$PATH:$PLAN9/bin`. INSTALL rewrites `bin/9`,
  `bin/9.rc`, `bin/9fs` in place (paths) — those dirty entries are expected; never
  reset them. Homebrew no longer ships a plan9port formula. Remote:
  clone shallow to `/workspace/…`. WebFetch of raw.githubusercontent.com works for
  public spot-reads without attaching.
- **Remote sandbox network**: ziglang.org, github releases, kroki.io blocked; apt +
  PyPI open — `pip install ziglang==0.16.0` gives a working Zig (≈12 s test suite);
  `apt-get install -y plantuml` (1.2020.2) for `-checkonly` (no salt tree-tables — use
  `@startmindmap`).

## Design notes pending a requirements revision (keep until folded into R-05/S-04)

- **Touch-profile warp semantics (user discussion 2026-09-14).** On a touch screen there is
  no pointer between touches, so point-to-type (R-EDIT-22) cannot apply; the touch profile
  uses acme's `-b` variant — the LAST TOUCHED text keeps focus. Once focus is a software
  value Snarf owns, the paper's warps (R-EDIT-25) map onto moving it and are HONORABLE on
  touch: new window ⇒ focus + dot move into it (keyboard types there); B3 hit ⇒ dot moves
  to the hit, highlighted + scrolled; deleting a pop-up ⇒ focus returns to the text it came
  from (remember it explicitly); layout-box "click again without moving" does NOT translate
  — dragging the box is the touch gesture. Record as a third host/profile case when the
  touch profile is built: desktop browser = no warp; native = real warp; touch = focus/dot
  follow the action.
- **Tablets with hardware keyboards + trackpads/mice** behave like a desktop browser, not
  like touch: iPadOS (trackpad/Magic Keyboard) and Android (mouse) synthesize a real
  pointer — `pointermove` with `pointerType == "mouse"`, hover works, so point-to-type works
  and warping is impossible exactly as on the desktop. The SAME device can switch between
  finger (`pointerType == "touch"`) and pointer mid-session, so profile selection (R-IN-08)
  must be per-event, not per-boot, and the focus model must be hybrid: hover focus while a
  pointer is present, last-touch focus for touches. iPadOS also emulates a "middle button"
  and secondary click on trackpads via gestures/settings — unverified which buttons reach
  the page. **OQ-IN-4 (new): per-event profile switching + hybrid focus; verify iPadOS/Android
  button mapping with a real device before the touch wave.** Fold into R-05 v3 / S-04 when
  the touch profile is scheduled.

## Learnings / dead ends (keep)

- **Gate pattern (OPS LESSON 2026-07-20)**: `zig build test | grep …` returns the LAST
  pipe stage's code — a failing suite can ride a green-looking `&&` chain. Run tests to
  a file, check `$?`, then grep the file. Shell `printf '0x%x'` mangles > INT64_MAX —
  use python for hash conversions.
- **Git close-out (2026-07-19 incident)**: never `git add -A` near close-out (an
  exclusion pathspec against an ignored dir FAILS and a later add sweeps the stale
  index); stage explicit paths; `git status` before ANY commit on main; don't mix
  newline/&& chaining in critical sequences. `.claude/` is gitignored.
- **Agent orchestration (phase 1)**: worktrees spawn from possibly-stale refs (agents
  must verify a marker file or rebase); each agent adds its OWN namespace-root re-export
  or its tests are vacuously unreachable; type-only imports still serialize builds;
  the inspect wave catches real bugs — keep it.
- **Zig 0.16 API notes**: build = `b.addModule`/`createModule`, `.root_module`, target
  only on root; wasm exports = `entry .disabled` + `rdynamic` + `export fn`;
  `refAllDeclsRecursive` gone. Networking = `std.Io.net` + `std.Io.Threaded` (std.net
  GONE); reader/writer via `stream.reader(io,&buf).interface`; files via `std.Io.Dir`;
  `std.http.Server` has server-side WebSocket built in (`upgradeRequested`,
  `respondWebSocket`, `readSmallMessage`); custom headers via `respond`
  `extra_headers`; `trimRight`→`trimEnd`; build→exe constants via `b.addOptions()`.
- plan9port acme at the pinned SHA = 15,830 lines / 25 files; per-file counts are in
  the S-07 survey table — don't recount.

## Session log (newest first)

### 2026-09-13 — acme paper → markdown, related papers, R-02 re-verification (local, larry's Mac)
- `docs/acme/acme.md` generated from `acme.ms` by new `docs/acme/ms2md.py` (regenerate,
  don't hand-edit). Subagent archived Pike's sam, plumb, 8½ papers + 28 Plan 9/plan9port
  man pages under `docs/acme/{sam,plumb,8half,man}/` from the pinned MIT forks;
  `docs/acme/PAPERS-INDEX.md` records copied/not-copied and the rule **only
  Pike-authored = definitive**, everything else supplementary (user direction).
- Re-verified paper semantics vs requirements + code: mouse language, chords, undo,
  live tags, served tree all faithful. R-02 → v4: fixed R-EDIT-02 (live tag) and
  R-EDIT-03 (B3 not B2 opens entries); added R-EDIT-20..25 (directory context, +Errors,
  point-to-type, placement heuristics, single-click expansion, no-warp divergence).
  Implementation gaps → backlog above. Docs branch merged `f6ef98a`.
- Phase 12b (same day, later): the three real gaps built and merged `96d7cb5` via the
  full pipeline (see Current state). Local `git push --delete` of merged remote branches
  WORKED from larry's Mac this session (auto mode) — the classifier block noted under
  Environment is not absolute; try it before falling back to `! <cmd>`.

### 2026-09-05 (later) — phase 12 built + merged (local, larry's Mac)
- Origin-server logging landed first (user request): stdout/stderr split (`e69d451`),
  then ops-level 9p access log (`cd0139f`) — that log became the smoke oracle.
- Phase 12 via the pipeline: B1 (shim+ABI+WsTransport) and B2 (mount+Reconnect+ping)
  as sequential opus worktree agents; orchestrator smoke battery drives a REAL
  spawned snarf-origin and executes `Reconnect` as a real user gesture. Merged
  `34bb36c`; contract updated to AS BUILT with B1/B2/orchestrator rulings.
- Pipeline lesson: point-to-type inserts at the window's DOT, not at the pointer —
  input-injection tests must B1-click first to anchor the dot.

### 2026-09-05 — verification + wave planning (local, larry's Mac)
- Deleted stale merged remote branches `origin-server`, `claude/snarf-docs-specs-iuj6q3`
  (user ran the push — classifier blocks it for agents). Remote = `main` only.
- Confirmed zero open PRs by reading github.com/larryr/snarf/pulls via the Chrome
  extension (API remains blind — see facts).
- Manual browser walkthrough with the user (results in Current state above).
- Planned waves with the user; DRAFT contracts for phase 12 (origin mount, browser
  side) + phase 13 (/mnt/opfs) committed to `main` (`f534272`) at user request for
  browser review. Spec corrections found while drafting: no JS-initiated WS pings
  (keepalive must be server-side); wsOpen URL arg dropped (same-origin only).
- User direction recorded: OPFS mount is wanted, later exportable over 9P; OPFS > 
  localStorage as the backing store (localStorage is the separate small /dev/storage).
- Spawned a background Opus agent to add Mermaid review mirrors of the 7 PlantUML
  diagrams under `docs/spec/diagrams/mermaid/` (user-authorized direct commit to main).
- Pruned this file (~100 lines shorter); dead pointer to the remote-machine plan file
  removed — contracts + this file are the plan of record.

### 2026-09-02 — coordination session (remote)
- Recorded input claim (since merged as `0bd405f` and cleared); added the push-early
  rule to CLAUDE.md (`9fad850`); PR APIs re-tested, still blocked; libghostty assessed:
  no action, only future fit is libghostty-vt IF real VT terminals ever happen
  (would need the first ADR-0002 amendment).
