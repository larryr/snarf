# Proposal: Superlogical Rex: overlap and fit with snarf

**Status: PROPOSED / PARKED until after M3.** No roadmap change now. This is a SnarfProdd working note, not a requirement.
**Author:** SnarfProdd (PM). **Date:** 2026-10-26.

All Rex and libghostty facts below were checked against the cited sources on 2026-10-26. **[unverified]** marks anything the sources do not settle.

**Sources:**
- [S1] superlogical.com, the announcement: <https://www.superlogical.com/>
- [S2] Hashimoto, "Superlogical", 2026-07-29: <https://mitchellh.com/writing/superlogical>
- [S3] Bitdoze briefing: <https://www.bitdoze.com/superlogical-rex/>
- [S4] Developers Digest, updated 2026-10-09: <https://www.developersdigest.tech/blog/superlogical-mitchell-hashimoto-terminal-multiplexer>
- [D] Rex docs:
  - [index](https://www.superlogical.com/rex/docs/)
  - [CLI](https://www.superlogical.com/rex/docs/automate/cli)
  - [Server API](https://www.superlogical.com/rex/docs/automate/server-api)
  - [Events](https://www.superlogical.com/rex/docs/reference/events)
  - [Lua scripts](https://www.superlogical.com/rex/docs/automate/lua-scripts)
- [G] Ghostty repo:
  - [README](https://github.com/ghostty-org/ghostty)
  - [`include/ghostty/vt.h`](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h)
  - [`build.zig.zon`](https://github.com/ghostty-org/ghostty/blob/main/build.zig.zon)
  - [LICENSE](https://github.com/ghostty-org/ghostty/blob/main/LICENSE)

## 1. What Rex is

**Company and vision**
- Superlogical is Mitchell Hashimoto's new company, announced 2026-07-29 [S2].
- Its vision is "the multiplexer for all work", in three steps: **(1)** build an incredible multiplexer, **(2)** make everything in it composable, **(3)** make it safe and operable in production [S1].
- It starts with a terminal multiplexer, but the stated target is a "durable session around the work itself … driven by software while remaining visible and controllable by people" [S1].

**Rex is the terminal, not a layer inside one**
- Rex is a terminal emulator and multiplexer in one native app. You don't run it inside another terminal [S3].
- The server owns sessions and PTYs. It **tees raw PTY bytes** to every client, rather than diffing a shared screen model [S3].
- Each client parses with **libghostty** and owns its own viewport, so two clients can scroll independently [S3].
- Each split is its own PTY connection, rendered as a native split, tab or window. There is no in-window pane tree [S3].
- Input serializes through the server: one writer, many readers [S3].

**Clients and sharing**
- Sessions are planned to be reachable via the web and native macOS/iOS apps, with live sharing "built in from the start" [S1].
- **Shipping today: only the macOS app.** Linux servers are going out to Linux testing waves [D index]. iOS, Linux and Windows clients exist "at varying stages" [S3, S4].
- Remote hosts get a real system login; Hashimoto says he doesn't run SSH on that machine [S3].

**Automation surface** [D]
- The `rex` CLI takes `--json` and returns meaningful exit codes (0/1/2/3/4/130).
- The server API is self-describing: `rex api list|describe|call`, with JSON Schema inputs and outputs.
- `rex events --json` streams NDJSON (newline-delimited JSON) for session, terminal and server events.
- Lua handles config and custom actions (`rex.on`, `rex.wait`).
- `rex capture` reads a terminal's screen.
- A built-in **agent skill** lets Claude Code or Codex open panes and read screens.
- The **Program Status Protocol** (OSC 7501) lets a program report idle / working / waiting / failed.

**Status and cost**
- Public testing on macOS started **2026-10-05**, by mailing-list invite [S4].
- Rex is "is and will always be free", needs no account, and is self-hostable. The clients and servers won't be directly monetized [S3, S4].
- No telemetry [D].

**libghostty** [G]
- A "cross-platform, zero-dependency **C and Zig** library", **MIT**-licensed.
- It is being split into libraries, starting with **`libghostty-vt`**: VT parsing, terminal state, scrollback, reflow, a render-state API for custom renderers, and key/mouse encoding.
- It targets macOS, Linux, Windows and WebAssembly.
- The C API is **explicitly unstable**: "breaking changes are expected", and it is unversioned.
- Ghostty `main` declares **`minimum_zig_version = "0.17.0"`**. snarf pins **0.16.0**.
- Superlogical consumes the same MIT components and upstreams shared work [S2].

## 2. Overlap with snarf

| Area | Rex | snarf | Overlap | snarf's differentiation |
|---|---|---|---|---|
| Durable session / state | Server-owned long-lived sessions; detach and reattach from any client [S1, S3] | `Dump`/`Load` snapshots (R-EDIT-16); the core lives and dies with the window | **Medium** | Saved as a text file you can read and edit. Not reattachable today (see the lesson in §3) |
| Programmable workspace for agents | JSON server API + NDJSON events + CLI + Lua + agent skill [D] | Everything is a 9P file: windows, `ctl`, `body`, `event` (M4 served tree); agents as namespace clients (M5 draft) | **High in vision, low today** | Files, not RPC. Any language that can `open`/`read`/`write` can drive it, with no schema or SDK. Rex's API is richer and shipping; snarf's is mostly still M4 |
| Human + agent, visible and controllable | Shared live session; one writer, many readers; status protocol [S1, S3, D] | M5 draft: agent windows visible, attributed, audited, with human override | **High (vision)** | Agents act on text in the same windows the human edits, not on terminal screens. Actions are executable text that stays on screen |
| Remote | Server/client with real login; Mac↔Mac today, Linux server in testing [S3, D] | M2 headless 9P server (#18) mounted from local native snarf | **Medium** | Remote is a mount in one namespace (`/n/host`), not a separate session. No identity layer yet (M4 `Tauth`) |
| Composability | Lua actions, the API, events, `rex do` [D] | Plumber subset (R-EDIT-13), executable text (B2), pipes (M2), the Edit language | **Medium** | Plan 9's model: the text itself is the command line. Composition is files plus plumbing, not scripts against an API |
| Production ops (step 3) | Stated goal, not yet shown [S1] | **None** (not a goal) | **None today** | Not competing. snarf is a single-user editor |
| Terminal quality | Best-in-class emulator (libghostty) [S3, G] | No terminal. ACME's `win` is a dumb text pane, a weak point even in acme | **Low** | snarf doesn't try to be a terminal. Rex wins here outright |

**Conclusion**
- The overlap is in the **long-term vision**: the agent harness and workspace layer (snarf M4–M5 vs Superlogical steps 2–3). It is not in today's product: Rex is a terminal, and snarf is an editor.
- snarf's lasting differentiators:
  - **text is the interface**;
  - **everything is a file** (9P);
  - the **Plan 9/ACME model** (executable, plumbable text);
  - **local-first and single-user**;
  - **editor-first**.
- **Risk:** if Superlogical's steps 2–3 land well, Rex could become the *default agent workspace*. Agents would then target its JSON API, not 9P files.
- **Mitigation:** interoperate rather than compete. Make Rex sessions visible *inside* snarf as files (§3 option B), and stay editor-first.

## 3. Fit options

| Option | What | Cost and constraints | Timing |
|---|---|---|---|
| **A. libghostty-backed `Term` window** | A native-only snarf window whose body is a libghostty-vt terminal. ACME semantics are kept: output stays selectable, executable (B2) and plumbable (B3), like `win` but with a correct emulator | Needs a new ADR superseding part of ADR-0002 (std-only) under the immutable-ADR convention. Zig 0.17 vs our 0.16 pin. Unstable C API. It must stay out of the WASM build (frozen target) | **Spike candidate after M3** |
| **B. Rex bridge 9P server** | A small 9P server that exposes Rex sessions and blocks as files (`data`, `ctl`, `events`), using `rex api call`, `rex capture` and `rex events --json`. Mount it at `/n/rex` | No change to snarf core; it is a separate process. It depends on Rex API stability and the M4/M5 multi-client work | **M5 candidate** |
| **C. Side by side** | Rex for terminals, snarf for text. Plumb `path:line` from Rex to snarf (and back via `rex send`) | Zero code. It works as soon as Larry has a Rex invite and the native plumber subset | Any time |

**Lesson worth an ADR later:** Rex's server-owned, reattachable session is the right shape. A **persistent snarf core** (headless core that outlives the window, with devdraw clients attaching and detaching) would serve the M2 remote story (#18) and M5 agents in one go. This is not proposed now; it should be revisited when M4 is scheduled.

## 4. Open questions

1. **Rex API stability.** The server API is self-describing and versioned per server (`rex api describe`) [D], but it is beta at 0.1.x. When does it stabilize?
2. **Rex's own license.** It is "free" and self-hostable [S3, S4], but I found **no source license or open-source statement** for Rex itself **[unverified]**. Option B is fine either way; anything that vendors Rex code is not.
3. **Does libghostty-vt build with Zig 0.16?** Ghostty `main` requires 0.17.0 [G]. Do we pin an older libghostty, link a prebuilt C library, or wait for snarf to move to 0.17? **[unverified]**: no build was tried.
4. **Platforms.** Rex ships macOS-only to testers today, and Linux servers are in testing waves [D]. That's fine for Larry, but a bridge that needs a Rex server on Linux remotes depends on that rollout.
5. Would the **Program Status Protocol** (OSC 7501) be worth emitting from snarf-run commands, or reading in a `Term` window, for agent status?

## Revision log

| Date | Change |
|---|---|
| 2026-10-26 | v0.1 created (SnarfProdd): Rex facts verified against S1–S4, the Rex docs and the Ghostty repo; overlap table; options A–C; open questions. PROPOSED / PARKED after M3 |
