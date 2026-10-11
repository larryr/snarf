# notes/snarfprod: SnarfProdd working notes

These are **working notes and proposals by SnarfProdd**, Larry's PM agent. They are **not agreed requirements, and not the agreed product docs either.**

- **Agreed product docs** live in [`docs/product/`](../../docs/product/): the roadmap, the state of snarf, the Pointer Lock spike brief and the touchpad research. That directory is the baseline. A proposal here gets **promoted into `docs/product/` through a PR** once Larry agrees to it.
- **Authoritative requirements, specs and decisions** are [`docs/requirements/`](../../docs/requirements/), [`docs/spec/`](../../docs/spec/) (including [ADRs](../../docs/spec/adr/)) and the execution queue [`agents/NEXT-PHASES.md`](../../agents/NEXT-PHASES.md).
- **Repo rule (Larry, 2026-10-10):** SnarfProdd may commit directly to `main` under `notes/snarfprod/`. Everything else goes through a PR.

| Note | What it is |
|---|---|
| [roadmap-v0.2-proposal.md](roadmap-v0.2-proposal.md) | **Proposal.** Roadmap v0.2, revised after the 2026-10-10 sync (native host primary, browser frozen). Written against [`docs/product/roadmap.md`](../../docs/product/roadmap.md) v0.1 |
| [meetings/2026-10-10-sync.md](meetings/2026-10-10-sync.md) | Meeting note from the Larry ↔ SnarfProdd product sync on 2026-10-10: decisions, roadmap impact, open items, actions |
| [meetings/2026-10-11-followup.md](meetings/2026-10-11-followup.md) | Meeting note from the 2026-10-11 follow-up: local commands fully trusted (run as the user, no silent identity switch), allow-list for remote only; Retina and M4 deferred; immutable-ADR convention |
| [input/input-mapping-guide.md](input/input-mapping-guide.md) | **Future user-guide material.** acme's 3-button mouse as the canonical reference; Magic Mouse and Magic Trackpad mappings under devdraw; trackpad profiles P1–P5 with macOS settings, a comparison matrix and a recommended default |
| [requirements/m5-ai-harness-requirements-draft.md](requirements/m5-ai-harness-requirements-draft.md) | **PROPOSED** R-08 draft for M5 (AI harness): agent as namespace client, grants, runs as the user, visibility and audit, override, multi-client, `Tauth`, where the model runs, eval harness; R-01 v5 and non-goal deltas; open questions |
