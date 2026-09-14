# ADR-0005 — Two hosts, one core: the browser stays; a native host speaks plan9port `devdraw`

Status: **Accepted (2026-09-14) · SPIKE DONE (2026-09-14) — findings below** ·
Satisfies: R-OV-03, R-OV-09 (new) · Fed back into
requirements [R-01](../../requirements/01-overview.md) (v3 revision is this decision) ·
Related: ADR-0001 (target), ADR-0002 (dependencies), ADR-0003 (/dev/draw), ADR-0004 (input)

## Context

Snarf was conceived as ACME in a browser (R-01 §2): open a URL, get the editor, with the
DOM, clipboard, host files and origin server mounted as 9P file servers. Twelve phases in,
the browser is a working host, and the ACME paper re-verification (R-02 v4) made the
sandbox's costs concrete:

- **No mouse warping** (R-EDIT-25). The paper leans on `moveto` in five places — new
  windows, search hits, layout-box moves, and returning the pointer after a pop-up is
  deleted. Browsers will never allow a page to move the pointer. With point-to-type
  (R-EDIT-22) this also means a newly opened window does not receive focus by arrival.
- **No processes.** Executing text as a command with output in `dir/+Errors`, `win`, `mk`,
  `grep -n`, the plumber — the coupling story of paper §Coupling — can only be imitated
  through an origin-side command service (OQ-EDIT-1); `win` is parked (OQ-EDIT-3).
- **Keyboard and clipboard are the browser's first.** Ctrl-W/Cmd-Q are uncapturable
  (R-IN-09); `/dev/snarf` and `/mnt/host` sit behind permission prompts (R-9P-07/09).

The user asked (2026-09-14) whether dropping the browser for an installed "frame" would
work better, at the cost of an install. Options considered:

1. **Browser only** (status quo). Zero install; `/dev/dom`; the sandbox costs above are
   permanent.
2. **Replace the browser with a webview frame** (Tauri/Electron-shaped). Install cost,
   but the page inside is still a browser page: nothing above is regained unless the
   frame grows native bridges, at which point it is option 3 with a web renderer bolted
   on.
3. **Replace the browser with a native host** written for Snarf (own window, own input,
   own drawing). Regains everything; abandons the founding vision and `/dev/dom`; a
   native windowing layer in std-only Zig is a large, platform-specific project and
   strains ADR-0002.
4. **Two hosts, one core.** Keep the browser host; add a native host as a *second device
   layer* beneath the same editor core. Because the core already draws only through
   `/dev/draw` (ADR-0003) and reads only `/dev/mouse`//dev/kbd (ADR-0004), a native host is
   a set of device servers, not an editor change. Make the native host's contract
   **plan9port `devdraw`** — the pinned reference implementation's own display server,
   which speaks a small, documented pipe protocol (`include/drawfcall.h`: `Tinit`,
   `Trdmouse`, `Trdkbd`, `Twrdraw`, `Trddraw`, `Tmoveto`, `Tcursor`, `Tresize`, `Trdsnarf`,
   `Twrsnarf`, `Tlabel`, `Ttop`) and already handles the window, mouse, keyboard, cursor,
   clipboard and **warping** on macOS and X11.

## Decision

Option 4. **Snarf is one editor core with two hosts.** The browser host remains the
zero-install, `/dev/dom`-bearing host and the default demo. A **native host** is a backlog
commitment, not an option: it SHALL exist, and its display/input contract is
**plan9port `devdraw` or a protocol-compatible server** (`larryr/plan9port@337c6ac`
`include/drawfcall.h`, `src/cmd/devdraw/`).

Concretely:

1. **One core.** `src/core`, `src/draw` (the libdraw-like client) and `src/ninep` are host-
   agnostic and compile natively today for the test suite (R-CON-02). No host-specific
   code may enter them; the boundary rules of S-07 §6 apply to the native host exactly as
   to the browser host (`core` never imports `dev`, `shim`, or any native glue).
