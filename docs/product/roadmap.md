# snarf: product feature roadmap (v0.2)

**Status: v0.2 — agreed baseline pending this PR** (product prioritization. Requirements stay authoritative in `docs/requirements/`, decisions in `docs/spec/adr/`, execution in `agents/NEXT-PHASES.md`).

*Replaces v0.1 (2026-10-07, refreshed for phase 17 on 2026-10-10; see git history of this file). Written by SnarfProdd (PM), 2026-10-10, and updated 2026-10-11 after ADR-0005's amendment was accepted (PR #2, merge `1ba1f40`) and after the 2026-10-11 follow-up sync. Sources:*
- *the sync: [`notes/snarfprod/meetings/2026-10-10-sync.md`](../../notes/snarfprod/meetings/2026-10-10-sync.md);*
- *the follow-up: [`notes/snarfprod/meetings/2026-10-11-followup.md`](../../notes/snarfprod/meetings/2026-10-11-followup.md);*
- *the pipeline review with Fable's verdicts: [`notes/claude/roadmap-review-2026-10-10.md`](../../notes/claude/roadmap-review-2026-10-10.md);*
- *[ADR-0005 amendment](../spec/adr/0005-two-hosts-one-core.md) and [R-01 v4](../requirements/01-overview.md);*
- *the repo @ `1ba1f40`.*

*Background docs: [`state-of-snarf.md`](state-of-snarf.md) (snapshot as of phase 17, predates the amendment), [Pointer Lock spike brief](spikes/pointer-lock-warp.md) (parked), [touchpad research](research/touchpad-interaction.md).*

*Proposals linked from here (working notes, not agreed): [input mapping guide](../../notes/snarfprod/input/input-mapping-guide.md) (mouse, Magic Mouse and trackpad profiles; recommended trackpad default) and [M5 AI-harness requirements draft](../../notes/snarfprod/requirements/m5-ai-harness-requirements-draft.md) (PROPOSED R-08).*

*ADR convention (agreed 2026-10-11): ADRs are **immutable once accepted**. A changed decision gets a **new numbered ADR that supersedes** the old one, and the old one gets a Status pointer. ADR-0005's in-place amendment predates the convention and stays as historical record. ADR-0006 (PR #3) is the first ADR under the new rule.*

*Labels: **[found]** = in the repo docs; **[accepted]** = decided in an ADR or requirement; **[inferred]** = my reading; **[Larry]** = product direction from Larry not yet in the requirements.*

## What changed from v0.1
- **Decision 1 is ACCEPTED: the native host is primary**, and the browser is a frozen secondary target (ADR-0005 amendment items 1–2; R-01 v4 R-OV-09). The vision, target hosts, M0, M1 and M3 are rewritten around this.
- **`devdraw` stays the native rendering/input module indefinitely: ACCEPTED** (ADR-0005 amendment item 3). The draft's open "devdraw vs self-drawn window" decision is closed; the self-drawn frame is deprioritized.
- **M0:** the Pointer Lock spike is parked. CI is added, including a WASM-still-builds check. The `savemouse`/`restoremouse` micro-item is split out (Fable, Finding 4).
- **M1:**
  - The browser Clipboard API is dropped, and the clipboard goes native-first.
  - A native file server is added.
  - Phase-17 items are marked shipped.
  - Retina is now a question rather than a commitment.
- **Oct 11 decisions:**
  - Local commands are trusted and run as the logged-in user, with no silent identity switch; elevation only by user-invoked `sudo`.
  - The allow-list is for remote servers only.
  - Retina is deferred until native is running.
  - M4 scheduling is deferred.
  - `.app` packaging is deferred; devdraw is resolved relative to the `snarf-native` executable.
- **M2:** the allow-list is scoped to remote 9P servers (**decided 2026-10-11**), and a headless 9P server is added.
- **M3:** opens with **Zig build of devdraw + runnable native snarf** (in progress; `.app` packaging deferred), with product done-criteria. Native polish follows.
- **M4:** reframed as backlog that can be scheduled now.
- **M5:** still stop-and-ask, with a sharper reason.
- **Process:** two standing rules are added. A proposed R-IN-06 change is noted, but requirements are not edited.

