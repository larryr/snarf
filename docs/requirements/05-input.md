# R-05 — Input Requirements (keyboard, and the 3-button-mouse problem)

Status: **Draft v2** (revised after ADR-0004)

ACME is unusable without the three-button mouse language *including chords* (R-EDIT-05..09).
Most 2026 hardware is a trackpad or a touch screen. This document requires a **logical
mouse model** plus a set of **emulation profiles** so every gesture has a first-class
expression on every input device. Design/state machine:
[../spec/04-input-devices.md](../spec/04-input-devices.md); decision: ADR-0004.

## 1. Logical model

| ID | Requirement |
|----|-------------|
| R-IN-01 | Input SHALL be delivered to the core via `/dev/mouse` and `/dev/kbd` (formats in spec 04), never via direct event callbacks into editor code. The core consumes *logical* events: position + button bitmask (B1=1, B2=2, B3=4) + time, exactly like Plan 9. |
| R-IN-02 | All emulation happens **below** `/dev/mouse` (in the input device server): the core never knows whether a chord came from real buttons, a modifier key, or a two-finger tap. |
| R-IN-03 | Every ACME gesture SHALL be reachable in every profile: B1/B2/B3 click, B1/B2/B3 sweep, chord B1+B2 (cut), chord B1+B3 (paste), chord 2-1 (execute-with-argument). |

## 2. Emulation profiles (all SHALL ship in v1)

| ID | Profile | Requirement |
|----|---------|-------------|
| R-IN-04 | **native** | Real multi-button mice: buttons map 1:1; `contextmenu` and middle-click autoscroll/paste defaults suppressed inside the Snarf canvas. Real chords work. |
| R-IN-05 | **modifier** | Keyboard-assisted: holding `Alt` maps a B1 press/click to **B2**; holding `Meta`/`Ctrl` (platform-dependent, configurable) maps to **B3**. Crucially, pressing the modifier **while a B1 sweep is in progress** synthesizes the *chord* press (Alt during sweep ⇒ +B2 = cut; Meta during sweep ⇒ +B3 = paste), releasing it synthesizes the chord release. This is the creative core: modifiers are treated as extra mouse buttons in the state machine, not as click-time modes. |
| R-IN-06 | **touch** | One finger = B1 (drag = sweep). Two-finger tap = B2 click; three-finger tap = B3 click. A second finger tapped **while one finger is held/sweeping** = chord B2 (cut); two extra fingers (or a tap in the right half? — see OQ-IN-1) = chord B3 (paste). Long-press = B3 (look) as a discoverable alias. Two-finger drag scrolls. |
| R-IN-07 | **chordbar** | An optional on-screen bar (drawn by Snarf itself, not DOM) with three latching buttons; tapping `2` then the text = B2 click, latching `1` then tapping `2` mid-sweep = chord. Serves accessibility and single-button devices, and doubles as live documentation of the mouse language. |
| R-IN-08 | Wheel/aux niceties: scroll wheel scrolls ACME-style; wheel-click = B2 where hardware has it. Profile selection is automatic (pointer/touch capability detection) with manual override via `/dev/input/ctl`. |

## 3. Keyboard

| ID | Requirement |
|----|-------------|
| R-IN-09 | `/dev/kbd` SHALL deliver Unicode code points plus Plan 9-style control runes (Kup, Kdown, Kleft, …); browser shortcuts that collide (Ctrl-W!) are captured where the Page Visibility/keyboard-lock APIs allow, and the set of un-capturable keys is documented. |
| R-IN-10 | Standard editing keys work as in ACME (arrows, Home/End, Esc selects last typed text, Ctrl-U/W/A/E line editing in tags). |
| R-IN-11 | IME composition SHALL work for text entry (composition events funneled through `/dev/kbd` as commit strings). |

## 4. Open questions

- OQ-IN-1: Best touch mapping for chord-paste (B1 held + B3): second-finger *double*-tap,
  two-finger tap while holding, or screen-region split? Needs prototyping with real hands.
- OQ-IN-2: Should the modifier profile also offer `Space` as a sweep-time B2 (very fast to
  reach)? Conflicts with typing only when a sweep is active — likely safe. *Prototype.*
- OQ-IN-3: Gamepad/pen support — out of scope v1.

## 5. Revision log

- **v1** — required only "a way to emulate B2/B3".
- **v2** — post-ADR-0004: chords made a hard per-profile requirement (R-IN-03), the
  modifier-as-extra-button state machine idea promoted to requirement (R-IN-05), touch
  vocabulary defined (R-IN-06), chord bar added (R-IN-07), profiles auto-selected (R-IN-08).
