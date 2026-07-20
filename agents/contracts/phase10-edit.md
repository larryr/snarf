# Phase 10 contract — Edit language + served tree start

Master reconciliation for O20 (`phase10-regx-addr.md`), O21 (`phase10-edit-cmd.md`),
O22 (`phase10-served.md`). Build agents read the master FIRST, then their side file.
Hard gates unchanged (in-worktree `zig build test --summary all` green + `zig fmt
--check build.zig src/ tools/` clean; named tests exact, never weakened; cite pinned C
by SHA; STOP-and-report on unimplementable signatures; ~400-line soft cap, split on
behavioral seams).

## Rulings — Edit language (numbers)

- **R-P10-1 (type homes)**: `src/core/edit/ast.zig` (O21 §2.1) is THE home for
  `Addr`/`Kind`, `Address`, `String`, `Diag`, `Error`. **Amendment to O21's shape:
  `Address = struct { r: File.Range, t: *Text }`** (O20's F5 adopted — snarf's File
  has no `curtext`; where the C reads `a.f`, use `a.t.file`). `Rangeset =
  [nrange]Range` lives in `Regx.zig` (O20 §2.1). `addr.zig` holds evaluation
  functions ONLY. Import graph: `Regx` ← `ast` ← `addr` ← {`parse`? no —
  `parse` imports `ast` only} ← `cmd`/`loop`/`edit` — acyclic; `ast.zig` imports
  core siblings (Text/File) but never parse/cmd.
