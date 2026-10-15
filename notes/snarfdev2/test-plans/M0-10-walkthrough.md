# Test plan: #10 Guided manual walkthrough on native

**Issue:** #10 · **Requirements:** R-EDIT-05..12, R-EDIT-25 · **Checklist:** `notes/snarfprod/checklists/native-first-run.md` · **Blocked by:** #19 (bundled devdraw)

Role of test engineering: (1) dry-run the checklist on Linux/X11 plan9port devdraw where possible before Larry, (2) give each step an automated headless twin so the manual run only covers what needs a human, (3) triage results into issues.

| Checklist step | Manual check | Automated twin (headless) | Traces |
|---|---|---|---|
| 1–3 | build, devdraw resolution order, cwd independence | `Conn.devdrawPath` unit test with env/fs stubs (ADR-0006 order) — see #19 | ADR-0006, R-OV-09 |
| 4 | root tag & `/` dir window | assert root tag text `Newcol Kill Putall Dump Exit` | R-EDIT-02 |
| 5–7 | files, Put/Get/Putall, Dump/Load | #11 plan NFS-* | R-EDIT-15/16 |
| 8 | dir windows + warp on open | dirwin open → `MouseSink.last` inside new window | R-EDIT-03, R-EDIT-25 |
| 9–10 | New, point-to-type, double-click select | existing Gesture/textselect tests; add native input-pump replay | R-EDIT-05/07 |
| 11–13 | Look, B3 next match + warp | look.zig test asserting warp target | R-EDIT-08, R-EDIT-25 |
| 14–17 | chords Cut/Paste/Snarf/2-1 via modifier profile P2 | scripted `/dev/mouse` button sequences through devdraw input decode | R-EDIT-09/10, R-IN-* |
| 19–20 | Edit, Undo/Redo grouping | edit + undo tests | R-EDIT-11/12 |
| 21 | Del warp-back | #9 RM-02 | R-EDIT-25 |
| 22 | clipboard | #12 plan | R-EDIT-14 |
| 23–26 | Cmd keys, Retina, resize, free notes | manual only; record | R-IN-*, R-GFX-05 |

Exit criteria: results table filled (pass / fail / expected-fail), top-3 blockers recorded, an issue per unexpected failure, each tagged with checklist step number.
