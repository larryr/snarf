# snarf: product feature roadmap (v0.2 proposal)

**Status: Draft v0.2 — revised after 2026-10-10 sync** (a PM proposal, not agreed requirements).

*This is a proposal against [`docs/product/roadmap.md`](../../docs/product/roadmap.md) (v0.1 plus Larry's phase-17 refresh), which stays the agreed baseline until this is promoted by PR. Written by SnarfProdd (PM), 2026-10-10. Sources:*
- *the sync: [`meetings/2026-10-10-sync.md`](meetings/2026-10-10-sync.md);*
- *the pipeline review with Fable's verdicts: [`notes/claude/roadmap-review-2026-10-10.md`](../claude/roadmap-review-2026-10-10.md);*
- *the repo @ `7352203`.*

*Background docs, unchanged: [`state-of-snarf.md`](../../docs/product/state-of-snarf.md), [Pointer Lock spike brief](../../docs/product/spikes/pointer-lock-warp.md), [touchpad research](../../docs/product/research/touchpad-interaction.md).*

*Labels: **[found]** = in the repo docs; **[inferred]** = my reading; **[Larry]** = product direction from Larry not yet in the requirements.*

## What changed from v0.1
- **Decision 1 is resolved: the native host is primary**, and the browser becomes a frozen secondary target. The vision, target hosts, M0, M1 and M3 are rewritten around this.
- **M0:** the Pointer Lock spike is parked. CI is added, including a WASM-still-builds check. The `savemouse`/`restoremouse` micro-item is split out (Fable, Finding 4).
- **M1:**
  - The browser Clipboard API is dropped, and the clipboard goes native-first.
  - A native file server is added.
  - Phase-17 items are marked shipped.
  - Retina is now a question rather than a commitment.
- **M2:** the allow-list is scoped to remote 9P servers, and a headless 9P server is added.
- **M3:** native polish, plus the devdraw vs self-drawn-window decision.
- **M4:** reframed as backlog that can be scheduled now.
- **M5:** still stop-and-ask, with a sharper reason.
- **Process:** two standing rules are added. A proposed R-IN-06 change is noted, but requirements are not edited.

## Vision

> **Now:** Larry opens **native snarf** on his Mac and does his real day's work in it: ACME semantics with real warp, his files, his commands, his clipboard. **[Larry]**
>
> **Hosts [Larry, 2026-10-10]:** snarf ships as **targeted native binaries** (Zig cross-compile, native host per ADR-0005). The **browser/WASM build is a frozen secondary target**: it keeps building and passing tests, but gets no new features. The core stays host-neutral (R-OV-03, R-OV-09), so the browser can return later without a core change. Remote work goes through **dedicated headless 9P servers**, not a browser tab.
>
> **Later:** snarf becomes a **developer AI harness**. AI agents work in the same editor through the same 9P file interface the human's tools use. **[Larry]**, made concrete by me **[inferred]** from R-EDIT-17/19 and R-9P-04.

**Why native [Larry]:** the browser can't reach ACME-level usability, and no install was its only real benefit. Snarf's job is editing documents and running text services, which is mostly heavy local use.

**Founding vision, kept for history** **[found, R-01 §2]:** "A programmer opens a single web page…". R-01 still says this. *Product note:* R-01 will need a revision to match native-primary. That is a requirements change for Larry, done by PR, and not made here.

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
| **M3** | Native daily-driver polish *(Next)* | Larry stops opening other editors | **devdraw vs self-drawn window decision**, trackpad chords, native polish, IME |
| **M4** | Programmable editor *(schedulable now)* | acme tooling and scripts drive snarf from outside | Full acme(4) served tree (already SHALLed), headless driver; `Tauth`/external attach (ADR-gated) |
| **M5** | AI harness *(stop-and-ask)* | An agent works beside Larry, visibly and safely | Needs new requirements first |
| — | Frozen / parked | not scheduled | Browser features (Pointer Lock, Clipboard API, touch, Worker+SAB, HiDPI), dual trackpad |

Sizes: **S** = less than one pipeline phase · **M** = one phase · **L** = several phases or ADR-first.

---

## M0: Ground truth (Now)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **CI on push (macOS + Linux)** | Every push runs `zig build`, `zig build test`, fmt, `zig build native`, **and a WASM-build-still-compiles check** (plus the smoke test) | Freezing the browser only works if CI catches it breaking. Daily-driver reliability. A future agent eval harness | R-BLD-03, S-06 §5, NEXT-PHASES Tier 4 #11 | S | A workflow file (needs a PR). The smoke test needs Node ≥ 22 |
| **Return-after-`Del` warp (`savemouse`/`restoremouse`)** | Deleting a pop-up window (e.g. `+Errors`) puts the pointer back where it was | The paper's third warp. Real on native today because devdraw warps | R-EDIT-25 (last unported site: `util.c:384-408`, `cols.c:150/178`); Fable Finding 4 | S | None. **Host-agnostic, headless-tested through the `MouseSink` `/dev/mouse` stand-in (`src/core/warp.zig`), independent of any spike.** About 40 lines on `Editor`, cleared via `dropTextRefs`, plus one R-EDIT-25 log line |
| Guided manual walkthrough (native) | A 15-minute checklist in native snarf: chords, B3 sweeps, Del two-strike, Delcol, Edit, undo grouping, warps | Gestures never tried by a human (HANDOFF) | R-EDIT-05..12, 25 | S | — |
| ~~Phase 17 status~~ | Done: shipped `e734e3f` | — | `agents/reports/phase17-put-get-dump-load.md` | — | — |
| *Parked:* Pointer Lock warp spike | Only if a browser host returns | Native already warps. Its value was settling the host choice, which is now settled | Brief kept: [`spikes/pointer-lock-warp.md`](../../docs/product/spikes/pointer-lock-warp.md) | M | Browser un-frozen |

## M1: Edit real files on native (Now)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| ~~Put / Get / Putall~~ **SHIPPED (phase 17)** | Save, reload, save all | — | R-EDIT-15, `e734e3f` | — | — |
| ~~Create on origin export~~ **SHIPPED (phase 17)** | New files under `/n/origin/fs/` | Browser path, now frozen | `tools/origin/hostfs.zig` | — | `remove` still unbuilt, now low priority |
| ~~Dump / Load~~ **SHIPPED (phase 17)** | Restore a session | — | R-EDIT-16 | — | Native `$home` is `NotMounted` until the next row lands |
| **Native file server** | Native snarf reads and writes local files directly: **Put/Get/Dump/Load work on native** | Today native returns `NotMounted` for these (phase 17), so this is the #1 native blocker | ADR-0005 §2, NEXT-PHASES Tier 2 #4 (`tools/origin/hostfs.zig` reused in-process) | M | — |
| **System clipboard, native-first** | Snarf/Cut/Paste exchange text with macOS apps | Daily editing crosses apps. Today the buffer is internal (`src/core/snarf.zig`) | R-EDIT-14, R-9P-07; devdraw `Trdsnarf`/`Twrsnarf`; NEXT-PHASES Tier 2 #6 | S–M | — (**browser Clipboard API dropped**: frozen target) |
| **Small builtins: Sort, Zerox, Kill, Exit** | Tag commands that do nothing today start working | Dead tag words erode trust | R-EDIT-02, NEXT-PHASES Tier 1 #3 | S–M | Zerox needs multi-Text-per-File. Kill pairs with M2 |
| Retina text **(question)** | Crisp text on a Retina display | Was the "top user-felt gap" **in the browser** | R-GFX-05 | ? | **Open:** devdraw handles Retina (ADR-0005 §consequences). Keep this only if Larry still sees soft text on native |

## M2: Run real commands (Next)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **Native process service** | B2 on `mk`, `zig build`, `grep -n foo *.zig` runs a real local process. Output goes to `dir/+Errors`, and B3 on `file.zig:42` jumps there | This is what makes acme an IDE | R-EDIT-06/18/20/21, NEXT-PHASES Tier 2 #5 | L (two waves) | M1 native file server |
| **Host-command allow-list ADR, remote scope only** | Policy for which commands a **remote 9P server** may run, where, and for whom | Exec reachable from the network is RCE. **Local native = trusted** (Larry's own commands, his own machine) **[Larry; to confirm]** | R-EDIT-18, R-NG-03, OQ-EDIT-1 | S (doc) | Confirm whether this ungates the native process service |
| Pipes `\|cmd`, `<cmd`, `>cmd` | Filter the selection through a command | Everyday text surgery | R-EDIT-06 | M | Process service |
| `Kill` / long-running output | Stop a runaway command, and output keeps streaming | Builds run long | R-EDIT-02 | S | Process service |
| **Headless 9P server for remote machines** | Run snarf's file and command services windowless on a remote box, then mount it from local native snarf to edit and build remote documents | Replaces the browser as the remote story **[Larry]** | **No requirement yet [inferred]**; nearest: S-02 §6 external attach, ADR-0003 headless backend | L | Allow-list ADR (remote scope), `Tauth` (M4) |

**Harness-friendly choice:** design the remote allow-list as **who × what × where**, so a future agent gets a narrower grant through the same mechanism.

## M3: Native daily-driver polish (Next)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **Decide: devdraw vs a self-drawn native window** | Whether native snarf keeps using plan9port's `devdraw` or draws its own window | Now forced by native-primary: install friction, control over input and trackpad, distribution | `agents/reports/spike-rhun-self-drawn-frame.md` (borrow-the-model verdict), NEXT-PHASES Parked ("devdraw built in-tree", "native frame"), ADR-0002 amendment | S (decision) → M/L | Re-read the rhun analysis under native-primary stakes (architect) |
| Trackpad chords (D1) | Hold a click and tap another finger: +B2 Cut, +B3 Paste, and 2-1 from B2. Modifier+click stays | Chords on a Mac trackpad without hunting for keys | [touchpad research](../../docs/product/research/touchpad-interaction.md) D1 | M | Lands in devdraw (Larry's `plan9port` fork) or the self-drawn window, depending on the decision above |
| Native polish | Window title, `-b` flag, `Conn` reader on `std.Io` | Feels finished | NEXT-PHASES Tier 2 #6 | S | — |
| Keyboard / IME | Non-ASCII composition | If Larry needs it | R-IN-11 | M | — |
| Structure pass | 16 over-cap files | Filler | NEXT-PHASES Tier 4 #0 | S–M | — |

## M4: Programmable editor, the harness foundation (schedulable now)

*Reframed per Fable (review Finding 3). Most of M4 is **specified but unscheduled**: R-EDIT-17 already SHALLs the full served tree, R-9P-12 mandates `/mnt/snarf-self` with acme's file API shape, and S-02 §6 lists every file and labels external attach "a v2 item". It can get a NEXT-PHASES tier now under existing requirements. **Only `Tauth` plus the external-attach transport is ADR-gated.***

| Feature | User-facing description | Traces to | Size | Gate |
|---|---|---|---|---|
| **Full acme(4) served tree** | `addr, data, xdata, event, errors, rdsel, wrsel, editout`, and the full `ctl` verb set | R-EDIT-17, R-9P-12, S-02 §6, `fsys.zig` SEAM(O21) | L | None: existing SHALLs |
| **Headless scripted driver** | Run snarf windowless and script it: keys, clicks, hashes | NEXT-PHASES Tier 4 #11, S-06 `snarf-headless`, ADR-0003 | S–M | None |
| acme tooling compatibility | Go `9fans.net/go/acme` clients work against snarf | R-EDIT-17 | S | Served tree, attach |
| **External attach + `Tauth`** | Outside programs (CLI tools, the M2 remote setup, agents) mount snarf's tree, authenticated | OQ-9P-3, R-9P-15, S-02 §6 | M + ADR | **ADR**: makes `Tauth` and a transport mandatory. Shared with M2's headless server |

## M5: AI harness (stop-and-ask)

*Still **stop-and-ask**, but for a sharper reason (Fable, Finding 3). M5 introduces a **new actor class (an agent as a namespace client) with no requirement at all**. It brushes against **R-NG-04** (no multi-client editing), not R-NG-03: an agent running allow-listed commands through R-EDIT-18 is not "arbitrary execution". R-NG-02 is only at risk under one model-placement option. Before building anything: R-01 v4, a new R-08, and a model-connection ADR.*

The feature list is unchanged from v0.1 (agent as namespace client, per-agent namespaces and permissions, agent windows, `kbd hold`, audit log, model connection). See [`docs/product/roadmap.md` §M5](../../docs/product/roadmap.md).

## Frozen / parked
- **Frozen with the browser host** (must keep building and testing, gets no new work): Pointer Lock lock-mode wave and spike, browser Clipboard API, browser key-capture audit, Worker+SAB, HiDPI for the browser, touch profile + hybrid focus (R-IN-06, OQ-IN-1, OQ-IN-4), chordbar (R-IN-07), `/mnt/host`, `/dev/storage`, `/dev/dom`, GitHub Pages and ReleaseSmall deploy.
- **Parked:** dual Magic Trackpad chord pad (touchpad D5). Revisit only if multitouch clearly adds something a modifier key can't, given the cost of both hands off the keyboard **[Larry]**. Also parked: `win` terminal windows (OQ-EDIT-3), plumber rules (OQ-EDIT-2), webview shell.

## Process (standing rules)
1. **Every builtin also gets its served-tree `ctl` verb**, with a test through `/mnt/snarf-self`. This was a "Later" aspiration in v0.1. It is now a standing definition-of-done rule, since phase 17 already did it (`get`/`put`).
2. **The roadmap and `agents/NEXT-PHASES.md` coexist.** The roadmap handles product prioritization: milestones, user value, Larry's calls. NEXT-PHASES is the execution queue the pipeline builds from, refreshed from the roadmap's calls. Neither supersedes the other (review recommendation, agreed in the sync).
3. Every human-visible behavior still crosses 9P (R-OV-03). This is unchanged and is what keeps both the frozen browser and the AI path open.

The architectural choices that protect the AI-harness path are unchanged from v0.1 (see [`docs/product/roadmap.md`](../../docs/product/roadmap.md)). There is one addition: **the headless 9P server and M4 external attach should share one transport and auth design.**

## Open proposal (not a requirements edit)
- **R-IN-06 finger mapping.** R-IN-06 says 2-finger tap = B2 and 3-finger tap = B3. macOS and devdraw use **2 fingers = B3** (secondary click) and **3-finger tap = B2** (devdraw since `9af9ceca`). Proposal: align R-IN-06 to the macOS/devdraw convention (review Finding 5). Caveat: **Larry uses macOS three-finger drag, so 3-finger tap is unreliable for him.** This is why D1 (hold-and-tap plus modifier+click) is his trackpad path. The touch profile is frozen with the browser, so this is a zero-code text fix, and it is not made here. It needs a PR when Larry wants it.

## Remaining open decisions for Larry
1. **Your top 3 daily-use blockers** on native, to cut M1–M3 to the minimum.
2. **Confirm local native = trusted**, so the allow-list applies to remote 9P servers only. Does this ungate the native process service?
3. **Retina on native:** is text still soft under devdraw? If not, drop the M1 row.
4. **M4 tier now or later:** give the served tree and headless driver a NEXT-PHASES tier now, or after M1–M2?
5. **M5 greenlight:** start R-01 v4, R-08 and the model-connection ADR, or hold?

## Questions for the architect
- devdraw vs self-drawn window: does the rhun analysis (borrow-the-model, ~30–35% frame probability) still hold now that native is primary?
- One transport and auth design for the headless remote server and M4 external attach?
- The native clipboard via devdraw `Trdsnarf`/`Twrsnarf`: does it survive a self-drawn-window decision?
