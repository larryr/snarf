# Research: acme's mouse language on Apple trackpads (chords and warp)

*Product research note by SnarfProdd, 2026-10-09. Not an agreed requirement. For Larry and the tech architect.*
*Scope: Magic Trackpad (standalone) and MacBook Force Touch trackpads, on both snarf hosts: the browser and the native `devdraw` host.*
*"Prior research note" means `/workspace/research/acme-trackpad.md`, written by another assistant on 2026-10-09. I re-checked every claim reused here against a primary source or the code; corrections are marked **(corrected)**.*

## 1. The problem in one paragraph
Acme's grammar (B1 select, B2 execute, B3 look, the 1-2 Cut, 1-3 Paste and 2-1 argument chords, and warp) assumes three physical buttons that can be pressed at the same time. A Mac trackpad has one physical button. Snarf already treats this as a first-class problem: R-IN-03 requires that every gesture, chords included, be reachable in every profile, and R-IN-02 requires that all emulation happen below `/dev/mouse` so the core never knows where a chord came from (`docs/requirements/05-input.md`). The question is how far each host can get on a trackpad, and how good that can feel.

## 2. What exists today (verified)
**Native host = plan9port `devdraw`** (ADR-0005; pinned to `larryr/plan9port@337c6ac`). ADR-0005 notes that snarf's own chord emulation is *absent* on this host, because devdraw delivers real 3-button records. So on a Mac, the trackpad behaviour of snarf-native **is** devdraw's (`src/cmd/devdraw/mac-screen.m` at that revision):
- 1-finger click = B1. 2-finger (secondary) click = B3 (`rightMouseDown` → `getmouse`, with bits remapped). Option-click = B2, Command-click = B3, and Shift adds 5 (devdraw(1)).
- **3-finger tap = B2 click, and 4-finger tap = the 2-1 chord** (`touchesEndedWithEvent`, l.668-685, tap shorter than 250 ms; added in commit 9af9ceca, Nov 2018). The prior research note missed this: half of its idea 1 already ships. **(corrected)**
- While a button is held, Control, Option and Command add B1, B2 and B3 (`flagsChanged`, l.622-650). The Control-adds-B1 behaviour came in a9e66ffa, "makes 2-1 chords possible with touchpad on a mac laptop".
- Pinch toggles full screen. Pressure and haptics are not used.
- Warp uses `CGWarpMouseCursorPosition` plus `CGAssociateMouseAndMouseCursorPosition(true)` (l.759-760), so it is real warp.
- plan9port's acme(1) still says Command-X/V/Z are "much less awkward than the equivalent chords" on Mac laptops (`docs/acme/man/plan9port/acme.1:675`). That is the product gap.

**Browser host.** `src/dev/profiles.zig` ships the `native` and `modifier` profiles; `touch` and `chordbar` are TODO. The modifier profile (R-IN-05: Alt = B2, Meta/Ctrl = B3, and a modifier pressed *mid-sweep* = chord) is the trackpad path today. Warp is refused (`src/dev/input.zig:432`, R-EDIT-25). The Pointer Lock spike (`docs/product/spikes/pointer-lock-warp.md`) is the route to browser warp.

## 3. What each host can actually see from a Mac trackpad

