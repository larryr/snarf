# snarf — product feature roadmap (DRAFT v0.1)

**Status: Draft — under review** (PM proposal; not agreed requirements).

*Draft by SnarfProdd (PM), 2026-10-07, for Larry (product owner), the tech architect and the
developer. Grounded in [`state-of-snarf.md`](state-of-snarf.md) and the repo @ `cf9e30c`. Labels:
**[found]** = stated in the repo docs; **[inferred]** = my reading; **[Larry]** = product
direction Larry gave on 2026-10-07 that isn't in the repo yet.*

## Vision

> **Now:** Larry opens snarf and does his real day's programming in it: real ACME semantics,
> his files, his commands, his clipboard, crisp text. **[Larry]**
>
> **Founding vision** **[found, R-01 §2]:** "A programmer opens a single web page and gets a
> complete ACME environment… a Plan 9-style namespace… No install, no server-side session
> state, no JavaScript framework." Plus ADR-0005 / R-OV-09: the same core also runs as a
> native host.
>
> **Later:** snarf becomes a **developer AI harness**: AI agents work in the same editor and
> environment as the human, through the same 9P file interface the human's tools use.
> Human and agent see the same windows, the same `+Errors`, the same files. **[Larry]**,
> made concrete by me **[inferred]** from R-EDIT-17/19 and R-9P-04.

**Why the AI angle fits [inferred]:** ACME's design is "external programs drive the editor
by reading and writing a file tree" (paper §Coupling; R-EDIT-17). An LLM agent is just
another external program. Snarf's hard architectural rule, that *everything* crosses 9P
(R-OV-03, ADR-0003/0004), means an agent can do anything the human UI can, with no extra
API to design.

## Target users

1. **Larry: primary, daily driver** **[Larry]**. Plan 9/acme-fluent programmer who works
   on macOS (HANDOFF: Safari + real mice, local plan9port build). Languages he edits (Zig, docs, …) are **[inferred]**.
2. **Acme-fluent programmers who want acme with zero install, or on a trackpad** **[found,
   R-01 §2, R-OV-06 chord emulation]**. Secondary. Not courted until Larry is happy.
3. **AI agents (and the people running them)** **[Larry, later]**. Namespace clients that
   read and edit text, run commands, and report results in windows a human can watch and
   correct.

Explicit non-users for now **[found, R-07]**: collaborative/multi-user editing (R-NG-04),
mobile-first users (R-NG-05), people who want syntax highlighting or LSP inside the editor
(R-NG-06, "should later arrive *through the namespace*").

---

## Milestone overview

