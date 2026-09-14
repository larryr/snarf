# Phase 16 report — the debt-collection pass (16a structure · 16b fixes · 16c fidelity · 16d size)

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 712/712 (692 + 20), run twice ·
node smoke 40/40 · `zig build native` OK · `zig fmt` clean · **exactly one golden moved
(FROZEN-ACCEPT-3, sanctioned, pixel-level evidence below)** · **Contract:**
`agents/contracts/phase16-debt-pass.md` · **wasm:** 2321565 B ReleaseSafe / 289098 B
ReleaseSmall (`make sizes`). User instruction: "make another debt-collection pass if you
are bored; then report on that."

## 16a — structure only (pure move, reviewed line-by-line: PASS)

Every over-cap file split at a named seam, verbatim, with forwarders/decl aliases; 692 test
names identical; every FROZEN literal byte-identical — including the draw device, which sits
under every golden.

| File | before → after | new file(s) |
|---|---|---|
| `main_wasm.zig` | 458 → 245 | `wasm_boot.zig` 255 |
| `core/Window.zig` | 559 → 390 | `core/wintag.zig` 253 (tag composition + the frameEnd sweep) |
| `core/Editor.zig` | 414 → 380 | `core/originhook.zig` 33 |
| `core/expand.zig` | 407 → 258 | `core/pendinglook.zig` 174 |
| `ninep/client.zig` | 637 → 399 | `ninep/client_ops.zig` 284 |
| `ninep/msg.zig` | 476 → 393 | `ninep/msg_test.zig` 102 (test-only) |
| `dev/opfs.zig` | 440 → 380 | `dev/opfs_io.zig` 60, `dev/opfs_testsrv.zig` 147 |
| `dev/draw.zig` | 806 → 357 | `dev/draw_msgs.zig` 223, `draw_font.zig` 51, `draw_ctl.zig` 69, `draw_testsrv.zig` 218 |
| `host/devdraw/Conn.zig` | 612 → 361 | `host/devdraw/mux.zig` 300 |
| `host/devdraw/wsys.zig` | 408 → 314 | `host/devdraw/wsys_enc.zig` 121 |
| `ninep/nsio.zig` | 451 (exempt: ~330 code + cited rationale) | — |

## 16b — fourteen cited fixes (one commit each)

1. **Tentative-newfid clunk** (`server_mut.discardNewfid/discardParkedWalk`, lib9p `srv.c:334-343`):
   a discarded or flushed walk fid now gets `Ops.clunk`, so `DevOpfs` slots no longer leak.
2. **`OpError.BadOffset` = `bad offset`** (lib9p `srv.c:11`) on misaligned OPFS directory reads.
3. **Per-path stat memo** in `DevOpfs` (`dev/opfs_cache.zig`), invalidated by mutations on the path
   or parent and by a parent `list`: **the smoke's fsOp log fell 13 → 6, `stat /notes.txt` 6 → 1.**
4. **One OPFS writable per write sequence**: fs-record **version 2**, `op close = 9` (fire-and-
   forget under ticket 0 on clunk); `web/opfs.js` keeps a writable per path and closes it before
   any other op on that path. Large `Put`s stop being quadratic.
5. **`applyAddress`**: verified `compoundaddr` already stops at the first unusable rune (the
   HANDOFF claim was wrong); "not an address" now falls to dot silently with the jump preserved
   (`addr.c:193-195`); evaluation failures still warn and suppress.
6. **`expandFile` carries `reverse`** (look.c:637-643) for Shift-B3 later; no behavior change.
7. **`errors.dirName` doc** corrected (four shapes; callers add the separator).
8. **`discardClunk` hardening**: the fid number is recycled when the Rclunk/Rerror lands, not
   immediately — correct under a reordering server (ADR-0005 native host).
9. **`retryFiltered` snapshot walk**: a nested retry can no longer make a pass skip an entry
   (the new test fails on the old code).
10. **`isalnum`** — the pinned plan9port acme uses its own `acmeisalnum` (util.c:327-342,
    "anything above the Latin controls"), neither ASCII nor Latin-1; `Text.bsWidth` now shares
    `select.isAlnum`: ^W at `foo_bar` erases 7 runes (was 3).
11. **`colgrow` `but=1` arm** (`core/colgrow.zig`, cols.c:368-405 + 407-470) called from
    `makeNewWindow` when the new window has < 2 lines (util.c:494-495); other arms deferred.
