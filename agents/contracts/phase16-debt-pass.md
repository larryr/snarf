# Phase 16 contract — debt-collection pass

Status: **binding once fable signs.** Branch `phase16` (worktree `../snarf-wt/phase16`), based on `main` after phase 15 (692 tests, ABI v6). Sub-waves run IN ORDER on this one branch, each as its own opus→sonnet→gate→review loop: 16a, then 16b (+16c inside the same loop), then 16d. User instruction 2026-09-14: "make another debt-collection
pass if you are bored; then report on that." Sources: the Debt sections of
`agents/reports/phase12b…15*.md`, HANDOFF "Backlog", the 12e size pass. Split into three
sub-waves so each is reviewable as a pure move or a small cited fix; goldens are the safety
net for the structure moves; one sanctioned re-freeze (16c) is a fidelity fix, not a move.

## 16a — structure only (pure moves, hash-guarded, R-P12e-1 rules)

| File | Pre-test now | Move |
|---|---|---|
| `src/main_wasm.zig` | 458 | `App` + `boot()` → `src/wasm_boot.zig`; exports + `tick` stay |
| `src/core/Window.zig` | 559 | tag composition (`setTag1`, `parseTag`, tag_state) → `core/wintag.zig`; `clean`/two-strike → `core/winclean.zig` if still over |
| `src/core/Editor.zig` | 414 | warning forwarders + `loads`/`pending_look` glue → already thin; move the `OriginHook`/`origin` plumbing to `core/originhook.zig`; target ≤ 380 |
| `src/core/expand.zig` | 402 | `PendingLook` + `startLook/stepPending/dropWindow/dropPending` → `core/pendinglook.zig`; `expandFile` (pure) stays |
| `src/ninep/client.zig` | 637 | sync helpers (`walk/open/read/write/clunk/stat/create/remove/wstat`) → `ninep/client_ops.zig` (fields cross-file OK); `Client` struct + `rpc`/frames stay |
| `src/ninep/msg.zig` | 476 (397 non-test) | test helper `expectBodyEqual` → `ninep/msg_test.zig`; codec table for read/write/walk → `msg_io.zig` if still over |
| `src/dev/opfs.zig` | 440 | the `Wire`/`drive` test harness → `dev/opfs_testsrv.zig`; `Ops` fn bodies for read/write → `opfs_io.zig` |
| `src/dev/draw.zig` | 806 | message decode (`'b','d','s','x',…` arms) → `dev/draw_msgs.zig`; font/glyph cache → `dev/draw_font.zig` — **only if the goldens hold byte-for-byte**; this is the riskiest move, do it last, alone in its commit |
| `src/ninep/nsio.zig` | 451 raw / ~330 code | leave (cited rationale); note |
| `src/host/devdraw/Conn.zig` | 611 | tag/slot machinery + codec glue → `host/devdraw/ConnTags.zig` (or `mux.zig`); spawn/poll/rpc stay |
| `src/host/devdraw/wsys.zig` | 407 | per-message encoders → `wsys_enc.zig` if needed |

Rules: verbatim moves, forwarders where call sites are many, test names identical, no golden
moves, every touched file ≤ ~400 pre-test.

## 16b — small correctness fixes (each cited, each with a sonnet test)

1. **Tentative-newfid slot leak (14b)**: `server_mut`/`handleWalk` calls `ops.clunk` when it
   discards a never-established newfid (5/walk: "the fid is not created" — but the SERVER
   may have per-fid state from a parked partial walk); `DevOpfs.dropFid` then frees pending
   slots. Test: parked Twalk on a fresh newfid, Tflush, answer late ⇒ `inflight() == 0`.
2. **`bad offset`**: additive `OpError.BadOffset` = `"bad offset"` (lib9p `srv.c:11`); `DevOpfs`
   dir reads and `nsdir.DirReader` (`error.BadOffset` already) use it; the served tree's
   directory read too if it emits `bad message` for the same case.
3. **Per-path stat memo in `DevOpfs`** (14b review): `StatReply` cache keyed by path hash,
   shared across fids, invalidated by `write/truncate/create_*/remove` on the path or its
   parent, and by `list` of the parent (fresh listing = fresh truth). Test: the smoke's
   `stat /notes.txt` count drops from 6 to ≤ 2 (assert in the node smoke log).