| Signal | Browser (Chrome / Firefox / Safari) | Native devdraw (AppKit) |
|---|---|---|
| Per-finger touches, finger count | **No.** Desktop browsers send no `touch*` events for a trackpad; it is `pointerType "mouse"` (HANDOFF design note; SO 68808218) | **Yes**, through `NSTouch` (public API), but only to the view under the pointer. devdraw already uses it |
| 2-finger click | Arrives as a secondary button (B3-able) *[inferred from Apple's "secondary click"; to verify in the event-log spike]* | B3 |
| 3-finger tap | Nothing reliable; macOS uses it for Look up (Apple 102482) | B2 (devdraw), if Look up is set to force click instead *[to verify]* |
| Pinch | `wheel` + `ctrlKey` in all three (Chrome 35+, Firefox 55+, Safari 15+) | `magnifyWithEvent` |
| Pressure / force click | **Safari only**: `webkitmouseforcedown`/`changed`, `MouseEvent.webkitForce` (MDN, BCD: Safari 9+, never Chrome or Firefox). `PointerEvent.pressure` is a fixed 0.5 for mouse-type pointers | `NSEvent` stage 0/1/2. **`primaryDeepDrag` keeps stage 2 during a drag**; only `primaryDeepClick` loses it (Apple docs). **(corrected)** The prior note said force click always dies on drag |
| Haptics | **None** | `NSHapticFeedbackManager`: only `generic`, `alignment`, `levelChange` |
| Warp | Impossible, unless Pointer Lock and a self-drawn cursor are used | Real (`CGWarpMouseCursorPosition`) |
| Raw multi-device contacts (second pad) | No | Only through the private `MultitouchSupport.framework` |

**The headline:** on a trackpad the browser host is essentially a one-button mouse plus modifiers, plus force click in Safari only. Every finger-count idea is **native-host-only**, and there it is a **devdraw patch in Larry's own fork**, with no change to snarf's core. This holds to ADR-0005's "host-scoped divergence".

## 4. Lessons from Oberon and PARC (verified)
- **Oberon interclicks** (ETH Oberon mouse table): MR+ML = delete, MR+MM = copy to caret, ML+MM = copy selection to caret, all three = cancel. Oberon's **2-button mode** has two substitutes for MM: the Ctrl key, or *a second ML click at the same spot*. That is the modifier profile and a "click again without moving" alias, 30 years early. The all-three-buttons cancel is worth stealing: acme has no chord abort.
- **Smalltalk-80** named its buttons red, yellow and blue by *role* (select / contents menu / view menu; Goldberg 1984). This is the precedent for mapping roles, not button positions, onto gestures.
- **Cedar Tioga TIP tables** (`ReadonlyTioga.tip`) defined every binding declaratively, with click-time windows (`ClickTime 200`) and "Blue Down WHILE Red Up" conditions. A TIP-like table is the right shape for snarf's profile maps. snarf already has the hook: profile selection and override go through `/dev/input/ctl` (R-IN-08).
- **Engelbart's NLS**: a 5-key chord keyset under the left hand, a 3-button mouse under the right, and the mouse buttons acting as shift cases (Engelbart Institute, "Design Considerations…", 1973). Snarf's modifier profile is already the cheap Engelbart setup: the left hand on Alt/Cmd while the right hand sweeps.

## 5. Design directions (prior research note's ideas mapped onto snarf)

**D1. Anchor-and-tap chords: native first** (prior note idea 1). *Native: high value, M size. Browser: not possible.*
- devdraw already turns finger taps into buttons. Extend `touches*` so that **while a physical click is held, another finger's tap adds a chord button**: during B1, a 1-finger tap = +B2 (Cut) and a 2-finger tap = +B3 (Paste); during B2, a tap = +B1 (2-1).
- This is **exactly R-IN-06's touch-profile chord grammar** ("a second finger tapped while one finger is held = chord B2"). One vocabulary would then cover touchscreens (browser `touch` profile) and Mac trackpads (devdraw).
- **Conflict to resolve:** R-IN-06 says 2-finger tap = B2 and 3-finger tap = B3. devdraw and macOS say 2 = B3 (secondary) and 3 = B2. Recommendation: **align R-IN-06 to the macOS/devdraw convention**, or make the mapping a TIP-style table.
- The prior note's 1-day Hammerspoon prototype is still the cheapest way to test feel. It injects Option or Command mid-click, which devdraw already reads as chords.

**D2. Chord feedback: visual everywhere, haptic on native** (prior note idea 2). *All hosts, S size.*
- Visual feedback goes in the core and works on both hosts: a cursor shape per live button state (R-GFX-08, settable cursor), and a brief flash when Snarf/Cut/Paste completes.
- Haptics belong in devdraw's input path (`levelChange` when a chord button joins). A "Snarf completed" haptic needs a **core-to-host feedback channel**, which neither `/dev/mouse` nor drawfcall has. *Architect question:* add a 9P `ctl` verb, or keep feedback visual-only? A file-based feedback channel would also let an AI-harness client make its actions perceptible to Larry.

**D3. Gentler warp: one design for both hosts** (prior note idea 4). *M size; depends on the Pointer Lock spike.*
- The core still issues one `moveto` (R-EDIT-25). **The host animates it**: devdraw `setmouse` steps over about 120 ms, and the browser under Pointer Lock moves its self-drawn cursor.
- Add a destination ring, and a haptic tick on native.
- A **warp stack** generalises acme's return-on-delete. "Warp back" should be a core command bound to a gesture or key, not host magic, so that it works identically (and is scriptable) everywhere.
- This turns the Pointer Lock spike from "can we warp" into "can we warp *well*": add the animated jump to its acceptance criteria.
- The prior note warns of macOS's roughly 0.25 s input suppression after a warp. devdraw already re-associates the mouse, but test this on a trackpad.

**D4. Force click = B3 look only** (prior note idea 5). *S size. Native and Safari.*
- This matches Apple's own force-click Look up and is harmless if triggered by accident. **Never map pressure to B2**, which executes text.
- On the browser, use Safari's `webkitmouseforcedown` in the shim's modifier profile. Chrome and Firefox can't see pressure.
- `primaryDeepDrag` makes "press harder mid-sweep = chord" technically possible on native, but it is an experiment, not a default.

**D5. Left-hand second trackpad as a chord pad** (prior note idea 3). *Parked; L size; native-only.*
- It needs the private MultitouchSupport framework, and both pads move the one pointer.
- Cheaper ways to get there: the modifier profile (keyboard as keyset), or the R-IN-07 chordbar on screen. If it is ever built, a helper that **writes chord records into snarf's 9P input namespace** would keep it out of devdraw and the core.
- "Named snarf buffers" is a separate product idea; put it on the roadmap backlog, not here.

**Considered and rejected:** Oberon's "second click at the same spot = MM" conflicts with acme's double-click word select. Pinch → font size is a nice-to-have only (pinch already toggles full screen in devdraw).

## 6. Where this lands in the roadmap
- **M1 (daily driver):** a browser trackpad **event-log spike**, 0.5 day: record what Chrome, Safari and Firefox on macOS deliver for each gesture in §3. This also answers HANDOFF OQ-IN-4. Add the animated warp to the Pointer Lock spike criteria. D2 visual feedback.
- **M2:** D1 and D4 as a devdraw "trackpad mode" patch in `larryr/plan9port`, plus the R-IN-06 mapping alignment and a TIP-style map via `/dev/input/ctl`.
- **Later:** D3 warp stack, the D2 haptic channel, and D5.

## 7. Open questions
**For Larry**
1. Which host do you actually use daily on the Mac: browser, native, or both? D1 and D4 are native-only.
2. Do you want to carry trackpad patches in your `plan9port` fork (and maybe upstream them), or keep devdraw pristine?
3. Should 2 fingers mean B3 (macOS/devdraw) or B2 (R-IN-06 today)?
4. Do you use the 3-finger Look up gesture? It collides with 3-finger tap = B2.

**For the architect**
1. A core-to-host feedback channel (haptic, flash) over 9P: worth it, and in what shape?
2. Warp animation in the host, versus a core-visible "warp back" command: confirm where the split goes.
3. A TIP-style declarative profile table in `profiles.zig`: does it fit the state machine?

## Sources
- Repo: `docs/requirements/05-input.md` (R-IN-02..08, OQ-IN-1); `docs/requirements/02-editor-functional.md` (R-EDIT-25); `docs/spec/adr/0005-two-hosts-one-core.md`; `agents/HANDOFF.md` (design notes, OQ-IN-4); `src/dev/profiles.zig`; `src/dev/input.zig:432`; `docs/acme/man/plan9port/acme.1:675`; `docs/product/spikes/pointer-lock-warp.md`.
- devdraw: https://github.com/larryr/plan9port/blob/337c6ac/src/cmd/devdraw/mac-screen.m ; devdraw(1) https://9fans.github.io/plan9port/man/man1/devdraw.html ; commits 9af9ceca and a9e66ffa (via https://git.inkletblot.com/inkletblot/plan9port/commits/commit/9af9ceca26596d562a3ae89fda70bad9f8822ab0).
- Pike, *Acme: A User Interface for Programmers*: https://plan9.io/sys/doc/acme/acme.html
- Apple: trackpad gestures https://support.apple.com/en-us/102482 ; `NSEvent.PressureBehavior` and `NSHapticFeedbackManager.FeedbackPattern` (developer.apple.com/documentation/appkit).
- Web: MDN Force Touch events https://developer.mozilla.org/en-US/docs/Web/API/Force_Touch_events ; `PointerEvent.pressure` https://developer.mozilla.org/en-US/docs/Web/API/PointerEvent/pressure ; pinch = ctrl+wheel https://danburzo.ro/dom-gestures/ , https://bugzilla.mozilla.org/show_bug.cgi?id=1052253 ; no trackpad touch events https://stackoverflow.com/questions/68808218 ; mdn/browser-compat-data (Safari-only force events).
- Oberon: https://en.wikibooks.org/wiki/Oberon/ETH_Oberon/mouse ; Smalltalk-80: Goldberg, *The Interactive Programming Environment* (1984) http://stephane.ducasse.free.fr/FreeBooks/TheInteractiveProgrammingEnv/TheInteractiveProgrammingEnv.pdf ; Tioga TIP: https://xeroxparcarchive.computerhistory.org/cyan/cedar6.1/tioga/.ReadonlyTioga.tip!1.txt ; Engelbart: https://dougengelbart.org/content/view/134 (site timed out on re-fetch; quoted via search summary).
- Prior research note: `/workspace/research/acme-trackpad.md`. Its BetterTouchTool, Hammerspoon and MultitouchSupport claims were not re-verified.