12. **`textbsinsert`** (`core/text/bsinsert.zig`, text.c:307-364): `\b` in warning text erases
    the previous rune; `flushWarnings` shows from where the run landed.
13. **Browser `Kdown` bug fixed**: `typing.zig` uses Plan 9 4e's `keyboard.h` values (only
    `Kdown` differed from plan9port: 0xF800 vs 0x80); the native `dev_input` translates
    devdraw's 0x80; `Editor.handleKey`'s activecol exclusion now actually fires. Browser
    ArrowDown works.
14. `Conn.zig` split — already done by 16a.

## 16c — the one sanctioned re-freeze

`Text.init` now applies acme's `textinit` tab width `maxtab × width("0")` = 36 px (text.c:53-60);
Snarf had kept libframe's `frinit` default of 72. Directory bodies still narrow to 27.

| golden | old | new |
|---|---|---|
| FROZEN-ACCEPT-3 | `0x7f16941423defd73` | `0x9171d75adca5e8eb` |

Spot-check (R-P2-7): forcing `maxtab` back to 72 reproduces the old hash byte for byte; the two
framebuffers differ in 160 pixels, all on line 4 of the tab scene — `"tab"` moved one 36-px tab
stop left and the caret tick became visible (`ptOfChar(33).x` was exactly the frame's right
edge at 72, so `ticked` was false). Every other golden unchanged. The served `ctl` line's tab
field and the T3 test (renamed to state the closed divergence) updated with names kept.

## 16d — size tooling (no default change)
`make small` builds ReleaseSmall into `zig-out/small`; `make sizes` prints both: **2 321 565 B
ReleaseSafe vs 289 098 B ReleaseSmall (8.0×)**. A `build.zig` step was not added because
modules share one optimize mode per build; a second prefix is the honest way.

## Debt ledger

**Closed this pass:** every 12b–15 structure cap except the three below; tentative-fid leak;
bad offset; stat chatter; writable-per-chunk; discardClunk ordering; retry skip; `isalnum`
note; `colgrow` (but=1); `textbsinsert`; `Kdown`; tab width 72→36; `applyAddress` claim
(disproved); `dirName` doc; `Conn` split.

**Still open:** `core/text/Text.zig` 498, `dev/opfs.zig` 412, `core/Load.zig` 404,
`core/served/fsys.zig` 539 pre-test lines (Text/fsys pre-existing); **and eleven further
pre-existing files over the cap that no phase report had flagged** (the gate's full scan,
"lines before the first `test`" — a metric that also counts test harnesses declared above the
first test block): `dev/draw_backend.zig` 818, `ninep/nsdir.zig` 760, `dev/input.zig` 585,
`draw/frame/Frame.zig` 514, `ninep/server.zig` 450, `core/edit/regx_exec.zig` 432,
`core/Buffer.zig` 432, `core/edit/parse.zig` 417, `core/served/xfid.zig` 408,
`core/edit/regx_compile.zig` 407, `draw/Font.zig` 406 — candidates for a second structure
pass (the harness-heavy ones, `draw_backend`/`nsdir`/`input`, mostly need their test fixtures
moved to `*_testsrv.zig` files as 16a did for draw/opfs); `colgrow` `but<0/2/3` arms
and `coladd`'s grow loop (cols.c:81-87 — would move `coladd` geometry goldens); served body
write still plain-insert (`xfid.c:597` `textbsinsert`); `Queue.clear` on Tversion drops fid
state without `Ops.clunk`; wasm ≈ 2.3 MB ReleaseSafe (+70 KiB this pass: colgrow, bsinsert,
memo) — the safe/small ratio is 8×; Retina DPR; `Kcmd` (plan9port-only 0xF100) dropped by
the native translation.

## Review nits (recorded, not blocking)
`errors.flushWarnings` shows from the offset `bsInsert` returns (where the run landed after leading
backspaces) — the C shows from the pre-insert end (util.c:241-245); cosmetic. `dev_input.pushRune`
passes plan9port's `Kcmd` (0xF100..) through untranslated — no 4e meaning, ignored by the core.

## Pipeline
16a: opus (10 pure-move commits) → fable review PASS (multiset pairing, 1729/1953 lines; one
cosmetic nit). 16b/16c: opus (15 commits, one per item) ∥ 16d orchestrator (Makefile, T3
rename) → sonnet tests ∥ fable review → gate → merge.
