# R-08 (proposed) — AI Harness: agents as namespace clients

Status: **PROPOSED draft v0** (SnarfProdd working note, 2026-10-11; not a requirement until promoted by PR into `docs/requirements/`)

*Roadmap M5 is stop-and-ask: it introduces a new actor class with no requirement ([roadmap v0.2](../roadmap-v0.2-proposal.md); Fable's verdict in [`notes/claude/roadmap-review-2026-10-10.md`](../../claude/roadmap-review-2026-10-10.md), Finding 3). This draft is the starting point for that ask. It follows the repo's requirements style (ID tables, SHALL language, OQs, revision log). Every row is **PROPOSED**.*

## 1. Purpose

Snarf already lets external programs drive the editor by reading and writing a file tree (R-EDIT-17, R-9P-04, R-OV-03). This document makes an **AI agent** a first-class client of that tree. The agent reads windows, edits text, runs commands and reports results through the same 9P interface the human's tools use, and the human can always see, attribute, interrupt and undo what it does. The agent gets no new API: whatever it can do, a script could do.

## 2. Actor model

| ID | Requirement (PROPOSED) |
|----|-----------|
| R-AG-01 | An **agent** SHALL be a 9P client of Snarf's served tree (`/mnt/snarf-self`, R-9P-12) and of the namespaces granted to it (R-AG-04). It SHALL have no capability unavailable to an equivalent non-AI client: no private hooks into the core, and no UI-only paths (roadmap standing rule: every builtin has a `ctl` verb). |
| R-AG-02 | Snarf SHALL distinguish **sessions**: one human session (the editor UI) plus zero or more **agent sessions**. Each session has a stable, human-readable name (e.g. `agent:review-1`) assigned at attach. |
| R-AG-03 | The editor core SHALL NOT embed, link or call a language model. Model inference lives in the agent process (§7). Snarf's only contract is the namespace. |

*Acceptance:* an off-the-shelf acme client (e.g. `9fans.net/go/acme`), attached as an agent session, can open a window, write `body`, set `addr`/`data`, and execute a builtin via `ctl`, with no agent-specific code in `src/core`.

## 3. Namespace, permissions and identity

| ID | Requirement (PROPOSED) |
|----|-----------|
| R-AG-04 | Each agent session SHALL get its **own namespace**, assembled by mount/bind (R-9P-03) from a declared **grant**: which trees (e.g. `/mnt/snarf-self` read-only or read-write, `/n/local/<project>`), and which commands (`/bin` members). Anything not granted SHALL be absent (a walk fails), not merely denied. |
| R-AG-05 | Grants SHALL be plain text files the human writes (R-9P-14), naming tree × mode × command set. The default grant SHALL be read-only on `/mnt/snarf-self` and nothing else. |
| R-AG-06 | **Runs as the user** (consistent with the 2026-10-11 local-trust decision): a local agent session's commands SHALL execute as the logged-in user, with no more rights than that user, narrowed by its grant. Snarf SHALL NOT switch identity silently. Elevation happens only if the *human* invokes `sudo` or similar. An agent SHALL NOT be granted a command that elevates. |
| R-AG-07 | Remote agent sessions (over a network transport) SHALL fall under the **remote** host-command allow-list (R-EDIT-18 / R-NG-03 local-vs-remote clause, pending) in addition to their grant. |

*Acceptance:*
- An agent with the default grant cannot write any `body`, and cannot see `/n/local` or `/bin`. Each attempt shows up as a walk/open error in the audit log.
- A grant adding `zig` lets B2-equivalent `ctl` execution run `zig build` as Larry, in the granted directory only.

## 4. Visibility, attribution, audit

| ID | Requirement (PROPOSED) |
|----|-----------|
| R-AG-08 | Every agent session SHALL have a visible **`+Agent/<name>`** window (pattern of R-EDIT-21 `+Errors`). It holds the agent's messages and a running summary of its actions. Snarf creates it at attach and does not hide it. |
| R-AG-09 | Edits made by an agent SHALL be **attributed**: the window tag marks windows an agent has modified since the human last touched them, and each undo record carries its session name. |
| R-AG-10 | Agent edits SHALL enter the window's normal undo log (R-EDIT-11), so one human `Undo` reverts the last agent change just as it would a typed one. |
| R-AG-11 | Snarf SHALL keep an **append-only audit log** as a line-oriented text file (R-9P-14). Each line holds a timestamp, session, operation (walk/open/write/exec/ctl), path and result. It is readable by the human at a namespace path (e.g. `/mnt/snarf-self/audit`) and never writable by agents. |

*Acceptance:*
- After an agent session that edits two files and runs one command, the audit file shows each write, each `ctl` and the exec, in order.
- `Undo` in an affected window reverts the agent's last edit.
- The tags of the two windows show the agent mark.

## 5. Human override and interrupt

| ID | Requirement (PROPOSED) |
|----|-----------|
| R-AG-12 | The human SHALL be able to **pause**, **resume** and **detach** any agent session: from its `+Agent` window tag (builtins, with matching `ctl` verbs), and by a global `Stop` that pauses all agents. A paused session's pending 9P requests SHALL be held, not failed. |
| R-AG-13 | **Human input wins**: while the human is typing or sweeping in a window, agent writes to that window's `body`/`data` SHALL be queued until the human's action completes. They SHALL NOT interleave with the human's edit. |
| R-AG-14 | Detach SHALL clunk all of the session's fids and kill its running commands (`Kill` semantics), and SHALL leave its `+Agent` window and the audit log intact. |
| R-AG-15 | Deliver-first event interception (`kbd hold`, S-02 §6, OQ-EDIT-4) SHALL remain **off** for agents unless separately approved. Larry deferred it ("don't build unprompted"). |

*Acceptance:* during a running agent edit loop, `Stop` freezes further writes within one event-loop tick. Typing in the window being edited is never interleaved. Detach leaves no orphaned processes.

## 6. Concurrency, transport and auth

| ID | Requirement (PROPOSED) |
|----|-----------|
| R-AG-16 | Snarf's served tree SHALL support **multiple concurrent attached clients** with independent fid spaces and out-of-order replies. This removes the single-client assumption noted in REVIEW-NOTES phase 13a ("fid numbers are recycled before the Rclunk arrives, which assumes in-order peers"). |
| R-AG-17 | Concurrent writes to one window SHALL be serialized in arrival order, each applied atomically. A client SHALL be able to detect intervening changes (e.g. via `event` or a version in `ctl`) before it writes. |
| R-AG-18 | Agents SHALL attach over the **external-attach transport defined for M4** (S-02 §6), with **`Tauth`** required for every non-in-process session (OQ-9P-3 resolved to "mandatory for external attach" by the M4 ADR). Local transport: a user-only Unix socket. Remote: the headless 9P server's authenticated transport. |

*Acceptance:*
- Two clients (human UI plus a scripted agent) each hold 50 open fids and interleave reads and writes for 10,000 operations. There are no fid collisions and no lost writes, and every request gets the right reply.
- Attach without valid auth fails before any walk.

## 7. Where the model runs (options; recommendation flagged for Larry)

| Option | Shape | Pros | Cons |
|---|---|---|---|
| **A. Local agent process** | A separate process on Larry's machine attaches to native snarf over the local socket. It calls whatever model it likes (a local model or a remote API) on its own | Snarf holds no credentials and no model code (R-AG-03). Runs as the user (R-AG-06). Simplest trust story | Each agent tool brings its own model plumbing |
| B. Remote agent | The agent runs on another machine and attaches over the network via the headless server's transport | Heavy compute elsewhere | Needs `Tauth` and the remote allow-list. More attack surface |
| C. Broker | A long-lived service manages agent sessions, models and state for many clients | Central policy and state | **Conflicts with R-NG-02** (no server-side session state). The most new surface |

**Recommendation (PROPOSED, for Larry): Option A first**, with B arriving for free once M4 and the headless server exist. C is not recommended in v1.

| ID | Requirement (PROPOSED) |
|----|-----------|
| R-AG-19 | v1 SHALL support **local agent processes** (option A). Remote agents (B) SHALL use the same protocol with mandatory `Tauth`. A broker (C) is out of scope. |

## 8. Evaluation and test harness

| ID | Requirement (PROPOSED) |
|----|-----------|
| R-AG-20 | Every R-AG requirement SHALL be testable **windowless**, using the headless scripted driver (roadmap M4; S-06 `snarf-headless`; ADR-0003 headless backend). Tests drive a scripted agent against the served tree and assert on files, the audit log and golden hashes. |
| R-AG-21 | The harness SHALL support **replay**: re-running a recorded agent session from its audit log against a fixed workspace produces identical results. These replays form a regression suite and an agent eval set. |

*Acceptance:* `zig build test` includes an agent scenario suite: default-grant denials, edit with undo, `Stop` mid-loop, concurrent fids, and audit replay. It runs on CI without a display.

## 9. Impact on existing requirements (PROPOSED deltas)

**R-01 v5** (delta against v4):
- Add **R-OV-10**: "Snarf SHALL support AI agents as 9P namespace clients with per-session namespaces, visibility, audit and human override, as specified in [08-ai-harness.md]."
- Extend §4 Glossary with *agent session* and *grant*.
- §5 Document map gains R-08.
- Revision log: "v5 — AI harness (R-08); agent = namespace client".
- R-OV-03 is unchanged: it is what makes this work.

**R-07 non-goals** (also bump the stale "Draft v1" status and start a revision log):

| Non-goal | Impact | Proposed change |
|---|---|---|
| **R-NG-04** no collaborative / multi-user editing | **Directly brushed.** Human plus agent on one served tree is multi-client (Fable's finding) | Clarify: "No multi-*human* collaborative editing. **Multiple clients of one user's session (human UI + that user's agents, R-08) are in scope**." |
| R-NG-02 no server-side session state | Only at risk under option C | No change if R-AG-19 holds. Note the broker exclusion |
| R-NG-03 no shell / arbitrary execution | Not violated: agents run granted commands through the R-EDIT-18 table | Fold into the pending local-vs-remote clause: local = trusted, runs as the user; remote = allow-list; agents = grant ∩ the applicable policy |
| R-NG-06 no LSP/completion in-editor | Consistent: AI arrives "through the namespace" | None, and cite it as the rationale |

Also touched: R-EDIT-17 (served tree completeness, which M4 delivers), R-9P-15 (security boundary: add per-session namespaces), and OQ-9P-3 (`Tauth` becomes mandatory for external attach).

## 10. Open questions (next meeting)
1. **Greenlight:** start the R-08 + R-01 v5 + model-connection ADR track now, or after M1–M2 ship?
2. **Option A as the v1 model location**: agree? Must snarf ship a reference agent, or only the protocol?
3. **Default grant:** is read-only `/mnt/snarf-self` right, or should the default include the window's own directory (read-only)?
4. **Human-input-wins (R-AG-13):** queue agent writes, or reject them so the agent retries?
5. **Attribution UI:** what tag mark should show agent-modified windows? Should it clear on human edit, or on `Put`?
6. **Audit retention:** keep the log in memory per session, or persist it to `$home`? It may contain file contents.
7. Is **`kbd hold`** ever wanted for agents (co-pilot on typed commands), or permanently out?
8. **Dependency order:** M5 requires M4's served tree, external attach and `Tauth`. Should M4's scheduling (deferred 2026-10-11) be revisited when M5 is greenlit?

## 11. Revision log
- **v0** (2026-10-11): PROPOSED starting draft by SnarfProdd, from roadmap M5, Fable's Finding 3, and the 2026-10-11 local-trust decision. Not yet reviewed.
