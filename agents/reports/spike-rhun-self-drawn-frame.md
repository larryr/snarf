# Spike note — a self-drawn native frame (rhun's model) vs. plan9port `devdraw`

**Status:** feasibility write-up only, no code (as asked). **Date:** 2026-10-03.
**Reference:** [vshvedov/rhun](https://github.com/vshvedov/rhun) — `docs/guide.md`,
`src/mac/cocoa.s` (2.2k lines of AArch64 asm), `src/plat/*`, `src/rhun.inc`.
**Our side:** ADR-0005, `agents/reports/phase15-native-spike.md`, `src/host/devdraw/*`,
`src/dev/{draw,draw_backend,draw_canvas,input}.zig`.

## TL;DR — recommendation: **borrow the model, not the code; it is already ours**

rhun's "self-drawn frame" is: *rasterize into a pixel buffer you own, hand that buffer to the
display server, take raw input events back*. **Snarf's browser host is exactly that
architecture today**: `HeadlessBackend` (an RGBA8888 raster in `dev/draw_backend.zig`) is
the compositor, `draw_canvas.zig` presents it with one `blit`, and `dev/input.zig` turns
raw pointer/key events into Plan 9 records. The native host built in phase 15 is the
*other* model — a transport adapter that forwards the draw byte stream to `devdraw`, which
owns the pixels (ruling R-P15-1).

So a self-drawn native frame is not a new rendering path. It is **the browser host's device
stack with a native present and a native event source** — `dev/draw.zig` + `HeadlessBackend`
+ `dev/input.zig`, unchanged, plus one new `src/host/frame/<platform>.zig` that does what
`shim.js` does: show the buffer, feed events. `src/core`, `src/draw`, `src/ninep` stay
byte-identical by construction, for the same reason they already do on two hosts.

Adopt-or-borrow verdict: **borrow** (the IOSurface/CALayer present, the kqueue+CFRunLoop
poll loop, the headless `shot`+control-socket testing idea). **Reject** porting anything
(asm, TTF rasterizer, widgets — out of scope and off-model: we draw Plan 9 bitmap subfonts
through `/dev/draw`, not TrueType through a widget layer). **Keep `devdraw`** as a supported
peer under ADR-0005 §3; add the frame as a second backend when Larry says go.

## The seven questions

### 1. Can a host adapter own the frame buffer with `src/draw`/`src/ninep` unchanged?

**Yes, and it is already proven** — twice. The browser host owns the buffer
(`HeadlessBackend.fb`) and the core never knows (R-OV-03); phase 15 showed the core also
does not know when it *doesn't* own the buffer. A frame host is strictly the easier case:
`dev/draw.zig` already serves `/dev/draw` over a `Backend` vtable, produces the 144-byte
connection line itself (`conn_line_len`), handles `noteResize` → `refresh`, and its pixels
are the ones every FROZEN-ACCEPT golden hashes. Import rules hold: `host/*` may import `dev`
(it already does, for the record formatter) and never `core`/`draw`.

**A fidelity bonus the devdraw path cannot give**: under `devdraw`, pixels are composited by
plan9port's memdraw, so the native window is *not* guaranteed golden-identical (rounding in
CALC11/12 paths). Under a frame, the native window shows `HeadlessBackend`'s bytes — the same
`0x…` hashes the test suite pins. One compositor, two hosts, identical pixels.

### 2. Minimum present path; is AppKit acceptable?

| Platform | rhun does | Minimum for us | Notes |
|---|---|---|---|
| macOS | AppKit `NSWindow` + layer-backed `NSView`, `setWantsLayer:`, redraw policy *never*; three `IOSurface`s (BGRA), frame → `IOSurfaceLock` → draw → `CATransaction` + `layer.setContents:` | **Same shape, simpler**: one `IOSurface` (or a `CGImage` over `fb` via `CGDataProviderCreateWithData` for the first spike) set as `CALayer.contents` after each `flush` | Byte order: our fb is RGBA8888 (XRGB32 semantics, A=0xFF); IOSurface wants BGRA — a swizzle on present, or a BGRA `HeadlessBackend` variant. Cheap either way. |
| Linux Wayland | raw wire protocol, `wl_shm` + `xdg_shell`, fractional scaling, cursor-shape | `wl_shm` pool + `xdg_toplevel` + frame callback — moderate; **keyboard is the hard part** (XKB keymap parsing with no libxkbcommon) | **No pointer warp on Wayland** — `Tmoveto` is a documented no-op already (ADR-0005 §3). |
| Linux X11 | raw wire protocol, `PutImage`/SHM, Xcursor theme | `XPutImage` over the socket, or MIT-SHM; `XWarpPointer` exists | Simpler than Wayland for a first Linux cut; devdraw's own X11 path is the precedent. |
| Windows | Win32 window + DIB `BitBlt` | `CreateDIBSection` + `BitBlt`; `SetCursorPos` for warp | Out of our stated platforms (macOS/Linux, ADR-0001); listed for completeness. |

