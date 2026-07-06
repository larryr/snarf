# R-07 — Constraints & Non-Goals

Status: **Draft v1**

## 1. Constraints

| ID | Constraint |
|----|-----------|
| R-CON-01 | **Standard library bias**: the WASM module uses the Zig standard library only. Any exception requires an ADR amendment to ADR-0002 with a named justification. Embedded *assets* (fonts) are not libraries and are permitted with license review. |
| R-CON-02 | Everything browser-specific lives behind the device layer / JS shim boundary (R-OV-03). The editor core and 9P kernel MUST compile and unit-test natively (no browser) — this is what makes the std-only rule cheap to keep. |
| R-CON-03 | Browser sandbox is respected as designed: no attempt to escape same-origin policy, no third-party fetch proxying in v1 (OQ-9P-2), host FS access only by user gesture (R-9P-09). |
| R-CON-04 | Plan 9 fidelity is a means, not an end: where the browser makes a Plan 9 behavior impossible (fork/exec, real ptys), Snarf documents the divergence rather than emulating Unix. |
| R-CON-05 | License: Snarf's own code under MIT (or repository owner's choice — confirm); imported Plan 9-derived algorithms/text respect the Lucent/MIT lineage of plan9port with attribution. |

## 2. Non-goals (v1)

| ID | Non-goal |
|----|----------|
| R-NG-01 | Not a Plan 9 emulator or a full drawterm: no kernel, no processes, no rio. Snarf is one application plus a namespace. |
| R-NG-02 | No server-side session state: the origin 9P export is optional and stateless from Snarf's perspective; everything needed to run lives in the static assets. |
| R-NG-03 | No shell / arbitrary command execution (see R-EDIT-18); no `win` terminal windows in v1 (OQ-EDIT-3). |
| R-NG-04 | No collaborative editing / multi-user sync in v1. |
| R-NG-05 | No mobile-first UI redesign: touch works (R-IN-06) but the layout remains ACME's column model. |
| R-NG-06 | No syntax highlighting, LSP, or completion in v1 — faithful ACME first; such tooling should later arrive *through the namespace* (external programs), as ACME intended. |

## 3. Revision log

- **v1** — initial.