## Vision

> **Now:** Larry opens **native snarf** on his Mac and does his real day's work in it: ACME semantics with real warp, his files, his commands, his clipboard. **[Larry]**
>
> **Hosts [accepted: ADR-0005 amendment, R-01 v4]:** snarf ships as **targeted native binaries** (Zig cross-compile, native host per ADR-0005), with **plan9port `devdraw` as the display and input server, indefinitely**. The **browser/WASM build is a frozen secondary target**: it keeps building and passing tests, but gets no new features. The core stays host-neutral (R-OV-03, R-OV-09), so the browser can return later without a core change. Remote work goes through **dedicated headless 9P servers**, not a browser tab (headless server: no requirement yet).
>
> **Later:** snarf becomes a **developer AI harness**. AI agents work in the same editor through the same 9P file interface the human's tools use. **[Larry]**, made concrete by me **[inferred]** from R-EDIT-17/19 and R-9P-04.

**Why native [Larry]:** the browser can't reach ACME-level usability, and no install was its only real benefit. Snarf's job is editing documents and running text services, which is mostly heavy local use.

**Founding vision** **[found, R-01 §2 + v4 note]:** "A programmer opens a single web page…" is kept as written, but R-01 v4 now labels it the **zero-install showcase** vision (browser, frozen). The **daily-driver** target is native.

## Target users
1. **Larry: primary, daily driver, on native macOS** **[Larry]**.
2. **Acme-fluent programmers on Mac and Linux trackpads or mice**, through native binaries **[inferred]**. Secondary.
3. **AI agents (and the people running them)** **[Larry, later]**.

The non-users from v0.1 are unchanged (R-NG-04/05/06).

## Milestone overview

| # | Milestone | Outcome for Larry | Headline features |
|---|-----------|-------------------|-------------------|
| **M0** | Ground truth *(Now)* | Trust what's built | CI incl. a WASM-builds check, `restoremouse` warp, a guided walkthrough on native |
| **M1** | Edit real files on native *(Now)* | Open, edit and save local files, copy/paste with macOS | ~~Put/Get/Dump/Load~~ (shipped), **native file server**, native clipboard, builtins, Retina? |
| **M2** | Run real commands *(Next)* | `mk`, `zig build`, `git` from B2, output in `+Errors` | Native process service, pipes, `Kill`, remote-only allow-list ADR, **headless 9P server** |
| **M3** | Native daily-driver polish *(Next)* | Larry stops opening other editors | **Zig-built devdraw + runnable `snarf-native`** (in progress), trackpad chords, native polish, IME |
| **M4** | Programmable editor *(schedulable; timing deferred)* | acme tooling and scripts drive snarf from outside | Full acme(4) served tree (already SHALLed), headless driver; `Tauth`/external attach (ADR-gated) |
| **M5** | AI harness *(stop-and-ask)* | An agent works beside Larry, visibly and safely | Needs new requirements first |
| — | Frozen / parked | not scheduled | Browser features (Pointer Lock, Clipboard API, touch, Worker+SAB, HiDPI), dual trackpad |

Sizes: **S** = less than one pipeline phase · **M** = one phase · **L** = several phases or ADR-first.

---

