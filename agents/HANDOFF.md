# Session handoff — shared memory between agent sessions

Protocol: see `CLAUDE.md` §"Session handoff protocol". Read top-to-bottom; newest session
entry first. Any session may edit; commit to `main` with prefix `handoff:` (standing
authorization for this file only). Prune freely — git keeps history.

## ⚠ In-flight claims (check before touching these areas)

- *(none as of 2026-09-05 late — phase 12 merged `34bb36c`, all branches cleaned;
  remote has only `main`)*

## Current state (update in place)

- **Phases 1–12 are MERGED to `main`; `main` is green.**
  522/522 tests, node smoke 20/20, `zig fmt` clean, Zig 0.16.0, wasm ≈ 1554 KiB (watch —
  +48 KiB in phase 12).
- **Phase 12 MERGED (`34bb36c`, 2026-09-05)** — see agents/reports/phase12-origin-mount.md:
  browser mounts the origin at `/mnt/origin` (ABI v4 ws imports, WsTransport,
  tick-driven OriginMount in NEW module `src/origin/`, 10 s absence tolerance,
  `Reconnect` builtin via Editor.OriginHook, server 30 s keepalive). Also that day:
  origin server logging (info→stdout, errors→stderr, ops-level 9p access log —
  `e69d451`, `cd0139f`). GAPS handed forward (in the as-built contract): ninep.Client
  has NO async ticket for walk/open/clunk (Get/Put + origin file reads BLOCKED on it);
  Namespace lacks `unmount(prefix)`; ed.warnings still invisible in the UI.
  MANUAL STEP for Larry: restart `zig build serve`, reload browser, watch the server
  stdout access log show the mount handshake; kill/restart server, middle-click
  `Reconnect`.
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
  chunky on Retina.
- **STANDING AUTHORIZATION (user, 2026-07-19)**: run phases autonomously — merge each
  phase to `main` WITHOUT per-phase sign-off once orchestrator-inspected + suite green +
  fmt clean + boundary check passes; leave a report per phase in `agents/reports/`
  (committed with the phase; `--no-ff` merge = one revertable commit). Still stop and
  ask for ADR-level changes or design forks the specs don't settle.
- **Pipeline pattern** (all phases so far): Outline → Build agents in isolated worktrees
  under per-agent contracts → orchestrator Inspect → merge. (The original plan file
  lived on a remote machine's `~/.claude/plans/` and is gone; the pattern, the contracts,
  and this file ARE the plan.)
- **NEXT: phase 13 (`agents/contracts/phase13-opfs.md`, DRAFT)**: `/mnt/opfs` — in-module
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
  integration wave); +Errors window (rewire ed.warnings); host-command allow-list
  (ADR); `Tauth` (OQ-9P-3); CI (S-06 §5); Editor.zig ~1800-line gesture-machine
  carve-out; OQ-BLD-2 ABI codegen.
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
- **Self-approval**: GitHub forbids approving your own PR; don't promise an "approve" step.
- **Remote-session repo scope**: only repos attached at start or via `add_repo`
  (same-owner-only v1; fork third-party repos to `larryr/` first).
- **Reference forks** (pinned, cite by SHA — see CLAUDE.md): `larryr/plan9port@337c6ac`,
  `larryr/plan9@ed1a9c2`. Local full clones: `~/proj/plan9port`, `~/proj/plan9` (tips
  already AT the pinned SHAs; macOS case-collision dirty entries are harmless). Remote:
  clone shallow to `/workspace/…`. WebFetch of raw.githubusercontent.com works for
  public spot-reads without attaching.
- **Remote sandbox network**: ziglang.org, github releases, kroki.io blocked; apt +
  PyPI open — `pip install ziglang==0.16.0` gives a working Zig (≈12 s test suite);
  `apt-get install -y plantuml` (1.2020.2) for `-checkonly` (no salt tree-tables — use
  `@startmindmap`).

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
