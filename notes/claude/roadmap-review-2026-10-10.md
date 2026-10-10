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

**REFINED by Fable sync, 2026-10-10** — my original framing lumped M4 and M5 together as
"stop and ask." That's wrong for M4.

**M4 (full acme(4) served tree, external attach, `Tauth`, headless driver) is overwhelmingly
"specified-but-unscheduled," not new product direction.** R-EDIT-17 already SHALLs the full
served tree ("tooling can be written against Snarf just as against ACME"); R-9P-12 already
mandates `/mnt/snarf-self` with "the same file API shape as ACME's"; S-02 §6 already lists
every file (`addr body data tag event ctl xdata`) and already labels external attach "a v2
item." None of this is new — it's existing SHALLs that were simply never pulled into a
`NEXT-PHASES.md` tier (the HANDOFF backlog already half-carries two of these items). The
**one** genuinely new decision inside M4 is making `Tauth` + an external-attach transport
*mandatory* (today optional per OQ-9P-3) — that's one ADR-sized decision, not a requirements
rewrite, and Larry has already signaled the shape of it once (HANDOFF: "`Tauth` first" for
the OPFS-export idea). So: **most of M4 could get its own `NEXT-PHASES.md` tier right now,
under existing requirements, no stop needed** — only the auth/transport piece is gated.

