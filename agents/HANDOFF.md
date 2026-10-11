# Session handoff — shared memory between agent sessions

Protocol: see `CLAUDE.md` §"Session handoff protocol". Read top-to-bottom; newest session
entry first. Any session may edit; commit to `main` with prefix `handoff:` (standing
authorization for this file only). Prune freely — git keeps history; per-phase detail lives
in `agents/reports/phase*.md` (results, frozen-golden hashes) and `agents/contracts/` (binding
as-built rulings — read the contract before touching an area).

**Pruned 2026-10-11** (was 419 lines, well over the ~300-line target): collapsed phase-by-
phase narrative into the one-line table below (full detail is in the reports/contracts, which
is the actual archive — this file is working memory, not one); dropped the "Session log"
section entirely (redundant with `git log` and the reports); removed resolved/superseded
items (the 2026-10-10 roadmap-reconciliation question, the 2026-09-14 draft/backlog notes
that predate `NEXT-PHASES.md`, the then-"committed" native-host spike, now phase 15); fixed
one fact that had gone stale and wrong (PR creation — see below).

## ⚠ In-flight claims (check before touching these areas)

- **Phase 18 built, PR #24 open** (`phase18-devdraw-build`): `build.zig`, `build.zig.zon`,
  `build/`, `src/host/devdraw/{Conn,DevdrawPath}.zig`, `src/host/host.zig`,
  `src/main_native.zig`. Full pipeline run (fable → opus → sonnet → fable, ACCEPT WITH NITS)
  complete; all gates green on this Mac. Awaiting merge (classifier/credential friction on
  `gh pr merge` — Larry merges via web UI, same as #2/#3/#5) and Larry's manual check (§5 of
  the contract: `zig build native && zig build run-native` with `$PLAN9` set must print
  `(bundled)`).
- **`agents/NEXT-PHASES.md` re-tier, PR #6 open**: do not also edit this file until #6 lands —
  phase 18's own "devdraw built in-tree" Parked→done update is queued behind it (see Current
  state).

## Current state (update in place)

