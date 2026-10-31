# Test plan: #45 warp the pointer to the focused window (acme parity)

Issue: #45 (M3). Decision (Larry via SnarfProdd, 2026-10-30): **the pointer warps to the currently focused item.** Opening or focusing a new window, `+Errors` included, warps the pointer into it (acme), and Del warps back (#9 / PR #43). Together they make a zero-travel round trip. The `+Errors` opt-out setting is **out of scope** (follow-up).

Requirement: R-EDIT-25 (the paper's warps). Builds on #9 (`core/restoremouse.zig`, PR #43). Tests: `src/core/warp_focus_test.zig`, branch `snarfdev2/warp-focus-tests`, skipped behind `warp_focus_landed` until #45 lands.

## acme reference (larryr/plan9port@337c6ac)
- `coladd` (cols.c:150-154): `savemouse(w)`, then `if(!mousectl->m.buttons) moveto(mousectl, addpt(w->tag.scrollr.max, Pt(3, 3)))`, i.e. "near the button, but in the body". Every new window goes through `coladd`: New, Newcol, B3 open of a new file (look.c:854 `makenewwindow`), `+Errors` (util.c:98), Zerox, Load.
- `openfile` on an already-open or just-loaded file (look.c:896-897): `if(e->jump) moveto(... frptofchar(&t->fr, t->fr.p0) + (4, h-4))`. snarf already ports this (`loadaddr.zig`, `warp.toSelection`).
- `colclose` (cols.c:178): `restoremouse(w)`, ported by #43. Exact ACME (PM 2026-10-31): it warps back whenever the deleted window is the saved one, with no pointer-inside check. ~~Q3's "still inside the pop-up" gate~~ is superseded.
- `winmousebut` (wind.c:292, after colgrow/coldragwin) is a layout-focus warp. snarf has no user-reachable layout box yet (colgrow `but==2/3` deferred), so it is out of scope here and listed as WF-11 for later.

## Cases
| ID | Type | Scenario | Expected | Trace |
|---|---|---|---|---|
| WF-01 | unit | Pointer at P0 in the main window; execute `New` (the cmd_window `new` builtin, no arg) | One `/dev/mouse` write; the point is inside the new window's `r` | #45, cols.c:153 |
| WF-02 | unit | B3 open of a not-yet-open file (`openFile`, `jump=false` so only the creation warp can fire) | A warp lands inside the new window | #45, look.c:854 → cols.c:153 |
| WF-03 | unit | `+Errors` created (`errors.errorWin`) | A warp lands inside `+Errors` (no opt-out; out of scope) | #45 |
| WF-04 | unit | WF-01's warp point | Equals acme's `w.tag.scrollr.max + (3,3)` (acme parity; PM default rule) | cols.c:153 |
| WF-05 | regression | Focus an already-open window: `openFile` of its name with `jump=true` | Warp lands inside that window (look.c:897; already implemented) | #45 "focus", R-P15-3 |
| WF-06 | regression | Focus an already-open window with an invalid address (`jump` suppressed) | No warp (look.c:887) | look.c:887 |
| WF-07 | unit | **Zero-travel round trip, New:** pointer at P0; New; pointer is where the warp put it; `Del` (the builtin) | A warp **into** the new window happened, and after Del the last write == P0 exactly; net pointer travel zero. Without the warp-in, a no-gate restore alone would also land on P0, so the test checks both | #45 + #9 |
| WF-08 | unit | **Zero-travel round trip, +Errors:** same with `+Errors` | Warp into `+Errors` happened, and after Del the last write == P0 exactly | #45 + #9 |
| WF-13 | unit | **Nested round trip, single slot:** P0 → `+Errors` (pointer follows the warp to pe) → New from there → Del New → Del `+Errors` | Del New warps back to pe; Del `+Errors` does **not** warp to P0, because the slot was overwritten and then cleared (exact ACME, SnarfProdd 2026-10-31) | #45 + #9, util.c:383-402 |
| WF-09 | unit | The user moved out of the new window before Del | **Warps back to P0 anyway** (exact ACME; the Q3 gate is dropped, PM 2026-10-31) | util.c:396 |
| WF-10 | unit | No `/dev/mouse` (`ed.ns == null`, browser/headless): New, +Errors, Del | No error surfaces | R-EDIT-25 per-host |
| WF-11 | deferred | Layout focus (`colgrow`/drag) warps to the tag button (`winmousebut`) | n/a until the layout box is ported | wind.c:292 |
| WF-12 | manual (native) | New, then Del without touching the mouse; `+Errors` from a failing command, then Del | Pointer ends exactly where it started | checklist #21 |

## Notes for whoever lands #45
- acme skips the creation warp while a button is held (`!mousectl->m.buttons`). snarf dispatches commands at all-buttons-up (R-P9-2), so this guard is not unit-tested. Keep it if the warp can fire mid-gesture.
- `openfile.zig` test T12 ("out-of-order or invalid :addr ... issues NO /dev/mouse write") asserts `sink.writes == 0` after opening a NEW window. With #45 the creation warp makes that one write, so T12 must change to "no *selection* warp".
- Nested pop-ups: acme has a single save slot, so New-in-+Errors-then-Del-both restores only the innermost; the outer Del does not warp (SnarfProdd ruling 2026-10-31; RM-06, WF-13). Zero travel holds per pop-up, not for a nested chain.
- WF-01..04, WF-07/08 and WF-13 are gated on `warp_focus_landed` (#45). WF-09 is gated on `acme_exact_restore_landed` (the gate removal in #43). WF-05, WF-06 and WF-10 already hold, so they always run.
- Because exact-ACME restore has no pointer-inside gate, a Del of the saved window lands on P0 even with no warp-in. So WF-07/08/13 also assert that the warp **into** the window happened; otherwise the round trip would pass vacuously.