## M0: Ground truth (Now)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **CI on push (macOS + Linux)** | Every push runs `zig build`, `zig build test`, fmt, `zig build native`, **and a WASM-build-still-compiles check** (plus the smoke test) | **A precondition of the browser freeze holding**: ADR-0005 amendment Risks says the "SHALL continue to build / pass tests" clause is unenforceable without CI. Also daily-driver reliability and a future agent eval harness | R-BLD-03, S-06 §5, NEXT-PHASES Tier 4 #11 | S | A workflow file (needs a PR). The smoke test needs Node ≥ 22 |
| **Return-after-`Del` warp (`savemouse`/`restoremouse`)** | Deleting a pop-up window (e.g. `+Errors`) puts the pointer back where it was | The paper's third warp. Real on native today because devdraw warps | R-EDIT-25 (last unported site: `util.c:384-408`, `cols.c:150/178`); Fable Finding 4 | S | None. Explicitly unaffected by the freeze (ADR-0005 amendment item 2). **Host-agnostic, headless-tested through the `MouseSink` `/dev/mouse` stand-in (`src/core/warp.zig`), independent of any spike.** About 40 lines on `Editor`, cleared via `dropTextRefs`, plus one R-EDIT-25 log line |
| Guided manual walkthrough (native) | A 15-minute checklist in native snarf: chords, B3 sweeps, Del two-strike, Delcol, Edit, undo grouping, warps | Gestures never tried by a human (HANDOFF) | R-EDIT-05..12, 25 | S | — |
| ~~Phase 17 status~~ | Done: shipped `e734e3f` | — | `agents/reports/phase17-put-get-dump-load.md` | — | — |
| *Parked:* Pointer Lock warp spike | Only if a browser host returns | Native already warps. Its value was settling the host choice, which is now settled | Brief kept: [`spikes/pointer-lock-warp.md`](spikes/pointer-lock-warp.md). Parked by ADR-0005 amendment item 2 ("Only Pointer Lock parks") | M | Amendment reversed |

## M1: Edit real files on native (Now)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| ~~Put / Get / Putall~~ **SHIPPED (phase 17)** | Save, reload, save all | — | R-EDIT-15, `e734e3f` | — | — |
| ~~Create on origin export~~ **SHIPPED (phase 17)** | New files under `/n/origin/fs/` | Browser path, now frozen | `tools/origin/hostfs.zig` | — | `remove` still unbuilt, now low priority |
| ~~Dump / Load~~ **SHIPPED (phase 17)** | Restore a session | — | R-EDIT-16 | — | Native `$home` is `NotMounted` until the next row lands |
| **Native file server** | Native snarf reads and writes local files directly: **Put/Get/Dump/Load work on native** | Today native returns `NotMounted` for these (phase 17), so this is the #1 native blocker | ADR-0005 §2, NEXT-PHASES Tier 2 #4 (`tools/origin/hostfs.zig` reused in-process) | M | — |
| **System clipboard, native-first** | Snarf/Cut/Paste exchange text with macOS apps | Daily editing crosses apps. Today the buffer is internal (`src/core/snarf.zig`) | R-EDIT-14, R-9P-07; devdraw `Trdsnarf`/`Twrsnarf`; NEXT-PHASES Tier 2 #6 | S–M | — (**browser Clipboard API dropped**: frozen target) |
| **Small builtins: Sort, Zerox, Kill, Exit** | Tag commands that do nothing today start working | Dead tag words erode trust | R-EDIT-02, NEXT-PHASES Tier 1 #3 | S–M | Zerox needs multi-Text-per-File. Kill pairs with M2 |
| Retina text **(question)** | Crisp text on a Retina display | Was the "top user-felt gap" **in the browser** | R-GFX-05 | ? | **Deferred (2026-10-11)** until native is merged and running. devdraw handles Retina (ADR-0005 consequences), so keep this only if Larry still sees soft text on native. The M3 checklist records it |

