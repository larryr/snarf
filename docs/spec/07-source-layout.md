# S-07 — Source Layout & Zig Idioms

Satisfies: R-CON-01, R-CON-02, R-OV-03. Informs: S-00 §3 (which now defers here), S-03,
S-04, S-05.

This spec derives Snarf's Zig source structure from a survey of the original ACME C
source, preferring **smaller files and structured code** over ACME's layout while keeping
its behavioral seams.

## 1. Reference sources (pinned)

Two forks under the project owner's account are the canonical references; every citation
in the docs uses these commits, so references stay stable regardless of upstream:

| Role | Repository @ commit | Paths used |
|------|--------------------|------------|
| **Primary acme code reference** | `larryr/plan9port` @ `337c6ac` | `src/cmd/acme/*`, `src/libframe/*`, `src/libdraw/*` |
| **Device & protocol semantics** | `larryr/plan9` (Plan 9 4e) @ `ed1a9c2` | `sys/src/9/port/devdraw.c`, `devmouse.c`, `devcons.c`; manuals `sys/man/3/{draw,mouse,cons}`, `sys/man/5/*` |

plan9port is primary for editor code because it is the maintained acme and already solved
"acme without a Plan 9 kernel" (its `devdraw` helper process is the ancestor of our JS
shim). The 4e tree is authoritative for the kernel device files our device layer
re-creates (specs S-01, S-03, S-04 cite it). Citation form: `acme/text.c:1234`
(plan9port) or `9/port/devdraw.c:567` (4e).

## 2. Survey of the original C source

`src/cmd/acme` at the pinned commit: **15,830 lines** in 22 `.c` + 3 `.h` files, plus
**libframe** (1,276 lines, 9 files) which acme requires for text frames.

| File | Lines | Responsibility (porting notes) |
|------|------:|-------------------------------|
| `exec.c` | 1817 | B2 execute: 30-entry builtin `Exectab`, cut/paste/get/put, external command spawning via pipes (no shell for us → S-05 §4) |
| `text.c` | 1664 | The `Text` type: typing, selection, double-click expansion, frame glue, scrolling — four jobs in one file |
| `ecmd.c` | 1396 | Edit-language command execution (the `x/s/m/t/g/v` machinery) |
| `acme.c` | 1161 | `main`/`threadmain`, arg parsing, **mousethread/keyboardthread/waitthread**, timefmt, error window plumbing |
| `xfid.c` | 1147 | 9P request execution for the served tree: **one libthread thread per Xfid** |
| `look.c` | 942 | B3 look: search, file/URL resolution, plumbing |
| `rows.c` | 857 | `Row`: top-level layout, Dump/Load session serialization |
| `regx.c` | 843 | sam-style structural regexp engine |
| `fsys.c` | 749 | 9P server framing/dispatch for `/mnt/acme` (hand-rolled, pre-lib9p) |
| `wind.c` | 726 | `Window`: tag+body pairing, ctl-line printing |
| `edit.c` | 686 | Edit-language parser |
| `cols.c` | 591 | `Column`: window stacking, drag/resize rules |
| `dat.h` | 582 | **God-header**: every struct (`Block Disk Buffer Elog File Text Window Column Row Command Timer Dirtab Mntdir Fid Xfid Reffont Rangeset`) + **60 `extern` globals** |
| `util.c` | 497 | warnings (`warning()` → Errors window), rune/UTF conversion helpers, memory wrappers |
| `elog.c` | 354 | Edit transcript log applied atomically per command |
| `buff.c` | 325 | `Buffer`: cached rune storage over `Disk` blocks |
| `file.c` | 311 | `File`: Buffer + undo/redo delta stacks |
| `addr.c` | 297 | address parsing/evaluation (`#n`, `/re/`, line ranges) |
| `logf.c` | 199 | `acme/log` event file |
| `scrl.c` | 159 | scrollbar drawing & interaction |
| `disk.c` | 133 | temp-file block allocator backing Buffer |
| `time.c` | 124 | timer channels |
| `fns.h` | 109 | prototype god-header |
| `edit.h` | 99 | Edit-language types |
| `dat.c` | 62 | definitions of the globals |

libframe: `frinsert.c` 291, `frdraw.c` 215, `frbox.c` 159, `frselect.c` 132,
`frdelete.c` 130, `frptofchar.c` 115, `frutil.c` 111, `frinit.c` 86, `frstr.c` 37.

