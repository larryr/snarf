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
| [M3-45-warp-focus.md](M3-45-warp-focus.md) | #45 warp to focused window | M3 |
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
| R-EDIT-25 | RM-01..10, WF-01..12, walkthrough 8, 12, 21 |
| R-9P-07 | CB-01..08 |
| R-9P-14 | NFS-11 |
| ADR-0005 §2 | NFS-01, NFS-15 |

## PM decisions (SnarfProdd, 2026-10-14)
Default rule: when unsure, use ACME behaviour.
- Q1 mount point: follow #11 spec text; conflicts with checklist step 4 → test TBD pending Larry.
- Q2 clipboard: test native devdraw Trdsnarf/Twrsnarf; browser keeps Clipboard API; PM fixes R-9P-07 wording.
- Q3 Del warp-back: restore only if pointer still in pop-up. ~~nested → innermost saved point~~. **Superseded 2026-10-31:** a single ACME save slot (see below).
- Q4 Exit two-strike, ACME Sort order, Zerox as ACME allows.
- Q5 Put atomic temp+rename, old file kept on failure; new files 0666 &~ umask.
- Q6 spec S-02 authoritative for R-P17-5.
- Q7 Node 22 pinned; native build in a separate CI job.
- #20 plans on hold (R-IN-06 undecided).

## Product decisions (Larry via SnarfProdd, 2026-10-30)
- #45: the pointer warps to the focused item. Opening or focusing a new window (`+Errors` included) warps into it, and Del warps back, giving a zero-travel round trip. The `+Errors` opt-out is out of scope. See M3-45-warp-focus.md.

## Product ruling (SnarfProdd, 2026-10-31): restoremouse is exact ACME (util.c:383-408)
- Deleting ANY window clears the saved pointer state, so a later Del of the original pop-up does not warp (RM-03).
- There is one save slot. A from P0, then B from P1: Del B warps to P1, then Del A does nothing (RM-06). This replaces "innermost / stack".
- The RM-04 pointer-inside gate (Q3) is kept unless the PM rules otherwise.