| # | Milestone | Outcome for Larry | Headline features |
|---|-----------|-------------------|-------------------|
| **M0** | Ground truth *(Now)* | Know it works and which host to bet on | **Pointer Lock warp spike**, ~~phase 17 status~~ (done, see below), guided manual walkthrough, CI |
| **M1** | Edit real files *(Now)* | Open, edit, **save** real files, copy/paste with the OS, readable text | Put/Get/Putall, origin create/remove, system clipboard, Dump/Load, Retina, small builtins |
| **M2** | Run real commands *(Next)* | `mk`, `zig build`, `grep -n`, `git` from B2, output in `+Errors`, B3 to jump | Allow-list ADR, external commands via `/bin`, pipes `\| < >` |
| **M3** | Daily-driver host & polish *(Next)* | snarf is good enough that Larry stops opening acme/other editors | Native file + process servers *or* browser polish (Larry's host choice), devdraw-in-tree, keyboard/IME |
| **M4** | Programmable editor: harness foundation *(Later)* | acme tooling (and scripts) can drive snarf, from outside the process | Full acme(4) served tree, external 9P attach with auth, headless driver |
| **M5** | AI harness *(Later)* | An agent works beside Larry in snarf, visibly and safely | Agent session model, per-agent namespaces/permissions, `kbd hold`, agent windows, audit |
| — | Backlog / parked | (not scheduled) | Touch & chordbar, `/mnt/host`, `/dev/dom`, browser feature files, Worker+SAB, webview shell |

Sizes: **S** = less than one pipeline phase · **M** = one phase (spec→build→test→gate→review,
like phases 12b–16) · **L** = several phases or needs an ADR first.

---

## M0: Ground truth (Now)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **Pointer Lock warp spike** (first) | Opt-in mode where snarf draws its own cursor and acme's warps (search hit, opened file, return after `Del`) work in the browser | Settles whether the browser can be Larry's daily host (Decision 1), and the paper's one known browser divergence | R-EDIT-25, ADR-0005, S-04 §1/§3, R-GFX-08, phase-review 2026-10-03 Decision 2. Brief: [`spikes/pointer-lock-warp.md`](spikes/pointer-lock-warp.md) | M (timeboxed) | None. Ports acme `restoremouse` (dropped in phase 8) |
| ~~Phase 17 status check~~ **DONE 2026-10-10** | ~~Find out whether Put/Get/Dump/Load work started~~ It shipped — see M1's first two rows below | Was: claimed in HANDOFF 2026-10-04, nothing pushed as of this doc's writing (2026-10-07/09) | `agents/reports/phase17-put-get-dump-load.md`, merge `e734e3f` | S | — |
| Guided manual walkthrough | A 15-minute checklist Larry runs in Safari/Chrome: chords, B3 sweeps, Del two-strike, Delcol, Edit, undo grouping | These have **never been tried by a human** (HANDOFF "Manual browser verification"). A daily driver can't have untested gestures | R-EDIT-05..12 | S | — |
| CI on push (Linux + macOS) | Every push runs `zig build`, `zig build test`, fmt, smoke | Daily-driver reliability. Also the future eval harness for agents | R-BLD-03, S-06 §5, NEXT-PHASES Tier 4 #11 | S | Larry OK to add a workflow file. Smoke needs Node ≥ 22 |

## M1: Edit real files (Now) — *daily-driver core*

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **Put / Get / Putall for files** — **SHIPPED 2026-10-10 (phase 17)** | B2 `Put` saves the window. `Get` reloads it. `Putall` saves everything. Tags show `Put` only when dirty | Without save it isn't an editor. #1 blocker | R-EDIT-15, R-EDIT-11 (undo survives Put), NEXT-PHASES Tier 1 #1 | M | OPFS one-writable (done in 16b item 4) — **done**, `agents/reports/phase17-put-get-dump-load.md` |
| **Create on the origin export** — **SHIPPED 2026-10-10 (phase 17)** | Saving a *new* file (or `Put` to a new name) under `/n/origin/fs/` works | Today `tools/origin/hostfs.zig` can't create files, so new files fail on the most likely daily path (browser + local `snarf-origin`) | R-EDIT-15, S-02 §5, R-9P-01 | S | 14a framework (done) — **done**: files only, exclusive, logged (`tools/origin/tree.zig`/`hostfs.zig`). `remove` still unbuilt |
| **System clipboard (`/dev/snarf`)** | Snarf/Cut/Paste exchange text with other macOS apps | Daily editing constantly crosses apps. Today the snarf buffer is internal only (`src/core/snarf.zig`, R-P7-5 deferred) | R-EDIT-14, R-9P-07 | M | Browser Clipboard API permissions; native already has `Trdsnarf/Twrsnarf` |
| **Dump / Load** — **SHIPPED 2026-10-10 (phase 17)** | Close the tab or quit, come back, and the columns and windows are restored | Daily use = long-lived sessions | R-EDIT-16; `$home` decision: `/mnt/opfs` in browser, `$HOME` native (NEXT-PHASES) | M | Put/Get — **done**: `$home` resolved as specified; native is honestly `NotMounted` until Tier 2's native file server lands, not silent |
| **Retina text (2× font)** | Text is crisp on a Retina display | "Top user-felt gap" (HANDOFF backlog). Larry uses a Mac | R-GFX-05, OQ-GFX-2 (font choice/licensing) | M | Font asset decision |
| **Small builtins: Sort, Zerox, Kill, Exit** | The root/column tag commands that are printed but do nothing start working | Root and column tags advertise them (R-EDIT-02). Dead tag words erode trust | R-EDIT-02, NEXT-PHASES Tier 1 #3 | S–M | Exit needs Dump. Zerox needs multi-Text-per-File |

**Harness-friendly choices to make in M1 [inferred]:**
- Every new command also gets its **served-tree `ctl` verb** (acme(4) has `get`, `put`,
  `dump`, `clean`, `show`, …). Make it a definition-of-done rule that **no feature is
  UI-only**, so M4 doesn't turn into a retrofit.
- Keep the **Dump file plain text and stable** (acme's format) so an agent can snapshot and
  restore a workspace.
- Put/Get go **through the namespace only** (already the rule, R-EDIT-15). Agents then get
  saving for free, under the same permission checks as the human.

## M2: Run real commands (Next) — *the paper's "coupling" story*

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **Host-command allow-list ADR** | (Decision) which host commands the origin may run, in which directory, under what trust | Arbitrary exec over a WebSocket = RCE (`tools/origin/services.zig:6-9`). Must be decided first | R-EDIT-18, R-NG-03, OQ-EDIT-1, NEXT-PHASES Tier 1 #2, phase-review Decision 1 (add trust-by-locality sentence) | S (doc) | Larry decision |
| **External commands via `/bin`** | B2 on `mk`, `zig build`, `grep -n foo *.zig` runs it in the window's directory. Output streams into `dir/+Errors`. B3 on `file.zig:42` jumps there | This is what makes acme an IDE | R-EDIT-06, R-EDIT-18, R-EDIT-20, R-EDIT-21 | L | ADR, 12d `/bin` union (done) |
| **Pipes `\|cmd`, `<cmd`, `>cmd`** | Filter the selection through a command (e.g. `\|fmt`, `\|sort`) | Everyday text surgery | R-EDIT-06 (acme semantics) | M | External commands |
| **`Kill` / long-running output** | Stop a runaway command. Output keeps streaming | Builds and tests run long | R-EDIT-02 (root tag `Kill`) | S | External commands |

**Harness-friendly choices [inferred]:** design the allow-list as a **policy keyed by *who*
is asking (client identity/namespace) as well as *what* command**, not a flat list. That
lets the same mechanism later grant an agent a narrower set than Larry. Command output is
already a *file* (`bin/<cmd>/output`), and `+Errors` is a window, so agents can read results
the same way humans do.

## M3: Daily-driver host & polish (Next)

The content of this milestone depends on **Decision 1 below (which host is Larry's daily
driver)**. Both tracks are listed. Pick one first.

**Track N: native host as daily editor** (ADR-0005 phase 2, NEXT-PHASES Tier 2)

| Feature | Description | Why | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| Native file server | Native snarf edits real files directly, with no origin process | Removes a moving part from daily use | ADR-0005 §2, NEXT-PHASES #4 (`tools/origin/hostfs.zig` reused in-process) | M | M1 Put/Get |
| Native process service | Commands run as real local processes (stdin `/dev/null`, output to `+Errors`) | Full acme coupling, and the natural home for a harness | NEXT-PHASES #5, R-EDIT-21 | L (two waves) | M2 semantics |
| devdraw built in-tree | `zig build run-native` works without installing plan9port | Install friction | NEXT-PHASES Parked (needs first ADR-0002 amendment: fetch vs vendor) | M | Larry ADR decision |
| Native polish | Window title, `-b` flag, `/dev/snarf` wired to the snarf buffer | Feels finished | NEXT-PHASES #6 | S | — |

**Track B: browser as daily editor** (NEXT-PHASES Tier 3)

| Feature | Description | Why | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| Browser key capture audit | Known list of keys the browser steals (Cmd-W, …) and fallbacks | Daily typing friction | R-IN-09/10 | S | — |
| Pointer Lock lock-mode wave | Productize the opt-in lock mode **if the M0 spike passes** | The one paper behavior the browser can't do today | R-EDIT-25, NEXT-PHASES Parked, [`spikes/pointer-lock-warp.md`](spikes/pointer-lock-warp.md) | M | M0 spike pass |
| Worker + SAB | Snarf runs off the main thread: smoother input, OPFS sync handles | Responsiveness on big files | R-PLAT-03, R-P6-1 | M | COOP/COEP (origin already sends them) |

**Both tracks:** IME composition (R-IN-11) if Larry types non-ASCII. Second structure pass
over the 16 over-cap files (Tier 4 #0) as filler.

## M4: Programmable editor, the harness foundation (Later)

| Feature | User-facing description | Why it matters | Traces to | Size | Depends on |
|---|---|---|---|---|---|
| **Full acme(4) served tree** | `/mnt/snarf-self/<id>/{addr,data,xdata,event,errors,rdsel,wrsel,editout}` + the full `ctl` verb set | This *is* the automation API. Today only `body/ctl/tag` exist and `ctl` has five verbs | R-EDIT-17, R-9P-12, `fsys.zig` SEAM(O21), R-P10-J | L | — |
| **External attach to snarf-self** | Programs outside snarf (origin-side scripts, CLI tools, agents) can mount snarf's tree over 9P | Without this, no external program can drive the editor at all | R-EDIT-17 ("served… to the origin server or other tabs"), R-9P-04, S-02 §6 ("v2 item") | L | Auth (below) |
| **Authentication for 9P** | Only authorized clients can attach | An agent/automation entry point must not be open to anything that can reach the port | OQ-9P-3 (`Tauth`), R-9P-15 | M | ADR |
| **Headless scripted driver** | Run snarf windowless: send keys/clicks, get screenshots and hashes | CI for UI behavior, and a sandbox for agents and evals | NEXT-PHASES Tier 4 #11, S-06 `snarf-headless`, ADR-0003 headless backend | S–M | — |
| acme tooling compatibility check | Existing acme clients (e.g. Go `9fans.net/go/acme`) work against snarf | Proves the API, and gives a free ecosystem | R-EDIT-17 ("tooling can be written against Snarf just as against ACME") | S | Full served tree, external attach |

## M5: AI harness (Later)

*Nothing in the repo specifies this yet. Everything here is* **[inferred]** *from Larry's
direction plus existing hooks, and needs requirements (an R-01 v4 / new R-08) before
building.*

| Feature | User-facing description | Why it matters | Traces to (existing hooks) | Size | Depends on |
|---|---|---|---|---|---|
| Agent as a namespace client | An agent attaches to snarf like any acme client: reads windows, edits via `addr`/`data`, runs commands via `/bin` | Uses the architecture as-is. No special agent API | R-EDIT-17, R-9P-04, R-OV-03 | M | M4 |
| Per-agent namespace & permissions | Each agent gets its own mount table: which dirs, which commands, read-only vs write | Safety. Plan 9 per-process namespaces are a natural sandbox | R-9P-03 (bind/mount per instance), R-9P-15, M2 allow-list policy | L | M2 ADR, M4 auth |
| Agent windows & visibility | An agent's activity shows up in windows (`+Agent`, like `+Errors`), so Larry sees and can undo every change | Human stays in control. Undo works across agent edits | R-EDIT-21 pattern, R-EDIT-11 | M | — |
| `kbd hold` / deliver-first events | A client can intercept keystrokes and B2/B3 before they apply (for agents *and* the deferred vim layer) | Lets an agent act as a co-pilot on typed commands | S-02 §6, OQ-EDIT-4, R-EDIT-19 (**deferred by Larry: "don't build unprompted"**) | M | M4 event file |
| Audit log | Every agent read/write/exec is recorded to a file | Trust, debugging, replay | R-9P-14 (line-oriented text files) | S | M4 |
| Model connection | Where the LLM runs and how it reaches the namespace (origin-side process, native host process, remote) | Shapes security and deployment | R-NG-02 (no server-side session state), R-CON-03, OQ-9P-2 (`/dev/fetch`) | L (ADR) | Decision 4 |

## Backlog / parked (not scheduled)

Touch profile + hybrid tablet focus (R-IN-06, OQ-IN-1, OQ-IN-4) · chordbar (R-IN-07) ·
`/mnt/host` File System Access picker (R-9P-09) · `/dev/storage` and the browser feature
files (R-9P-08) · `/dev/dom` (R-9P-05, low priority per Larry) · settable cursor (R-GFX-08) ·
webview shell and native frame (NEXT-PHASES Parked) · `win` terminal windows (OQ-EDIT-3) ·
plumber rules file (OQ-EDIT-2) · ReleaseSmall deploy decision (Tier 4 #12) · GitHub Pages
deploy (S-06 §5).

---

## Architectural choices to protect the AI-harness path (early phases)

For the tech architect. Most of these cost little now and a lot to retrofit later.

1. **No UI-only features.** Every builtin added in M1–M3 also gets its served-tree ctl
   verb/file and a test through `/mnt/snarf-self` (R-EDIT-17).
2. **Allow-list ADR = identity-aware policy** (who × what × where), including the
   trust-by-origin-locality sentence already requested (phase-review Decision 1).
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

## Open questions for the tech architect

- M1: Put to a path whose mount disappears (origin drop): what does the user see? Does the
  window stay dirty? (R-9P-10 absence semantics)
- M1: Clipboard in Safari needs a user gesture per read. How does B1-B3 paste (a mouse
  chord) satisfy that? Is a read-on-focus cache acceptable? (R-9P-07 "permission failures
  surface as 9P errors")
- M1: Font for 2×: Go fonts (BSD) vs Plan 9 `lucm`/`fixed`? (OQ-GFX-2)
- M2: Streaming output: does `bin/<cmd>/output` need a blocking/long-poll read (parking
  exists, 14a), and how is `Kill` delivered (ctl verb)?
- M2/M3: Can one command-service protocol serve the origin (browser) and the native process
  service, so the M5 permission model is written once?
- M4: Transport for external attach: reverse attach over the existing origin WebSocket,
  `BroadcastChannel`, or a native listening socket? (S-02 §6)
- M4: Which `Tauth` scheme fits a local-first tool (token in URL/cookie per OQ-9P-3, or
  p9any-style)?
- M5: Do per-agent namespaces need a second `Namespace` instance per client inside the
  module, or a separate process (native host)?

## Top decisions for Larry (product owner)

1. **Which host is your daily driver: browser (+ local `snarf-origin`) or native
   (`devdraw`)?** The M0 Pointer Lock spike is meant to inform this. The answer sets M3's track and whether M2's command service lives in the origin
   or in-process. *(My lean [inferred]: native for daily coding, since warp, real processes
   and no permission prompts are exactly what ADR-0005 says the browser can't give. Keep the
   browser as the zero-install showcase.)*
2. **Host-command allow-list policy:** which commands (`mk`, `zig`, `go`, `grep`, `git`…),
   in which directories, and is a loopback origin "fully trusted"? This is the gate for M2.
3. ~~Is Phase 17 (Put/Get/Dump/Load) running~~ **Answered 2026-10-10: shipped and merged**
   (`e734e3f`, `agents/reports/phase17-put-get-dump-load.md`) — the autonomous pipeline did
   continue and finished it while this roadmap was being drafted. **Still open: does this
   roadmap supersede `agents/NEXT-PHASES.md` as the plan of record, or do the two coexist**
   (roadmap = product prioritization, NEXT-PHASES = the execution queue, refreshed from the
   roadmap's calls)? See `agents/reports/roadmap-review-2026-10-10.md` for a fuller review —
   recommendation there is **coexist**, not supersede. Also unresolved from that review:
   whether the Pointer Lock spike (M0) runs now, concurrent with the rest of Tier 1 (external
   commands, remaining builtins), or after — this roadmap and the 2026-10-03 phase-planning
   decision disagree on that ordering.
4. **AI harness scope change:** OK to amend the requirements (R-01 v4 + a new
   requirements doc) to make agents first-class namespace clients? This touches non-goals
   R-NG-03 ("no shell / arbitrary command execution") and R-NG-02 ("no server-side session
   state"), and un-deferring `kbd hold` (OQ-EDIT-4). Also, where should the model run?
5. **Quality bar for "daily driver":** what would make you stop opening acme/another editor?
   Your top 3 missing behaviors would let us cut M1–M3 to the minimum. Also: OK to add CI
   (a `.github/workflows` file) now?
