# Session handoff — shared memory between agent sessions

Protocol: see `CLAUDE.md` §"Session handoff protocol". Read top-to-bottom; newest session
entry first. Any session may edit; commit to `main` with prefix `handoff:` (standing
authorization for this file only). Prune freely — git keeps history.

## Current state (update in place)

- **Repo**: docs + scaffold + `zig build serve` all on `main` (scaffold `0c4ec78`, serve
  `d8a53d2`; branches deleted). `main` builds green.
- **Docs**: 7 requirements + 8 specs (S-00..S-07) + 4 ADRs + 7 PlantUML diagrams under
  `docs/`. Entry point `docs/README.md`.
- **Scaffold (on `main`)**: `build.zig` + `build.zig.zon` (empty deps) + `.zigversion`,
  five module namespaces (core/draw/ninep/dev/shim) with stub type-files + colocated
  tests, `main_wasm.zig`/`main_native.zig`, `web/{index.html,shim.js}` stubs.
  All green on Zig 0.16.0: `zig build` → `zig-out/www/{snarf.wasm,index.html,shim.js}`
  (wasm instantiates + init/wake/tick callable, verified under node); `zig build test`
  13/13; `zig build run-native` runs the headless Editor; `zig fmt` clean. S-07 §6 import
  rules are enforced by the module graph (core→shim fails to compile — verified). Only
  representative stubs per namespace, NOT all ~55 files of S-07 §4.
- **`zig build serve`** (done, `tools/serve.zig`): std-only dev server over `zig-out/www`,
  `application/wasm` + COOP/COEP + `Cache-Control: no-store`; `-Dport` (default 8017);
  rejects `..`, maps `/`→`/index.html`. Host-only dev tool, outside the editor module
  graph. Built on 0.16 `std.Io` (see learning below). Confirmed loads in a browser.
- **Phase 1 (ninep) MERGED to `main` (`f5da818`, user-approved); phase branch and agent
  worktrees deleted.** Full 9P2000 core: qid/msg codec (+wire cursor,
  stat(5) codec), transport vtable, errors, chan (SPSC ring+Pipe), server (lib9p-shaped
  Srv), client (sync + pump), mount (ordered prefix table). 84/84 tests incl. an
  end-to-end acceptance test (client walks/opens/reads/writes a served tree over a Pipe,
  mount resolve on top). Built by the phased agent pipeline (contract at
  `agents/contracts/phase1-ninep.md` — read it before touching ninep; R-rulings 1-8
  record as-built decisions incl. Ops.attach signature and R5 unsupported-msg handling).
- **Agent-pipeline plan** (user-approved): Outline(fable) → Build(opus/sonnet, isolated
  worktrees) → Inspect(orchestrator) per phase; plan file
  `~/.claude/plans/sequential-dreaming-shell.md`. Phase 2 = rectangle on a headless
  framebuffer (draw proto/Display/Image + devdraw headless backend, golden-image tests).
- **STANDING AUTHORIZATION (user, 2026-07-19)**: run phases autonomously — merge each
  phase to `main` WITHOUT per-phase sign-off once orchestrator-inspected + suite green +
  fmt clean + boundary check passes; leave a report per phase in `agents/reports/`
  (committed with the phase; `--no-ff` merge = one revertable commit). Still stop and
  ask for ADR-level changes or design forks the specs don't settle.
- **Phase 2 (draw/rect) MERGED to `main`** (see agents/reports/phase2-draw.md): draw
  proto/Display/Image client + devdraw server + HeadlessBackend compositor + acceptance
  root src/accept.zig. 115/115. Contract: agents/contracts/phase2-draw.md (rulings
  R-P2-1..7; G1-G10 ground truth incl. draw wire = LITTLE-endian, sys/man/3/draw:111).
  Frozen goldens listed in the report; re-freeze needs orchestrator re-verification.
- **Phase 3 (fonts) MERGED to `main`** (agents/reports/phase3-font.md): text renders —
  "hello, acme" end-to-end (embedded misc-fixed subfont, image(6) decompressor, verbs
  i/l/s/y, general-mask CALC12 compositor). 148/148. **OQ-GFX-2 resolved**: fixed/ is
  public domain (embedded, sha256-pinned); Lucida is ENCUMBERED — never embed; Go fonts
  deferred (S-03 §4 amended w/ revision log). Contracts: phase3-font{,-client,-device}.md.