## M2: Run real commands (Next)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **Native process service** | B2 on `mk`, `zig build`, `grep -n foo *.zig` runs a real local process. Output goes to `dir/+Errors`, and B3 on `file.zig:42` jumps there | This is what makes acme an IDE | R-EDIT-06/18/20/21, NEXT-PHASES Tier 2 #5 | L (two waves) | M1 native file server |
| **Host-command allow-list ADR, remote scope only** | Policy for which commands a **remote 9P server** may run, where, and for whom | Exec reachable from the network is RCE. **Local native = fully trusted [decided 2026-10-11]**: local commands run as the logged-in user. Snarf never silently switches identity, and elevation happens only if the user invokes `sudo` or similar | R-EDIT-18, R-NG-03, OQ-EDIT-1 | S (doc) | The requirement text (R-NG-03/R-EDIT-18 local-vs-remote clause) is still to be written when the allow-list ADR is drafted (ADR-0005 amendment item 4). Under the immutable-ADR convention, that will be a new ADR. The native process service is not gated on it |
| Pipes `\|cmd`, `<cmd`, `>cmd` | Filter the selection through a command | Everyday text surgery | R-EDIT-06 | M | Process service |
| `Kill` / long-running output | Stop a runaway command, and output keeps streaming | Builds run long | R-EDIT-02 | S | Process service |
| **Headless 9P server for remote machines** | Run snarf's file and command services windowless on a remote box, then mount it from local native snarf to edit and build remote documents | Replaces the browser as the remote story **[Larry]** | **No requirement yet [inferred]**; nearest: S-02 §6 external attach, ADR-0003 headless backend | L | Allow-list ADR (remote scope), `Tauth` (M4) |

**Harness-friendly choice:** design the remote allow-list as **who × what × where**, so a future agent gets a narrower grant through the same mechanism.

