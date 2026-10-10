# State of snarf — where the product actually stands

*Prepared 2026-10-07 by SnarfProdd (PM) from a read-only clone of `larryr/snarf` @ `cf9e30c`
(main, last commit 2026-10-04). PM notes, not agreed requirements (see [docs/product](README.md)). Every claim cites a file or
commit; "inferred" marks my reading where the docs do not say it outright.*

## 1. Headline

Snarf is much further along than the README's "implementation in progress" suggests. **The
ACME editing model works in the browser end to end** (mouse language, chords, live tags,
undo, the Edit language, Look, `+Errors`, window placement, directory windows), the 9P
namespace is real (unions, synthetic root, async ops everywhere), and a **native host** runs
the same core in a plan9port `devdraw` window with real pointer warping. What is missing is
what makes it a *daily editor*: ~~saving files (Put)~~ **saving files shipped 2026-10-10
(phase 17)** — **running real commands, the system clipboard, and crisp Retina text remain.**
For the AI-harness ambition, the matching gap is that the editor's own file interface
(`/mnt/snarf-self`) only serves a small subset of acme's files and is not reachable from
outside the process.

Sources: `agents/NEXT-PHASES.md` §intro ("What is missing is *files in and out* and
*commands*"), `agents/HANDOFF.md` "Current state". **Update 2026-10-10**: Put/Get/Putall/
Dump-Load shipped — `agents/reports/phase17-put-get-dump-load.md`; see
`notes/claude/roadmap-review-2026-10-10.md` for the fuller reconciliation against this
doc set and `agents/NEXT-PHASES.md`.

## 2. Verified on this box (2026-10-07)

| Check | Result |
|---|---|
| `zig build test` (pinned Zig 0.16.0, `.zigversion`) | **712/712 tests passed, 20/20 steps**, ~12 s incl. compile (matches HANDOFF line 49) |
| `zig build` (wasm) | OK — `zig-out/www/snarf.wasm` 2,321,388 B ReleaseSafe (HANDOFF says 2,321,565 B; trivially different) |
| `zig fmt --check src build.zig` | clean |
| `node tools/smoke_wasm.mjs` | **Did not run here**: box has Node 20, which lacks a global `WebSocket` (`smoke_wasm.mjs:387`). HANDOFF reports 40/40 on Larry's machine. Needs Node ≥ 22 — undocumented prerequisite (small doc fix). |
| CI | **None.** No `.github/` directory; S-06 §5 is labeled "CI (sketch)". |
| Open branches / PRs / issues | Remote has only `main` (`git ls-remote`). ~~Phase 17 is *claimed* in HANDOFF (2026-10-04) but no branch or contract file is pushed — status unknown.~~ **Update 2026-10-10: shipped and merged**, `e734e3f`, `agents/reports/phase17-put-get-dump-load.md`. |

Scale: ~50k lines of Zig in `src/` + `tools/`, 347 commits, 83 merges, 16 numbered phases
(+ 12b–e, 13a/b, 14a/b) since 2026-07-06.

## 3. What's implemented (with evidence)

Requirement IDs are the project's own (`docs/requirements/*.md`, stable `R-XX-nn`).

### 3.1 Editor (R-02)

| Capability | Req | Evidence |
|---|---|---|
| Columns, windows, tag lines, live window tags (Undo/Redo/Put/Get appear and vanish) | R-EDIT-01/02 | phase 8 (`agents/reports/phase8-windows.md`), `src/core/{Row,Column,Window,wintag}.zig` |
| Directory windows (B3 into entries, columnated listing) | R-EDIT-03 | phase 13b `fd1abe0`, `src/core/dirwin.zig` |
| Dirty box, ACME scrollbars | R-EDIT-04 | `src/core/text/scroll.zig`, phase 7 |
| B1 select/double-click, B2 execute, B3 look (file-or-search, `:addr`) | R-EDIT-05/06/07 | phases 6, 9, 13b; `src/core/{look,expand,openfile}.zig`; B3 file check is async (R-02 v5 note) |
| Chords (cut/paste, 2-1 argument) | R-EDIT-08 | phase 7 `src/core/textselect.zig`; *not yet manually exercised by Larry* (HANDOFF "Manual browser verification") |
| UTF-8 / rune-addressed piece buffer | R-EDIT-10 | `src/core/{Buffer,RuneIndex}.zig` |
| Undo/redo with run grouping | R-EDIT-11 (part) | `src/core/File.zig`; ~~"surviving Put" untestable until Put exists~~ **now tested (phase 17 T14)**: `dirty = seq != putseq`, undo past a Put re-dirties, redo back to it cleans |
| Edit language (structural regexps, x/s/g/v/m/t…) | R-EDIT-12 | phase 10, `src/core/edit/*` (own regexp engine, ADR-0002) |
| Plumbing subset: `path:line`, `path:/re/`; URL *recognized* in expansion | R-EDIT-13 (part) | `src/core/expand.zig:36,86`; opening URLs in the browser **not verified** |
| Directory context, `+Errors` windows, point-to-type, placement heuristics, click expansion | R-EDIT-20..24 | phase 12b `96d7cb5`, `src/core/{errors,place,colgrow}.zig` |
| Warp requested via `/dev/mouse` write; honoured natively, refused in browser | R-EDIT-25 | phase 15, `src/core/warp.zig` |
| Builtins (14): `Cut Del Delcol Delete Edit Get Look New Newcol Paste Reconnect Redo Snarf Undo` | R-EDIT-06 | `src/core/exec/builtins.zig:60-86` (`Get` = directories only, R-P13b-5) |

### 3.2 Namespace & 9P (R-03)

| Capability | Req | Evidence |
|---|---|---|
| 9P2000 client + server framework, full mandatory subset except `Tauth` (create/remove/wstat since 14a) | R-9P-01 | `src/ninep/*`, R-03 v5 |
| In-memory + WebSocket transports | R-9P-02 | `src/ninep/transport.zig`, `src/shim/WsTransport.zig` |
| Mount/bind **with unions**, synthetic `/`, `/n`, `/mnt` | R-9P-03, R-9P-16 | phase 12d, `src/ninep/{mount,nsdir}.zig` |
| Every 9P op non-blocking (tickets + jobs, parking) | R-9P-13 | phases 13a/14a, `src/ninep/{tickets,nsjob,nsio,park}.zig` |
| `/n/origin` over WebSocket + origin `bin/` unioned into `/bin`, `Reconnect` | R-9P-10 | phase 12, `src/origin/*` |
| Origin server `snarf-origin` (`zig build serve`): static files + 9P at `/9p` exporting `version`, `bin/{echo,date}`, `fs/` = a host dir | R-9P-10 | phase 11, `tools/origin/*`; **built-ins only, never spawns a process** (`tools/origin/services.zig:6-9`) |
| `/mnt/opfs` (browser private FS, writable, async) | R-9P-09 (OPFS half) | phase 14b `851d0dc`, `src/dev/opfs*.zig`, `web/opfs.js` |
| `/mnt/snarf-self` served tree: `index`, `new/`, `ns`; per window `body`, `ctl`, `tag` | R-9P-12 / R-EDIT-17 (part) | `src/core/served/fsys.zig:97-110`; ctl verbs only `clean/dirty/del/delete/name` (`xfid.zig` header, ruling R-P10-H) |

### 3.3 Graphics, input, hosts, build

| Capability | Req | Evidence |
|---|---|---|
| `/dev/draw` device, canvas + headless backends, golden-hash tests | R-GFX-01/02/04/07 | phases 2–4, `src/dev/draw*.zig`, `src/draw/*` |
| Canvas fills window, follows resize | R-GFX-05 (half) | phase 12c `e351203` |
| `/dev/mouse`, `/dev/kbd`; **native** and **modifier** profiles (Option=B2, Cmd/Ctrl=B3, modifier-during-sweep = chord) | R-IN-01..05 | `src/dev/{input,profiles}.zig`; boot default modifier profile (`0bd405f`) |
| Native host: unchanged core in a `devdraw` window, real warp, `/dev/snarf` + `/dev/label` devices | R-OV-09, ADR-0005 | phase 15 `efeb3fe`, `src/host/devdraw/*`, `src/main_native.zig` (`zig build run-native`; needs plan9port's `devdraw`) |
| Zig-only build, std-lib only, pinned 0.16.0 | R-BLD-01/02, R-CON-01 | `build.zig`, empty `build.zig.zon` deps |

## 4. Specified but not built

| Item | Req / spec | Status evidence |
|---|---|---|
| ~~**`Put`, `Putall`, `Get` for files**~~ **SHIPPED 2026-10-10** | R-EDIT-15 | `agents/reports/phase17-put-get-dump-load.md`, merge `e734e3f` |
| ~~**`Dump` / `Load` session**~~ **SHIPPED 2026-10-10** | R-EDIT-16 | same; `$home` = `/mnt/opfs` (browser) / real `$HOME` (native, unmounted until Tier 2 — honest `NotMounted`) |
| **External commands** (non-builtin B2 → `/bin/<cmd>/ctl`, output to `+Errors`, `\|` `<` `>`) | R-EDIT-06/18/21, OQ-EDIT-1 | NEXT-PHASES Tier 1 #2; blocked on a **host-command allow-list ADR** (not written) |
| Remaining builtins: `Zerox Sort Exit Kill Font Tab Indent Id Incl Local Send Abort` | R-EDIT-02 (root/column tags list `Kill Putall Dump Exit Sort Zerox`) | absent from `builtins.zig` exectab |
| **System clipboard** `/dev/snarf` in the browser | R-9P-07, R-EDIT-14 | "/dev/snarf sync (`acmeputsnarf`) is deferred (R-P7-5)" — `src/core/snarf.zig` header; no Clipboard API in `web/shim.js` |
| HiDPI / Retina (2× font, DPR-aware backing store) | R-GFX-05 (half) | phase 12c report R-P12c-6; NEXT-PHASES Tier 3 #7 |
| `/mnt/host` (File System Access picker) | R-9P-09 (host half) | R-03 v6 revision log: "remains unbuilt" |
| `/dev/storage`, `/dev/notify`, `/dev/location`, `/dev/title`, `/dev/log` | R-9P-08 | S-02 §1.3 as-built: "Not yet mounted" |
| `/dev/dom` | R-9P-05 | kept, browser-only, **low priority by Larry's decision** (HANDOFF namespace decision 5) |
| Served-tree files `addr`, `data`, `xdata`, `event`, `errors`, `rdsel`, `wrsel`, `editout` | R-EDIT-17 | `fsys.zig:104-105, 307-308` (`SEAM(O21)`, deferred R-P10-J) |
| External access to `/mnt/snarf-self` (from origin / other tabs / native clients) | R-EDIT-17, R-9P-04 | S-02 §6: "server-initiated attach is a v2 item" |
| `kbd hold` (deliver-first keyboard events for external modal clients) | S-02 §6, OQ-EDIT-4 | specified, **deferred by Larry — "don't build unprompted"** (HANDOFF open questions) |
| Touch and chordbar input profiles | R-IN-06/07 | `src/dev/profiles.zig:34,218` "TODO machines", no-op passthrough |
| IME composition | R-IN-11 | S-04 §3 design; no composition handling in `web/shim.js` |
| Settable cursor image | R-GFX-08 | no cursor handling found in `web/shim.js` (inferred not built) |
| Web Worker + SharedArrayBuffer transport | R-PLAT-03 | `web/shim.js:467` "reserved for the future Worker"; module runs on the main thread by ruling R-P6-1 |
| ~~Create/remove of files on the origin's `fs/` export~~ **`create` SHIPPED 2026-10-10, `remove` still not built** | R-EDIT-15 (via `/n/origin`) | `tools/origin/{tree,hostfs}.zig` gained `create` in phase 17 (files only, exclusive, logged) — S-02 §5 phase-11 note's gap is half-closed. `remove` remains unbuilt. |
| Native file server + native process service | ADR-0005 phase 2 | NEXT-PHASES Tier 2 #4–5 (`tools/origin/hostfs.zig` is reusable) |
| CI on Linux + macOS | R-BLD-03, S-06 §5 | no `.github/` |
| `Tauth` for `/n/origin` | OQ-9P-3 | optional, not built |
| Layout/scroll warps (`cols.c`, `scrl.c`, `wind.c`, `util.c` `moveto`s) | R-EDIT-25 | "not ported yet on any host" (R-EDIT-25 text) |

## 5. Known gaps, bugs, debt

- ~~Phase 17 (Put/Get/Dump/Load) claimed 2026-10-04, no visible progress~~ **Resolved
  2026-10-10: shipped and merged** (`e734e3f`). New debt from that phase: one named test
  (T21, a browser smoke-test click on the live "Put" tag word) not landed — a geometry issue,
  not a correctness one, fix recipe is in the phase report; `xfid.zig` (424 lines) and
  `Window.zig` (405 lines) nudged just over the ~400-line soft cap.
- **Manual verification gap** (HANDOFF "Manual browser verification", 2026-09-05): chords,
  B3 look sweeps, Del two-strike, Delcol regrow, Edit language and undo grouping have never
  been exercised by a human in a browser; one unreproduced tag-corruption anomaly
  (`New Cut Paste ste ste ste…`).
- **Retina text is soft** (DPR 1) — top user-felt gap per HANDOFF backlog.
- **16 files over the ~400-line cap** (phase 16 ledger, `agents/reports/phase16-debt-pass.md`
  §Debt ledger; NEXT-PHASES Tier 4 #0).
- Phase 16 still-open items: `colgrow`'s other arms, served body write backspace handling,
  `Queue.clear` on Tversion skipping clunk (`agents/REVIEW-NOTES.md` phase 16).
- OPFS: no rename (Chromium-only `move()`), `wstat` length only (REVIEW-NOTES 14b).
- wasm size 2.3 MB ReleaseSafe vs 289 KB ReleaseSmall — Larry chose ReleaseSafe for now.
- Native host needs a local plan9port build (`devdraw`); devdraw-in-tree is parked pending an
  ADR-0002 amendment (NEXT-PHASES "Parked").
- Smoke test requires Node ≥ 22 (found here; undocumented).
- In-code TODOs are few (9 hits): touch/chordbar machines (`profiles.zig:34,218`), the
  `expand()` filename seam in `exec.zig:96-98`, `SEAM(O21)` in `fsys.zig:307`.

## 6. Docs and decisions relevant to agents / automation (for the AI-harness ambition)

The repo has **no requirement that mentions AI or LLM agents** (grep of `docs/`), but the
architecture is unusually well suited to it, and several documents already point that way:

| Doc | Why it matters for an AI harness |
|---|---|
| R-01 §1 ("the editor — **and any program scripted against it**"), R-OV-03 | Everything is a 9P file → an agent can drive the editor with plain reads/writes. |
| **R-EDIT-17** + S-02 §6 (`/mnt/snarf-self`, acme(4) shape) | The intended agent API: per-window `addr/body/data/tag/event/ctl`. Only ~half built (§4). |
| **R-9P-04** | "All servers SHALL be usable by external 9P clients in principle" — the layering rule an external agent depends on. |
| **R-EDIT-19** (dot-transformer) + **OQ-EDIT-4** + S-02 §6 **`kbd hold`** | Already designs a non-human "modal client" that drives the editor through addresses and event interception — the same mechanism an agent would use. Deferred by Larry. |
| R-EDIT-18, OQ-EDIT-1, origin `bin/<cmd>/{ctl,output}` (`tools/origin/services.zig`) | Command execution as files — the tool-use channel. Gated on the allow-list ADR (security). |
| R-9P-15, R-CON-03, OQ-9P-2 (`/dev/fetch`), OQ-9P-3 (`Tauth`) | The security boundary; an agent harness raises the stakes on all of these. |
| ADR-0005 (two hosts) + NEXT-PHASES Tier 2 (native file/process servers) | A native host can run real processes — the natural home for a harness. |
| NEXT-PHASES Tier 4 #11 **headless scripted driver** (`key/click/move/resize/shot/hash`), S-06 `snarf-headless`, ADR-0003 headless backend | A deterministic, windowless editor an agent (or CI) can drive and screenshot. |
| `agents/` directory, `CLAUDE.md` | The project is *built* by AI agents (spec→build→test→gate→review pipeline, HANDOFF protocol). That's dogfooding experience for the harness, not a product feature. |