**Is Cocoa acceptable even though rhun avoids toolkits?** Yes — rhun avoids *toolkits*
(GTK/Qt), not the OS: its macOS path *is* AppKit, called through the ObjC runtime from
assembly. From Zig that is `objc_msgSend` via `extern` + `linkFramework("AppKit")` /
`linkSystemLibrary("objc")` — no package in `build.zig.zon`, so ADR-0002's empty dependency
table holds. It does need one **clarification** to ADR-0002, not an amendment: OS frameworks
are "the platform" on the native host exactly as browser APIs are on the browser host —
allowed, behind the device layer only. The wasm build is untouched (freestanding, no libc);
the native executable on macOS already links libSystem.

### 3. Input mapping — mouse, chords, warp, `Kdown`

rhun's `key`/`click`/`move`/`down`/`up`/`scroll` are **scripting commands on its control
socket**, not an input API. The real question is how raw platform events become Plan 9
records, and the answer is: **reuse the browser's `dev/input.zig` + `profiles.zig`, not
`dev_input.zig`**.

- `devdraw` delivers *cooked* three-button records (its Cocoa layer maps Option→B2, Cmd→B3)
  so `dev_input.zig` is a passthrough. A frame receives *raw* `mouseDown:`/`rightMouseDown:`/
  `otherMouseDown:`/`flagsChanged:` — exactly what `shim.js` receives — so ADR-0004's profile
  machinery (native/modifier profiles, the 2-1 argument-chord rule) is needed and **already
  exists**: `DevInput.pushPointer/pushMod/pushKey/pushWheel`. The frame feeds those; the
  native host then has `/dev/input/ctl` and profile selection for free (phase 15 noted it
  lacked them). Real middle buttons work via the native profile.
- **Warp**: `/dev/mouse` write → `CGWarpMouseCursorPosition` (+`CGAssociateMouseAndMouseCursorPosition`
  to avoid the post-warp delta glitch) on macOS, `XWarpPointer` on X11, no-op on Wayland.
  Handled in the frame's device, same file-level contract (`mouse(3)`), `core/warp.zig`
  unchanged. rhun itself never warps — nothing to borrow here.