- **Phase 4 (text) MERGED to `main`** (agents/reports/phase4-text.md): piece-table
  Buffer/RuneIndex (verbatim-store/U+FFFD-at-read; NULs kept — flagged divergence),
  File undo/redo (file.c-faithful, mod restoration), full libframe port
  (frame/{Frame,insert,draw,util}, tab rule, '\n' 5000px quirk preserved), Text.fill.
  192/192. Contracts: phase4-text{,-data,-frame}.md (rulings R-P4-1..7).
- **Phase 5 (browser) MERGED to `main` — THE VERTICAL SLICE IS COMPLETE**
  (agents/reports/phase5-browser.md): 921 KiB snarf.wasm boots the full stack in-module
  and presents via one blit import; canvas backend is golden-identical BY CONSTRUCTION
  (pinned by test); node smoke 13/13 against the real binary (tools/smoke_wasm.mjs,
  manual tool). Main-thread v1 (Worker+SAB land with devinput — S-00 revision note);
  ABI v2 runtime-checked. MANUAL STEP for Larry: `zig build serve` → 127.0.0.1:8017 →
  see "hello, acme wraps"/"second line⇥tab" on the canvas (extension screenshot was
  unavailable; node pixel checks stand in).
- **Phase 6 (interactive editing) MERGED to `main`** (agents/reports/phase6-input.md):
  Snarf is an EDITOR — click/type/select in the browser. Parked 9P reads + client
  tickets (S-00 §2 CORRECTED per R-P6-1: async-mode tickets ARE the architecture;
  Worker move = transport swap later); devinput (R-IN-02 byte-identity proven; native+
  modifier profiles); frdelete/incremental-select/tick; texttype/textsetselect with
  T-1 run-scoped undo grouping; the Editor loop. 259/259 + smoke 14/14 (injected
  keystroke end-to-end). Contracts: phase6-input{,-ninep,-devinput,-editing}.md.
  NOTE: .claude/ is now gitignored (a git add -A once staged agent worktrees).
- **Phase 9 (exec & look) MERGED to `main` (2150b11)**
  (agents/reports/phase9-exec-look.md): B2 executes the 10-builtin Exectab
  (Cut/Del/Delcol/Delete/New/Newcol/Paste/Redo/Snarf/Undo; et/seltext routing,
  2-1 argument chord), B3 literal search w/ wraparound (core/look.zig), shared
  xselect colored sweeps (B2 red/B3 green), live tags (frameEnd sweep, R-P9-4),
  two-strike Del, colclose/rowclose regrowth. 369/369 + smoke 14/14.
  Contracts: phase9-{exec-look,exec,look}.md (R-P9-1..13; R-P9-13 = Row.close
  takes `ed` for dropTextRefs — B1-agent-flagged contract defect, patched).
  FROZEN-ACCEPT-8 re-frozen 0x9816211a7aca91d7 (live-tag Undo); FROZEN-ACCEPT-9
  = 0xb52b86b54d50d100. Debt: Editor.zig ~1743 lines (carve gesture machine out
  next structural pass); getArg raw-bytes until namespace `expand`.
- **Phase 10 (Edit language + served tree) MERGED to `main` (4c59893)**
  (agents/reports/phase10-edit.md): structural regexp engine (sam Pike-VM,
  fwd+bwd), full addresses, Edit commands a c i d s m t + x y g v loops + p = u
  {} (one Edit = one undo via Elog frozen-coordinate reverse apply), and the
  /mnt/snarf-self served tree start (index/ctl/body/tag, ctl clean/dirty/del/
  delete/name, walk-new creates windows). 476/476 + smoke 14/14. Contracts:
  phase10-{edit,regx-addr,edit-cmd,served}.md (R-P10-1..9 + A..J).
  FROZEN-ACCEPT-10 = 0xe9014ecfa82cbc4b. Agent-found contract corrections
  recorded in the report (NPROG/test-9); Edit builtin uses et's window body,
  never seltext.
