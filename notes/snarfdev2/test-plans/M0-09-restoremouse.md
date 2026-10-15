# Test plan: #9 Return-after-Del warp (savemouse/restoremouse)

**Issue:** #9 · **Requirements:** R-EDIT-25 (warp requested by core, honoured per host; last unported site `util.c:384-408`, `cols.c:150/178`), R-OV-03, ADR-0005 amendment item 2 · **Status:** draft

Harness: headless editor + `warp.MouseSink` (`src/core/warp.zig`) served over a `ninep` pipe as `/dev/mouse`; assert on `MouseSink.last`.

| ID | Type | Scenario | Expected | Traces |
|---|---|---|---|---|
| RM-01 | unit | Pointer at P0; a pop-up window (e.g. `+Errors`) is created by `Column.add` with the pointer moved into it (savemouse) | Editor records P0 and the new window as `mousew` | #9, R-EDIT-25 |
| RM-02 | unit | `Del` that same window (`Column.close`) | `MouseSink.last == P0` (restoremouse warp emitted) | #9, R-EDIT-25 |
| RM-03 | unit | Delete a *different* window than the saved one | No restore warp; saved state unchanged (acme: only if `w == mousew`) | R-EDIT-25, util.c |
| RM-04 | unit | Pointer moved by user after pop-up opened (acme checks the pointer is still inside the window) | Restore **only if** pointer still inside the pop-up; otherwise no warp (PM Q3, acme) | R-EDIT-25 |
| RM-05 | unit | Saved window destroyed by another path (Delcol, Load replacing layout) | `dropTextRefs` clears fields; no dangling pointer, no warp; runs clean under Debug safety | #9 |
| RM-06 | unit | Two pop-ups in sequence; delete second, then first | Nested pop-ups: deleting the innermost restores to its own saved point (PM Q3) | R-EDIT-25 |
| RM-07 | unit | Host with no warp (browser `/dev/mouse` write is a no-op / divergence) | Core still requests; no error surfaces | R-EDIT-25 per-host |
| RM-08 | regression | Existing warp tests (open, look hit, layout move) | Still pass | R-EDIT-25 |
| RM-09 | review | One R-EDIT-25 revision-log line added; "permanently impossible" comments re-cited (`rg -n "permanently impossible" src`) | Present / none stale | #9 |
| RM-10 | manual (native) | Checklist step 21: trigger `+Errors`, Del it | Pointer returns to origin | #9, checklist #21 |