- **R-P10-2 (Regx API frozen)**: O20 §2.1 signatures verbatim — `compile(pattern:
  []const u21) CompileError!void`, `execute(src: Source, startp: usize, eof: ?usize)
  ExecError!?Rangeset` (`eof == null` ⇒ the C's Infinity: search-to-end AND wrap
  once), `bexecute(src, startp)`, `isNull`, `describe`. O21's loops call
  `rx.execute(.{ .buffer = &t.file.buffer }, p, q1)` — bounded, no wrap
  (looper/ecmd.c:864-891). `error.ListOverflow` surfaces from Regx; consumers
  (addr.nextMatch, loops) map it to a warning + treat-as-no-match, faithful to
  regx.c:622-627 (O20's F3, acked).
- **R-P10-3 (addr API)**: evaluation takes NO Editor —
  `eval(rx: *Regx, ap: *const ast.Addr, a: ast.Address, sign: i8) Error!ast.Address`
  (the `;` mid-eval dot write on `a.t` is a documented side effect, ecmd.c:1115-1122);
  `nextMatch(rx: *Regx, t: *Text, re: []const u21, p: usize, sign: i8) Error!File.Range`;
  `charAddr`/`lineAddr` **pub** (nl_cmd + linelooper call them directly);
  `mkAddr(t: *Text) Address`. addr.Error stays ENUMERATED (O20 §2.2 — testable);
  `cmd.zig` translates at its boundary: `addr.eval(...) catch |e| return
  x.diag.set("{s}", .{addr.describe(e)})` with the C's editerror strings.
- **R-P10-4 (error model)**: `ast.Error = error{Edit, OutOfMemory} || Text.Error`;
  `Diag` rides `cmd.Ctx`; `editerror` ⇒ `diag.set(...)` returning `error.Edit`; on
  any error `elog.term()` first (edit.c:145-146 — a failed Edit applies NOTHING),
  then ONE `ed.warning("Edit: {s}\n", ...)`. No longjmp, no threads, no channels.
- **R-P10-5 (Editor fields)**: `ed.regx: Regx` added by wave 10a-A1 (C-global
  lifetime — the lastregexp cache spans Edit invocations, O20's F2);
  `ed.edit_lastpat: std.ArrayList(u21)` added by 10a-A2 (edit.c:181 — persists
  ACROSS Edit invocations). Both deinit'ed. Editor.zig merge conflicts between the
  two waves are orchestrator-resolved (phase-4 one-line precedent).
- **R-P10-6 (Elog placement)**: the Elog lives on the per-Edit `cmd.Ctx`, not on
  File (v1 single-file; the multi-file allwindows sweep collapses to one apply on
  the target body). FLAG: moves to File in the multi-file Edit phase.
- **R-P10-7 (v1 command set)**: O21 §1.8 adopted — include addresses,
  `a c i d s m t`, `x y g v` (+ bare-x linelooper), `= p u \n { }`. Defer
  `b B D e r f w` (namespace/disk/menu), `X Y` (cross-file), `< | >` (pipes —
  impossible pre-namespace), `"` file-match (parses, eval ⇒ Unsupported), `'` mark
  (errors exactly as acme does). Deferred letters are NOT in the v1 cmdtab ⇒
  "unknown command" (honest divergence, flagged).
- **R-P10-8 (Edit builtin)**: exectab row `.{ .name = "Edit", .fn_ = edit.builtin,
  .mark = false, ... }` (exec.c:106 — Edit manages seq ITSELF: `ed.seq += 1`
  unconditionally in the builtin per exec.c:1141; `File.mark` happens lazily inside
  the first Elog.apply mutation, elog.c:271-272). Chord argt wins over the inline
  remainder. Alphabetical position: between Delete and New; builtins shape-test
  count updates.
- **R-P10-9 (spec amendments — orchestrator commits with the contracts)**:
  (a) 07-source-layout.md mapping note: `addr.zig` ports ecmd.c's cmdaddress
  family; acme's `addr.c` (the xfid/B3 incremental evaluator) joins in a later
  phase (O20's F1). (b) S-07 §6: `core/served/*` may use `ninep/server` — §4
  always planned `core/served/fsys.zig` riding ninep/server; §6's list omitting it
  was an oversight, not a decision. Revision-log entries, not ADR changes.

## Rulings — served tree (letters, from O22 §3.1, adopted verbatim)

R-P10-A (qid scheme `(win<<8)|Q`, v1 serves dir/index/new/w_body/w_ctl/w_tag),
R-P10-B (errors.zig + `DeletedWindow`/`BadCtl`), R-P10-C (no refcount — fids carry
the window id; re-resolve per op; dead ⇒ DeletedWindow on open fids,
FileDoesNotExist on fresh walks), R-P10-D (Mntdir collapses), R-P10-E (no runtime
mount in v1 — acceptance goes through `Namespace` in tests; boot wiring waits for
the first in-editor client), R-P10-F (ctl line fonts arm with literal `fixed9x18`,
isdir=0), R-P10-G (utfRead rescans from rune 0 — the cache is a flagged seam),
R-P10-H (ctl subset: clean/dirty/del/delete/name; unknown ⇒ BadCtl; "delete" must
precede "del" in the table), R-P10-I (`cmd_window.makeWindow` goes pub; walk-to-new
calls it; column = seltext's, else first, else error), R-P10-J (deferred: event,
addr/data/xdata — `// SEAM(O21)` markers, cons/label/log/editout, rdsel/wrsel,
lock/unlock). Full text + cites in `phase10-served.md`.

## Sub-wave assignments

- **10a (concurrent, three agents):**
  - A1 **opus** — the regexp engine: `src/core/edit/{Regx.zig,regx_compile.zig,
    regx_exec.zig}` + `ed.regx` field + `core.zig` edit namespace export seed.
    O20 §2.1 + tests 1-23.
  - A2 **opus** — AST + parser: `src/core/edit/{ast.zig,parse.zig}` (with the
    R-P10-1 Address amendment) + `ed.edit_lastpat`. O21 §2.1-§2.2 + parse tests
    (O21 tests 1-6 + shape pins).
  - A3 **opus** — served tree server half: `src/core/served/fsys.zig`,
    `src/ninep/errors.zig` (+2 members), `Window.ctlPrint` + `ctl_size`,
    `cmd_window.makeWindow` → pub. O22 §3.2 Wave A + O22 tests 1, 2, 5, 6, 7.
- **10b (concurrent, after 10a merges):**
  - B1 **sonnet** — `src/core/edit/addr.zig` per R-P10-3. O20 §2.2 + tests 24-41.
  - B2 **sonnet** — `src/core/edit/Elog.zig` per O21 §2.3. Direct-call tests
    (merge/coalesce/apply-order/out-of-sequence halves of O21 tests 30/34).
  - B3 **sonnet** — served tree file half: `src/core/served/xfid.zig` (utfRead,
    indexRead, ctlWrite + the five commands) + the S-07 §6/§4-mapping revision
    lines (R-P10-9) + acceptance through Client+Namespace. O22 §3.2 Wave B +
    O22 tests 3, 4.
- **10c (single, after 10b): C1 opus** — `src/core/edit/{cmd.zig,edit.zig}` +
  builtins Edit row (R-P10-8). O21 §2.4/§2.6/§2.7 + tests 7-17, 32-35.
- **10d (single, after 10c): D1 opus** — `src/core/edit/loop.zig` (s + x/y/g/v +
  braces). O21 §2.5 + tests 18-31.
- **Wave C (orchestrator)**: acceptance scene (`Edit` driven end-to-end via B2 in
  a booted scene — s/x composition + one-undo pin; new freeze if the write stream
  is scene-worthy), report, merge, HANDOFF.

## Cross-contract interface (frozen)

- `Regx.init(alloc)`, `compile([]const u21) CompileError!void`,
  `execute(Source, startp, eof: ?usize) ExecError!?Rangeset`,
  `bexecute(Source, startp) ExecError!?Rangeset`, `isNull`, `describe(anyerror)
  []const u8`; `Source = union(enum){ buffer: *const Buffer, runes: []const u21 }`;
  `Rangeset = [10]File.Range` ([0] whole match; unmatched groups {0,0}).
- `ast.Addr{ kind: Kind, next: ?*Addr }` with O21's Kind union;
  `ast.Address{ r: File.Range, t: *Text }`; `ast.Diag.set(fmt, args) error{Edit}`;
  `ast.Error = error{Edit, OutOfMemory} || Text.Error`.
- `addr.eval(rx, ap, a, sign) Error!Address`; `addr.nextMatch(rx, t, re, p, sign)
  Error!File.Range`; `addr.charAddr/lineAddr(l, a, sign) Error!Address` (pub);
  `addr.mkAddr(t)`; `addr.describe(e) []const u8`.
- `Elog.insert/delete/replace(f, ...)`, `empty()`, `term()`, `apply(t: *Text)
  ast.Error!void` — apply iterates in REVERSE, marks once with `ed.seq`, mutates
  only via `Text.insertAt/deleteRange(..., tofile=true)`.
- `cmd.Ctx{ ed, arena, diag, elog, addr, rx, nest }`; `cmd.cmdexec(x, t, cp)
  ast.Error!bool`; `cmd.lookup(cmdc)`.
- `edit.editcmd(ed: *Editor, ct: *Text, cmd: []const u8) void` (never propagates);
  `edit.builtin(...)` matching `builtins.Entry.fn_`.
- Served: `fsys.Fsys.init(ed)`, `Fsys.ops: ninep.server.Ops`, `qpath/qwin/qfile`;
  `xfid.read/write(f, w: ?*Window, q, offset, buf)`; `xfid.utfRead(t, offset, buf,
  alloc)`; `xfid.indexRead(ed, offset, buf, alloc)`; `Window.ctlPrint(w, buf,
  fonts: bool) []u8` + `Window.ctl_size = 60`.
