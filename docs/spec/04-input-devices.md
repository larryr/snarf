# S-04 — Input Devices Specification (/dev/mouse, /dev/kbd, /dev/cons)

Satisfies: R-IN-01..11, R-EDIT-05..09. Decision record:
[adr/0004-three-button-mouse.md](adr/0004-three-button-mouse.md).

## 1. `/dev/mouse`

Plan 9 wire format, verbatim: each read returns one 49-byte text record

```
m x[11] y[11] buttons[11] msec[11]
```

`buttons` bitmask: B1=1, B2=2, B3=4; wheel as buttons 8 (up) / 16 (down), one event per
notch. Reads block (R-9P-13); `Tflush` cancels. Writes to `/dev/mouse` move nothing (no
warp in a browser) and return an error. `/dev/cursor` is in S-03 §1.

**The core consumes only this file.** Everything below happens inside `devinput`.

## 2. Profiles and the synthesis state machine (R-IN-02..08)

`devinput` receives raw shim events (`pointerdown/up/move`, `touchstart/…`, `keydown/up`
for designated modifiers, chordbar hits) and runs the state machine below to emit *logical*
button transitions. The active profile decides which raw events map to which edges;
auto-detected at boot (`pointer: coarse`? `maxTouchPoints`? platform for Meta-vs-Ctrl),
overridable at `/dev/input/ctl` (S-02 §3).

![mouse-chords](diagrams/mouse-chords.puml)

Diagram source: [diagrams/mouse-chords.puml](diagrams/mouse-chords.puml)

Key invariant (R-IN-02): downstream of this machine, an emulated chord is byte-identical
to a hardware chord — `buttons` goes `1 → 3 → 1` for a B1+B2 cut regardless of origin.

### 2.1 native profile (R-IN-04)

`pointerdown.button` 0/1/2 → B1/B2/B3. Shim suppresses `contextmenu`, middle-click
autoscroll, and selection defaults within the canvas. Real simultaneous buttons = chords,
no synthesis needed.

### 2.2 modifier profile (R-IN-05)

Modifiers are **latched as virtual buttons**, not click-time modes:

- `Alt` down ⇒ virtual B2 pressed *if* a pointer button is or becomes down; `Alt` up ⇒
  virtual B2 released.
- `Meta` (mac) / `Ctrl` (other; configurable `map` in `ctl`) ⇒ virtual B3 likewise.
- Pointer button with modifier already held starts as B2/B3 (classic one-button emulation).
- Modifier pressed **mid-B1-sweep** adds the bit ⇒ chord (cut/paste) — the state machine
  makes this identical to pressing a second physical button (R-IN-05).
- 2-1 argument chord: hold `Alt`, press pointer (=B2 down), release `Alt` while pointer
  still down (=B2 up? **no** — see rule): releasing the *modifier* while the pointer is
  down transfers the press to B1 (bit swap 2→1 in one event), which ACME reads as the 2-1
  join. Rule: a modifier release with pointer down swaps to B1 rather than ending the
  gesture; only pointer-up ends it. This is the one deliberate divergence from "modifier ==
  button" and it is what makes execute-with-argument reachable on a trackpad.

### 2.3 touch profile (R-IN-06)

| Gesture | Logical |
|---------|---------|
| 1 finger down/move/up | B1 press/sweep/release |
| 2-finger tap (< 250 ms, < 8 px travel) | B2 click at midpoint |
| 3-finger tap | B3 click |
| long-press (> 500 ms, still) | B3 press (look), release on lift |
| 2nd finger tap while 1st held | +B2 chord pulse (cut) |
| 2nd finger double-tap while 1st held | +B3 chord pulse (paste) — pending prototyping OQ-IN-1 |
| 2-finger drag | wheel events (scroll) |

Tap/press discrimination timers run in `devinput` (Zig), not the shim, so they're testable.

### 2.4 chordbar profile (R-IN-07)

Snarf draws (through its own /dev/draw!) a slim bar with `1 2 3` latch buttons; a latch
arms the next pointer press as that button; latching during an active press adds the bit
(chord). Doubles as the discoverability story: hovering shows "2 = execute, 3 = look".

## 3. `/dev/kbd` (R-IN-09..11)

Modeled on Plan 9's kbd file (rune-based, not scancode):

- Read returns UTF-8 runes; specials as Plan 9 constants: `Kup=0xF00E`, `Kdown=0xF800`,
  `Kleft`, `Kright`, `Khome`, `Kend`, `Kpgup`, `Kpgdown`, `Kins`, `Kdel=0x7F`, `Kesc=0x1B`,
  `Kbs=0x08`, `Ksoh=0x01`(^A)… control chars pass through as-is.
- Browser-reserved shortcuts: shim calls `preventDefault` on everything it can within the
  canvas; the Keyboard Lock API is requested in fullscreen. Un-capturable set (Ctrl-W/T/N
  outside keyboard-lock, Cmd-Q) documented in-app under `/dev/input/ctl` read.
- IME (R-IN-11): composition happens in a hidden, correctly-positioned `<input>` managed by
  the shim; `compositionend` text is injected as a rune string; interim composition shown
  by the core as pending text (v1: inject-on-commit only).
- Modifier keys configured as mouse emulation (profile `modifier`) are consumed by
  `devinput` and **not** delivered as kbd runes while a pointer gesture is active.

## 4. `/dev/cons`

Read: line-buffered keyboard echo for command-line-ish uses (rare in ACME). Write: appends
to the `+Errors` window. Exists mainly so ported Plan 9 idioms (`fprint(2, ...)` →
`/dev/cons`) have somewhere to land.

## 5. Event delivery plumbing

Shim (main thread) → SAB ring or postMessage (S-00 §2) → `devinput` state machine →
per-file wait queues → blocked `Tread`s complete. Coalescing: consecutive `move` events
with identical buttons collapse to the newest when the reader is behind (ACME only wants
the latest position), but button *transitions* are never dropped.

> Revision log: 2026-07-19 (phase 6) — native + modifier profiles shipped;
> touch/chordbar deferred (R-05's all-four-in-v1 tracked). Kdown pinned to 0xF800 per
> the 4e tree (plan9port's 0x80 is a noted p9p divergence). §5 implemented: coalescing
> in devinput's queue, transitions never dropped (diverges from the kernel's
> qfull-discard, justified by R-IN-02). IME and Keyboard Lock deferred.
