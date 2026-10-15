# Test plan: #13 Small builtins Sort, Zerox, Kill, Exit

**Issue:** #13 · **Requirements:** R-EDIT-02 (tag words), R-EDIT-17 + roadmap process rule 1 (each builtin gets a served `ctl` verb tested via `/mnt/snarf-self`), R-EDIT-11 (undo across views) · Baseline: none of these words appear in `src/core/exec/builtins.zig` today.

| ID | Type | Scenario | Expected | Traces |
|---|---|---|---|---|
| BI-01 | unit | `Exit` with all windows clean | editor signals quit to host (testable hook, no process exit in tests) | #13 |
| BI-02 | unit | `Exit` with a dirty window | warning in `+Errors` naming dirty windows; no quit; second `Exit` quits (acme two-strike) — **Q4** | #13 |
| BI-03 | unit | `Sort` in column with windows `c b a` | order `a b c` by name; layout heights preserved per acme | #13 |
| BI-04 | unit | `Sort` with duplicate names / dir vs file | stable order, defined tiebreak | #13 |
| BI-05 | unit | `Zerox` | second window, same File; both tags show name | #13 |
| BI-06 | unit | Type in view A | appears in view B; dirty flag shared; selections independent | #13, R-EDIT-11 |
| BI-07 | unit | Undo in view B of edit made in A | reverts in both | R-EDIT-11 |
| BI-08 | unit | Del one Zerox view | other view survives, File not freed; Del last view triggers dirty check | #13 |
| BI-09 | unit | `Put` from one view | both clean | R-EDIT-15 |
| BI-10 | unit | `Zerox` on directory window / `+Errors` | per acme (allowed?) — record behaviour | #13 |
| BI-11 | unit | `Kill` with no running processes | no-op, no error (or message) — wired not crashing | #13, #17 |
| BI-12 | unit | Each builtin via `/mnt/snarf-self/<id>/ctl` verb | same effect as tag word | process rule 1, R-EDIT-17 |
| BI-13 | manual | native: each word from tag | works; Exit closes devdraw window cleanly, no orphan devdraw process | #13 |
