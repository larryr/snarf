# Working notes — phase-plan review after the rhun spike (2026-10-03)

**Status: DRAFT / in-progress discussion, not yet committed to `NEXT-PHASES.md` or HANDOFF.**
Captures the Larry ↔ Sonnet-session ↔ Fable-review discussion so the final doc updates
don't have to be re-derived. Fold the settled parts into `agents/NEXT-PHASES.md` +
`agents/HANDOFF.md` once this stabilizes, then this file can be deleted (git keeps history).

## Background

`agents/reports/spike-rhun-self-drawn-frame.md` (landed today, issue #1) proposed three new
ideas beyond the existing Tier 1/2/3/4 plan in `NEXT-PHASES.md` (written 2026-09-14, before
the spike): a Pointer Lock spike for browser-host mouse warping, building `devdraw` in-tree
instead of requiring a plan9port install, and a parked webview-shell backlog line. A first
Fable review (read-only) analyzed ADR/requirement impact in depth and proposed threading the
Pointer Lock spike into Tier 1 alongside Put/Get.

## Decision 1 — sequencing: finish the existing Tier 1 queue first, defer all three new ideas

**Status: DECIDED.** Larry's call: continue the existing planned phases (Put/Get/Putall →
external commands via `/bin` → remaining builtins, unchanged) before picking up any of the
spike's three new ideas, unless one is architecturally significant — and none of them are:

- Pointer Lock stays within `dev/input.zig` + `web/shim.js` (host-local; doesn't touch
  `core`/`draw`/`ninep`).
- devdraw-in-tree is a build/dependency mechanism question (still two-hosts-one-core, still
  an unlinked sibling process) — ADR-level (needs an ADR-0002 amendment) but not
  architecture-level.
- webview shell was already backlog-only with no wave proposed.

**Fable gut-check (second pass) confirmed this**, with two additions folded in:
1. When the host-command allow-list ADR gets written (Tier 1 item 2), add one sentence on
   trust-by-origin-locality ("a loopback/in-process origin may be configured as fully
   trusted") so the parked webview-shell idea doesn't later force an ADR rewrite.
2. Each parked line in `NEXT-PHASES.md` should carry its own gating decision, not just a
   pointer to the spike report:
   - Pointer Lock → gated on the Esc-conflict resolution (see Decision 2); prototype before
     promising (Safari + Chromium both, since behavior differs).
   - devdraw-in-tree → gated on fetch-vs-vendor; first ADR-0002 amendment, narrowly worded.
   - webview shell → gated on ADR-0005 option 2 revisit; needs the warp bridge; no wave.
3. Don't lose the spike's **headless scripted driver** idea (§6) — it's not rhun-specific,
   it's a standalone ~150-line platform-free test driver; attach it as a sub-bullet under
   Tier 4 item 11 (CI), not parked with the other three.

**Cost of deferring confirmed as near-zero**: Tier 1's actual work (Put/Get, `/bin` exec,
builtins) never touches `dev/input.zig`/`shim.js` — nothing gets harder or riskier by
waiting. Running Pointer Lock in parallel (the first review's suggestion) would have
stacked three separate Larry-decisions at once (Esc remap, `$home`, allow-list) for no Tier
1 benefit — deferring is the cleaner call.

**Done** — `agents/NEXT-PHASES.md` updated in place (uncommitted, working tree only as of
this writing): header revision date, item 2's loopback-trust hedge sentence, item 6's stale
Kdown line removed + the `/dev/snarf` "still open" correction (it was wrongly marked done),
item 11's headless-driver sub-bullet, and the new "Parked — rhun spike, 2026-10-03" section
(four items: Pointer Lock, devdraw-in-tree, webview shell, native frame — each with its
gating decision). Not yet committed — per CLAUDE.md, `NEXT-PHASES.md` isn't the HANDOFF
standing exception, so it needs a branch + merge, not a direct `main` commit.

## Decision 2 — the Pointer Lock / Esc conflict

Browsers reserve Esc to exit Pointer Lock. Acme's own Esc (R-IN-10, S-04 §3 `Kesc`,
`text.c:836-846`, ported in `core/text/typing.zig:25`) selects the most recently
typed/modified text — a convenience binding, not part of the mouse-language/chord identity
that defines acme. **Conclusion: remapping or reinterpreting this is not architecturally
significant, and it is browser-host-only** — the native host has no Pointer Lock, so
devdraw keeps real Esc untouched regardless of what the browser host does.

Two paths discussed:

