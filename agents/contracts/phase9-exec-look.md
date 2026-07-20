# Phase 9 contract — exec & look (B2 executes, B3 searches)

Master reconciliation for O18 (exec — `phase9-exec.md`) and O19 (look — `phase9-look.md`).
Build agents read the master FIRST, then their side file. Hard gates unchanged
(in-worktree `zig build test --summary all` green + `zig fmt --check build.zig src/ tools/`
clean; named tests exact, never weakened; cite pinned C by SHA; STOP-and-report on
unimplementable signatures; ~400-line soft cap per file, split on behavioral seams).

## Rulings

- **R-P9-1 (shared colored sweep — resolves the O18/O19 conflict)**: O19's
  `Select23State` + `select23Begin/Update/End` + module-private `selRestore` in
  `src/draw/frame/select.zig` (look contract §3.2) is THE implementation for **both**
  buttons. O18's "endpoints-only, no but2col highlight in v1" flag is **overruled**:
  the machinery exists (`drawSel0` is pub and takes arbitrary back/text pairs,
  `tick` is pub), and one port serves both masks exactly as the C's `textselect23`
  does. B2 sweeps paint `but2col` (0xAA0000FF), B3 `but3col` (0x006600FF), glyphs in
  `display.white`; paint never touches `f.p0/f.p1` and is fully restored at exit.
- **R-P9-2 (unified gesture exit protocol)**: `buts` freezes at the FIRST button-set
  change (textselect23 text.c:1350) — the change sample's position is folded into the
  sweep first (text.c:1279-1316). `select23End` runs at that change (restores paint,
  yields the frame range, applies the DELAY=2ms/MINMOVE=4px null-click collapse —
  text.c:1253-1258, 1317-1325; `msec` comes from `Editor.MouseEvent.msec`, already
  plumbed). Dispatch happens at all-buttons-up; `.draining` bridges the gap
  (text.c:1355-1357). Masks: B2 gesture — B3-join cancels, B1-join sets
  `argt = ed.argtext` (textselect2:1368-1373); B3 gesture — B1 OR B2 join cancels
  (textselect3:1377-1384, mask 1|2). After a committed B2 dispatch, `execute` may have
  destroyed the Text — the gesture code must not touch `t` afterward (exec side §3a).
- **R-P9-3 (Editor fields — placement)**: `seltext`, `argtext`, and
  `warnings: std.ArrayList(u8)` land in wave **9a-A2** (which is already touching
  Editor.zig). The Editor.zig:69 doc comment calling `focus` "acme's argtext/seltext"
  is corrected in the same change — `focus` stays the keyboard fallback only. Writers:
  B1-press sets both (acme.c:656-657, wired in 9d); Snarf resets `argtext`
  (exec.c:1013); a search hit sets `seltext` (look.c:375/427). `dropTextRefs` (9b-B1)
  nils `focus/gesture_text/seltext/argtext` pointing into a dying window
  (text.c:109/113).
- **R-P9-4 (tag lifecycle)**: per exec side §3c/§3f — `File.name` + `setName`;
  `Window.dirty` + `parseTag/setTag1/setTag/clean` (wind.c:437-685) + cached
  `tag_state {undo,redo,mod}`; the `Text.insertAt/deleteRange` dirty hook
  (text.c:378/474, body+tofile only). The C's 29 winsettag call sites collapse to ONE
  `frameEnd` sweep gated on the tag_state cache (9d). Boot switches from tag literals
  to `setName` + `setTag1`; composition must be **byte-identical** to today's literals
  (pinned by test — fresh window, no pipe, seq==0 ⇒ name + " Del Snarf" + " |" +
  " Look ", wind.c:497-536).
- **R-P9-5 (ownership move)**: body Files move from `boot.Tree.bodies` (deleted) to
  the owning `Window` (`body_file` + owned flag, freed in deinit); `winid` moves from
  `boot.Tree` to `Row` — both must be reachable from `ed.row` so Del/New can
  destroy/create windows mid-session.
- **R-P9-6 (warnings)**: v1 sink is `ed.warning(fmt, args)` appending to
  `ed.warnings`; a warning must never fail a command (OOM ⇒ drop). No +Errors window,
  no tag flash. FLAG: rewires to +Errors in the served-tree phase.
- **R-P9-7 (Exectab v1 subset)**: exactly O18's table — Cut, Del, Delcol, Delete, New,
  Newcol, Paste, Redo, Snarf, Undo (exec.c:98-130 cites per entry). Paste's
  `flag2 = XXX = 2` is TRUTHY (dat.h:488-493) and load-bearing (`tobody`: tag-Paste
  lands in the body) — ported as `true` with the cite; all genuinely-unused XXX ⇒
  `false` + `// XXX` comment. Unknown word ⇒ silent no-op (the external `run` path is
  the namespace phase). **Sort, Zerox, Exit: deferred** per O18 §3g evaluation
  (Zerox needs multi-Text-per-File; Exit needs session semantics).
- **R-P9-8 (look v1)**: per look side §3.3 — bare-click expansion is the alnum run
  (with no host fs, `expandfile` always fails — look.c:745 arm honestly reduces);
  click-inside-selection uses the selection (look.c:738-743); search starts at `ct.q1`
  with wraparound and one-lap termination, a sole occurrence re-finds itself
  (look.c:383-436); hit ⇒ `ct.show(q, q+n, true)` + `ed.seltext = ct`; miss ⇒ silent,
  body-case caret stays collapsed at word end (look.c:208-213). `moveto` mouse warp
  permanently dropped (R-P8-6 lineage). B3 in a tag searches the BODY (look.c:205)
  with the needle read from the tag's file. `isAlnum` in `core/text/select.zig` is
  promoted `pub`; `exec.isfilec` is pub for the later `expand` upgrade. The `reverse`
  param rides every signature; Shift-B3 input wiring deferred.