- **Native host is now primary; browser is a frozen secondary** — ADR-0005 amendment accepted
  2026-10-11 (PR #2, merged), prompted by a Larry↔SnarfProdd product sync. Browser SHALL keep
  building/testing/passing goldens, gets no new features. `devdraw` is the native rendering/
  input module *indefinitely* (not provisional). R-01 v4 applied (`01-overview.md` §2 + R-OV-09
  reworded). Full reasoning: `notes/claude/roadmap-review-2026-10-10.md`,
  `docs/spec/adr/0005-two-hosts-one-core.md`'s Amendment section.
- **ADR convention changed 2026-10-11**: ADRs are now immutable once accepted — a changed
  decision gets a **new numbered ADR that explicitly supersedes** the old one (one-line Status
  pointer on the old file), not an in-place "Amendment" section. `CLAUDE.md` updated. ADR-0005's
  existing in-place amendment predates this and is left as historical record, not retrofitted.
- **ADR-0006 ACCEPTED** (PR #3, merged `38f47d0`): fetch the pinned `larryr/plan9port@337c6ac`
  snapshot via one lazy `build.zig.zon` entry, build just the `devdraw` closure unmodified into
  a sibling `zig-out/bin/devdraw`. Final resolution order (revised during review, not the
  earlier draft): `$DEVDRAW` → bundled (relative to the running executable's own path) →
  `$PLAN9/bin/devdraw` → bare `devdraw` on `$PATH`.
- **Phase 18 built — PR #24 open, not yet merged**: implements ADR-0006. `devdraw` built
  in-tree (372 KB, 0 warnings, cold build ~18s incl. fetch, warm ~0.5s); `zig build`/
  `zig build test` verified network-free (`--system <empty dir>`); a real pre-existing
  double-kill bug in `Conn.spawn` found and fixed along the way (regression-tested). Full
  pipeline (fable contract → opus build → sonnet gate → fable review) complete, verdict ACCEPT
  WITH NITS, all findings resolved or accepted as documented debt. See "In-flight claims"
  above and `agents/reports/phase18-devdraw-build.md`.
- **docs/product/roadmap.md v0.2 promoted** (PR #5, merged `b92d825`): now the agreed baseline,
  superseding the v0.1 draft. Per its own "Process" rule: the roadmap is product prioritization,
  `agents/NEXT-PHASES.md` is the execution queue — they coexist, neither supersedes the other.
  `NEXT-PHASES.md`'s re-tier for native-primary is PR #6 (open) — see "In-flight claims".
- **GitHub PR creation now works (fixed 2026-10-11)** — corrects a prior wrong fact below:
  the repo owner had "Pull Requests" disabled at the repo level (Settings → General; not an
  API/token issue — every credential tested, OAuth/fine-grained-PAT/classic-PAT, 404'd
  identically, and Larry's own browser session failed too, which is what isolated it). Once
  re-enabled, `gh pr create`/`gh pr comment` work normally with the existing `gh auth` OAuth
  token. **`gh pr merge` is blocked by Claude Code's own auto-mode classifier** ("Merge Without
  Review", unrelated to GitHub) — Larry merges via the web UI; I delete the branch after.
- **Phase 17 MERGED (`e734e3f`, 2026-10-10)** — Put/Get/Putall/Dump/Load (R-EDIT-15/16). `$home`
  closed: `/mnt/opfs` (browser), real `$HOME` (native, `NotMounted` until Tier 2's native file
  server). Debt: T21 (wasm smoke B2-click-on-Put) not landed, geometry issue, recipe in the
  report; `xfid.zig`/`Window.zig` nudged over the 400-line cap.
- **Phases 1–16 are MERGED to `main`; green.** One line each (reports have full detail):

  | Phase | What | Merge |
  |---|---|---|
  | 16 | Debt pass: 10 file splits, 14 cited fixes incl. browser `Kdown`, one golden re-freeze | `f51e4a0` |
  | 15 | ADR-0005 spike: native host, `devdraw` adapter, real warp — zero forced core changes | `efeb3fe` |
  | 14b | `/mnt/opfs` (ABI v6, FsRecord codec, parked ops) | `851d0dc` |
  | 14a | 9P server: parking for every op, create/remove/wstat | `afff8ac` |
  | 13b | Directory windows, `Load`, `openfile`, FROZEN-ACCEPT-13B | `fd1abe0` |
  | 13a | Async 9P tickets, real boot namespace | `cee0441` |
  | 12e | Structure only: `Editor.zig` 824→383 | `35eccc5` |
  | 12d | Unions, synthetic root, `/mnt/origin`→`/n/origin` | `6d13dda` |
  | 12c | Canvas fills window + follows resize | `e351203` |
  | 12b | `Look`, `+Errors`, placement — first full pipeline run | `96d7cb5` |
  | 12 | Origin mount at boot, `Reconnect`, origin server logging | `34bb36c` |
  | 1–11 | ninep, draw, fonts, text/frame, browser slice, input, scroll+snarf, windows, exec+look, Edit+served tree, origin server | see `agents/reports/` |

- **Spike landed (2026-10-03) — rhun self-drawn frame vs. `devdraw`**:
  `agents/reports/spike-rhun-self-drawn-frame.md`. **Recommendation: borrow rhun's model, not
  its code** — keep `devdraw` as the ADR-0005 host (now indefinitely, see above). Addendum A
  (build `devdraw` ourselves) became ADR-0006, above. Addendum B (webview shell) and the native
  frame itself remain backlog-only in `NEXT-PHASES.md`'s Parked section.
- **STANDING AUTHORIZATION (user, 2026-07-19)**: run phases autonomously — merge each phase to
  `main` WITHOUT per-phase sign-off once orchestrator-inspected + suite green + fmt clean +
  boundary check passes; leave a report per phase in `agents/reports/`. Still stop and ask for
  ADR-level changes or design forks the specs don't settle.
- **STANDING INSTRUCTION (user, 2026-09-14)**: keep a per-phase digest for Larry in
  `agents/REVIEW-NOTES.md` (newest first; update with every merge).
- **Workflow convention (user, 2026-10-11)**: my own working/draft notes go under
  `notes/claude/` (direct-to-main like this file); everything else — code, ADRs, requirements,
  `NEXT-PHASES.md` — goes through a PR now that there are more reviewers (SnarfProdd reviews
  product/ADR docs; see PR #2 and #3 for the pattern).
- **Pipeline pattern**: Fable (spec/contract) → Opus (build, isolated worktree) → Sonnet
  (tests + gate: build/test/fmt/boundary) → Fable (adversarial review) → orchestrator applies
  nits and merges `--no-ff` (one revertable commit).
- **Next**: nothing queued pending ADR-0006's sign-off (PR #3) and `NEXT-PHASES.md`'s
  native-primary re-tier. See that file's Tiers/Parked sections for the ranked backlog.

## Environment & account facts

- **Claude cloud sessions tied to `lrau@skyhawk.ai` act as GitHub user `larry-sk`**
  (2026-10-03), which has **pull-only** on `larryr/snarf` — reads and filing issues work,
  pushes 403. Such a session should file a GitHub issue for work it can't land itself (pattern:
  issue #1 / `spike-rhun-self-drawn-frame.md` — write the content, ask `larryr` to land it).
- **Local Mac permission note**: the Claude Code auto-mode classifier blocks some destructive/
  shared-outcome git and GitHub commands (`git push --delete`, `gh pr merge` without a formal
  review) — the user runs those via `! <cmd>` in-session or merges via the web UI instead.
- **Remote sandbox git**: `git push --delete <branch>` is refused by the git proxy (403) —
  merged branches must be deleted by the user/UI or a local session. Ordinary pushes print
  scary noise (`--negotiate-only … RPC failed … 403 …`) yet SUCCEED — confirm with
  `git ls-remote --heads` before concluding a push failed.
- **Self-approval**: GitHub forbids approving your own PR; don't promise an "approve" step.
- **Remote-session repo scope**: only repos attached at start or via `add_repo`
  (same-owner-only v1; fork third-party repos to `larryr/` first).
- **The ACME paper is in-tree**: `docs/acme/` (HTML+PDF+troff+markdown, from the pinned 4e
  fork). Cite `acme paper §N`. doc.cat-v.org/9p.io/plan9.io are proxy-blocked from remote
  sandboxes — use the fork (`raw.githubusercontent.com/larryr/plan9/<full-sha>/…`).
- **Reference forks** (pinned, cite by SHA — see CLAUDE.md): `larryr/plan9port@337c6ac`,
  `larryr/plan9@ed1a9c2`. Local full clones: `~/proj/plan9port`, `~/proj/plan9` (already at the
  pinned SHAs). **plan9port is BUILT on larry's Mac**: `~/proj/plan9port/bin/` holds `devdraw`
  + `acme` (arm64 Mach-O) at the pinned SHA. Use `PLAN9=~/proj/plan9port`,
  `PATH=$PATH:$PLAN9/bin`. Homebrew no longer ships a plan9port formula.
- **Remote sandbox network**: ziglang.org, github releases, kroki.io blocked; apt + PyPI open —
  `pip install ziglang==0.16.0` gives a working Zig; `apt-get install -y plantuml` for
  `-checkonly` (no salt tree-tables — use `@startmindmap`).

## Design notes pending a requirements revision (keep until folded into R-05/S-04)

*(Both frozen with the browser host per the ADR-0005 amendment above — only relevant again if
the browser un-freezes.)*

- **Touch-profile warp semantics**: no pointer between touches, so point-to-type can't apply;
  use acme's `-b` variant (last-touched text keeps focus). Once focus is a software value,
  the paper's warps (R-EDIT-25) map onto moving it and are honorable on touch. Third
  host/profile case alongside desktop-no-warp and native-real-warp.
- **Tablets with hardware keyboards/trackpads** behave like desktop browsers (real synthesized
  pointer), not touch — profile selection (R-IN-08) must be per-event, not per-boot; focus
  model must be hybrid (hover while a pointer is present, last-touch for touches). OQ-IN-4:
  verify iPadOS/Android button mapping with a real device before the touch wave.

## Learnings / dead ends (keep — reusable, timeless)

- **Gate pattern**: `zig build test | grep …` returns the LAST pipe stage's exit code — a
  failing suite can ride a green-looking `&&` chain. Run tests to a file, check `$?`, then
  grep the file. Shell `printf '0x%x'` mangles > INT64_MAX — use python for hash conversions.
- **Git close-out**: never `git add -A` near close-out; stage explicit paths; `git status`
  before ANY commit on main; don't mix newline/`&&` chaining in critical sequences.
  `.claude/` is gitignored.
- **Agent orchestration**: worktrees spawn from possibly-stale refs (agents must verify a
  marker file or rebase); each agent adds its OWN namespace-root re-export or its tests are
  vacuously unreachable; type-only imports still serialize builds; the inspect wave catches
  real bugs — keep it.
- **Zig 0.16 API notes**: build = `b.addModule`/`createModule`, `.root_module`, target only on
  root; wasm exports = `entry .disabled` + `rdynamic` + `export fn`; `refAllDeclsRecursive`
  gone. Networking = `std.Io.net` + `std.Io.Threaded` (`std.net` GONE); reader/writer via
  `stream.reader(io,&buf).interface`; files via `std.Io.Dir`; `std.http.Server` has
  server-side WebSocket built in; custom headers via `respond` `extra_headers`;
  `trimRight`→`trimEnd`; build→exe constants via `b.addOptions()`.
- plan9port acme at the pinned SHA = 15,830 lines / 25 files; per-file counts are in the S-07
  survey table — don't recount.