4. **One OPFS writable per open fid** (14b nit 3): `web/opfs.js` keeps `createWritable`
   open per (path) while a write sequence runs, closes on a `close` op — add `op close=9` to
   the record contract (version 2, mirrored) issued from `Ops.clunk` of a written fid.
   Test: two sequential writes produce one `createWritable` in the stub's log.
5. **`applyAddress` stops at the first non-address rune** (13b review) per look.c `address()`
   with `agetc`; `file:12,` and `file:3x` behave as acme: address = `12` / `3`, rest ignored.
6. **`expandFile` `reverse` bookkeeping** (look.c:641-644) — carried in `Candidate` for the
   future Shift-B3; no behavior change now.
7. **`errors.dirName` doc vs behavior** — fix the comment (strips the trailing `/`).
8. **`discardClunk` hardening** (13a nit): tombstone carries the fid; `dispatch` frees the fid
   number on the Rclunk (or on Rerror) instead of immediately — correct under a reordering
   server; in-order servers unaffected. Test: fid reuse waits for the Rclunk in the scripted
   transport.
9. **`retryFiltered` nested-retry skip** (14a nit): iterate over a snapshot of tags rather
   than indices. Test: nested `completeReads` inside an `Ops.write` during a retry pass —
   every parked entry retried exactly once per outer pass.
10. **Latin-1 `isalnum`** (12b/Text.zig divergence): Plan 9's `isalnum` covers Latin-1
    letters (util.c / libc `isalpharune`? — verify which acme uses: `isalnum` from libc on a
    Rune truncated? read `acme/util.c isalnum`); implement the same range. Check goldens.
11. **`colgrow`** (R-P12b-3): port `colgrow` (cols.c:333-420) — `but=1` arm used by
    `makeNewWindow` (`maxlines < 2`) and `but=2/3` for the layout-box clicks phase 8 deferred?
    Scope to the `but=1` arm only unless the rest is a verbatim port under 100 lines.
12. **`textbsinsert` on `+Errors`** (util.c:243 `textbsinsert`): backspace processing when
    inserting warning text (a `\b` deletes the previous rune) — text.c `textbsinsert`.

13. **Browser `Kdown` mismatch (found by the 15 spike)**: `core/text/typing.zig:43` uses
    plan9port's `Kdown = 0x80` while `web/shim.js:52` + `dev/profiles.zig:67` use the 4e
    tree's `0xF800` (R-P6-7), so browser ArrowDown does nothing; the native host works
    because devdraw sends `0x80`. Decide ONE convention (the core's `typing.zig` is the
    contract; the 4e `keyboard.h` values are what R-IN-09 cites — verify both headers) and
    align all three sites + `Editor.handleKey`'s `Kdown/Kleft/Kright` activecol exclusion.
    Test: a browser-profile ArrowDown keystroke scrolls one line in the accept harness.
14. **`Conn.zig` 527 pre-test lines** (15): split the tag/slot machinery from spawn/poll.

## 16c — fidelity fix with ONE sanctioned re-freeze

- **Normal-window tab width 36 not 72** (13b finding): acme `textinit` sets
  `fr.maxtab = maxtab * stringwidth("0")` = 4×9 = 36 (text.c:53-60); Snarf left libframe's
  `frinit` default 8×9 = 72. Port `textinit`'s line; FROZEN-ACCEPT-3 (the tab scene) moves —
  spot-check that ONLY tab stops changed (R-P2-7 procedure), record old/new hashes; the
  served `ctl` line's tab field changes too (its test updates, name kept).

## 16d — size (measure + tooling, no default change)

- `zig build small` step producing `zig-out/www/snarf-small.wasm` at ReleaseSmall; `make
  small`; the report records Safe/Small/Fast for `main` before and after 16a-c.
- A one-off per-module estimate: build with each `src/*` root stubbed? Too invasive — instead
  `wasm-objdump -h` if available via `brew install wabt` (host tool, not a build dep) to list
  section sizes; else skip. Report only.

## Tests
Sonnet: one named test per 16b item (T1–T12), the 16c spot-check + re-freeze, and the 16a
shell evidence (test-name list identical, goldens identical except FROZEN-ACCEPT-3 in 16c).

## Gate
Suite ×2; fmt; wasm; smoke; boundaries; goldens per sub-wave rule; caps table before/after;
report `agents/reports/phase16-debt-pass.md` with a closed/open debt ledger; REVIEW-NOTES.