- **OPS LESSON (2026-07-20, recorded after a near-miss)**: `zig build test |
  grep | awk` gates return the LAST pipe stage's exit code — a failing suite
  still lets `&&` chains continue. A wrong frozen-hash constant rode green-looking
  gates until a forced-failure probe exposed it. Gate pattern now: run tests to a
  file, check `$?` explicitly, grep the file for fail/crash. ALSO: shell
  `printf '0x%x'` silently mangles decimals > INT64_MAX — use python for hash
  conversions.
- **Next (directive completed through P10; new work needs user direction)**:
  Get/Put via namespace (host fs / origin mounts), Dump/Load, Worker+SAB,
  touch profile, /dev/snarf clipboard, Zerox (multi-Text-per-File), Sort, Exit,
  Shift-B3 reverse look + dot=addr ctl wiring (small integration wave), +Errors
  window (rewire ed.warnings). Also outstanding: CI (S-06 §5); wasm size watch
  (1504.6 KiB after P10); Editor.zig ~1800 lines (gesture-machine carve-out).
- **Open questions**: OQ-BLD-1 → Zig 0.16.0; OQ-GFX-2 → misc-fixed (see above). Still
  open: touch chord-paste gesture (OQ-IN-1), ABI codegen (OQ-BLD-2).

## Environment & account facts (verified 2026-07-19)

- **GitHub App permissions (remote sessions)**: the Claude integration token for `larryr`
  has Contents (push, branches API) but **no Pull requests permission** — PR
  create/list/merge via API fail 403/404. PRs must be opened by the user in the GitHub UI;
  merges can be done by pushing a git merge commit (GitHub then flips an open PR to
  Merged). Re-test occasionally in case the grant lands.
