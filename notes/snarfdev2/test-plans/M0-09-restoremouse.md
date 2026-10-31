# Test plan: #9 Return-after-Del warp (savemouse/restoremouse)

**Issue:** #9 · **Requirements:** R-EDIT-25 (warp requested by core, honoured per host; last unported site `util.c:384-408`, `cols.c:150/178`), R-OV-03, ADR-0005 amendment item 2 · **Status:** draft

Harness: headless editor + `warp.MouseSink` (`src/core/warp.zig`) served over a `ninep` pipe as `/dev/mouse`; assert on `MouseSink.last`.

| ID | Type | Scenario | Expected | Traces |
|---|---|---|---|---|
| RM-01 | unit | Pointer at P0; a pop-up window (e.g. `+Errors`) is created by `Column.add` with the pointer moved into it (savemouse) | Editor records P0 and the new window as `mousew` | #9, R-EDIT-25 |
| RM-02 | unit | `Del` that same window (`Column.close`) | `MouseSink.last == P0` (restoremouse warp emitted) | #9, R-EDIT-25 |
| RM-03 | unit | Pop-up A saved from P0; Del a *different* window B (pointer anywhere) | No warp, **and the saved state is cleared** (`mousew = nil`, util.c:400): a later Del of A with the pointer inside A does **not** warp to P0 (ACME, SnarfProdd 2026-10-31) | R-EDIT-25, util.c:390-402 |
| RM-04 | unit | Pop-up saved from P0; the user moves the pointer **out of** the pop-up, then Dels it (pointer anywhere) | **Warps back to P0 anyway**: restore fires whenever the deleted window is the saved one, with no check on where the pointer is (exact ACME, util.c:396; PM 2026-10-31. Replaces the Q3 "only if still inside" case) | R-EDIT-25, util.c:390-402 |
| RM-05 | unit | Saved window destroyed by another path (Delcol, Load replacing layout) | `dropTextRefs` clears fields; no dangling pointer, no warp; runs clean under Debug safety | #9 |
| RM-06 | unit | **Single save slot.** Pop-up A opened from P0, then pop-up B opened from P1; Del B (pointer in B), then Del A (pointer in A) | Del B warps to P1; Del A does **nothing** (no warp to P0). There is no stack (ACME, SnarfProdd 2026-10-31; replaces "nested → innermost") | R-EDIT-25, util.c:383-402 |
| RM-07 | unit | Host with no warp (browser `/dev/mouse` write is a no-op / divergence) | Core still requests; no error surfaces | R-EDIT-25 per-host |
| RM-08 | regression | Existing warp tests (open, look hit, layout move) | Still pass | R-EDIT-25 |
| RM-09 | review | One R-EDIT-25 revision-log line added; "permanently impossible" comments re-cited (`rg -n "permanently impossible" src`) | Present / none stale | #9 |
| RM-10 | manual (native) | Checklist step 21: trigger `+Errors`, Del it | Pointer returns to origin | #9, checklist #21 |

## Ruling (SnarfProdd, 2026-10-31): keep ACME's exact save/restore semantics
Verified against larryr/plan9port@337c6ac `src/cmd/acme/util.c`. The statics `prevmouse` and `mousew` are at :15-16; `savemouse` (:383-388) overwrites the single slot; `restoremouse` (:390-402) warps only if `mousew == w` and **always** sets `mousew = nil`; `clearmouse` (:404-408) sets `mousew = nil`.
- RM-03: deleting any window clears the slot, so a later Del of the original pop-up does not warp.
- RM-06: single slot. A from P0, then B from P1: Del B → P1; Del A → no warp.
- RM-04 (PM, 2026-10-31, second ruling): **the pointer-still-inside gate is dropped.** Restore happens whenever `mousew == w` (util.c:396), wherever the pointer is. ~~PM Q3 2026-10-14: restore only if the pointer is still inside the pop-up~~ (superseded).