- **`Kdown`**: the `0x80`→`0xF800` translation exists only because devdraw speaks plan9port's
  `keyboard.h`. A frame maps `NSEvent.keyCode`/XKB keysyms straight to the 4e constants
  (as `shim.js`'s `KEYRUNE` table does) — the translation disappears. Ctrl-letter folding,
  `Kcmd`, IME commit (`insertText:` → rune string) follow the shim's rules (S-04 §3).

### 4. Resize and the info line — does a frame still speak wsys?

**No pipe at all.** `Twrdraw "JI"` + `Trddraw 144` was adapter work to coax a connection line
out of a server that has no file system (phase 15 report §1). With a frame, `/dev/draw` is
`dev/draw.zig`, which *is* the file system and formats the line itself. Resize is phase 12c's
browser path verbatim: platform resize event → `HeadlessBackend.resize` → `noteResize`
→ `refresh` exposure → `Display.getWindow` → `Tree.resize` (acme.c:548-555). Everything in
`src/host/devdraw/{wsys,wsys_enc,mux,Conn}.zig` is devdraw-specific and stays with that
backend; none of it is needed by a frame.

### 5. Dependency win — drop the plan9port requirement? What breaks?

Yes: `zig build run-native` would need no `$PLAN9`/`$DEVDRAW`, no `NOLIBTHREADDAEMONIZE`,
no child process. What we would have to supply ourselves:

- **Fonts**: nothing breaks — fonts are our bitmap subfonts rendered by our compositor on
  every host; devdraw never rasterized for us. rhun's TrueType rasterizer is irrelevant.
- **HiDPI**: devdraw gave Retina handling "free"; a frame must read `backingScaleFactor`
  (rhun's `update_size`) and either present 1× pixels scaled (blurry) or run the
  compositor at 2× with a **2× subfont** — which is R-GFX-05's unfinished second half on
  the browser too. Same work, shared across hosts; the frame does not add a problem, it
  removes the one place where the problem was hidden.
- **Clipboard `/dev/snarf`**: `Trdsnarf`/`Twrsnarf` → `NSPasteboard generalPasteboard`
  (`stringForType:`/`setString:forType:`) — rhun's `p_clip_get/set` are the exact calls;
  ~40 lines. X11 selections are the usual pain; Wayland needs `wl_data_device`.
- **Cursor** (`/dev/cursor`): `NSCursor` from a 16×16 1-bit blob; minor.
- **Multi-monitor**: AppKit handles placement; mixed-DPI moves re-trigger the resize/scale
  path. devdraw had the same exposure.
- **Window label** (`/dev/label`): `setTitle:`. Trivial.
- **What we lose**: devdraw's decade of edge-case handling (focus/activation quirks, drag
  outside the window, Cmd-key passthrough); the `drawfcall` compat clause stays valid for
  users who prefer it.

### 6. Headless frame dump — worth it?

**Already exists, and already better than PPM**: `HeadlessBackend.writePpm` dumps a frame,
and `HeadlessBackend.hash` (Wyhash) is what the FROZEN-ACCEPT goldens pin; `zig build test`
runs the whole editor headless at 640×480 today. What rhun adds that we lack is the
**control socket**: `--headless WxH --script file` with `key`, `click`, `move`, `resize`,
`shot`, `wait`. Ours would be a ~150-line test driver that feeds `DevInput.push*` from a
script and calls `writePpm`/`hash` after `frameEnd` — no platform code, runs in CI, and
gives the native host the scripted UI tests the browser gets from `smoke_wasm.mjs`.
**Worth doing first** (see "smallest experiment"): it de-risks the frame by exercising the
exact device stack a frame would drive, with zero windowing.

### 7. Cost

| Option | New code | Runtime deps | Fidelity | Warp | Notes |
|---|---|---|---|---|---|
| **Status quo — devdraw pipe** | 0 | plan9port `devdraw` binary | memdraw's pixels (not golden-pinned) | yes (mac/X11) | done, works, 2.1k lines of adapter already paid |
| **Frame, macOS (AppKit via objc)** | ~500–700 lines: window+view+layer present (~200), event pump + key tables (~200), pasteboard/cursor/warp/label (~100), build wiring | none beyond system frameworks | golden-identical | yes | one `*.zig` + a `main_native` switch on `--frame`; reuses `dev/*` |
| **Frame, X11 raw wire** | ~800–1000 (connect/auth, window, `PutImage`/SHM, events, keysym table, selections) | none (or libxcb if we relax) | golden-identical | yes | devdraw's X11 path is the citeable precedent |
| **Frame, Wayland raw wire** | ~1500+ (shm, xdg, frame cb, **XKB keymap parser**, data-device, fractional scale) | none | golden-identical | **no** | the expensive one; rhun did it in asm, which is the only reason it looks cheap |
| **SDL/GLFW present** | ~300 | a C library | golden-identical | yes | violates ADR-0002 outright; listed to reject it explicitly |

Assembly/no-libc is rhun's constraint, not ours; what it buys rhun (a 1 MB static binary)
we don't need. Our constraint is *no third-party packages*, and the macOS frame fits it.

## Smallest next experiment (if Larry says proceed)

Two steps, the first free of any platform code:

1. **Headless control driver (1 wave, no window)**: `src/host/frame/headless.zig` — runs the
   native boot (`ns_boot` + `dev/draw.zig` over `HeadlessBackend` + `dev/input.zig`),
   reads rhun-style commands from stdin/a socket (`key`, `type`, `click x y [1|2|3]`,
   `move`, `down`/`up`, `resize WxH`, `shot file.ppm`, `hash`, `quit`), and exits with the
   final frame hash. Acceptance: scripting the FROZEN-ACCEPT-13B boot scene reproduces its
   golden hash on the native build. Gain: scripted native UI tests in CI *today*, and the
   exact device stack a frame will drive.
2. **macOS frame spike (1 wave)**: `src/host/frame/mac.zig` — `NSWindow` + layer-backed view,
   `CGImage` over `fb` as `layer.contents` on each `flush` (IOSurface later), event pump →
   `DevInput.push*`, `backingScaleFactor` read and logged (1× present for the spike),
   `--frame` flag in `main_native`. **Honesty check as in phase 15**: `git diff -- src/core
   src/draw src/ninep` must be empty. Acceptance: the boot scene appears, typing and B2 via
   real middle button and Option+click both work, and a `shot` of the window's backing
   buffer hashes to the same value as step 1's headless run.

Decisions needed from Larry before step 2: (a) the ADR-0002 clarification that OS
frameworks are platform, not dependencies; (b) macOS first, Linux later (X11 before
Wayland), with devdraw kept as the fallback backend per ADR-0005 §3.

---

## Addendum A (2026-10-03) — Larry's counter-proposal: build devdraw ourselves

**Idea:** before any frame, remove the plan9port *install* by building just the `devdraw`
executable from the pinned fork inside our own build, and shipping it next to
`snarf-native`. Measured closure at `larryr/plan9port@337c6ac`:

| Piece | Files | Size | Notes |
|---|---|---|---|
| `src/cmd/devdraw` | ~12 used | ~90 KiB | `devdraw.c` 32K, `srv.c` 10K, `mac-screen.m` 36K (Cocoa + **Metal**, `-fobjc-arc`); X11 adds `x11-screen.c` 41K + keysym table 67K |
| `libmemdraw` + `libmemlayer` | 40 | 173 KiB | the compositor |
| `libdraw` | 59 | 136 KiB | linked whole (`SHORTLIB=draw memdraw`); devdraw needs a fraction |
| `lib9` | 103 | 123 KiB | plan9port's libc shim; per-OS file lists in its mkfile |
| `libthread` | 10 + asm | 39 KiB | pthreads + per-arch context-switch `.s` |
| `libbio` | 18 | 12 KiB | |
| **Total** | ~240 | **~570 KiB ≈ 15–18k lines** | vs. plan9port's ~650k lines |

Why it fits: (1) **Zig is already a C/ObjC compiler** — `build.zig` compiles `.c`/`.m`/`.s`,
passes `-fobjc-arc`, `linkFramework("Cocoa"/"Metal"/"QuartzCore")`; no `mk`/`9c`/`9l`, no
system compiler (R-BLD-02 holds; the macOS SDK headers come with the command-line tools).
(2) **devdraw stays a separate process** — ADR-0005 §3 "MUST NOT link plan9port code" is
satisfied by building a sibling executable in `zig-out/bin/`; `Conn.devdrawPath` defaults
to it before `$DEVDRAW`/`$PLAN9`; `src/host/devdraw/*` unchanged. (3) The work is file lists:
transcribe six mkfiles' per-OS selections, generate `latin1.h` via `mklatinkbd` at build
time (or vendor the generated header), the `.s` context switch per arch, X11 for Linux.
~1 wave macOS, ½ wave Linux.

**Decision needed — fetch vs. vendor:** vendor ~570 KiB into `third_party/plan9port/`
(offline, visible, 15k lines of C in PRs) or declare the pinned tarball as a hash-verified
`build.zig.zon` dependency (small repo; ends the "empty dependency table"). Either is the
first ADR-0002 amendment, narrowly worded: *the pinned reference implementation, used solely
to build the devdraw peer executable; nothing from it is linked into snarf.* Lean: fetch.
Keep devdraw **unmodified** (patching forks the compatibility clause; the `msec` bug and
`Kdown` dialect stay absorbed in our adapter).

**Effect on the frame:** removes its biggest selling point (install), leaving golden-
identical pixels, no child process, a possible Wayland future. Frame-as-default-within-a-year
drops from ~60% to **~30–35%**; it becomes a fidelity/independence project, not a dependency
fix. The headless scripted driver (§6) stands on its own merits regardless.

## Addendum B (2026-10-03) — a webview shell (VS Code / Atom model) as a native host?

ADR-0005 considered this as option 2 and rejected it: "the page inside is still a browser
page; nothing above is regained unless the frame grows native bridges, at which point it is
option 3 with a web renderer bolted on." **The premise has shifted since phases 11–12**: the
bridges now exist as `snarf-origin` + the `/n/origin` mount. A shell = *our origin server
in-process + a webview pointed at it*, and because the shell is local the origin is
trusted: real host processes (the allow-list question collapses for loopback), the host
file system as `/n/origin/fs`, no permission prompts for clipboard/files (the shell grants).
Reuses 100% of the browser host: canvas, `shim.js`, OPFS, `/dev/dom`.

What it does NOT fix: **warp** — WebKit/Chromium give pages no pointer-warp API; it would
need a bridge (`/dev/mouse` write → origin → native `CGWarpMouseCursorPosition`), a 9P round
trip for a cursor move; and keyboard capture (Cmd-Q, Ctrl-W) needs the shell's menu to
intercept. Still a browser underneath: ~100+ MB runtime, DPR/canvas quirks remain.

Toolchain: **Electron (node/npm, ~150 MB) and Tauri (Rust) are out** under ADR-0001/0002.
A **Zig shell over the system webview** is not: `WKWebView` via `objc_msgSend` (macOS),
WebKitGTK (Linux), WebView2 (Windows) — ~300–500 lines, the same ObjC-runtime approach as
the frame, but rendering through the existing browser host. Verdict: a legitimate fourth
backend — the cheapest route to "processes + files natively" for someone who also wants
`/dev/dom` on the desktop — **not a replacement for devdraw-in-tree**, which keeps real
warp and real three-button input at lower weight. Worth a line in NEXT-PHASES as "ADR-0005
option 2, revisited after phase 12"; no wave proposed.

## Addendum C (2026-10-03) — the warp loss, and recovering it on the browser host

Larry: *"the warp capability loss is a major issue because it is a fundamental behavior of
acme."* Agreed — the paper leans on `moveto` in five places (new window, search hit,
layout-box moves, pointer return after a pop-up dies) because the pointer IS the point of
attention: when the editor moves your attention it moves your hand. Three separations:

**1. Where warp is actually lost.** Only the pure browser host and Wayland. Every native
backend keeps it — devdraw today, devdraw-built-by-us, the frame on macOS/X11 — and the
**webview shell keeps it too**: its bridge is a real `CGWarpMouseCursorPosition` reached by
a 9P round trip, which is exactly Plan 9's own mechanism (acme writes `/dev/mouse`, the
kernel moves the pointer). Addendum B's "bridge only" is a warp-KEEPING path; the table
there should be read that way. The core requests the warp unconditionally on every host.

**2. The browser's known partial recovery** (HANDOFF design note, OQ-IN-4 hybrid
pointer/focus model): a refused warp becomes a *focus move* — point-to-type's target jumps
to where the pointer would have landed, with a visible cue. Preserves the functional
consequence (keystrokes land in the new window / at the hit), loses the physical one.
Cheap; honest fallback.

**3. A full recovery not yet tried — Pointer Lock.** Browsers let a page own the pointer
(the Pointer Lock API, built for games): the OS cursor is hidden, the page receives raw
movement deltas, and draws its own cursor. That is ACME's native situation — `/dev/cursor`
exists because acme draws its own cursors. Under lock, warp is trivial: move the drawn
cursor; the OS pointer is irrelevant. Wayland has the same mechanism for the same reason
(`zwp_pointer_constraints`: lock, then `set_cursor_position_hint` on release) — one trick
covers both warp-less platforms.