- **Local `gh` (larry's Mac) 2026-07-19**: `gh` 2.96.0, authed as `larryr` via keyring
  (ssh git protocol), token scopes `repo`/`read:org`/`gist`/`admin:public_key`. Git
  push/fetch and read APIs (`gh api user`, `gh pr list`, `gh repo view`) work. **BUT
  `gh pr create` STILL FAILS** — `GraphQL: larryr does not have the correct permissions to
  execute CreatePullRequest`. So PR *creation* is blocked in **both** remote and local
  contexts, despite the `repo` scope — treat "can't create PRs from here" as the standing
  reality; the user opens PRs in the UI (or we land via `git merge`). `gh auth status`
  reporting "not logged in" is a sandbox-without-keyring artifact, not a real logout.
- **Self-approval**: GitHub forbids approving your own PR; don't promise an "approve" step.
- **Remote-session repo scope**: sessions only reach repos attached at start or added via
  `add_repo`; `add_repo` is same-owner-only (v1) — third-party repos must be forked to
  `larryr/` first.
- **Reference forks** (pinned, cite by SHA — see CLAUDE.md):
  `larryr/plan9port@337c6ac` (acme code), `larryr/plan9@ed1a9c2` (device semantics).
  In remote sessions clone shallow to `/workspace/plan9port`, `/workspace/plan9`
  (~86 MB / ~254 MB).
  - **Local (larry's Mac) 2026-07-19**: full clones at `~/proj/plan9port` and
    `~/proj/plan9`; both default-branch tips already ARE the pinned SHAs (no checkout
    needed). Public over HTTPS — no `gh` auth required. macOS case-insensitive FS causes
    ~12 harmless case-collision dirty entries in plan9 postscript/troff/rc font dirs;
    none touch cited paths (`sys/src/9/port/*`, `sys/man/`).
- **Network policy in remote sandbox**: github release downloads and kroki.io are
  blocked by the proxy; **apt works** — `apt-get install -y plantuml` (1.2020.2) is the
  way to verify diagrams. Older PlantUML: salt tree-tables unsupported — use
  `@startmindmap` for trees.
- **Docs verification recipe**: `plantuml -checkonly docs/spec/diagrams/*.puml`, render
  suspicious ones to PNG and eyeball.

## Learnings / dead ends

- plan9port acme measured at the pinned SHA: 15,830 lines / 25 files; the S-07 survey
  table has per-file counts — don't recount.
- Older PlantUML (2020.2) rejects `salt {T` tree-tables inside `@startuml`; mindmap
  rendering of the namespace tree was the fix (see `namespaces.puml`).
- WebFetch of `raw.githubusercontent.com` works for public files even when git-level
  access is scoped — useful for spot-reads without attaching a repo.
- **Zig 0.16 build API** (learned wiring the scaffold): modules via
  `b.addModule`/`b.createModule`; exe/test take `.root_module`. Leaf/imported modules
  should carry NO `.target` — it's set only on the root module and inherited, so one
  module object works for both the wasm exe and native test compilations. WASM exports:
  set `exe.entry = .disabled` + `exe.rdynamic = true` and use `export fn`. `build.zig.zon`
  needs `.name` as an enum literal (`.snarf`) and a `.fingerprint` (zig prints the correct
  value in the error if wrong). `std.testing.refAllDeclsRecursive` is GONE — only
  `refAllDecls` (non-recursive) exists, fine for one-level namespace roots. `{d:>11}`
  on a SIGNED int prints a `+` for positives (kernel `%11d` doesn't) — format with
  `{d}` then pad manually when byte-matching C output.
- **Zig 0.16 std.Io overhaul** (learned writing `tools/serve.zig`): `std.posix` DROPPED
  the socket calls (socket/bind/listen/accept/connect) and `std.net` is GONE. Networking
  is `std.Io.net` and needs an `Io`: `var t: std.Io.Threaded = .init(gpa, .{}); const io =
  t.io();`. Listen/serve: `const a: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
  var srv = try a.listen(io, .{ .reuse_address = true }); var s = try srv.accept(io);`.
  Get Io.Reader/Writer from a stream via `s.reader(io, &buf).interface` /
  `s.writer(io, &buf).interface` and hand `&…interface` to `std.http.Server.init`. Files:
  `std.fs` read helpers moved to `std.Io.Dir` — `std.Io.Dir.cwd().readFileAlloc(io,
  path, gpa, .unlimited)`. `std.http.Server` has no content-type option; set it (and any
  custom headers) via `respond`'s `extra_headers: []const std.http.Header`. Pass build→exe
  constants with `b.addOptions()` + `.createModule()` imported as `build_options` (argv
  iterators also churned; addOptions sidesteps them).

- **Ops incident (2026-07-19, phase-7 close-out)**: a newline-chained close-out script
  used `git add -A ':!.claude'` — the exclusion pathspec against an ignored dir FAILS
  (exit 1), the `&&`-chained accept commit was skipped, and a later `git add <file> &&
  git commit` swept the ENTIRE stale index into a mislabeled `handoff:` commit
  (90a341b, pushed). Repaired forward (no force-push): branch recreated from reflog,
  merged properly. LESSONS: (a) never batch critical git sequences with mixed
  newline/&& chaining; (b) never `git add -A` near close-out — stage explicit paths;
  (c) always `git status` before ANY commit on main.
- **Agent-orchestration learnings (2026-07-19, phase 1):** (1) Worktrees spawn from a
  possibly-stale ref — every build-agent prompt must include "verify file X exists, else
  `git rebase <integration-branch>`" (all five agents needed it). (2) Each agent must add
  its OWN re-export line to the namespace root or its tests are unreachable and the
  in-worktree gate passes vacuously; orchestrator resolves the one-line conflicts.
  (3) Type-only imports still serialize builds (mount needed client.zig to exist → B4
  sequenced after B2). (4) Wave C catches real bugs: multi-chunk-walk fid leak (B2,
  fixed as clunk-or-burn), infallible pump = hang-not-fail (B2), `catch unreachable` on
  op-controlled data (B1 handleStat, patched + regression test).

## Session log (newest first)

### 2026-07-19 — docs bootstrap session (remote, larryr)
- Authored and merged to `main`: full docs tree (requirements R-01..R-07, specs
  S-00..S-07, ADR-0001..0004, 7 diagrams), root README, this agent setup
  (CLAUDE.md/AGENTS.md, agents/HANDOFF.md).
- Decisions settled with the user: Zig std-only; wasm32-freestanding; /dev/draw as the
  graphics contract; virtual-button chord emulation; reference forks pinned (user forked
  plan9 + plan9port to `larryr/`); citation-by-SHA policy.
- PR flow attempted and blocked by missing App permission (see facts above); user chose
  direct git merge instead ("just merge it").
