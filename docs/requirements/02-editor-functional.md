# R-02 — Editor Functional Requirements (ACME semantics)

Status: **Draft v4**

Snarf's editing model is ACME's. This document states the behaviors that must survive the
port; the implementation design is in [../spec/05-editor-core.md](../spec/05-editor-core.md).
The behavioral source of truth is Pike's paper, archived as
[`../acme/acme.md`](../acme/acme.md); requirements below cite its sections as *paper §…*.
Where a paper behavior is impossible in a browser, the requirement says so explicitly
rather than staying silent (R-EDIT-25).

## 1. Screen layout

| ID | Requirement |
|----|-------------|
| R-EDIT-01 | The display SHALL be divided into vertical **columns**; each column holds a stack of **windows**. Columns and windows are created, moved, resized, and deleted with the mouse. |
| R-EDIT-02 | The top of the screen, each column, and each window SHALL have a **tag line**: an editable line of text holding the entity's name, commands, and (right of the `\|` bar) a free scratch area. Pre-loaded tag commands: `Newcol Kill Putall Dump Exit` (root), `New Cut Paste Snarf Sort Zerox Delcol` (column), `Del Snarf \| Look ` (window). The window tag is **live** (paper §User interface, Fig. 2): `Undo`/`Redo` appear only while there is something to undo/redo, `Put` appears only while the window is modified and vanishes once written, `Get` appears only for named windows. Text the user types in any tag is preserved across these recompositions. Tags are not menus: any text anywhere may be executed (R-EDIT-06). |
| R-EDIT-03 | A window SHALL display either a text buffer (file body) or a **directory listing**: the tag name ends in `/` and the body lists the entry names, subdirectories suffixed `/`. **Looking** (B3, R-EDIT-07) at an entry name opens it, resolved against the window's directory (R-EDIT-20). (v3 wrongly said B2; B2 on a name would try to *execute* it.) |
| R-EDIT-04 | Windows SHALL indicate modification state (the tag's square/dirty box) and scroll position (scrollbar at the left edge, ACME-style: B1 scrolls up, B3 scrolls down, B2 jumps absolute). |

## 2. Mouse language

| ID | Requirement |
|----|-------------|
| R-EDIT-05 | **B1** selects text (click sets the caret; sweep selects; double-click selects word/line/bracketed or quoted range by context). |
| R-EDIT-06 | **B2** **executes** the swept or clicked text (expansion of a bare click per R-EDIT-24): built-in commands by name, otherwise the text is run as an external command *where meaningful* (see §5 — in the browser, "external" means programs addressable through the namespace, not a Unix shell), in the directory context of R-EDIT-20 with output to R-EDIT-21. |
| R-EDIT-07 | **B3** **looks** (paper §User interface): if the indicated text, resolved per R-EDIT-20, names an existing file it is opened (or the existing window is brought to the front), optionally at a `:addr` suffix (R-EDIT-13); otherwise it is literal text searched for in the body of the window holding it, from the end of the current selection with wraparound, and the hit becomes the selection. A bare click expands per R-EDIT-24. The **`Look`** built-in always searches for the selection as literal text, for the rare file name that is just text. |
| R-EDIT-08 | **Chords** SHALL work exactly as in ACME: while a B1 sweep/hold is active, B2 = **Cut**, B3 = **Paste**; B1+B2 then B3 without release = Snarf-and-paste idioms. Argument passing: sweeping a command with B2 and, while holding, clicking B1 passes the current selection as argument (2-1 chord). |
| R-EDIT-09 | The mouse language SHALL be available through the emulation model of [05-input.md](05-input.md) so no requirement here silently depends on three physical buttons. |

## 3. Text and editing

| ID | Requirement |
|----|-------------|
| R-EDIT-10 | Text SHALL be Unicode (UTF-8 files, code-point addressed buffers); the editor MUST handle files at least up to 64 MiB within browser memory limits. (Deliberate divergence from paper §Undo, which keeps text in a temporary file with only the visible portion in memory: the browser has no cheap temp file, so buffers are in-memory.) |
| R-EDIT-11 | Unlimited undo/redo per window, surviving `Put` (save). |
| R-EDIT-12 | The **Edit** command language (structural regular expressions: addresses, `x/…/`, `s/…/…/`, `g`, `v`, `m`, `t`, …) SHALL be implemented as in ACME's `Edit`. |
| R-EDIT-13 | **Plumbing (subset)**: B3 on `path`, `path:line`, `path:/regexp/`, and `http(s)://…` SHALL open the file at the address (within the namespace) or open the URL (via the browser). A full plumber with user rules is deferred (OQ-EDIT-2). |
| R-EDIT-14 | The **snarf buffer** SHALL be synchronized with the system clipboard through `/dev/snarf` (see R-9P-07), so cut/copy/paste interoperates with the rest of the user's desktop. |

## 4. File operations

| ID | Requirement |
|----|-------------|
| R-EDIT-15 | `Get`, `Put`, `Putall` SHALL read/write through the namespace (any mount: host FS, origin, DOM). A window's name is a namespace path. |
| R-EDIT-16 | `Dump`/`Load` session state SHALL serialize to a namespace file so a session can be resumed (target: `/mnt/host` or `/dev/storage`). |

## 5. Programmability

| ID | Requirement |
|----|-------------|
| R-EDIT-17 | Snarf SHALL export its own state as a file tree, ACME-style (`/mnt/acme`-equivalent: per-window `addr`, `body`, `tag`, `event`, `ctl`, …), served over 9P **to the origin server or other tabs** where transports permit, and always available internally — so tooling can be written against Snarf just as against ACME. |
| R-EDIT-18 | Executing text that is not a built-in SHALL be resolved against an extensible command table; v1 ships built-ins only plus commands the origin exports (OQ-EDIT-1). There is no local shell. |
| R-EDIT-19 | **Dot-transformer principle**: dot (the selection, always a range) is the only cursor. Every input modality — B1 select (spatial), B3 look (content), `Edit`/`addr` (structural), and any future layer such as a modal/vim-motion client — SHALL move the cursor only by computing an address and assigning dot. No input feature may move the cursor by a mechanism the address engine cannot express. |

## 6. Context, placement, and browser divergences (added v4 from the paper)

| ID | Requirement |
|----|-------------|
| R-EDIT-20 | **Directory context** (paper §User interface): there is no single "current directory". Every command, file name, and address SHALL be interpreted in the directory named by the tag of the window holding the text (`mammals` in a window named `/lib/` or `/lib/insects` means `/lib/mammals` if it exists). External commands run in that directory and are searched for there first. Names in angle brackets (`<stdio.h>`) resolve against the configured include directories. |
| R-EDIT-21 | **Output windows** (paper §User interface, §Coupling to existing programs): output and diagnostics of a command executed in a window whose directory is *dir* SHALL go to a window named *dir*`/+Errors`, created on demand, so relative file names in the output resolve correctly with B3. Editor warnings go to the `+Errors` window of the relevant directory. Output windows are placed towards the right, away from edited text (R-EDIT-23). Standard input is empty (`/dev/null`). |
| R-EDIT-22 | **Point-to-type** (paper §Nuances): there is no click-to-type. Keyboard input goes to the text under the mouse pointer; scroll wheel likewise scrolls the text under the pointer. ACME's `-b` click-to-type variant is out of scope unless a later revision adds it as an option. There are no pop-up or pull-down menus. |
| R-EDIT-23 | **Window placement heuristics** (paper §Nuances): a new window appears in the **active** column, the one most recently used for typing or B1 selection — executing and searching do NOT change the active column. Within the column: consume large blank space, keep existing text visible, divide large windows before small ones, and place the new window near the one whose action created it. When a window is deleted its neighbour regrows. Concretely this is ACME's `makenewwindow` (column choice, emptiest-else-biggest window) plus `coladd`/`colclose` geometry. |
| R-EDIT-24 | **Single-click expansion** (paper §Nuances): a B2 or B3 click with a null selection SHALL be expanded to the text around it. First, a click inside the window's B1 selection uses that selection (so repeated B3 clicks step through occurrences and a selected multi-word command becomes a menu item). Otherwise, for B2 the "word" is the largest run of file-name characters around the click; for B3 the editor looks for a file name (with optional `:addr`) that names an existing file per R-EDIT-20, else takes the largest alphanumeric run. |
| R-EDIT-25 | **Mouse warping is REQUESTED by the core and honoured per host** (*amended v6, 2026-09-14, ADR-0005 / phase 15; was "no mouse warping"*). The paper moves the pointer to a new window's selection, to a search hit, to a moved layout box, and back to its origin when a pop-up window is deleted. The editor core SHALL express each such warp as a **write to `/dev/mouse`** — Plan 9's own warp (`mouse(3)`: "writing the mouse file, in the same format, causes the mouse cursor to move to the position specified by the *x* and *y* coordinates"), which is exactly what ACME's `moveto` performs. The core SHALL ignore the write failing. A host that can move the pointer SHALL honour it; a host that cannot SHALL refuse the write and SHALL instead make the target obvious: the hit or new window's selection is highlighted and scrolled into view, and layout-box clicks keep operating on the same window under a stationary pointer where possible. **Browser host: cannot warp** (no page may move the pointer) — this remains the one paper behavior Snarf knowingly does not honour *there*. **Native host: warps** (`Tmoveto`). **Touch profile:** neither — the warps map onto moving focus/dot instead (see `agents/HANDOFF.md`, design note pending). Implemented sites: a search hit with `e.jump` (`look.c:219`) and the window `openfile` opened (`look.c:897`); the layout/scroll `moveto`s (`cols.c`, `scrl.c`, `wind.c`, `util.c`) are not ported yet on any host. |

## 7. Open questions

- OQ-EDIT-1: Command execution of non-built-ins — resolve via `/bin` (the union that the
  origin's `/n/origin/bin` is bound into, R-9P-03/R-9P-10) (origin-
  exported services invoked by writing to their `ctl` files)? *Current stance: yes, spec'd
  as "external commands are files"; no code execution of fetched binaries in v1.*
- OQ-EDIT-2: Full plumber with rules file vs. hard-coded plumbing heuristics. *v1:
  hard-coded (R-EDIT-13); rules file later.*
- OQ-EDIT-3: Win/terminal windows (`win`) are meaningless without a shell — permanently out
  of scope, or emulated against an origin-side pty service? *Deferred.*
- OQ-EDIT-4 (*design settled 2026-07-21; implementation deferred*): **modal editing
  ("vim motions") as an external namespace client.** Vim's grammar maps onto acme's:
  motions are address arithmetic (`3j` → `+3`, `w` → `+/word-re/`, `/pat` → `/pat/`),
  operator+motion is an address span acted on via `addr`+`data`, visual mode is dot,
  registers are `/dev/snarf` + scratch files. One gap blocks a *pure* client: per
  acme(4), open `event` files intercept B2/B3 but keyboard events are report-only —
  typed runes self-insert before a client sees them. Snarf specifies (but defers) the
  `kbd hold` interception verb in spec S-02 §6 to close this. No v1 work; revisit once
  the editor core is functional.

## 8. Revision log

- **v1** — initial ACME behavior inventory.
- **v2** — R-EDIT-09 added to bind the mouse language to the emulation requirements;
  R-EDIT-06/18 reworded after deciding there is no local shell (browser sandbox);
  R-EDIT-14 tied explicitly to `/dev/snarf`.
- **v3** — added R-EDIT-19 (dot-transformer principle: all input modalities converge on
  dot assignment through the address engine) and OQ-EDIT-4 (vim-motion modal layer as an
  external client, enabled by the deferred `kbd hold` verb, S-02 §6). Design discussion
  with user; implementation deferred.
- **v4** (2026-09-13) — re-verified against the archived paper (`docs/acme/acme.md`).
  Corrected R-EDIT-03 (B3, not B2, opens a directory entry) and R-EDIT-02 (the window
  tag is live: `Undo`/`Redo`/`Put`/`Get` come and go; the fixed part is `Del Snarf | Look `).
  R-EDIT-07 now states the full look resolution and the `Look` built-in. Added §6:
  directory context (R-EDIT-20), `+Errors` output windows (R-EDIT-21), point-to-type
  (R-EDIT-22), placement heuristics (R-EDIT-23), single-click expansion (R-EDIT-24), and
  the recorded no-warp divergence (R-EDIT-25). Noted the in-memory-buffer divergence on
  R-EDIT-10. Implementation gaps found in the same pass are in `agents/HANDOFF.md`.
- **v6** (2026-09-14, phase 15 — the ADR-0005 native-host spike) — no IDs added,
  changed or renumbered; **R-EDIT-25 AMENDED** from "no mouse warping — recorded
  divergence" to "warping is requested by the core and honoured per host". The
  divergence was always a *host* property, not an editor property, and ADR-0005 made
  that concrete by adding a second host that can warp. The core now issues the paper's
  warps as `/dev/mouse` writes (Plan 9 `mouse(3)`, `9/port/devmouse.c:458-476`) and
  swallows the failure; the browser device refuses the write, the native `devdraw`
  device answers it with `Tmoveto`. Ruling R-P15-3. Spec: S-04 §1. Code:
  `src/core/warp.zig`, `src/host/devdraw/dev_input.zig`. The rest of R-EDIT-25's
  guidance (highlight + scroll the target on a host that cannot warp) is unchanged and
  still what the browser does.
- **v5** (2026-09-14, phase 13b) — no requirement IDs added, changed or renumbered; one
  BROWSER-HOST note recorded against **R-EDIT-07** (and it applies equally to R-EDIT-03
  and R-EDIT-13): ACME decides whether B3'd text is a file name with a synchronous
  `access()` inside `look3` (`acme/look.c:706`). Snarf cannot — the answer comes from a
  9P walk whose reply may arrive only on a later browser tick (R-9P-13) and the main
  thread must not block — so the existence check is ASYNCHRONOUS (ruling R-P13b-2, spec
  S-05 §6): the look parks on a `StatJob`, at most one at a time, and resolves a frame
  or two later either into an opened window or into the literal search. The same
  inversion applies to loading a window's contents at all (`textload` → `src/core/Load.zig`,
  S-05 §2), so a directory window's listing likewise appears a frame or two after the
  window does. Two further rulings recorded without ID changes: `wdir` is `/`
  (R-P13b-3 — the port has no process working directory, so an unrooted name that the
  window's own directory does not resolve hangs off the namespace root), and `Get`
  serves DIRECTORY windows only until the Put/Get wave (R-P13b-5).
