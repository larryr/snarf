# Spike brief: mouse warping in the browser host via Pointer Lock

*SnarfProdd (PM), 2026-10-09. PM proposal, not an agreed requirement; see [docs/product](../README.md). Repo @ `cf9e30c` (pulled; unchanged since 2026-10-04).
Status: **proposed, timeboxed to ~1 pipeline phase**. Roadmap slot: **M0, first item** ([roadmap](../roadmap.md)).*

## Goal

Find out whether the browser host can honour acme's pointer warps (R-EDIT-25), and whether
the result *feels* good enough for Larry's daily use. The idea: lock the real pointer,
draw snarf's own cursor, track a virtual position, and let the core's existing
`/dev/mouse` warp writes move that position.

## Hypothesis

Warping can be done **entirely inside the browser input device and the JS shim**, with
**zero changes to the editor core's warp path**. The core already issues every warp as a
write to `/dev/mouse` (`src/core/warp.zig`; S-04 §1). Today the browser device refuses that
write with `permission denied` (`src/dev/input.zig` `writeOp`). Under lock it would accept
it and move the virtual pointer. The drawn cursor is already allowed by the spec:
R-GFX-08 says the cursor may be "mapped to CSS cursors **or a drawn cursor** as the backend
chooses". The Esc conflict was settled in principle on 2026-10-03
(`notes/claude/phase-review-2026-10-03.md` Decision 2: lock loss counts as Esc, with a
`document.hasFocus()` guard, and Esc is not forwarded as `Kesc` while locked). That review
said **no ADR is needed** because the change is host-local.

## Scope (minimal build)

1. **Shim (`web/shim.js`)**: an opt-in lock mode (e.g. `?lock=1`, or a `ctl` verb). Call
   `requestPointerLock()` on a canvas click. That first click is consumed as the gesture
   and not forwarded. Turn `movementX/Y` into a virtual position clamped to the canvas, and
   draw the cursor on a separate overlay canvas or element (keeps the `/dev/draw` scene
   untouched). Handle `pointerlockchange` and `pointerlockerror`, the focus guard, and Esc
   dedupe. Show a "click to re-enter" hint after unlock.
2. **Input device (`src/dev/input.zig`)**: while locked, accept `m x y` writes. Update the
   virtual position, queue a mouse record at the new point (Plan 9 semantics: the next read
   reports the warped point), and send the new position to the shim. Keep refusing writes
   while unlocked. Expose state in `/dev/input/ctl` (`lock on|off`, read-back).
3. **Core, one port: return-after-popup.** acme's `savemouse`/`restoremouse` was dropped in
   phase 8 (`src/core/Column.zig:8`, `colgrow.zig:25`, ruling R-P8-7). Without it, the third
   warp can't be tested on *any* host. It is host-agnostic and helps the native host too.
   This is the spike's only core change.
4. **Instrumentation**: log input-to-cursor-paint latency and a lock event trace (enter,
   exit, cause) to the console.

**Non-goals:** making lock the default; the layout and scroll `moveto`s (cols.c/scrl.c,
"not ported on any host", R-EDIT-25); touch; Keyboard Lock; Linux/Windows; Worker+SAB;
polishing the cursor image. No ADR or requirement edits until the spike passes.

## Acceptance criteria

The spike **passes** only if every **must** row passes on macOS in **Chrome, Safari, and
Firefox** (current stable), with **both a trackpad and a 3-button mouse**.

