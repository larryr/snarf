# Phase 15 contract — ADR-0005 native-host SPIKE: the core in a real window through plan9port `devdraw`, with warping

Status: **binding once fable signs §3.** Branch `phase15` (worktree `../snarf-wt/phase15`), based on `main` after 14b (ABI v6, 665 tests). Decision: ADR-0005 (two hosts,
one core; native host = plan9port `devdraw` or a `drawfcall.h`-compatible server), R-OV-09.
This is the SPIKE the ADR names as "the honesty check on R-OV-03": if `src/core`, `src/draw`
or `src/ninep` need to change to run under `devdraw`, the boundary was not clean and that is
the first thing to fix. Scope is deliberately small: boot scene + typing + mouse language +
**warping** in a real window. No file system, no process service (later native waves).

## 1. Ground truth (`larryr/plan9port@337c6ac`; local build `~/proj/plan9port`, `PLAN9=~/proj/plan9port`, `bin/devdraw` arm64)

| Item | Where | What |
|---|---|---|
| Wire protocol | `include/drawfcall.h` (comment block + enum) | every message: `size[4] tag[1] type[1] …`, size includes the header, **big-endian** `PUT/GET`; types Rerror=1, Trdmouse=2/Rrdmouse=3 (`x[4] y[4] button[4] msec[4] resized[1]`), Tmoveto=4 (`x[4] y[4]`), Tcursor=6 (`cursor[]`), Tbouncemouse=8, Trdkbd=10/Rrdkbd (`rune[2]`), Tlabel=12, Tinit=14 (`winsize[s] label[s] font[s]`), Trdsnarf=16/Rrdsnarf (`snarf[s]`), Twrsnarf=18, Trddraw=20/Rrddraw (`count[4] data[count]`), Twrdraw=22/Rwrdraw (`count[4]`), Ttop=24, Tresize=26 (`rect[4*4]`), Tcursor2=28, Tctxt=30, Trdkbd4=32/Rrdkbd4 (`rune[4]`); strings `s` = `len[2] bytes`; `MAXWMSG` 4 MiB. Codec reference `src/libdraw/drawfcall.c` (`convW2M`/`convM2W`, `readwsysmsg`). |
| Spawning | `src/libdraw/drawclient.c:23-137 _displayconnect` | without `$wsysid`: `pipe`, `fork`, child dups the pipe onto fd 0 and 1 and `exec`s `devdraw` (from `$PLAN9/bin` / `$DEVDRAW`); parent talks over the pipe. With `$wsysid`: dial the running devdraw service and send `Tctxt`. The spike uses the spawn path. |
| Tags/mux | `drawclient.c:138-300 _displaymux`, `displayrpc` | tags 1..255, one outstanding per tag; `Trdmouse`/`Trdkbd` are long-poll requests — libdraw keeps one of each outstanding on a mux thread and demuxes replies by tag. **Snarf**: keep exactly one `Trdmouse` and one `Trdkbd` in flight; every other request is synchronous request/reply (tags distinguish). Reads are blocking on the pipe ⇒ the host loop needs either a reader thread (`std.Thread`) feeding a queue, or non-blocking fds + poll. Prefer one reader thread pushing complete frames into a mutex-protected queue drained by the main loop (mirrors the shim's `wsPush` shape). |
| Draw semantics | `Twrdraw` carries exactly the bytes libdraw writes to `/dev/draw/N/data`; `Trddraw` reads `/dev/draw/N/ctl`-style info? — **verify** in `src/cmd/devdraw/devdraw.c` `runmsg` (which draw-device file `Trddraw` maps to; `Tinit` returns the display info line via `Rrddraw`? read the code). `Tinit winsize` e.g. `"800x600"`; font `""` ⇒ default. `Rrdmouse.resized` ⇒ re-read the display rect (getwindow: `Tresize`/`Trddraw`). |
| Our stack | `src/dev/draw.zig DevDraw` = the draw DEVICE (server side, backend vtable `draw_backend.Backend`: allocImage/draw/flush/displayInfo/…); `src/draw/Display.zig` = the libdraw-like CLIENT that writes protocol messages to `/dev/draw/N/data` over 9P; `src/dev/input.zig DevInput` serves `/dev/mouse`,`/dev/kbd` from queues fed by `pushEvent`; `src/ns_boot.zig`, `src/screen.zig`, `src/input_pump.zig`, `src/main_wasm.zig` (the browser host); `src/main_native.zig` (11-line stub, `zig build run-native`). |

## 2. The two ways to adapt — RULING R-P15-1

(a) **Backend adapter**: keep `DevDraw` (our device) and give it a `Backend` whose `draw` ops
    are re-encoded as Plan 9 draw-protocol bytes and sent via `Twrdraw` — but `DevDraw`
    already *decodes* draw protocol into backend calls, so this would decode-then-re-encode.
(b) **Transport adapter (chosen)**: the core's `Display` client already emits exactly the
    draw-protocol bytes `devdraw` consumes. Implement a tiny 9P **device** `dev/devdraw9.zig`
    that serves `/dev/draw/new`, `/dev/draw/N/{ctl,data,refresh}` by forwarding: `data` writes
    ⇒ `Twrdraw`; `ctl` read ⇒ the info line assembled from `Tinit`/`Tresize` answers (verify
    what devdraw returns; libdraw builds `Display.image` from `Rrddraw` after `Tinit` — read
    `drawclient.c` `_displayinit` and `init.c initdisplay`); `refresh` ⇒ `Rrdmouse.resized`.
    Likewise `dev/devdrawinput.zig` serves `/dev/mouse` (from `Rrdmouse`, formatted as the
    49-byte Plan 9 record our `DevInput` already emits — reuse its formatter), `/dev/kbd`
    (from `Rrdkbd4` runes), **`/dev/mouse` WRITE ⇒ `Tmoveto`** (the warp), `/dev/cursor` ⇒
    `Tcursor2`, `/dev/snarf` ⇒ `Trdsnarf`/`Twrsnarf`, `/dev/label` ⇒ `Tlabel`.
    The editor core is then wired exactly as in `main_wasm`: `boot.boot` + `Editor` +
    `frameEnd` + the same input pump, with `main_native.zig` as the host loop. **Zero changes
    in `src/core`, `src/draw`, `src/ninep`** is the pass criterion (R-P15-2).

## 3. CONTRACT (to finalize)

### 3a. `src/host/devdraw/` (new directory — the native host's device layer, S-07: a peer of `dev/`)
- `wsys.zig`: the `drawfcall` codec (BE framing, all types above), `Conn` = spawn `devdraw`
  (`std.process.Child` with stdin/stdout pipes; path from `$DEVDRAW`, else `$PLAN9/bin/devdraw`,
  else `devdraw` on `PATH`), a reader thread → frame queue, `rpc(tag, msg)` for synchronous
  requests, `startRdMouse()/startRdKbd()` long-polls re-armed on each reply.
- `dev_draw.zig`: 9P `Ops` for `/dev/draw` (forwarding as §2b). `dev_input.zig`: `Ops` for
  `/dev/mouse` (read: records; **write: `Tmoveto`** — the R-EDIT-25 warp, honored here),
  `/dev/kbd`, `/dev/cursor`, `/dev/snarf`, `/dev/label`.
- `main_native.zig` (rewrite, ≤ ~400): pipes/servers/clients for the two devices exactly like
  `main_wasm.boot`, `Namespace` with `/dev`, `/dev/draw`, `/mnt/snarf-self` (via `ns_boot`'s
  pattern — factor a host-agnostic `bootNamespace` if `ns_boot` is wasm-tied), `boot.boot(dir_boot)`
  + `readFile("/")`, then a loop: drain frames → device queues → `input_pump` → `frameEnd` →
  flush (`Twrdraw` batches per frame). `zig build run-native` runs it; `zig build native` builds.
- `build.zig`: the native exe gains `host` module imports; **`core`/`draw`/`ninep` modules are
  the SAME objects the wasm uses** (no `-D` forks).

### 3b. Warp (the point of the spike)
- `Editor` never learns about warping: acme's `moveto` calls that 12b/12c/13b dropped are
  re-expressed as **writes to `/dev/mouse`** from the places the C calls `moveto` (look.c:218
  search hit `e.jump`; openfile new window; util.c errorwin? — verify each), guarded by a
  namespace capability check: if a write to `/dev/mouse` returns an error (the browser host's
  `DevInput` refuses writes today — verify; make it return `Rerror "warp unsupported"`), nothing
  happens. So the core issues the SAME 9P write on both hosts; only the native device honors
  it. This is R-EDIT-25's "browser-host divergence" made literal: R-EDIT-25 is amended to say
  "the core requests warps via `/dev/mouse` writes; hosts that cannot warp ignore them".
  **This is the one `core` change allowed, and it is a feature the ADR orders, not an
  adapter fix** — record it separately in the report from any adapter-forced change.
- Also `/dev/cursor` for B2/B3 sweep cursors? Out of scope (acme uses `setcursor` for the
  sweep? — verify; if cheap, include; else defer).

### 3c. Acceptance (what "the spike passed" means)
1. `zig build run-native` opens a devdraw window titled `snarf` with the two-column boot and
   the `/` directory window (`dev/ mnt/`) — same pixels as the browser modulo the window size.
2. Typing lands under the pointer; B1 sweeps; B2 `Del`/`New`; B3 on `mnt/` opens `/mnt/`;
   `Look` finds text and the **pointer warps onto the hit**; B3 on a file name warps into the
   new window.
3. Resize the window ⇒ `Rrdmouse.resized` ⇒ `Tree.resize` (12c's path) works.
4. `git diff main -- src/core src/draw src/ninep` = **only** the `/dev/mouse`-write warp
   requests (3b) — nothing else. Any other change ⇒ the boundary failed; report it as the
   spike's finding, do not paper over it.
5. Suite green; wasm host byte-identical (goldens unchanged); smoke unchanged; browser
   `DevInput` returns an error for `/dev/mouse` writes (tested) and the browser ignores warps.
6. CI cannot run the window; the native path gets a **headless test** of `wsys.zig`'s codec
   (round-trips for every message) and a `Conn` test against a fake `devdraw` (a child
   process replaced by a pipe pair scripted from the test) proving spawn-less framing, the
   long-poll re-arm, and `Tmoveto` emission on a `/dev/mouse` write.

### 3d. Docs / records
- ADR-0005 status → "spike done: <date>, findings"; R-EDIT-25 amended (warp requests via
  `/dev/mouse` writes); S-04 gains the `/dev/mouse` write = warp line (already Plan 9's
  `mouse(3)`: writing `m x y` moves the cursor — cite `9/port/devmouse.c` mousewrite);
  S-07 §6 gains the `host/` directory + import rules; HANDOFF env: `DEVDRAW`/`PLAN9`;
  REVIEW-NOTES: "for you: `zig build run-native` — a real window; try Look and watch the pointer".

### 3e. Rulings
- R-P15-1 transport adapter, not backend adapter. R-P15-2 zero adapter-forced changes in
  `core`/`draw`/`ninep`. R-P15-3 warp = `/dev/mouse` write (Plan 9 `mouse(3)` semantics), a
  core feature, browser ignores. R-P15-4 std-only: `std.process.Child`, `std.Thread`,
  `std.Io` (0.16) — no C, no plan9port linking (ADR-0002/0005). R-P15-5 macOS first (that is
  where `devdraw` is built); Linux/X11 untested but nothing platform-specific in our code.
- Manual acceptance items 1-3 are Larry's; the pipeline delivers 4-6 plus a screenshot
  attempt (`devdraw` has no screenshot; skip) — the review verifies the diff criterion.

## 4. Named tests (sonnet)

Pipeline: fable spec → **opus** codes §3 → **sonnet** writes §4 → **sonnet** runs the gate → **fable** reviews → loop.
T1 codec round-trips all 17 message types + BE framing + strings; T2 `Conn` over a scripted
pipe pair: Tinit handshake, one Trdmouse and one Trdkbd outstanding, replies demuxed by tag,
re-armed; T3 `/dev/mouse` read yields the 49-byte record from an `Rrdmouse`; T4 `/dev/mouse`
write `m 100 200` emits `Tmoveto 100 200`; T5 `/dev/kbd` read yields runes from `Rrdkbd4`;
T6 `/dev/draw/N/data` write forwards bytes verbatim as `Twrdraw`; `ctl` read returns the info
line; T7 `resized` ⇒ `refresh` record; T8 browser `DevInput` `/dev/mouse` write ⇒ `Rerror`;
T9 core: a `Look` hit issues one `/dev/mouse` write with the hit's point (headless, fake
`/dev/mouse` capturing writes); T10 boundary: `git diff main -- src/core src/draw src/ninep`
touches only the warp-request sites (list them); T11 wasm goldens + smoke unchanged.