2. **Native host = `devdraw` adapter + native 9P servers.** A native Zig executable links
   the core natively and provides:
   - a `/dev/draw` device whose backend forwards our draw protocol (`Twrdraw`/`Trddraw`)
     to a `devdraw` child process over its pipe, and answers `ctl`/`refresh` from
     `Tinit`/`Tresize`;
   - `/dev/mouse` and `/dev/kbd` servers fed by `Trdmouse`/`Trdkbd`, with `Tmoveto` and
     `Tcursor` exposed as the Plan 9 `/dev/mouse` write and `/dev/cursor` — **mouse
     warping is honored on this host** (R-EDIT-25 becomes browser-host-only);
   - `/dev/snarf` over `Trdsnarf`/`Twrsnarf`;
   - the host file system as a real 9P server (the `/mnt/host` role, no picker), and a
     process service that makes "execute text as a command" and `dir/+Errors` real
     (`win` and the plumber become possible: OQ-EDIT-3 reopens for this host only).
3. **Compatibility clause.** "Or compatible" means: any server that accepts the
   `drawfcall.h` message set at the pinned revision (plan9port's `devdraw` on macOS/X11;
   9front's or a future Snarf-native server that implements the same messages). Snarf
   MUST NOT depend on plan9port internals beyond that wire protocol, and MUST NOT link
   plan9port code (ADR-0002 holds — `devdraw` is a *runtime* peer process, not a build
   dependency). Wayland lacks pointer warping; on such a server `Tmoveto` is a documented
   no-op, as it is for the browser.
4. **Divergences become host-scoped.** Requirements that say "impossible in a browser"
   (R-EDIT-25, R-IN-09's uncapturable keys, permission-gated clipboard/files) are re-read
   as *browser-host* divergences. The native host is expected to honor the paper there.
5. **Order of work.** Finish the in-flight browser work (12c resize). Then the native
   host enters the phase pipeline as a spike first — the core + a `devdraw` adapter
   drawing the boot scene in a real window with warping — before any process/file
   server work. The spike is the honesty check on R-OV-03: if the core needs to change
   to run under `devdraw`, the boundary was not as clean as claimed and that is the
   first thing to fix.

## Consequences

- **Positive**: the paper's full behavior becomes reachable without abandoning the
  vision; the boundary claim (R-OV-03) gets a second, independent implementation, which
  is the strongest test of it; the reference implementation's own display server does the
  platform work (windowing, fonts scaling, HiDPI — `devdraw` handles Retina, which also
  answers the deferred half of R-GFX-05 for this host); no new libraries.
- **Negative / costs**: an install (plan9port, or at least its `devdraw` binary) for the
  native host; two hosts to keep green in CI; some features exist on one host only
  (`/dev/dom` browser-only; processes and warping native-only) and every such feature must
  say which host it belongs to; the origin server's role shrinks on the native host.
- **Risks**: `devdraw`'s pipe protocol is stable but informally specified — pin it by
  revision and write the adapter against `drawfcall.h` plus the `devdraw.c` behavior,
  citing lines as everywhere else; the native 9P servers for files and processes are real
  work and must not be rushed ahead of the spike.

## Feedback into requirements

- R-01 gains **R-OV-09**: "Snarf SHALL run on two hosts over one core: the browser host
  (R-OV-04 namespaces) and a native host whose display and input server is plan9port
  `devdraw` or a `drawfcall.h`-compatible server. Host-specific divergences from ACME are
  recorded per host." Revision log v3.
- R-02 R-EDIT-25 and R-05 R-IN-09 are re-scoped to the browser host at their next
  revision (no renumbering; a note suffices until then).
- HANDOFF backlog carries "native host spike (ADR-0005)" until it is a phase.

## Spike results (2026-09-14, phase 15)

The spike §5 asked for was built: `zig build native` produces `snarf-native`, which
spawns `$PLAN9/bin/devdraw`, speaks `drawfcall` over its pipe, and runs the unchanged
editor core in a real window. Contract: `agents/contracts/phase15-native-spike.md`;
report: `agents/reports/phase15-native-spike.md`.

### The honesty check (R-P15-2) — PASSED

> "if the core needs to change to run under `devdraw`, the boundary was not as clean as
> claimed and that is the first thing to fix."

`git diff main -- src/draw src/ninep` is **empty**. `git diff main -- src/core` is six
files and every line of it is the warp feature this ADR itself ordered (R-EDIT-25's
amendment) — **zero adapter-forced changes**. The whole native host is new code under
`src/host/`, plus a rewritten `src/main_native.zig` and a build step. `core`, `draw` and
`ninep` are the *same module objects* the wasm build links: no `-D` fork, no host switch,
no conditional compilation anywhere inside them.

R-OV-03 therefore has a second, independent implementation, which was the point.

### What the adapter had to absorb (all of it below `/dev`)

1. **plan9port's `devdraw` has no file system.** The kernel's "open `/dev/draw/new`,
   read the 144-byte connection line" has no counterpart; the line is produced by two
   DRAW VERBS — `J` (install the screen image as id 0) then `I` (queue its info) —
   read back with `Trddraw`, exactly as libdraw's `getimage0` does (`init.c:122-152`).
   A re-read must free image 0 first or `J` fails `Eimageexists` (`devdraw.c:920`).
   All of that lives in `src/host/devdraw/dev_draw.zig` and is invisible above it. So
   the answer to the contract's open question "what does `Trddraw` return after
   `Tinit`?" is: **nothing by itself** — `Trddraw` returns whatever the last draw
   read-verb queued, and after a bare `Tinit` that is an `Rerror "no draw data"`
   (`devdraw.c:617-637`).
2. **Two errors in the protocol table** we were working from, both corrected against
   the pinned source and recorded in `src/host/devdraw/wsys.zig`: `drawfcall` strings
   are `len[4] bytes` (not `len[2]`), and `Tinit` carries `winsize` + `label` only (the
   `font[s]` in the header comment is never encoded).
3. **A bug in the reference codec**, reproduced bug-for-bug because both ends of the
   wire agree on it: `Rrdmouse` writes `msec` at offset 18 and then stamps `resized` at
   offset **19**, inside `msec` (`drawfcall.c:132-137`, `:237-242`). Bits 16..23 of
   every timestamp are destroyed. The adapter therefore timestamps mouse records from
   the local monotonic clock and never trusts `Rrdmouse.msec`.
4. **No exclusive-open on the native `/dev/mouse`**, unlike the browser device: the warp
   needs a write fid while the host loop holds a standing read fid, and Plan 9's own
   `/dev/mouse` is one read-write file that acme does both through (`mouse.c:9-12`).

### What carried over untouched

* `draw.Display` — the connection-line parse, the `data` write batching, and
  `getWindow` — drove a second, completely different display server with no change.
* Phase 12c's resize path (`Rrdmouse.resized` → `Display.getWindow` → `Tree.resize`,
  `acme.c:548-555`) is the same code on both hosts; only what sits under `ctl` differs.
* `ninep.server`'s parked reads, `Client`'s standing tickets and `input_pump.drain`
  needed nothing: `/dev/mouse` and `/dev/kbd` park and complete identically whether the
  records come from a browser event or from `Rrdmouse`.
* ADR-0004's profile/chord emulation is simply ABSENT on this host — `devdraw` delivers
  real three-button records — which is the ADR's "host-scoped divergence" working in the
  other direction, and it needed no switch in the core either.

### Deviation from the contract worth recording

Contract §3a specified a reader `std.Thread` feeding a mutex-protected frame queue. Zig
0.16 removed `std.Thread.Mutex`/`Condition`; the replacements (`std.Io.Mutex`,
`Io.Condition`) require an `Io` at every lock and offer no timed wait. `Conn` is instead
single-threaded over `poll(2)` — which is libdraw's own `canreadfd`
(`drawclient.c:470-490`) used as the loop's wait rather than as a peek — and the whole
device stack stays on one thread, which is what the 9P servers above it want anyway.

### Still open for the native waves that follow

Host file system as a real 9P server, a process service (`+Errors` with real output,
`win`, the plumber — OQ-EDIT-3 reopens here), `/dev/snarf` wired to the editor's snarf
buffer, and CI for a host that needs a window. The layout/scroll `moveto` sites
(`cols.c`, `scrl.c`, `wind.c`, `util.c`) are still unported on both hosts.