Sharp edges, all below the boundary (`web/shim.js` + `dev/input.zig`, core unchanged):
lock needs a user gesture to enter and drops on window blur (re-acquire on next click);
browsers reserve **Esc to exit lock** — collides with acme's Esc (select recently typed) →
remap or double-Esc; the drawn cursor must leave the canvas gracefully (unlock at the edge);
acceleration differs under raw deltas (`unadjustedMovement: true` helps); the cursor is
drawn through `/dev/draw` (ACME's own cursor shapes, R-GFX) so it is golden-testable.

**Re-ranking the experiments** given warp's weight: (1) **Pointer Lock spike on the browser
host** — one wave, large payoff: the zero-install host stops being the one where acme is
diminished; must prototype before promising (Esc is what could sink it). (2) devdraw-in-tree
(Addendum A). (3) headless scripted driver (§6). (4) the frame, if ever. Proposed as a
NEXT-PHASES Tier-1 candidate alongside Put/Get; needs Larry's call on the Esc remap.

## Notes — discussion log (2026-10-03, Larry ↔ remote session)

1. **Task received** as an issue-shaped request (no GitHub issue existed; report written to
   `agents/reports/` instead). rhun's guide and `src/mac/cocoa.s` were read; our
   `src/host/devdraw/*`, `main_native.zig`, ADR-0005 and the phase-15 report re-read.
2. **Core finding**: rhun's model (own the pixel buffer, present it, take raw events) is
   the browser host's architecture already; the devdraw adapter is the odd one out. Verdict
   borrow/reject/keep as in the TL;DR; seven questions answered above.
3. **"Is this a peer to devdraw?"** — in *role* yes (window, pixels, input, warp,
   clipboard); in *interface* no (in-process over `dev/draw.zig` + `HeadlessBackend`, not a
   `drawfcall` process). ADR-0005 §3's "devdraw or a drawfcall-compatible server" would need
   a wording amendment to admit an in-process frame. A true `drawfcall` peer usable by
   plan9port's own acme/sam is possible later but out of scope.
4. **"Inspirational rather than actual?"** — yes. Nothing copied (asm, TTF rasterizer,
   widgets, no warp). Actual lifts: the IOSurface/CALayer present recipe (three BGRA
   surfaces, `IOSurfaceIsInUse`, `CATransaction` + `setContents:`, redraw policy never),
   the `CFRunLoopRunInMode` + kqueue loop shape, the headless `--headless/--script/shot`
   vocabulary. Biggest value: the mirror it held up (point 2).
5. **Warp framing confirmed**: browser never; native-devdraw yes (phase 15, macOS/X11);
   native-frame yes (mac/X11, **not Wayland**). The frame does not *buy* warp — devdraw
   already did; it buys warp without plan9port, plus golden pixels and no pipe. The core
   writes the warp record on every host; the host honors or refuses.
6. **Probability** that the frame is the default native backend within a year: ~60% stated,
   decomposed as authorize-and-build-this-year ~0.85 × mac spike works ~0.90 × matures to
   preferable (Cocoa edge cases + 2× subfont) ~0.80 × default flipped ~0.90 × devdraw kept
   ~0.97 ≈ 0.53, rounded up for positive correlation. The uncertain link is *priority*
   (competes with Tier 1 Put/Get/commands), not technology. Per-platform: macOS 65–70%,
   X11 ~30%, Wayland "not a contest".
7. **Clarification**: `zig build run-native` is our own `build.zig` step (phase 15), not a
   Zig feature; "default" means which backend sits under `/dev/draw` when it runs. The
   browser host is a separate build (`zig build serve`) and not in that ordering.
8. **Larry's counter-proposal** → Addendum A (devdraw built by us). Reassessed frame
   probability → ~30–35%.
9. **Webview-shell question** → Addendum B.
10. **Access note**: this session's GitHub credential lost push rights mid-session (git push
    and the GitHub API both 403; reads work). The report was committed locally on branch
    `spike-rhun-frame` and handed to Larry as a file; to be pushed once access is
    reconnected (claude.ai/connect-github) or committed from Larry's machine.
11. **Warp loss is a major issue for Larry** (fundamental acme behavior) → Addendum C:
    loss is confined to the pure browser host + Wayland; the webview shell KEEPS warp via
    its bridge (correction to Addendum B's table); browser recoveries = focus-follows-warp
    (OQ-IN-4, partial) and **Pointer Lock** (full, own-drawn cursor, Esc conflict to solve;
    same trick works on Wayland). Experiments re-ranked: Pointer Lock spike first.
