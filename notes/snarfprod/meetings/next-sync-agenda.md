# Next sync agenda (Larry ↔ SnarfProdd)

*About 30–45 minutes. Prepared 2026-10-11. Previous: [2026-10-11 follow-up](2026-10-11-followup.md).*

1. **Checklist results and top-3 blockers** (15 min): [native first-run checklist](../checklists/native-first-run.md).
   - Walk through the passes, the fails and the surprises.
   - Agree the top 3 blockers. **They set the M3 order** and the next NEXT-PHASES picks. The native file server and native clipboard are the likely leaders.
2. **M5 requirements draft review** (10 min): [m5-ai-harness-requirements-draft.md](../requirements/m5-ai-harness-requirements-draft.md). Its §10 questions:
   - greenlight timing;
   - local agent first;
   - default grant;
   - queue vs reject while the human types;
   - attribution mark;
   - audit retention;
   - `kbd hold`;
   - M4-before-M5.
3. **Input guide review and the R-IN-06 decision** (5 min): [input-mapping-guide.md](../input/input-mapping-guide.md).
   - Confirm the P2 default.
   - Is P3 (hold-and-tap) worth a devdraw patch?
   - Align R-IN-06 to macOS/devdraw (2 fingers = B3, 3 fingers = B2)? If yes, open a requirements PR.
4. **Roadmap v0.2 follow-through** (5 min):
   - PR #5 is merged (`b92d825`).
   - **Done 2026-10-11:** 16 GitHub Issues were created, labelled `roadmap` plus `M0`–`M3`:
     - **M0 (3):** [#8](https://github.com/larryr/snarf/issues/8) CI on push; [#9](https://github.com/larryr/snarf/issues/9) Return-after-Del warp; [#10](https://github.com/larryr/snarf/issues/10) guided native walkthrough.
     - **M1 (3):** [#11](https://github.com/larryr/snarf/issues/11) native file server; [#12](https://github.com/larryr/snarf/issues/12) system clipboard; [#13](https://github.com/larryr/snarf/issues/13) Sort/Zerox/Kill/Exit.
     - **M2 (5):** [#14](https://github.com/larryr/snarf/issues/14) native process service; [#15](https://github.com/larryr/snarf/issues/15) remote allow-list ADR; [#16](https://github.com/larryr/snarf/issues/16) pipes; [#17](https://github.com/larryr/snarf/issues/17) Kill and long-running output; [#18](https://github.com/larryr/snarf/issues/18) headless 9P server.
     - **M3 (5):** [#19](https://github.com/larryr/snarf/issues/19) Zig-built devdraw + snarf-native; [#20](https://github.com/larryr/snarf/issues/20) hold-and-tap chords; [#21](https://github.com/larryr/snarf/issues/21) native polish; [#22](https://github.com/larryr/snarf/issues/22) keyboard/IME; [#23](https://github.com/larryr/snarf/issues/23) structure pass.
     - Skipped as shipped, parked or deferred: Retina, `.app`, Pointer Lock, M4, M5.
   - **Project board: Larry needs to create it.** The GitHub connector has no Projects access (403). Suggested setup:
     - a Project v2 named "snarf roadmap", owned by larryr;
     - a single-select field "Milestone" with M0–M3;
     - add issues with `label:roadmap`.
     - To discuss: columns, and owners (Claude pipeline vs Larry vs SnarfProdd).
   - The M3 done-criterion #5 fix (ADR-0006 devdraw order) plus the stale status line are in [PR #7](https://github.com/larryr/snarf/pull/7), awaiting merge.
5. **M4 timing** (2 min): still deferred. Revisit only if item 2 greenlights M5, since M5 depends on M4.

**Outputs:**
- M3 order;
- M5 go/no-go;
- R-IN-06 call;
- board setup and owners.
