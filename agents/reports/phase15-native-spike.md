# Phase 15 report — the ADR-0005 native-host SPIKE: the unchanged core in a `devdraw` window, with warping

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 692/692 (665 + 27), run twice ·
node smoke 40/40 (wasm host untouched, ABI 6, no golden moved) · `zig build native` OK ·
**`zig build run-native` opens a plan9port `devdraw` window and draws the boot scene** ·
`zig fmt` clean · **Contract:** `agents/contracts/phase15-native-spike.md` (rulings R-P15-1..5).

## The finding (what the ADR asked)

**R-P15-2 PASSED: the editor core needed ZERO adapter-forced changes.** `git diff main --
src/draw src/ninep` is empty — byte-identical. Every changed line in `src/core` is the one
feature the ADR ordered (warp requests, below). The R-OV-03 boundary claim — "everything
outside the editor's memory crosses a 9P namespace" — held under a second, independent host.
Two hosts, one core is real.

## What exists now

- **`src/host/devdraw/`** (the native host's device layer, a peer of `dev/`, S-07 §6):
  `wsys.zig` — the `drawfcall` codec (BE `size[4] tag[1] type[1]`, `len[4]` strings, all 17
  message kinds); `Conn.zig` — spawn `devdraw` (`$DEVDRAW` → `$PLAN9/bin/devdraw` → PATH,
  `NOLIBTHREADDAEMONIZE=1`, the pipe on fds 0/1 exactly as libdraw's `_displayconnect`), tag
  discipline (1 = the standing `Trdmouse`, 2 = `Trdkbd4`, 3..255 rpc), single-threaded
  `poll(2)` wait (libdraw's `canreadfd`); `dev_draw.zig` — a 9P `/dev/draw` whose `data`
  writes forward verbatim as `Twrdraw` and whose `ctl` line comes from `Twrdraw "JI"` +
  `Trddraw 144` (libdraw `getimage0`), `refresh` from `Rrdmouse.resized`; `dev_input.zig` —
  `/dev/mouse` (records via the SHARED browser formatter; **write ⇒ `Tmoveto`, the warp**),
  `/dev/kbd` (`Trdkbd4`), `/dev/cursor` (`Tcursor2`), `/dev/snarf`, `/dev/label`.
- **`main_native.zig`** (241 lines): the same wiring shape as `main_wasm` — device pipes,
  `Namespace` (`/dev`, `/dev/draw`, `/mnt/snarf-self`), `boot(dir_boot)` + `readFile("/")`,
  loop `conn.poll(16 ms)` → devices → input pump → `frameEnd` → one `Twrdraw` per frame.
  `zig build native` / `zig build run-native`. `core`/`draw`/`ninep` are the SAME module
  objects the wasm links. std-only: no C, no plan9port linking (ADR-0002/0005).
- **Warp as a core feature (R-EDIT-25 amended, R-02 v6)**: `core/warp.zig` writes acme's
  `moveto` point (`frptofchar(fr, p0) + Pt(4, font.height-4)`) as an `m x y` record to
  `/dev/mouse` — Plan 9's `mouse(3)` semantics — from the places acme calls `moveto`: the
  literal-search hit (look.c:218, `jump` false for tag clicks, look.c:741-742) and the opened
  window's selection (look.c:897; `jump` false for an invalid/out-of-order address,
  look.c:892). The browser's `DevInput` answers the write with `permission denied` and the
  request is silently dropped — the browser is unchanged (goldens identical). The native
  device honors it. Same request on both hosts; the host decides. Touch semantics (HANDOFF
  design note) are not implemented.
- Docs: ADR-0005 "SPIKE DONE" + findings; R-02 v6; S-04 §1 warp line; S-07 §6 `host/*`.

## Verified facts about `devdraw` (corrections to the contract's §1 table)
Strings are `len[4]` (drawfcall.c:9-37), not `len[2]`. `Tinit` carries `winsize[s] label[s]`
only. A bare `Trddraw` after `Tinit` is `Rerror "no draw data"`: the connection info line is
obtained by `Twrdraw "JI"` then `Trddraw 144` (libdraw `getimage0`, init.c:129-152); a
re-read after resize must first free image 0 (`f` id 0) or `J` fails `Eimageexists`.
`Rrdmouse` writes `resized` at byte 19, INSIDE `msec` (drawfcall.c:132-137/237-242) — a
reference bug reproduced on the wire; `Conn` timestamps from the local monotonic clock
(the core uses `msec` only as deltas). devdraw sends plan9port's `Kdown = 0x80`.

## Deviations (accepted in review)
No reader thread (Zig 0.16 removed `std.Thread.Mutex`/`Condition`; `poll(2)` instead); no
exclusive `/dev/mouse` open (Plan 9's is one r/w file); browser refusal string is the
existing `permission denied` (a bespoke string would need a new `errors.zig` member, which
R-P15-2 forbids); no native `ctl` (no profile machinery); `/dev/cursor` included (10 lines).
Screenshot unobtainable (terminal lacks screen-recording permission; plan9port's own acme is
equally invisible to `screencapture` here) — the `DEVDRAWTRACE=1` trace is the evidence.

## Found along the way (debt pass)
- **Browser `Kdown` bug**: `core/text/typing.zig:43` took plan9port's `0x80`; the device
  authority is the 4e tree (`Kdown = 0xF800`, `shim.js:52`, `profiles.zig`), so browser
  ArrowDown does nothing today; the native host works by accident (devdraw sends `0x80`).
  Fix: `typing.zig` → `0xF800` and `dev_input.zig` translates devdraw's `0x80`.
- `Conn.zig` ≈ 612 / `wsys.zig` ≈ 408 pre-test lines (over cap; split tags/slots vs spawn).
- `warp.to` is the one sanctioned production use of the synchronous walker on `/dev`
  (`/dev/mouse` walk/open/write reply immediately; only its read parks) — note in `ns_boot`.

## Pipeline
fable spec → opus (5 commits + fixup; opened the window) → sonnet (T9 written; T1-T8/T10/T11
verified as already covered by the coder's colocated tests) ∥ fable review PASS with one
fidelity fix (no warp on an invalid address — applied by the orchestrator, look.c:892) →
sonnet regression test T12 + gate → merge.

## For Larry
`zig build run-native` (needs `~/proj/plan9port/bin/devdraw`; `PLAN9=~/proj/plan9port` or
`DEVDRAW=…/devdraw`). A `snarf` window: two columns, `/` on the right. B3 on `mnt/`; type;
`Look` a word and watch the pointer land on the hit — the paper's behavior, finally.