**M5 (AI harness) is still correctly a stop-and-ask — but for a sharper reason than "violates
the stated non-goals."** Checked against the actual text: R-NG-03's "no shell / arbitrary
command execution" doesn't apply — an agent running commands through the same
allow-listed R-EDIT-18 table the human uses (M2, already in `NEXT-PHASES.md` Tier 1 #2) is
not "arbitrary." R-NG-02's "no server-side session state" is only at risk under one specific
*design option* for where the agent's model runs (a stateful origin-side broker), not
inherent to M5 as described. **The non-goal M5 actually brushes against is R-NG-04** ("no
collaborative/multi-user editing") — human + agent sharing one served tree is a multi-client
scenario, something the roadmap's own "architectural choices" section already flags (citing
the single-client fid-recycling assumption from REVIEW-NOTES 13a). The real reason to stop:
**M5 proposes a new actor class (an agent as a namespace client) with no requirement at all**
— R-01 v4 + a new R-08 + a model-connection ADR, exactly what the roadmap's own Decision 4
asks for. `docs/requirements/07-constraints-non-goals.md` is itself stale (still "Draft v1,"
no revision-log entries, even though ADR-0005 already relaxed part of R-NG-03 for the native
host's process service) — worth a clarifying pass regardless of whether M5 proceeds.

## Finding 4 — a core change hiding inside what we called "host-local"

**RESOLVED by Fable sync, 2026-10-10 — verdict: its own small micro-phase, no stop, no ADR,
land BEFORE (and independent of) any Pointer Lock work.**

The Pointer Lock spike brief proposes porting acme's dropped `savemouse`/`restoremouse`
(return-after-popup warp) as "the spike's only core change," citing phase-8 ruling
**R-P8-7**. My original framing of this as "reversing a phase-8 ruling" was **overstated**:
R-P8-7's premise ("mouse warping PERMANENTLY divergent — browsers can't warp") was already
overturned in **phase 15** (ruling R-P15-3, R-EDIT-25 v6 — warping is host-scoped, not an
editor-level divergence). The current R-EDIT-25 text already lists `savemouse`/
`restoremouse`'s call sites (`util.c:384-408`, `cols.c:150/178`) under "not ported yet on any
host" — porting them is simply **the next R-EDIT-25 site**, the same category of work phase
15 already did for `look.c:219`/`:897` with no special process.

**Decisive point I missed**: this is headless-testable *today*, via the `MouseSink` stand-in
`/dev/mouse` (`src/core/warp.zig:132`, already used by `look.zig`/`openfile.zig`'s warp
tests) — directly contradicting the spike brief's own claim that "the third warp can't be
tested on any host." The spike brief's own pass/fail table also says the port "ships
regardless" either way — a change that ships on both branches of a spike doesn't belong
inside the spike. Landing it first (and separately) also keeps the eventual Pointer Lock
phase's honesty check (`git diff -- src/core` empty) auditable, same shape as phase 15's.

Real shape, per Fable's read of the C source: ~40 lines on `Editor` (two fields replacing
acme's `prevmouse`/`mousew` globals — no-globals rule), cleared via the existing
`dropTextRefs` hook on window destruction, called from `Column.add`/`Column.close`
(`cols.c:150/178`), one headless `MouseSink` test, one R-EDIT-25 revision-log line. One
real wrinkle: B3 look is async (R-P13b-2), so the saved pointer position is the latest
sample, not the exact click point — same in practice, worth a sentence in whatever contract
builds it. Also: several code comments (`Column.zig:8`, `Window.zig:7`, `Row.zig:10`,
`colgrow.zig:22-26`, `text/scroll.zig:13-14`) still cite the pre-ADR-0005 "permanently
impossible" rationale and should be re-cited when this lands — doc hygiene, not a blocker.

**Candidate addition to NEXT-PHASES.md**: a small, independent item — "port
`savemouse`/`restoremouse` (return-after-`Del` warp), R-EDIT-25's last unported site,
host-agnostic, headless-tested" — schedulable now, no gating decision needed, could even
piggyback on whatever wave next touches `Column.add`/`close` (Tier 1 #3 Zerox is adjacent).

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

## Side note (Fable sync) — a process rule already in effect, worth naming explicitly

Roadmap's M1 "harness-friendly choice" #1 ("no feature is UI-only; every builtin also gets
its served-tree `ctl` verb") reads as a "Later" aspiration in the doc, but **phase 17 already
did this** (ctl `get`/`put` landed alongside the builtins). Worth stating as a standing
pipeline/contract rule now, not scoped to M4/M5.

## Open, not yet resolved (Larry's calls, not Fable's)

- Sequencing: Pointer Lock now (concurrent) vs. after remaining Tier 1 (external commands,
  builtins)? The `restoremouse` micro-phase (Finding 4) is independent of this either way and
  could land regardless of which way this goes.
- Should the stale `state-of-snarf.md`/`roadmap.md` claims be refreshed by this session or
  left to the SnarfProdd workstream? — **done**: refreshed directly (see `docs/product/`
  diff, branch `docs-product-phase17-refresh`), since they were simple factual-currency
  fixes, not product judgment calls.
- M4: per Fable, most of it is schedulable now under existing requirements (R-EDIT-17,
  R-9P-12) — only the `Tauth`/external-attach-transport piece is ADR-gated. Does Larry want
  a new `NEXT-PHASES.md` tier for it now, or hold until after Tier 1/2?
- M5: confirmed stop-and-ask (new actor class, no requirement) — does Larry want to greenlight
  the R-01 v4 / new R-08 / model-connection-ADR work to start, or is this further out?
- Daily-driver host choice (browser vs. native) — roadmap's Decision 1, unresolved.

**Status: Fable sync complete on Findings 3 and 4.** Both corrected/sharpened above. Ready
to fold the `restoremouse` micro-phase and the M4-is-mostly-backlog reframing into
`NEXT-PHASES.md` once Larry confirms; everything else above needs his direct answer.

---

## Product sync, 2026-10-10 (Larry ↔ SnarfProdd) — native confirmed as primary host

Relayed to this session as a pasted transcript, not yet in `docs/product/`. Key decisions:

1. **Native is the primary host.** Reasoning given: the browser can't reach ACME-level
   usability, and avoiding an install was its only real advantage — moot now that Put/Get
   works and the native host already has real warp. Snarf's job (editing documents, text
   services) happens mostly on the local machine; remote work goes through dedicated
   headless 9P servers (new concept, not yet in any tier).
2. **Browser/WASM is now a frozen secondary target**: must keep building and passing tests,
   gets **no new features**, no WASM-VM wrapping. Core stays host-neutral (changes nothing
   about the R-OV-03 boundary — both hosts still exist, one just stops growing).
3. **Pointer Lock moves out of M0 entirely** — "only matters if the browser host comes
   back." This resolves the open sequencing question from the first Fable sync (concurrent
   vs. after Tier 1) by removing the question: it's not scheduled at all right now. The
   `restoremouse` micro-phase (Finding 4 above) is unaffected — it's host-agnostic and
   benefits native directly regardless of the browser's status.
4. **The host-command allow-list ADR's scope narrows**: "the command policy only applies to
   remote 9P servers." Read plainly, this means the **native process service** (Tier 2 #5,
   `std.process.Child` running Larry's own local commands) is **not** gated on that ADR —
   the allow-list only matters for the origin server when something reaches it from outside
   (remote/external attach, M4 territory). This potentially decouples Tier 2 #5 from the
   ADR that was blocking Tier 1 #2 — worth confirming explicitly with Larry before acting on
   it, since it's a real re-scoping of a decision `NEXT-PHASES.md` currently treats as one
   blocking ADR for both.
5. **New work, not in any tier today**: a **headless 9P server** for remote document editing
   (snarf-native with no window, reachable over 9P) — this is the natural target for M4's
   external-attach work, now motivated by remote human access rather than AI agents first.
   Worth noting M4/M5's infrastructure (served tree, external attach, `Tauth`) is largely
   shared regardless of which motivation drives it.
6. **The devdraw-vs-self-drawn-frame decision is now live**, not parked. With native
   confirmed primary, "choosing between plan9port's devdraw and a self-drawn native window"
   is explicitly named as next work — this is exactly the rhun spike's own question
   (`agents/reports/spike-rhun-self-drawn-frame.md`), previously filed under "Parked" because
   nothing forced the choice. It's forced now.
7. **Trackpad**: hold-and-tap chords + modifier+click (touchpad research's **D1**), since
   Larry uses 3-finger drag. D5 (dual trackpad) stays parked unless multitouch clearly wins.
   Answers that research doc's open question #1 directly (native, not browser).
8. **Still open** (Larry's own list): his top 3 blockers to daily use; phase 17 status
   (**already answered from this side**: shipped, `e734e3f`); roadmap approval; **when to
   bring in "the architect"** — plausibly this session, given the technical depth already
   exchanged on this exact pivot.

### What this changes about the execution plan (my read, not yet actioned)

- **Tier 2 (native host becomes daily editor) should become the near-term priority**, not a
  later tier behind Tier 1's remainder. Items 4 (native file server) and 5 (native process
  service) are now the real next work.
- **Tier 3 (browser host polish: HiDPI, touch profile, Worker+SAB) should be marked frozen**,
  not deleted — "only matters if the browser host comes back" means hold, not cancel.
- **Tier 1 #2 (external commands)** may partially unblock independently of the allow-list ADR
  if item 4 above is confirmed — needs Larry's explicit confirmation before I act on that
  reading, since it reinterprets an existing gate rather than just reordering work.
- **The Parked section's "devdraw built in-tree" and "native frame" items need to stop being
  parked** — this is the one place I think Fable's technical input is worth another pass:
  the rhun spike already did real analysis here (borrow-the-model verdict, ~30-35% frame
  probability, devdraw-in-tree's ADR-0002 amendment), so the question now is whether that
  analysis still holds given native-primary changes the stakes, not starting over.
- **New tier/items needed**: headless 9P server (remote access); trackpad D1 (devdraw patch
  in Larry's own plan9port fork, per the touchpad research's own M2 sizing).

**Not yet done**: no `NEXT-PHASES.md` edits made for this pivot — flagging the scale of the
change and the one technical decision (devdraw vs. frame) worth a fresh look before writing
anything, rather than silently reinterpreting the allow-list ADR's scope or re-tiering
everything without Larry's explicit confirmation.
