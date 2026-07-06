# ADR-0004 — Three-button mouse & chords on modern hardware

Status: **Accepted** · Satisfies: R-OV-06, R-IN-01..08 · Fed back into requirements
[R-05](../../requirements/05-input.md) (its v2 revision is this decision)

## Context

ACME without B2/B3 *and chords* (B1+B2 cut, B1+B3 paste, 2-1 execute-with-argument) is not
ACME. Target hardware is mostly trackpads and touchscreens; browsers additionally hijack
right-click (context menu) and middle-click (autoscroll/paste). The brief asks us to "be
creative."

Options considered:

1. Remap chord actions to keyboard shortcuts (give up on chords).
2. Click-time modifier *modes* (Alt-click = B2 click) — the classic one-button emulation;
   still no chords, because the modifier only changes how a click *starts*.
3. **Virtual-button model**: treat modifiers/extra fingers/on-screen latches as *buttons*
   feeding the same state machine as physical buttons, synthesizing bit transitions
   mid-gesture — chords included.
4. Hardware-only: require a 3-button mouse.

## Decision

Option 3, layered under `/dev/mouse` so the core cannot tell emulation from hardware
(R-IN-02), with **four shipping profiles** (auto-detected, user-overridable):

- **native** — real buttons pass through; browser defaults suppressed on the canvas.
- **modifier** — `Alt` = B2, `Meta`/`Ctrl` = B3, *held as buttons, not click modes*:
  pressing Alt in the middle of a B1 sweep produces exactly the `1→3→1` bitmask sequence
  of a hardware cut chord. The creative twist for the 2-1 argument chord: releasing the
  modifier while the pointer is still down *swaps* the active bit to B1 instead of ending
  the gesture (S-04 §2.2) — making execute-with-argument a fluid
  hold-Alt / press / release-Alt / release motion on a plain trackpad.
- **touch** — finger count = button number for taps; a second finger tapped during a hold
  is a chord pulse; long-press = look. Timers/discrimination live in testable Zig, not JS.
- **chordbar** — Snarf-drawn on-screen latch buttons `1 2 3`; latching mid-press adds
  chord bits. Serves single-button/accessibility cases and teaches the mouse language.

Full state machine: S-04 §2 and [diagram](../diagrams/mouse-chords.puml).

## Consequences

- ✅ Every ACME gesture reachable on every mainstream device; muscle-memory users with
  real mice lose nothing.
- ✅ One state machine to test; profiles are just edge-mapping tables.
- ⚠️ Modifier keys used for emulation are unavailable as kbd input during pointer
  gestures (acceptable: ACME barely uses modifiers).
- ⚠️ Touch chord vocabulary needs live prototyping (OQ-IN-1/2 stay open; requirements
  R-IN-06 marks the paste chord as provisional).
- 📌 Feedback into requirements (done): R-05 v2 — chords per profile made mandatory
  (R-IN-03), modifier-as-virtual-button promoted to requirement (R-IN-05).

## Alternatives rejected

- **Keyboard remaps** (1): destroys the defining interaction of the editor being ported.
- **Click-time modes** (2): subsumed — our model degrades to it for simple clicks but
  also delivers chords.
- **Require hardware** (4): unacceptable for a browser-delivered tool.
