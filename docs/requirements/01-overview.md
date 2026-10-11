# R-01 — Overview & Vision

Status: **Draft v4** (iterated: /dev/draw, mouse-emulation, two-hosts, and native-primary
decisions folded back in — see revision log)

## 1. What Snarf is

**Snarf** is a port of **ACME**, the Plan 9 user interface for programmers, rewritten from
scratch in **Zig**, compiled to **WebAssembly**, and running entirely inside a **browser
instance**. The name comes from Plan 9's term for the cut/copy buffer (`/dev/snarf`) — the
clipboard — which is also one of the first browser features Snarf exposes through its file
namespace.

ACME's central idea is that *everything is a file* and *text is the interface*: windows are
files, commands are text you execute with the mouse, and external programs integrate by
reading and writing a file tree. Snarf preserves that idea but replaces the Plan 9 kernel
with the browser: the DOM, the clipboard, host storage, and the origin web server are all
presented as **9P file servers** mounted into a single namespace that the editor — and any
program scripted against it — can use.

## 2. Vision statement

> A programmer opens a single web page and gets a complete ACME environment: real ACME
> mouse-and-text semantics, a Plan 9-style namespace where `/dev/dom` is the page it runs
> in, `/dev/snarf` is the system clipboard, `/mnt/host` is a directory the user granted from
> their local disk, and `/n/origin` is whatever file tree the web server chooses to
> export. No install, no server-side session state, no JavaScript framework — one `.wasm`
> module, one small JS shim, one HTML page.

**v4 note:** this founding vision describes the **zero-install showcase host** (browser),
kept exactly as written for history and because the core (R-OV-03) stays host-neutral by
design. It is no longer the **daily-driver** vision: per ADR-0005's amendment (2026-10-11,
native primary + browser freeze), the native host — real ACME semantics, real mouse warping,
real local processes, via `devdraw` — is where day-to-day editing happens. The browser
remains this vision statement's host: it keeps building and passing tests, but gets no new
features (ADR-0005 amendment §2).

## 3. Top-level requirements

| ID | Requirement |
|----|-------------|
| R-OV-01 | Snarf SHALL implement the ACME editing model (columns, windows, tag lines, execute/look mouse language) as specified in [02-editor-functional.md](02-editor-functional.md). |
| R-OV-02 | Snarf SHALL be written in Zig and compile to a WebAssembly module that runs in an unmodified evergreen browser (see R-06). |
| R-OV-03 | All access to resources outside the WASM linear memory SHALL be mediated by 9P file servers mounted in a per-instance namespace (see R-03). Direct ad-hoc JS calls from the editor core are prohibited; only the device layer's shim boundary may touch the browser. |
| R-OV-04 | Snarf SHALL expose, at minimum, these namespaces: the DOM (`/dev/dom`), browser features (`/dev/snarf`, `/dev/storage`, …), the host file system via the HTML5 File System Access API (`/mnt/host`), and an origin-server 9P export (`/n/origin`) when the origin offers one. |
| R-OV-05 | Graphics SHALL be drawn through a `/dev/draw` device modelled on Plan 9's draw protocol (decision ADR-0003; requirements in [04-graphics.md](04-graphics.md)). |
| R-OV-06 | The full three-button mouse language, **including chords**, SHALL be usable on hardware without three physical buttons (trackpads, touch screens) via the emulation model in [05-input.md](05-input.md) (decision ADR-0004). |
| R-OV-07 | Snarf SHALL be buildable on macOS and Linux with the Zig toolchain alone (decision ADR-0001; requirements in [06-platform-and-build.md](06-platform-and-build.md)). |
| R-OV-08 | External dependencies are biased strongly toward **Zig standard library only** (decision ADR-0002; constraints in [07-constraints-non-goals.md](07-constraints-non-goals.md)). |
| R-OV-09 | **Two hosts, one core** (decision ADR-0005, amended 2026-10-11): Snarf SHALL run on a **native host** — the **primary**, daily-driver target — whose display and input server is **plan9port `devdraw`** (indefinitely, per the amendment; not a provisional choice), AND on the browser host (R-OV-04 namespaces, zero install), now a **frozen secondary**: it keeps building and passing tests but receives no new features. Both run beneath the same unchanged, host-neutral editor core. ACME behaviors a host cannot honour (mouse warping, process execution, uncapturable keys) are recorded *per host*; the native host honours the paper where the browser cannot. |

## 4. Glossary

| Term | Meaning |
|------|---------|
| **ACME** | Rob Pike's Plan 9 editor/window system/shell hybrid. |
| **9P (9P2000)** | Plan 9's file-service protocol: a client walks, opens, reads, and writes named files served by a server; the baseline version negotiated is `9P2000`. |
| **Namespace** | The per-process mount table binding 9P servers into one file tree. |
| **snarf buffer** | Plan 9's clipboard, exposed as the file `/dev/snarf`. |
| **plumbing** | Plan 9's rule-driven message routing for "take this text to the right application" (right-click on a file name opens it, on an URL follows it, …). |
| **/dev/draw** | Plan 9's kernel graphics device; clients allocate images and send compiled draw operations to it. |
| **B1 / B2 / B3** | Mouse buttons 1 (left, select), 2 (middle, execute), 3 (right, look/plumb). |
| **chord** | Pressing a second mouse button while the first is held: B1+B2 = cut, B1+B3 = paste. |
| **JS shim** | The single, small, hand-written JavaScript file that instantiates the WASM module and services the device layer (canvas, events, clipboard, FS Access API, WebSocket). |
| **origin** | The web server the Snarf page was loaded from, in the browser same-origin sense. |

## 5. Document map

Requirements (this directory) say **what** and **why**; specifications
([../spec/](../spec/)) say **how**. Decisions with alternatives are captured as ADRs in
[../spec/adr/](../spec/adr/). Requirement IDs (`R-XX-nn`) are stable; specs cite them.

## 6. Open questions

- OQ-OV-1: Should Snarf also run under WASI/native (headless, for tests) as a hard
  requirement, or is the freestanding+browser target the only supported one? *Current
  stance: native test builds are a build-system nicety (spec 06), not a product requirement.*
- OQ-OV-2: Is multi-tab / multi-window (one namespace shared by several browser tabs via
  `SharedWorker`) in scope for v1? *Current stance: out of scope, revisit after v1.*

## 7. Revision log

- **v1** — initial draft: vision, top-level requirements, glossary.
- **v2** — iterated per ADR-0003/ADR-0004: added R-OV-05 (draw contract) and strengthened
  R-OV-06 to make *chords* explicitly mandatory on button-less hardware; added R-OV-03's
  prohibition on ad-hoc JS calls after the architecture review.
- **v3** (2026-09-14) — ADR-0005: added R-OV-09 (two hosts, one core; native host =
  plan9port `devdraw` or compatible). Prompted by the R-02 v4 paper re-verification
  showing which paper behaviors the browser sandbox can never honour (R-EDIT-25 warping,
  processes, key capture). The browser host and its vision statement (§2) stand.
- **v4** (2026-10-11) — ADR-0005 amendment (native primary, browser frozen; `devdraw`
  indefinite), confirmed by Larry: reworded R-OV-09 to make native the primary/daily-driver
  host and the browser a frozen secondary; added a §2 note distinguishing the founding
  zero-install *showcase* vision (unchanged, browser) from the *daily-driver* target (native).
  No change to R-OV-03/04 (core stays host-neutral; browser namespaces are unaffected).