4e kernel devices (semantics reference only, not ported line-for-line): `devdraw.c`
2218, `devcons.c` 1353, `devmouse.c` 779.

**Observations the Zig layout must answer:**

1. **A few files carry most of the weight** — `exec.c`, `text.c`, `ecmd.c`, `acme.c`,
   `xfid.c` are each 1.1–1.8k lines and each mixes several concerns.
2. **Two god-headers** — every module sees every struct and every prototype; nothing is
   private; include-order is load-bearing.
3. **Global state** — 60 externs (row, display, fonts, seltext/argtext/mousetext,
   channels, config flags) mutated from everywhere.
4. **Concurrency by libthread** — dedicated threads for mouse/keyboard/wait plus a
   thread per 9P request (`xfid.c`), synchronized by channels; we have an event loop
   (S-00 §2) instead.
5. **Type-int unions** — `Elog.type`, `Xfid` request codes, draw verbs are integers +
   unions, checked at runtime.
6. **What disappears in the browser** — `disk.c` (temp-file paging), `Command`/wait
   lists (no processes), `time.c`'s alarm threads (shim vsync/timeout ticks instead).

## 3. Porting principles (Zig idioms)

| # | Rule | Replaces | Rationale |
|---|------|----------|-----------|
| P-1 | **One type per file, file-as-struct**: `Buffer.zig` *is* `struct { … }`; type files `PascalCase.zig`, namespace modules `lowercase.zig` | `dat.h` struct pile | Zig's file=struct idiom; visibility via `pub`, not header discipline |
| P-2 | **≤ ~400 lines per file** (soft cap, enforced in review); split along ACME's own seams, never mid-algorithm | 1.8k-line files | small files stay reviewable; the seams (typing vs selection vs scrolling) already exist in the C as function groups |
| P-3 | **No globals**: one `Editor` context owns what `dat.c` declared; passed `*Editor` explicitly. The only file-scope state allowed is `comptime` constants | 60 externs | testability (construct two Editors in one test), R-CON-02 |
| P-4 | **Explicit allocators**: every long-lived type stores its `std.mem.Allocator`; no hidden allocation | `emalloc` wrappers | Zig convention; WASM heap discipline |
| P-5 | **Error unions per layer** (`error{FileDoesNotExist,PermissionDenied,…}` mirroring S-01 §5 strings); `errdefer` for unwind; user-visible warnings are explicit `warn.zig` calls, never a side effect of failure | int returns + `warning()` | failures become type-checked control flow |
| P-6 | **Tagged unions** for `Elog`, input events, 9P messages, Edit AST, draw ops | type-int structs | exhaustive `switch`, impossible states unrepresentable |
| P-7 | **Comptime tables**: builtin commands, 9P dispatch, Qid tables as comptime slices of struct literals | `Exectab[]`, `dirtab[]` | data-driven like the C, but checked at compile time |
| P-8 | **Threads/channels → event-loop state machines**: mouse/kbd threads become `devinput` (S-04); per-Xfid threads become ticket continuations (S-00 §2); timers become shim tick subscriptions | libthread | WASM has no cheap threads; already specified |
| P-9 | **Runes via `std.unicode` over UTF-8 slices**; rune addressing is `Buffer`'s private concern (`RuneIndex`), everything above speaks offsets it gets from Buffer | `Rune*` arrays everywhere | keeps std-only (R-CON-01) and localizes the rune/byte duality |
| P-10 | **Tests colocated** (`test` blocks in the module); every `src/core` and `src/ninep` file must compile and pass tests natively (`zig build test`) with no shim present | none in C | enforces the R-CON-02 layering mechanically |

## 4. The source tree

Target sizes in parentheses are budgets, not measurements; ~55 source files replacing
ACME's 25 + libframe's 9.