| # | Criterion | Must/Should |
|---|-----------|-------------|
| A1 | **Search-hit warp** (`look.c:219`): B3 on a word → the drawn cursor lands inside the highlighted hit, and the next B3 click there steps to the next hit | Must |
| A2 | **openfile warp** (`look.c:897`): B3 on `file:12` → the cursor lands on the selection in the new window, and typing goes there (point-to-type, R-EDIT-22). No warp on an invalid `:addr` (phase 15 rule) | Must |
| A3 | **Return-after-popup**: `Del` on a window the pointer was warped into → the cursor returns to where it came from (acme `restoremouse`) | Must |
| A4 | **Mouse language under lock**: B1 sweep, B2/B3 click and sweep, chords 1-2 and 1-3, 2-1 argument, double-click, scroll wheel. Works with physical buttons *and* the modifier profile (Option = B2, Cmd/Ctrl = B3) | Must |
| A5 | **Feel**: the drawn cursor tracks hand motion like the system cursor (same acceleration, no drift or jumps). Larry edits for 30 minutes per input device and would keep it on | Must (Larry's judgment) |
| A6 | **Latency**: input-to-cursor-paint ≤ 1 frame (16 ms) at p95; cursor motion causes no scene redraw (R-GFX-06) | Must |
| A7 | **Enter/exit UX**: the first click enters lock without also acting as a B1. The browser banner shows and is understood. Esc exits, *and* acme's Esc (select last typed) still works through lock loss. Re-entry after Esc works after the browser cooldown with a visible hint and never loops | Must |
| A8 | **Lock lost unexpectedly** (Cmd-Tab, Mission Control, DevTools, a permission prompt, sleep): no phantom Esc selection (focus guard), no stuck button state, and the system cursor reappears somewhere sane | Must |
| A9 | **Leaving the canvas**: Larry can reach the Dock, other apps and the browser chrome without remembering Esc (e.g. auto-exit when the cursor pushes past an edge), and the real cursor reappears near where it left | Must. Without this a daily editor is a trap |
| A10 | **HiDPI**: the cursor lands on the right glyph on Retina and on a 1× external display, and stays correct after resize and moving the window between displays | Must |
| A11 | Unlocked behavior is byte-identical to today: the full test suite and smoke stay green, and goldens don't move | Must |

**Fail** = any must row fails in Chrome *and* Safari (Larry's primary browser). A failure
only in Firefox is a recorded per-browser limitation.

## Known risks (verified against spec/MDN, 2026-10-09)

- **Unlocking puts the real cursor back at the lock-entry point, not at snarf's virtual
  position.** Spec "Exit Pointer Lock" step 1: the cursor is "positioned at [=cursor
  position=]", i.e. where lock began ([W3C Pointer Lock 2.0](https://w3c.github.io/pointerlock/)).
  Every exit (Esc, edge exit, Cmd-Tab) teleports the cursor. **Biggest risk to A8/A9 and
  feel.**
- **Esc is the mandatory unlock gesture and can't be overridden** (spec §Requirements,
  "default unlock gesture must always be available"). Safari's banner reads "Press Esc once
  to dismiss this banner. Press Esc again to reveal your mouse pointer"
  ([report](https://stackoverflow.com/questions/79783386/how-to-make-safari-update-css-variables-after-pointerlock-banner-disappears)),
  so **the first Esc in Safari may be swallowed**, which the Decision-2 design didn't
  account for. The banner also fires a **resize** event, so snarf's canvas reflows (phase
  12c resize path).
- **Re-lock needs a fresh user gesture, and Chrome adds a cooldown** after a user Esc.
  Immediate re-requests fail by spec ([MDN requestPointerLock](https://developer.mozilla.org/en-US/docs/Web/API/Element/requestPointerLock)).
  Chromium enforces a delay ([Chromium change on the cooldown error](https://github.com/ronitmevada/Chromium/commit/01f03c1da384fb01b88f4efa563eb5684ea2fe29),
  bug 40779661; about 1 s per [drei #1988](https://github.com/pmndrs/drei/issues/1988)).
  Lock can never be entered automatically at boot.
- **Lock drops on any focus loss** (spec §Requirements). There is no "why" field in the
  API, hence the focus guard. Chrome also documents a per-site **"wants to disable your
  mouse cursor" prompt** for untrusted sites ([Chromium design doc](https://www.chromium.org/developers/design-documents/mouse-lock/)).
  Behaviour in today's Chrome needs checking.
- **No coordinates under lock**: `clientX/Y` are frozen and only `movementX/Y` deltas
  arrive ([MDN Pointer Lock API](https://developer.mozilla.org/en-US/docs/Web/API/Pointer_Lock_API)).
  Rounding, acceleration and DPR scaling are now ours to get right (A5, A10). Leave
  `unadjustedMovement` **off** so OS acceleration matches the system cursor. That option
  is Chrome 88+ on macOS, Safari 18.4+, Firefox 152+, and the promise return is Chrome 92+
  and Safari 18.4+ ([MDN browser-compat-data 8.1.5](https://github.com/mdn/browser-compat-data)).
- **Not available on iOS/iPadOS Safari** (BCD: `safari_ios` unsupported), so this is a
  desktop-only feature. That's consistent with the HANDOFF touch note (touch = focus moves,
  not warps).
- **Accessibility**: the spec requires lock changes to be reported to screen magnifiers,
  and a hidden system cursor breaks pointer-following magnification. Lock must stay opt-in.
- **Keyboard Lock** (`navigator.keyboard.lock`) would capture Esc, but it's Chrome-only
  (BCD) and fullscreen-only. It's a later enhancement, not the design.

## What changes if it passes / fails

| | **Pass** | **Fail** |
|---|---|---|
| **R-EDIT-25** | Amend (R-02 v7): browser host warps **while locked (opt-in)**, otherwise highlight + scroll as today. Per-host table gains "browser-locked" | Unchanged. Add a revision-log line recording the spike result and which criterion failed, so it isn't re-litigated |
| **ADR-0005** | Context bullet "No mouse warping" softened to "browser warps only under opt-in Pointer Lock". The two-hosts decision is unchanged (processes, files and key capture still favour native). No new ADR (per Decision 2) | Strengthens the case for the native host as Larry's daily driver |
| **S-04 / R-IN-10 / R-GFX-08** | S-04 §1 host table gains a locked row. S-04 §3 records the focus guard, Esc dedupe, Safari double-Esc and edge-exit. R-GFX-08 drawn cursor marked built | Nothing |
| **Roadmap** | Track B (browser daily driver) becomes viable. The `restoremouse` port ships regardless. A full "lock mode" wave goes into M3 Track B | Drop Pointer Lock from M3. Decision 1 (daily host) leans native. Keep the `restoremouse` port (benefits native) |

## Open questions for the tech architect

1. Cursor rendering: a shim overlay (cheapest, outside `/dev/draw`) or composited by the
   canvas backend under `/dev/cursor` (R-GFX-08, S-03 §1)? Does the overlay break the
   golden-image story?
2. Should the warp produce a synthetic `/dev/mouse` read record, and does the core's
   gesture machine (`core/Gesture.zig`) tolerate a position jump mid-gesture (e.g. a warp
   during a B3 hold)?
3. Edge exit (A9): what threshold, and how should the cursor reappear given the spec puts
   it back at the lock-entry point? Is a brief exit-then-re-lock-on-next-click acceptable?
4. Opt-in surface: URL flag, `/dev/input/ctl` verb, or a tag command (`Lock`)? Should lock
   be persisted in Dump?
5. Does lock interact with the modifier profile's Cmd/Ctrl handling, or with Safari's
   swallowed first Esc, in ways that need S-04 changes before the build?
6. Is porting `restoremouse` in this spike acceptable under the "stop and ask for design
   forks" rule, or should it be its own micro-phase?
