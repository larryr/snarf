# SnarfDev2 test plans

Owner: SnarfDev2 (test engineer). Plans trace test cases to requirement IDs (`docs/requirements/`), ADRs (`docs/spec/adr/`) and roadmap issues (#8–#23). Plans are written before tests; tests land via PRs on `snarfdev2/*` branches.

## How to run (baseline `e4f006f`, Linux, Zig 0.16.0)
- `zig build test --summary all` — 743/743 pass, ~5 s (modules: ninep, shim, draw, core, dev, host, origin, tools/origin acceptance, …)
- `zig fmt --check src build.zig` — clean
- `zig build` (wasm + www) and `zig build native` — succeed; no bundled devdraw yet (#19)
- `node tools/smoke_wasm.mjs` — needs Node ≥ 22 (fails on Node 20)

## Index
| File | Issue | Milestone |
|---|---|---|
| [M0-08-ci.md](M0-08-ci.md) | #8 CI | M0 |
| [M0-09-restoremouse.md](M0-09-restoremouse.md) | #9 Del warp-back | M0 |
| [M0-10-walkthrough.md](M0-10-walkthrough.md) | #10 native walkthrough | M0 |
| [M1-11-native-fs.md](M1-11-native-fs.md) | #11 native file server | M1 |
| [M1-12-clipboard.md](M1-12-clipboard.md) | #12 native clipboard | M1 |
| [M1-13-builtins.md](M1-13-builtins.md) | #13 Sort/Zerox/Kill/Exit | M1 |
| (todo) M2 #14–#18, M3 #19–#23 | | |

## Traceability matrix
| Requirement / decision | Test cases |
|---|---|
| R-BLD-03 | CI-01..04, CI-10 |
| R-OV-09 (browser frozen, must build/test) | CI-05, CI-07, NFS-17, CB-09 |
| ADR-0005 amendment Risks | CI-05, CI-07 |
| ADR-0006 (network-free test, devdraw order) | CI-08, CI-11, walkthrough 1–3 |
| R-EDIT-02 | BI-01..13, walkthrough 4 |
| R-EDIT-03 | NFS-03, walkthrough 8 |
| R-EDIT-05..10 | walkthrough 9–17 |
| R-EDIT-11/12 | BI-06, BI-07, NFS-06, walkthrough 19–20 |
| R-EDIT-14 | CB-02..06, CB-10 |
| R-EDIT-15 | NFS-02, NFS-05..10, BI-09 |
| R-EDIT-16 / R-P17-5 | NFS-11..13 |
| R-EDIT-17 + process rule 1 | NFS-14, BI-12 |
| R-EDIT-25 | RM-01..10, walkthrough 8, 12, 21 |
| R-9P-07 | CB-01..08 |
| R-9P-14 | NFS-11 |
| ADR-0005 §2 | NFS-01, NFS-15 |

## Open questions for PM (tracked here until answered)
See the report to SnarfProdd 2026-10-14; IDs Q1–Q7 are referenced from the plans.