**A. Pick a different key** for the browser host's "select recently typed" trigger. Must be
non-printable (can't sacrifice a character the user needs to type — that's a harder
constraint than preserving Esc's binding) and not already bound elsewhere in acme.
Candidates and their snags:
- Function key (F2/F4/F8/F9 look unclaimed by default browser chrome in Chrome/Firefox/
  Safari) — but Mac laptops default the F-row to media keys, needs `fn` held unless the
  user has toggled "use F-keys as standard function keys" in System Settings.
- Insert — clean and unused, but physically absent on most laptops including Mac's.
- Caps Lock — ergonomically matches the ask exactly (same reason vim users remap Caps Lock
  *to* Esc), but has a history of inconsistent keydown/keyup delivery across browsers/OSes
  since the OS wants to toggle lock state; needs empirical testing before trusting it.
None of these should go into a spec without a quick empirical check in Safari (Larry's
primary test browser per HANDOFF) first.

**B. Don't remap the key — intercept the browser's lock-loss itself as the signal.** The
only thing that normally drops Pointer Lock is Esc. Instead of fighting the browser for the
raw keydown (which it swallows), treat a `pointerlockchange`-to-unlocked event as "Esc was
pressed," as long as the unlock wasn't self-initiated (track a flag for deliberate
programmatic unlocks). This keeps acme's actual keybinding (Esc) completely unchanged — zero
spec divergence to document or explain to a user who already knows acme — at the cost of
also dropping lock on that press (which a real Esc exit would have done anyway; next pointer
move needs a click to re-lock). Soft spot: window/focus loss (alt-tab) also drops lock and
isn't Esc — small chance of a false-positive "select recently typed" trigger on focus loss;
low-stakes (just an unwanted pre-selection) but worth naming in the eventual spec note.

**Leaning: B** — it removes the question from the spec entirely rather than adding a new
keybinding to document/test/explain.

**Status: CONFIRMED (Fable sync, 2026-10-03).** Option B is mechanically sound, with two
guards Fable called **mandatory, not optional**:

1. **Focus guard.** Pointer Lock drops for essentially one other class of cause besides
   Esc: focus/visibility loss (alt/Cmd-Tab, clicking browser chrome, DevTools taking focus,
   a permission prompt, window minimize/sleep, fullscreen exit). It does *not* drop on
   scroll, resize, or ordinary key combos. Esc-exit leaves document focus alone; every
   false-positive cause takes focus away — so at `pointerlockchange`-to-null time, check
   `document.hasFocus()` (or that a `blur`/`visibilitychange→hidden` arrived since lock was
   acquired) and only treat the loss as Esc if focus never left.
   - **Correction to this doc's earlier "low-stakes" framing**: a false positive is not just
     an unwanted pre-selection — acme's Esc makes the *next keystroke replace* the
     selection, so "typed, alt-tabbed mid-run, came back, kept typing" would silently delete
     the run. This is why the guard is mandatory.
2. **Dedupe rule.** Some browsers may also deliver the Esc `keydown` to the page while
   exiting lock. Rule: while locked, the shim does **not** forward Esc as `Kesc` over
   `/dev/kbd` — lock-loss is the only Esc channel while locked; once unlocked, Esc behaves
   normally again. Verify empirically in Safari + Chromium (same "prototype before
   promising" gate the spike already calls for).

This *is* the standard pattern (FPS-style web apps use `pointerLockElement === null` +
`hasFocus()` the same way) — there's no better signal available; the Pointer Lock API has
no "why was lock lost" field. The **Keyboard Lock API** (`navigator.keyboard.lock(['Escape'])`)
is a real but separate future enhancement — lets a fullscreen page capture Esc as a real
keydown without dropping lock — but it's Chromium-only, fullscreen-only, not a Safari
option, so it can't be *the* design; doesn't conflict with B, worth a one-line mention as a
later enhancement.

Option A (dedicated replacement key) is **not preferred**: its "also drops lock" cost framing
turns out backwards — under A, an acme user's muscle-memory Esc press still drops lock
(unavoidable, browser-level) *and* does nothing useful (no select-recently-typed), the worst
of both; under B the habitual gesture keeps working.

**No ADR needed** — host-local shim behavior (`dev/input.zig` + `shim.js`), consistent with
S-04's existing stance that warp is "a courtesy, never a precondition." When the Pointer
Lock wave is eventually picked up, the spec note lands in **S-04 §3** (one-clause pointer
from **R-IN-10**) and must record: the focus guard, the Kesc-not-forwarded-while-locked
dedupe rule, and the replace-on-type hazard as the guard's rationale (not just as a nicety).