```
src/
├── main_wasm.zig            (~60)  freestanding entry: exports init/wake/tick
├── main_native.zig          (~90)  native entry: headless harness for tests
├── core/                    — browser-free editor (imports: draw, ninep client only)
│   ├── Editor.zig           (~250) the context: row, fonts, snarf, seq, config  [dat.c + globals]
│   ├── boot.zig             (~200) namespace assembly, initial layout           [acme.c main]
│   ├── Row.zig              (~350) columns container, Dump/Load                 [rows.c]
│   ├── Column.zig           (~300) window stack, drag/resize                    [cols.c]
│   ├── Window.zig           (~350) tag+body, ctl format                         [wind.c]
│   ├── File.zig             (~250) buffer + undo/redo transactions              [file.c]
│   ├── Buffer.zig           (~300) piece table                                  [buff.c + disk.c]
│   ├── RuneIndex.zig        (~200) rune/line index tree for Buffer              [new]
│   ├── timer.zig            (~80)  tick-driven timers                           [time.c]
│   ├── warn.zig             (~100) warnings → +Errors window                    [util.c]
│   ├── text/
│   │   ├── Text.zig         (~350) Text type: frame+buffer glue, redraw         [text.c]
│   │   ├── typing.zig       (~250) rune input, tag/body editing keys            [text.c]
│   │   ├── select.zig       (~300) sweeps, double-click expansion, addr select  [text.c]
│   │   └── scroll.zig       (~200) scrollbar + scroll policy                    [scrl.c + text.c]
│   ├── exec/
│   │   ├── exec.zig         (~250) B2 dispatch, argument/chord handling         [exec.c]
│   │   ├── builtins.zig     (~150) comptime command table (P-7)                 [exec.c Exectab]
│   │   ├── cmd_window.zig   (~250) New Del Zerox Sort Delcol Newcol …           [exec.c]
│   │   ├── cmd_file.zig     (~300) Get Put Putall + name resolution             [exec.c]
│   │   ├── cmd_edit.zig     (~250) Cut Paste Snarf Undo Redo Look Send          [exec.c]
│   │   ├── cmd_session.zig  (~200) Dump Load Exit Font Tab Reconnect            [exec.c]
│   │   └── external.zig     (~200) origin-exported commands, |<> pipes          [exec.c run]
│   ├── edit/
│   │   ├── parse.zig        (~350) Edit-language parser                         [edit.c]
│   │   ├── cmd.zig          (~400) command execution                            [ecmd.c]
│   │   ├── addr.zig         (~250) address evaluation                           [addr.c]
│   │   ├── regx.zig         (~400) structural regexp engine                     [regx.c]
│   │   └── Elog.zig         (~200) tagged-union edit transcript (P-6)           [elog.c]
│   ├── look/
│   │   ├── look.zig         (~300) B3 search & resolution order                 [look.c]
│   │   └── plumb.zig        (~200) path:line / URL plumbing subset              [look.c]
│   └── served/
│       ├── fsys.zig         (~250) /mnt/snarf-self on ninep.Server              [fsys.c]
│       ├── xfid.zig         (~400) per-fid request state machines (P-8)         [xfid.c]
│       └── logf.zig         (~120) log event file                               [logf.c]
├── draw/                    — libdraw-like client + frame (imports: ninep client)
│   ├── Display.zig          (~250) connection, ctl/data/refresh files
│   ├── Image.zig            (~200) image handle, draw/line/blit ops
│   ├── Font.zig             (~300) font/subfont, glyph cache load
│   ├── proto.zig            (~250) draw message encoding (tagged union, P-6)
│   └── frame/               [libframe, same decomposition]
│       ├── Frame.zig        (~250) frame state + boxes                          [frinit.c frbox.c]
│       ├── draw.zig         (~200)                                              [frdraw.c]
│       ├── insert.zig       (~250)                                              [frinsert.c]
│       ├── delete.zig       (~150)                                              [frdelete.c]
│       ├── select.zig       (~150)                                              [frselect.c]
│       └── util.zig         (~200) ptofchar etc.                                [frutil.c frptofchar.c frstr.c]
├── ninep/                   — 9P2000 (imports: std only)
│   ├── msg.zig              (~400) message tagged union, encode/decode
│   ├── qid.zig              (~80)
│   ├── client.zig           (~300) fid/tag tables, walk/open/read helpers
│   ├── server.zig           (~350) Srv vtable framework (lib9p-shaped)
│   ├── mount.zig            (~200) mount table / namespace
│   ├── chan.zig             (~200) in-memory transport rings
│   └── ws.zig               (~150) WebSocket transport framing
├── dev/                     — device servers (imports: ninep server, shim)
│   ├── draw.zig             (~400) devdraw: image state, verb dispatch    [ref: 9/port/devdraw.c]
│   ├── draw_backend.zig     (~250) OffscreenCanvas backend + headless backend
│   ├── input.zig            (~350) devmouse/devkbd + chord state machine  [ref: 9/port/devmouse.c, S-04]
│   ├── profiles.zig         (~200) native/modifier/touch/chordbar mapping tables
│   ├── dom.zig              (~400) /dev/dom
│   ├── host.zig             (~350) /mnt/host + /mnt/opfs
│   ├── storage.zig          (~200) /dev/storage
│   └── misc.zig             (~250) snarf, notify, title, location, log, cons
└── shim/                    — WASM boundary (imports: std only)
    ├── abi.zig              (~200) extern imports/exports + version hash
    └── ring.zig             (~250) SAB/postMessage event rings
web/    index.html, shim.js  (hand-written JS, S-06 §4)
assets/fonts/                subfont assets (S-03 §4)
```

