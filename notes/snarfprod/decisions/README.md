# Product decisions log (SnarfProdd)

The durable record of product rulings. Each entry gives the date, who decided, the ruling, and where it's enforced. Newer entries win; a changed ruling gets a new entry that names the one it replaces.

| Date | Decided by | Ruling | Where it's enforced |
|---|---|---|---|
| 2026-10-11 | Larry | Local commands on the native host are fully trusted and run as the logged-in user; snarf never switches identity silently (only an explicit `sudo`). The allow-list applies only to remote 9P servers. | Roadmap v0.2, #14, #15 |
| 2026-10-14 | Larry / SnarfProdd | Local native mount follows symlinks (like ACME). Remote exports must refuse symlinks that escape the export root. | #28, #18 |
| 2026-10-14 | SnarfProdd (answers to SnarfDev2 Q1–Q7) | Default to ACME behavior; Put is atomic; new files 0666 masked by umask; Sort uses ACME order; Exit is two-strike. | Test plans in `notes/snarfdev2/test-plans/`, #13 |
| 2026-10-30 | Larry | The pointer warps to the currently focused item, including new windows and `+Errors`, as ACME does; `Del` warps back. An opt-out for `+Errors` is a possible later setting. | #45, PR #46 (WF tests) |
| 2026-10-31 | SnarfProdd, signed off by Larry merging PR #43 | **restoremouse is exact ACME parity** (util.c:383-408). On `Del` of the saved window the pointer warps back **wherever the pointer currently is**: there is no "pointer still inside the pop-up" check. This replaces the earlier Q3 answer ("restore only if the pointer is still in the pop-up"). Any `Del` clears the save (RM-03), and there is a single slot, not a stack (RM-06). | PR #43 (e303142), PR #50, #52; stack idea parked in #51 |
| 2026-10-31 | SnarfProdd (interim, pending Larry on `/` vs `/n/local`) | At native `/`, host directories are never hidden: each name appears once, and `dev/` and `mnt/` list snarf's entries first, then the host's. | #60 |
| 2026-10-31 | SnarfProdd | The `-b` flag stays out of scope, per R-EDIT-22 (point-to-type). It needs a requirements revision before anyone builds it. | #21 |
| 2026-10-31 | SnarfProdd (follows the 2026-10-30 rule) | The pointer also warps into windows created at startup and during `Load`, as acme does. | PR #64 (#45, #53) |
| 2026-10-31 | Larry / SnarfProdd | An unfinished `Put` at quit leaves the file unchanged; partial contents go to `.<name>.snarf-partial` (then `.1`, `.2`, …, never overwriting; `$TMPDIR` fallback), and stderr names the file actually written. | PR #68 (#58) |
