# Working notes — reviewing `docs/product/roadmap.md` (2026-10-10)

**Status: DRAFT / in-progress discussion**, same convention as
`phase-review-2026-10-03.md`. Fold settled parts into `NEXT-PHASES.md`/HANDOFF/specs once
stable, then this file can go.

## Context

While phase 17 (Put/Get/Putall/Dump/Load) was running, a separate "SnarfProdd" PM
workstream landed `docs/product/{README,state-of-snarf,roadmap,spikes/pointer-lock-warp,
research/touchpad-interaction}.md` directly to `main` (Larry's own commits `646504e`,
`98768fb`). Those docs are dated/pulled from `cf9e30c` (2026-10-07/09), **before** phase 17
merged (`e734e3f`, 2026-10-10). This review is my own pass; Fable's gut-check on the
architecturally substantive bits is running in parallel (see below).

## Finding 1 — the docs are now stale on exactly the items phase 17 just closed

`state-of-snarf.md` §4 lists "Put, Putall, Get for files" and "Dump/Load session" as
"specified but not built," and separately flags that the origin's `fs/` export can't create
new files — **both are now done** (phase 17, merged `e734e3f`). `roadmap.md`'s M1 table
lists the same two items as open work, and its "Top decisions for Larry" #3 directly asks
"is Phase 17 running?" — **answerable now: yes, done, merged.** Not a criticism of the PM
doc (it couldn't have known), just needs a refresh pass before it's used to plan what's
next, or the next planning round will double-count already-finished work.

## Finding 2 — real reprioritization proposed, not just reordering

Three items move earlier or get added relative to `NEXT-PHASES.md`:
1. **Pointer Lock spike** → roadmap's M0 (first item, concurrent with M1/Put-Get) vs. our
   2026-10-03 decision (parked, Tier 1 finishes first). Direct conflict with the sequencing
   call made in this session — needs Larry's explicit re-confirmation either way, not a
   silent override in either direction.
2. **Browser system clipboard** (`/dev/snarf` via the Clipboard API, R-9P-07/R-EDIT-14) —
   roadmap puts this in M1 ("Now"). **This isn't in `NEXT-PHASES.md` at all** — Tier 2 item
   6 only wires `/dev/snarf` on the *native* host (which already has `Trdsnarf`/`Twrsnarf`
   via devdraw). The browser side is a genuine gap in the execution plan, not a reordering.
3. **Retina text (2× font)** — roadmap moves this from Tier 3 (polish) to M1 (Now, "top
   user-felt gap"). A legitimate product call, but a real priority bump, not a rename.

## Finding 3 — M4/M5 are scope the execution plan doesn't cover at all

`NEXT-PHASES.md` has no tier for the full acme(4) served tree (`addr`/`data`/`xdata`/
`event`/etc. — M4), external 9P attach + `Tauth` (M4), or the AI-harness primitives (M5:
agent-as-namespace-client, per-agent namespaces, `kbd hold` un-deferred, audit log). This
isn't a conflict — `NEXT-PHASES.md` simply never had this horizon — but it means the two
docs aren't fully reconcilable by just re-ordering; M4/M5 would need **new Tier(s)** added
to `NEXT-PHASES.md`, and M5 explicitly needs new requirements (R-01 v4, a new R-08) before
any of it is buildable. The roadmap itself says this; flagging that it's a real "stop and
ask" item, correctly self-identified.

## Finding 4 — a core change hiding inside what we called "host-local"

The Pointer Lock spike brief (`spikes/pointer-lock-warp.md` §Scope, item 3) proposes
porting acme's dropped `savemouse`/`restoremouse` (return-after-popup warp; dropped phase 8,
ruling **R-P8-7**) as "the spike's only core change." Our 2026-10-03 review concluded
Pointer Lock work was host-local shim behavior needing no ADR — that conclusion was about
the Esc/lock-loss handling specifically, and still holds for that part, but a core change
reversing a phase-8 ruling is a different thing and wasn't in scope of what we blessed.
Not necessarily a problem (small, well-cited, benefits the native host too, doesn't touch
`draw`/`ninep`), but the spike brief's own open question #6 asks exactly this: "acceptable
under the stop-and-ask rule, or its own micro-phase?" — a real question for Fable/Larry, not
something to wave through by inertia.

## Finding 5 — a real, cheap, low-risk correction worth taking regardless of sequencing

`research/touchpad-interaction.md` §5 D1 finds **R-IN-06 conflicts with the actual macOS/
devdraw convention**: R-IN-06 specifies 2-finger tap = B2, 3-finger tap = B3; real macOS
trackpads + devdraw already do 2-finger = B3 (secondary click), 3-finger = B2 (devdraw's own
shipped behavior since commit `9af9ceca`, 2018). Recommendation (mine, not yet confirmed):
align R-IN-06 to the shipped convention rather than the other way around — it's a spec-text
fix, zero code impact today (the touch profile doesn't exist yet), and avoids baking in a
wrong number before the touch profile wave ever starts.

## What's good here, not just gaps

- Provenance labeling (`[found]`/`[inferred]`/`[Larry]`) throughout — makes the doc auditable
  against the actual repo rather than taken on faith.
- The Pointer Lock spike's own research is **more rigorous than our 2026-10-03 pass**: cites
  the W3C spec directly, finds that unlocking snaps the real cursor back to the lock-*entry*
  point (not snarf's tracked virtual position) and that Safari's unlock banner can swallow
  the first Esc — real risks neither Fable review surfaced. Whenever Pointer Lock is picked
  up, start from this doc.
- "Architectural choices to protect the AI-harness path" (roadmap.md, near the end) — e.g.
  "no UI-only features," "acme(4) wire compatibility byte for byte," "keep R-OV-03 strict" —
  is good forward-looking guidance and doesn't conflict with anything already decided.
- Touchpad research correctly scopes finger-count tricks as **native-host-only**, consistent
  with ADR-0005's host-scoped-divergence framing, and correctly separates "devdraw patch in
  Larry's own fork" from "snarf core" — no boundary violation proposed anywhere in it.

## Recommendation on the "does roadmap supersede NEXT-PHASES" question

**Coexist, don't replace.** `roadmap.md` is product-prioritization input (milestones, user
value, what Larry wants and why); `NEXT-PHASES.md` is the execution queue the pipeline
actually builds from (file-level, phase-sized, proven across 17 phases). Recommend:
`NEXT-PHASES.md` gets refreshed from the roadmap's prioritization calls (clipboard, Retina,
Pointer Lock timing) rather than retired in favor of it, and M4/M5 get their own new tiers
once/if Larry authorizes that horizon. The roadmap document itself says "it mostly agrees
with it, re-ordered around daily-driver value" — this framing fits that.

## Open, not yet resolved

- Sequencing: Pointer Lock now (concurrent) vs. after remaining Tier 1 (external commands,
  builtins)?
- Should I refresh `state-of-snarf.md`/`roadmap.md`'s stale "not built" claims myself, or
  leave that to the SnarfProdd workstream next time it runs (risk: double-work or
  conflicting edits to docs I don't fully own)?
- M4/M5: treat as validated future direction to plan toward now, or set aside as unvetted
  PM speculation until Larry explicitly greenlights the requirements work?
- Daily-driver host choice (browser vs. native) — roadmap's Decision 1, unresolved.

**Status: syncing with Fable now on Findings 3 and 4 specifically** (scope-reconciliation
and the restoremouse core-change question) — those are the two with real architectural
weight; the rest are Larry's calls to make, not Fable's to judge.