- **R-P9-9 (New with argument)**: creates a **named empty window** (no disk load —
  `openfile`/`dirname` are namespace-phase; look.c:918-941 arm reduces honestly).
  Chord argument (2-1) recurses with the argt selection; inline sweep-args ("New foo")
  come from execute's remainder. v1 argument consumers: **New only** (all other v1
  builtins `USED()`-discard args in the C).
- **R-P9-10 (undo scope)**: single-window undo/redo only; the same-seq multi-window
  walk (exec.c:462-477) is Edit-phase territory. `winundo`'s `textshow` is REQUIRED
  after `File.undo/redo` (wind.c:361 — the file op bypasses the frame; `show`
  refills + selects). `w.dirty = f.mod` approximates putseq until Put lands.
- **R-P9-11 (getArg v1)**: raw argt selection bytes (exec.c:276-312 minus the
  `expand` filename arm — marked TODO for O19's expand when the namespace phase
  lands it). `doaddr`/`printarg` dropped.
- **R-P9-12 (frame harness fallback)**: `Editor.but2col/but3col` are nullable; null
  (headless harness pre-Chrome) falls back to `t.fr.col(.high)` so gesture mechanics
  stay testable without Chrome.

## Sub-wave assignments

- **9a (concurrent, two agents):**
  - A1 **opus** — draw+chrome sweep machinery (look side §3.1-§3.2): `Select23State`,
    `select23Begin/Update/End`, `selRestore` in `src/draw/frame/select.zig`;
    `Frame.zig` aliases; `Chrome.zig` but2/but3 palette consts + solids + fields.
    Tests: the three `frame: select23 ...` write-stream tests + `chrome: but2/but3
    sweep colors match iconinit`.
  - A2 **opus** — tag lifecycle (exec side §3c, W1): `File.name/setName`;
    `Window.dirty/parseTag/setTag1/setTag/clean/tag_state`; Text dirty hook;
    boot rewire (composed tags + body-File ownership move + Row.winid move,
    R-P9-4/5); Editor fields `seltext/argtext/warnings` + `warning()` + focus doc
    fix (R-P9-3). Tests 14-15 (exec side §4) + boot byte-identity pin.
- **9b (concurrent, after 9a merges):**
  - B1 **sonnet** — close geometry (exec side §3c, W1'): `Column.close/clean`,
    `Row.close`, `Editor.dropTextRefs`. Geometry tests (test 9's direct-call half;
    extend-down, extend-up, white-fill-when-last for both axes).
  - B2 **opus** — `src/core/look.zig` (look side §3.3: `look`, `search`, the alnum
    expand subset) + `isAlnum` pub promotion + core.zig export. All `look:` named
    tests (direct calls, no gesture machine).
- **9c (single, after 9b): C1 opus** — exec module (exec side §3b): `src/core/exec/`
  {`exec.zig`, `builtins.zig`, `cmd_edit.zig`, `cmd_window.zig`} + core.zig export.
  Tests 3-5, 8, 11-13 (direct `execute` calls).
- **9d (single, after 9c): C2 opus** — gesture + integration (exec side §3a + look
  side §3.3 Editor arm): `.sweeping_b2/.sweeping_b3/.draining` states, `sel23` +
  frozen-buts fields, `but2col/but3col` bindings (boot adapter wires Chrome),
  handleMouse B1-press seltext/argtext writes + B2/B3 arms, R-P9-2 dispatch,
  `frameEnd` tag sweep (R-P9-4). Tests 1-2, 6-7, 9-10, 16 + all `editor: b3 ...`
  tests from the look side.
- **Wave C (orchestrator)**: acceptance scenes (`phase-9: B2 exec scene` with
  FROZEN-ACCEPT-9 + `editor: acceptance b3 look scene` — both NEW freezes, R-P2-7
  protocol) + report + merge + HANDOFF.

## Cross-contract interface (frozen)

- `select23Begin(f, mp, col, msec) !Select23State`;
  `select23Update(*state, mp) !void`;
  `select23End(*state, mp, msec) !struct { p0: usize, p1: usize }` — frame coords;
  callers add `t.org`. End ALWAYS restores paint; caller decides commit vs cancel.
- `exec.execute(ed, t, aq0, aq1, argt: ?*Text) Text.Error!void` — absolute rune
  coords; q0==q1 triggers expansion; et=t, target=ed.seltext per exec.c:244.
- `look.look(ed, t, q0, q1, reverse: bool) Text.Error!void`;
  `look.search(ed, ct, needle: []const u21, reverse: bool) Text.Error!bool`.
- `builtins.Entry.fn_: fn (ed, et, t: ?*Text, argt: ?*Text, flag1: bool,
  flag2: bool, arg: []const u8) Text.Error!void`.
- `Window.clean(w, ed, conservative: bool) bool`;
  `Column.close(c, ed, w, dofree) !void`; `Row.close(row, c, dofree) !void`;
  `Editor.dropTextRefs(w: *Window) void`.
- `Window.setTag1/setTag` `Text.Error!void`; `File.setName([]const u8) !void`.
