# R-02 — Editor Functional Requirements (ACME semantics)

Status: **Draft v2**

Snarf's editing model is ACME's. This document states the behaviors that must survive the
port; the implementation design is in [../spec/05-editor-core.md](../spec/05-editor-core.md).

## 1. Screen layout

| ID | Requirement |
|----|-------------|
| R-EDIT-01 | The display SHALL be divided into vertical **columns**; each column holds a stack of **windows**. Columns and windows are created, moved, resized, and deleted with the mouse. |
| R-EDIT-02 | The top of the screen, each column, and each window SHALL have a **tag line**: an editable line of text holding the entity's name plus commands. Built-in tag commands include at least: `Newcol Kill Putall Dump Exit` (root), `New Cut Paste Snarf Sort Zerox Delcol` (column), `Del Snarf Undo Redo | Look Edit ` (window; window tags are freely editable). |
| R-EDIT-03 | A window SHALL display either a text buffer (file body) or a directory listing; executing (B2) a directory entry name opens it. |
| R-EDIT-04 | Windows SHALL indicate modification state (the tag's square/dirty box) and scroll position (scrollbar at the left edge, ACME-style: B1 scrolls up, B3 scrolls down, B2 jumps absolute). |

## 2. Mouse language

| ID | Requirement |
|----|-------------|
| R-EDIT-05 | **B1** selects text (click sets the caret; sweep selects; double-click selects word/line/bracketed range by context). |
| R-EDIT-06 | **B2** **executes** the swept or clicked text: built-in commands by name, otherwise the text is run as an external command *where meaningful* (see §5 — in the browser, "external" means programs addressable through the namespace, not a Unix shell). |
| R-EDIT-07 | **B3** **looks**: search for the literal text in the window; if it names a file or resource in the namespace, open it (plumbing, R-EDIT-13). |
| R-EDIT-08 | **Chords** SHALL work exactly as in ACME: while a B1 sweep/hold is active, B2 = **Cut**, B3 = **Paste**; B1+B2 then B3 without release = Snarf-and-paste idioms. Argument passing: sweeping a command with B2 and, while holding, clicking B1 passes the current selection as argument (2-1 chord). |
| R-EDIT-09 | The mouse language SHALL be available through the emulation model of [05-input.md](05-input.md) so no requirement here silently depends on three physical buttons. |

## 3. Text and editing

| ID | Requirement |
|----|-------------|
| R-EDIT-10 | Text SHALL be Unicode (UTF-8 files, code-point addressed buffers); the editor MUST handle files at least up to 64 MiB within browser memory limits. |
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

## 6. Open questions

- OQ-EDIT-1: Command execution of non-built-ins — resolve via `/mnt/origin/bin` (origin-
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

## 7. Revision log

- **v1** — initial ACME behavior inventory.
- **v2** — R-EDIT-09 added to bind the mouse language to the emulation requirements;
  R-EDIT-06/18 reworded after deciding there is no local shell (browser sandbox);
  R-EDIT-14 tied explicitly to `/dev/snarf`.
- **v3** — added R-EDIT-19 (dot-transformer principle: all input modalities converge on
  dot assignment through the address engine) and OQ-EDIT-4 (vim-motion modal layer as an
  external client, enabled by the deferred `kbd hold` verb, S-02 §6). Design discussion
  with user; implementation deferred.
