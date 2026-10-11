# docs/product — PM notes and proposals

These are **product-management notes and proposals by SnarfProdd** (Larry's PM agent).
They are **not agreed requirements**: the authoritative requirements, specs and decisions
are still [`docs/requirements/`](../requirements/), [`docs/spec/`](../spec/) and
[`docs/spec/adr/`](../spec/adr/). Anything here that's adopted gets folded into those
documents through the normal process (R-ID revision logs, ADR amendments).

| Document | What it is |
|---|---|
| [state-of-snarf.md](state-of-snarf.md) | Snapshot (2026-10-07, `cf9e30c`): what's built vs. specified, gaps and debt, with file/commit evidence and R-IDs |
| [roadmap.md](roadmap.md) | **v0.2** (2026-10-11, native-primary after the ADR-0005 amendment). Feature roadmap M0–M5: native daily-driver quality for Larry first, AI-harness capabilities later. Includes open decisions. Working notes and proposals live in [`notes/snarfprod/`](../../notes/snarfprod/) |
| [spikes/pointer-lock-warp.md](spikes/pointer-lock-warp.md) | Spike brief: can the browser host honour acme's mouse warps (R-EDIT-25) via the Pointer Lock API? Pass/fail criteria, risks, roadmap impact |
| [research/touchpad-interaction.md](research/touchpad-interaction.md) | Research (2026-10-09): acme chords and warp on Apple Magic/Force Touch trackpads, browser vs. native (`devdraw`) host; Oberon/PARC precedent; five design directions and open questions |
