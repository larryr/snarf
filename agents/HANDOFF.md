# Session handoff — shared memory between agent sessions

Protocol: see `CLAUDE.md` §"Session handoff protocol". Read top-to-bottom; newest session
entry first. Any session may edit; commit to `main` with prefix `handoff:` (standing
authorization for this file only). Prune freely — git keeps history.

## Current state (update in place)

- **Repo**: design-docs phase complete and merged to `main` (`7214ffe`). No code yet.
- **Docs**: 7 requirements + 8 specs (S-00..S-07) + 4 ADRs + 7 PlantUML diagrams under
  `docs/`. Entry point `docs/README.md`.
- **Next planned work** (not started): scaffold `build.zig`, `.zigversion`,
  `web/index.html` + `web/shim.js` stubs, and the `src/` skeleton per S-07 §4, with
  `zig build` producing a loading `snarf.wasm` and `zig build test` green.
- **Open questions** worth resolving early: Zig version pin (OQ-BLD-1), font licensing
  check (OQ-GFX-2), touch chord-paste gesture (OQ-IN-1).

## Environment & account facts (verified 2026-07-19)

- **GitHub App permissions (remote sessions)**: the Claude integration token for `larryr`
  has Contents (push, branches API) but **no Pull requests permission** — PR
  create/list/merge via API fail 403/404. PRs must be opened by the user in the GitHub UI;
  merges can be done by pushing a git merge commit (GitHub then flips an open PR to
  Merged). Re-test occasionally in case the grant lands.
- **Local `gh` (larry's Mac) 2026-07-19**: `gh` 2.96.0, authed as `larryr` via keyring
  (ssh git protocol), personal token scopes `repo`/`read:org`/`gist`/`admin:public_key`.
  Unlike the remote App token, this has full `repo` scope, so PR create/list/merge work
  locally. Note: `gh auth status` fails ("not logged in") when run in a sandbox without
  keyring access — that's a sandbox artifact, not a real logout.
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