## M3: Native daily-driver polish (Next; first item in progress)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **Zig build of devdraw + runnable native snarf** *(Claude session in progress)* | One command builds `snarf-native` plus a sibling `devdraw` that Larry runs to get native snarf: no separate plan9port install. **`.app` packaging is deferred** (2026-10-11) | The last install step between Larry and a daily driver. With `devdraw` accepted indefinitely (ADR-0005 amendment item 3), this is the distribution answer, not a rendering-ownership question | ADR-0005 amendment; NEXT-PHASES Parked "devdraw built in-tree"; **ADR-0006 (proposed, [PR #3](https://github.com/larryr/snarf/pull/3))**: fetch pinned `larryr/plan9port@337c6ac` via `build.zig.zon` and compile the devdraw closure. It supersedes only ADR-0002's empty-dependency clause, per the immutable-ADR convention. It also sets the `Conn.devdrawPath` resolution order | M | ADR-0006 acceptance (Larry). Done-criteria and checklist below |
| Trackpad chords (D1) | Hold a click and tap another finger: +B2 Cut, +B3 Paste, and 2-1 from B2. Modifier+click stays | Chords on a Mac trackpad without hunting for keys | [touchpad research](research/touchpad-interaction.md) D1; profile P3 in the [input mapping guide](../../notes/snarfprod/input/input-mapping-guide.md) (proposal; recommended default today is P2, the modifier profile) | M | A patch in `devdraw` (Larry's `larryr/plan9port` fork), then a re-pin of the ADR-0006 snapshot. Stock devdraw already gives modifier chords, 2-finger click = B3, 3-finger tap = B2, 4-finger tap = 2-1 |
| Native polish | Window title, `-b` flag, `Conn` reader on `std.Io` | Feels finished | NEXT-PHASES Tier 2 #6 | S | — |
| Keyboard / IME | Non-ASCII composition | If Larry needs it | R-IN-11 | M | — |
| Structure pass | 16 over-cap files | Filler | NEXT-PHASES Tier 4 #0 | S–M | — |

**Product done-criteria: Zig-built devdraw + runnable native snarf**
1. **One command, then a runnable Mac app.** On a clean Mac with Zig 0.16 and no plan9port, a single documented command (e.g. `zig build native`, plus a packaging step if it's separate) produces `snarf-native` with `devdraw` beside it, which Larry can launch with no `$PLAN9` needed. **devdraw is resolved relative to the `snarf-native` executable**, not the working directory (2026-10-11). A `.app` bundle is deferred. The first fetch may need the network. `zig build` and `zig build test` stay network-free (ADR-0006).
2. **Crisp Retina text: check it, but it is not a gate.** Retina is deferred until native is merged and running (2026-10-11). Record what you see on a Retina display. If text is soft, the M1 Retina row becomes real work. If crisp, that row is dropped.
3. **Trackpad chords work.** On a MacBook trackpad and on a Magic Trackpad:
   - 1-finger click = B1, 2-finger click = B3, Option-click = B2.
   - Mid-sweep, Option adds B2 (Cut), Command adds B3 (Paste), and Control adds B1 (the 2-1 chord).
   - Larry uses three-finger drag, so 3/4-finger taps are not required. Hold-and-tap (D1) is a follow-up, not a gate.
4. **Real warp works:** B3 on a search hit and opening a file move the pointer.
5. **devdraw is chosen in ADR-0006's order, and the choice is logged.** The order is `$DEVDRAW` (an exact binary; a deliberate override always wins), then the **bundled** `devdraw` resolved relative to the `snarf-native` executable, then `$PLAN9/bin/devdraw`, then bare `devdraw` on `$PATH`. `$PLAN9` ranks below the bundled default, so a plan9port install that happens to be set in the environment doesn't silently shadow the tested build. `snarf-native` prints which `devdraw` it resolved, and from where, at startup.

**Hands-on checklist for Larry** (about 15 minutes, on the Mac you actually use):
- [ ] From a fresh clone, run the one documented command. Note wall time and whether it fetched anything. Launch the app.
- [ ] Is the text crisp? Compare against plan9port acme, or zoom a screenshot. Record only; Retina is deferred.
- [ ] Open a real file (B3 on a path, or `Get`). Edit it, `Put`, and confirm the file changed on disk. *(This needs the M1 native file server. If it isn't landed yet, note "NotMounted" and move on.)*
- [ ] B1 sweep, then Option mid-sweep: the text is cut. B1 sweep, then Command mid-sweep: the text is pasted. Option-click on a word, then Control: the 2-1 chord runs it with an argument.
- [ ] 2-finger click on a word looks it up (B3), and the pointer warps to the hit.
- [ ] Snarf in snarf, then paste in another macOS app, and the reverse. *(This needs the M1 native clipboard. Note pass or fail.)*
- [ ] Repeat the chord checks on the second trackpad (Magic Trackpad vs MacBook).
- [ ] Write down the **top 3 things that stopped you from staying in snarf**. That list becomes the next M1–M3 cut.

## M4: Programmable editor, the harness foundation (schedulable; timing deferred 2026-10-11)

*Reframed per Fable (review Finding 3). Most of M4 is **specified but unscheduled**: R-EDIT-17 already SHALLs the full served tree, R-9P-12 mandates `/mnt/snarf-self` with acme's file API shape, and S-02 §6 lists every file and labels external attach "a v2 item". It can get a NEXT-PHASES tier now under existing requirements. **Only `Tauth` plus the external-attach transport is ADR-gated.***

| Feature | User-facing description | Traces to | Size | Gate |
|---|---|---|---|---|
| **Full acme(4) served tree** | `addr, data, xdata, event, errors, rdsel, wrsel, editout`, and the full `ctl` verb set | R-EDIT-17, R-9P-12, S-02 §6, `fsys.zig` SEAM(O21) | L | None: existing SHALLs |
| **Headless scripted driver** | Run snarf windowless and script it: keys, clicks, hashes | NEXT-PHASES Tier 4 #11, S-06 `snarf-headless`, ADR-0003 | S–M | None |
| acme tooling compatibility | Go `9fans.net/go/acme` clients work against snarf | R-EDIT-17 | S | Served tree, attach |
| **External attach + `Tauth`** | Outside programs (CLI tools, the M2 remote setup, agents) mount snarf's tree, authenticated | OQ-9P-3, R-9P-15, S-02 §6 | M + ADR | **ADR**: makes `Tauth` and a transport mandatory. Shared with M2's headless server |

## M5: AI harness (stop-and-ask)

*Still **stop-and-ask**, but for a sharper reason (Fable, Finding 3). M5 introduces a **new actor class (an agent as a namespace client) with no requirement at all**. It brushes against **R-NG-04** (no multi-client editing), not R-NG-03: an agent running allow-listed commands through R-EDIT-18 is not "arbitrary execution". R-NG-02 is only at risk under one model-placement option. Before building anything: R-01 v5, a new R-08, and a model-connection ADR. A starting draft exists: [M5 requirements draft](../../notes/snarfprod/requirements/m5-ai-harness-requirements-draft.md) (PROPOSED).*

The feature list is unchanged from v0.1:

| Feature | User-facing description | Why it matters | Traces to (existing hooks) | Size | Depends on |
|---|---|---|---|---|---|
| Agent as a namespace client | An agent attaches to snarf like any acme client: reads windows, edits via `addr`/`data`, runs commands via `/bin` | Uses the architecture as-is. No special agent API | R-EDIT-17, R-9P-04, R-OV-03 | M | M4 |
| Per-agent namespace & permissions | Each agent gets its own mount table: which dirs, which commands, read-only vs write | Safety. Plan 9 per-process namespaces are a natural sandbox | R-9P-03 (bind/mount per instance), R-9P-15, M2 allow-list policy | L | M2 ADR, M4 auth |
| Agent windows & visibility | An agent's activity shows up in windows (`+Agent`, like `+Errors`), so Larry sees and can undo every change | Human stays in control. Undo works across agent edits | R-EDIT-21 pattern, R-EDIT-11 | M | — |
| `kbd hold` / deliver-first events | A client can intercept keystrokes and B2/B3 before they apply (for agents *and* the deferred vim layer) | Lets an agent act as a co-pilot on typed commands | S-02 §6, OQ-EDIT-4, R-EDIT-19 (**deferred by Larry: "don't build unprompted"**) | M | M4 event file |
| Audit log | Every agent read/write/exec is recorded to a file | Trust, debugging, replay | R-9P-14 (line-oriented text files) | S | M4 |
| Model connection | Where the LLM runs and how it reaches the namespace (origin-side process, native host process, remote) | Shapes security and deployment | R-NG-02 (no server-side session state), R-CON-03, OQ-9P-2 (`/dev/fetch`) | L (ADR) | Decision 4 |


## Frozen / parked
- **Frozen with the browser host** (ADR-0005 amendment item 2: must keep building and testing, may get bug fixes, gets no new features): Pointer Lock lock-mode wave and spike, browser Clipboard API, browser key-capture audit, Worker+SAB, HiDPI for the browser, touch profile + hybrid focus (R-IN-06, OQ-IN-1, OQ-IN-4), chordbar (R-IN-07), `/mnt/host`, `/dev/storage`, `/dev/dom`, GitHub Pages and ReleaseSmall deploy.
- **Deprioritized:** self-drawn native frame (ADR-0005 amendment item 3; revisit only for a concrete forcing reason such as Wayland).
- **Parked:** dual Magic Trackpad chord pad (touchpad D5). Revisit only if multitouch clearly adds something a modifier key can't, given the cost of both hands off the keyboard **[Larry]**. Also parked: `win` terminal windows (OQ-EDIT-3), plumber rules (OQ-EDIT-2), webview shell.

## Process (standing rules)
1. **Every builtin also gets its served-tree `ctl` verb**, with a test through `/mnt/snarf-self`. This was a "Later" aspiration in v0.1. It is now a standing definition-of-done rule, since phase 17 already did it (`get`/`put`).
2. **The roadmap and `agents/NEXT-PHASES.md` coexist.** The roadmap handles product prioritization: milestones, user value, Larry's calls. NEXT-PHASES is the execution queue the pipeline builds from, refreshed from the roadmap's calls. Neither supersedes the other (review recommendation, agreed in the sync).
3. Every human-visible behavior still crosses 9P (R-OV-03). This is unchanged and is what keeps both the frozen browser and the AI path open.

## Architectural choices to protect the AI-harness path (early phases)

For the tech architect. Most of these cost little now and a lot to retrofit later.

1. **No UI-only features.** Every builtin also gets its served-tree ctl
   verb/file and a test through `/mnt/snarf-self` (R-EDIT-17).
2. **Allow-list ADR = identity-aware policy** (who × what × where), scoped to **remote** 9P servers (local native = trusted, decided 2026-10-11).
3. **acme(4) wire compatibility, byte for byte** for `event`/`addr`/`ctl`, so existing acme
   clients and any agent built for acme work unchanged.
4. **Keep R-OV-03 strict.** Anything a human can do must cross 9P (already enforced by the
   `core` import rules, S-07 §6). This is what makes agents first-class for free.
5. **Text, stable formats** for Dump, `+Errors` and command output (R-9P-14), so agents
   can parse them.
6. **Undo covers external edits.** Edits via `body`/`data` writes must land in the
   window's undo log like typed edits, so Larry can always roll back an agent.
7. **Headless driver + golden hashes stay deterministic.** They become the agent eval and
   regression harness.
8. **Don't foreclose multi-client.** OQ-OV-2 (multi-tab) and R-NG-04 (no collab) are
   right for v1. Note that "human + agent on one namespace" is a multi-client scenario and
   ask the architect to avoid single-client assumptions (e.g. fid recycling that assumes
   in-order peers, REVIEW-NOTES 13a).
9. **The headless 9P server and M4 external attach should share one transport and auth design** (new in v0.2).


## Open proposal (not a requirements edit)
- **R-IN-06 finger mapping.** R-IN-06 says 2-finger tap = B2 and 3-finger tap = B3. macOS and devdraw use **2 fingers = B3** (secondary click) and **3-finger tap = B2** (devdraw since `9af9ceca`). Proposal: align R-IN-06 to the macOS/devdraw convention (review Finding 5). Caveat: **Larry uses macOS three-finger drag, so 3-finger tap is unreliable for him.** This is why D1 (hold-and-tap plus modifier+click) is his trackpad path. The touch profile is frozen with the browser, so this is a zero-code text fix, and it is not made here. It needs a PR when Larry wants it.

## Follow-ups owned elsewhere (not in this roadmap's PR)
- **`agents/NEXT-PHASES.md` re-tier** (Tier 2 ahead of Tier 1's remainder, Tier 3 frozen, `restoremouse` micro-item, headless 9P server, devdraw-in-tree promoted out of Parked): Claude pipeline, per the ADR-0005 amendment item 1.
- **R-NG-03 revision-log line** (local vs remote command execution): Claude pipeline, when the allow-list ADR is drafted (ADR-0005 amendment, "Still pending").
- **ADR-0006 (proposed)** (devdraw fetch; supersedes only ADR-0002's empty-dependency clause): PR #3, Larry's sign-off.

## Remaining open decisions for Larry
1. **Your top 3 daily-use blockers** on native, to cut M1–M3 to the minimum.
2. ~~Confirm local native = trusted~~ **Decided 2026-10-11**: trusted, runs as the user, allow-list for remote only.
3. **Retina on native:** *deferred* until native is merged and running. Then: is text still soft under devdraw?
4. **M4 tier:** *deferred* (2026-10-11). Revisit with the M5 greenlight, since M5 depends on M4.
5. **M5 greenlight:** start the new R-08 and the model-connection ADR, or hold? (R-01 v4 already landed for native-primary. M5 would need a further R-01 revision for the agent actor.)
6. **R-IN-06 finger mapping:** align to macOS/devdraw (open proposal above)?

## Questions for the architect
- One transport and auth design for the headless remote server and M4 external attach?
- devdraw lookup relative to the `snarf-native` executable (decided 2026-10-11): how does it fit ADR-0006's `$DEVDRAW` → bundled → `$PLAN9` → `$PATH` order (revised after SnarfProdd's PR #3 review — bundled now outranks `$PLAN9` so an ambiently-set plan9port install doesn't shadow the tested build)? Where would it look inside a future `.app` (deferred)?
- The Retina check: does snarf's font path (R-GFX-05, OQ-GFX-2) need a 2× subfont even under devdraw, or does devdraw's scaling suffice?
