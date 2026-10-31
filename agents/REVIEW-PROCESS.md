# PR review process — snarf mapping

The global process (5 stages, `~/.claude/CLAUDE.md`: prior art → lanes → synthesis →
precheck + arbiter → a person decides) governs; this file maps its generic terms to
snarf. Agents draft; **Larry makes every decision that counts** — he alone merges
(also enforced by credentials).

## Stage 1 — prior art and ground truth
- Prior art: closed/open PRs and issues, `agents/REVIEW-NOTES.md`, the HANDOFF's
  dead-ends section, `agents/reports/phase*.md`.
- Ground truth: `gh pr view --json headRefOid,baseRefName,files` and `git fetch` of the
  PR branch — never the PR body, never a local worktree. Cite `file:line` at the PR head.
- Canon handed to every lane: `CLAUDE.md`, `agents/HANDOFF.md` (gotchas + in-flight
  claims), and the `agents/contracts/phase*.md` rulings for every area the PR touches.
- Contract impact = ADRs (`docs/spec/adr/`, immutable once accepted), requirement R-IDs,
  spec sections (S-00…S-07), FROZEN-* goldens (any re-freeze needs orchestrator sign-off,
  R-P2-7), and the pinned-C citation policy (behavior claims cite `acme/file.c:NNN`
  at `larryr/plan9port@337c6ac` / `larryr/plan9@ed1a9c2`).

## Stage 2 — lanes
- Split by THIS PR's risk; typical snarf lanes: **core fidelity** (behavior vs. the
  pinned C, citation spot-checks), **host/9P** (namespace, devices, hostfs), **build +
  gates**. Deep lanes run on a strong model (opus); the build lane runs the FULL matrix:
  `zig fmt --check src build.zig tools` · `zig build` (wasm) · `zig build test
  --summary all` (0 fail; record totals) · `zig build native` · `node
  tools/smoke_wasm.mjs` (40/40) · a 2-second `snarf-native` launch killed by recorded
  PID. The launch and smoke are the "outside the CI matrix" items most likely to break
  unnoticed (until PR #44's CI lands, everything is outside it).
- Re-review: re-check each earlier finding first — OPEN / FIXED / PARTIAL / ACCEPTED.

## Stage 3 — synthesis
Per the global process. Out-of-scope findings become `gh issue` drafts (text handed to
Larry while the PAT cannot create issue comments), not review items.

## Stage 4 — precheck + arbiter (snarf mapping)
- Mechanical precheck per finding: citation points at the right code at the PR head;
  the line is in the diff; no `// claude:suppress` marker; the file is reachable from
  some build.zig module/test root (check the module graph — core/ninep import rules,
  S-07 §6); resolved `-D` build options where relevant; call sites by grep; prior art
  in HANDOFF/REVIEW-NOTES/issues.
- Arbiter: a model that did NOT coordinate this review (fresh fable or opus subagent),
  given ONLY the claim list with file:line — no severity, no reasoning, no lane notes.
  Coordinator resolves disagreements at the decisive line.

## Stage 5 — staging and the human decision
- Stage as a PENDING GitHub draft review (`gh api repos/{owner}/{repo}/pulls/{n}/reviews`
  with no `event`, inline comments attached). If the active credential refuses, fall
  back to ONE ordinary PR comment titled "DRAFT REVIEW (not submitted — Larry decides)"
  with the same structure, or hand Larry the markdown directly.
- Body shape: action items only above a separator; Details below it with confidence,
  arbiter result, mechanism, and fix per point. Never re-list fixed items.
- The agent never submits a review verdict, never approves, never merges. Larry edits
  and chooses Comment / Approve / Request changes, and merges via the web UI.
- Blockers accepted for now are filed as tracking issues (drafted for Larry) so the PR
  can land while the work stays tracked.

## Relation to the build pipeline
The phase pipeline (fable contract → tests-first → opus → sonnet gate → fable verify)
is PRE-merge self-review for phases this session orchestrates. This process covers
every PR — including pipeline PRs (the gate report seeds Stage 1's prior art) and
PRs authored by other sessions/personas, which otherwise had no assigned reviewer.