## 5. C → Zig mapping (every original file accounted for)

| C file | → Zig | Notes |
|--------|-------|-------|
| `acme.c` | `core/boot.zig`, `core/Editor.zig`, `dev/input.zig` | mouse/keyboard threads become devinput; waitthread has no equivalent (no processes) |
| `addr.c` | `core/edit/addr.zig` | |
| `buff.c` | `core/Buffer.zig` | piece table replaces block cache (S-05 §1) |
| `cols.c` | `core/Column.zig` | |
| `dat.c` | `core/Editor.zig` | globals → context fields (P-3) |
| `dat.h` | dissolved | each struct moves into its type's file (P-1) |
| `disk.c` | **dropped** | temp-file paging is meaningless in WASM; piece table + browser memory |
| `ecmd.c` | `core/edit/cmd.zig` | |
| `edit.c` | `core/edit/parse.zig` | |
| `edit.h` | dissolved into `core/edit/*` | AST becomes tagged unions (P-6) |
| `elog.c` | `core/edit/Elog.zig` | |
| `exec.c` | `core/exec/` (7 files) | largest split; table → comptime (P-7) |
| `file.c` | `core/File.zig` | |
| `fns.h` | dissolved | Zig namespaces replace prototypes |
| `fsys.c` | `core/served/fsys.zig` | rides `ninep/server.zig` instead of hand-rolled framing |
| `logf.c` | `core/served/logf.zig` | |
| `look.c` | `core/look/{look,plumb}.zig` | |
| `regx.c` | `core/edit/regx.zig` | |
| `rows.c` | `core/Row.zig` | Dump/Load format per S-05 §8 |
| `scrl.c` | `core/text/scroll.zig` | |
| `text.c` | `core/text/` (4 files) | typing / selection / frame-glue / scrolling seams |
| `time.c` | `core/timer.zig` | alarm threads → tick subscription (P-8) |
| `util.c` | `core/warn.zig` + `std.unicode` | rune helpers vanish into std (P-9) |
| `wind.c` | `core/Window.zig` | |
| `xfid.c` | `core/served/xfid.zig` | thread-per-request → ticket state machines (P-8) |
| `libframe/*` (9 files) | `draw/frame/` (6 files) | same decomposition, boxes stay internal to `Frame.zig` |
| `libdraw` (client subset) | `draw/{Display,Image,Font,proto}.zig` | only what acme uses (S-03 §2 verb set) |
| 4e `devdraw.c`, `devmouse.c`, `devcons.c` | `dev/draw.zig`, `dev/input.zig`, `dev/misc.zig` | **semantic** reference: file API and message grammar, not a line port |

## 6. Dependency rules

Allowed imports (anything not listed is a review error; no cycles by construction):

- `core/*` → `draw/*`, `ninep/client|mount|msg`, `std`
- `draw/*` → `ninep/client|msg`, `std`
- `ninep/*` → `std` only
- `dev/*` → `ninep/server|msg`, `shim/*`, `std`
- `shim/*` → `std` only
- `main_wasm.zig` → everything; `main_native.zig` → everything except `shim`

`core` importing `dev` or `shim` is forbidden — that is the R-CON-02 boundary that keeps
the editor natively testable. Mechanically: `zig build test` compiles `core`+`draw`+
`ninep` with a stub namespace and no shim module on the path, so a violating import is a
compile error, not a convention.

![module-deps](diagrams/module-deps.puml)

Diagram source: [diagrams/module-deps.puml](diagrams/module-deps.puml)

## 7. Trace

| This spec | Requirements / specs |
|-----------|---------------------|
| §1 reference policy | R-CON-05 (license lineage), all C citations in S-01..S-05 |
| §2 survey | grounds S-05's divergences (piece table, no shell) |
| §3 P-1..P-10 | R-CON-01 (std-only), R-CON-02 (native testability), R-OV-03 (boundary) |
| §4–§5 tree & mapping | S-00 §3 (owns the detail now) |
| §6 dependency rules | R-OV-03, R-CON-02 |
