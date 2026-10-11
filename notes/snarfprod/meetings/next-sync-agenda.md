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
   - Next: create **GitHub Issues** for the M0–M3 items and a **Project board** (columns, owners: Claude pipeline vs Larry vs SnarfProdd).
   - Fix the roadmap's M3 done-criterion #5 wording to match ADR-0006's final devdraw order (bundled before `$PLAN9`). This needs a small PR.
5. **M4 timing** (2 min): still deferred. Revisit only if item 2 greenlights M5, since M5 depends on M4.

**Outputs:**
- M3 order;
- M5 go/no-go;
- R-IN-06 call;
- issue/board plan.
