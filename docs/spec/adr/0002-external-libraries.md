# ADR-0002 — External libraries: Zig std only

Status: **Accepted** · **AMENDMENT PROPOSED (2026-10-11), pending Larry's sign-off — see
"Amendment: fetch the pinned plan9port snapshot to build a devdraw peer executable" below** ·
Satisfies: R-OV-08, R-CON-01

## Context

The brief: "decide on external libraries — but bias should be use only standard libraries
where possible." Candidate temptations and what std already covers:

| Need | Obvious external | Zig std / in-project answer |
|------|------------------|------------------------------|
| allocators, ArrayList/HashMap, sort | — | `std.heap`, `std.ArrayList`, `std.HashMap` |
| UTF-8/unicode | ICU-ish libs | `std.unicode` (enough: ACME needs code points, not grapheme clusters — divergence documented) |
| regex (Edit language) | PCRE, an external regex pkg | **write it**: Plan 9 structural regexps are a small, well-specified engine; every ACME port implements its own (S-05 §5) |
| 9P | a 9p package | **write it**: the protocol is tiny and central to the project's identity; owning it is the point |
| draw protocol | — | in-project by design (ADR-0003) |
| fonts | FreeType/HarfBuzz | **not needed**: pre-rasterized Plan 9 subfonts as embedded assets (S-03 §4); shaping is out of scope (OQ below) |
| JSON (dom event detail) | — | `std.json` |
| WebSocket framing | ws lib | browser provides WebSocket; the shim uses it; Zig side sees framed 9P bytes |
| dev HTTP server | node, caddy | `std.http.Server` in `zig build serve` |
| testing | frameworks | `zig build test` built-in |

## Decision

- The WASM module and native test builds depend on **the Zig standard library only**.
  `build.zig.zon` keeps an **empty dependency table**; adding any entry requires amending
  this ADR with the concrete justification and a review of transitive cost.
- **Assets are not libraries**: embedded font data (v1: XFree86 misc-fixed subfont,
  public domain — OQ-GFX-2 resolved, see assets/fonts/fixed/README.md; Go fonts BSD-3
  deferred pending an offline conversion tool) and any icon/cursor bitmaps are permitted
  with license notes in-tree.
- **Docs-time tools** (PlantUML/Java or Kroki, GitHub Actions) never become build
  dependencies (R-BLD-05).
- **Browser APIs are the platform, not dependencies**: Canvas2D/OffscreenCanvas,
  Clipboard, File System Access/OPFS, WebSocket, IndexedDB via shim — allowed by
  definition, but only behind the device layer (R-OV-03).

## Consequences

- ✅ No supply-chain surface; a fresh clone + Zig builds forever-reproducibly.
- ✅ Forces the 9P/draw/regex cores to be owned, understood, testable code — these *are*
  the project.
- ⚠️ We re-implement things packages offer (regex engine, 9P). Accepted: each is
  small, stable-spec'd, and central.
- ⚠️ No complex text shaping (bidi, ligatures, grapheme-cluster cursoring) without
  HarfBuzz-class machinery. Accepted for v1 (ACME itself never had it); recorded as a
  known limitation, revisit only with a real user need — would require an ADR amendment.

## Amendment: fetch the pinned plan9port snapshot to build a devdraw peer executable (PROPOSED, 2026-10-11)

**Status: proposed, not yet accepted. Treat the rest of this ADR as current until Larry
confirms.** Prompted by ADR-0005's amendment (accepted 2026-10-11): `devdraw` is now the
native host's rendering/input module *indefinitely*, which makes removing its separate
plan9port-install requirement worth doing now rather than leaving it Parked. Source analysis:
`agents/reports/spike-rhun-self-drawn-frame.md` Addendum A (2026-10-03).

### Context

Today, native snarf requires `devdraw` to already exist on the machine — `$DEVDRAW` set to a
binary, or `$PLAN9` set to a plan9port tree, or bare `devdraw` on `$PATH` (`Conn.zig:153-159`,
`src/main_native.zig:98-99` prints this as an error if none resolve). `Conn.zig` already
spawns the resolved binary as a subprocess and speaks the draw protocol over its stdin/stdout
pipes (`Conn.zig:166-191`) — so there is no "two-terminal dance" to fix, only the
installation requirement.

Addendum A measured the closure needed to build just `devdraw` (not all of plan9port) from
the pinned fork `larryr/plan9port@337c6ac`: `src/cmd/devdraw` plus the slice of
`libmemdraw`/`libmemlayer`, `libdraw`, `lib9`, `libthread`, `libbio` it actually calls — about
240 files, ~570 KiB (~15–18k lines), against plan9port's ~650k total. Zig's C/ObjC compiler
driver can build `.c`/`.m`/`.s` directly (`-fobjc-arc`, `linkFramework` for
Cocoa/Metal/QuartzCore on macOS; X11 on Linux) with no `mk`/`9c`/`9l`/system compiler, so
`zig build` stays the only build entry point (ADR-0001 holds).

### Decision (proposed)

1. **Fetch, not vendor.** `build.zig.zon` gains one dependency entry — a tarball of the
   pinned commit `larryr/plan9port@337c6ac`, content-hash-verified by Zig's normal fetch
   mechanism, cached after first fetch like any Zig dependency (not re-fetched every build;
   CI and offline rebuilds after the first fetch need no network). This is the **first entry**
   in the dependency table ADR-0002's original Decision keeps empty — the amendment that
   adding it requires. Scope is deliberately narrow: *the pinned reference implementation,
   used solely to build a `devdraw` peer executable for the native host build; nothing from
   it is linked into `snarf`/`snarf-native`, and the WASM module's build graph never touches
   it.* Vendoring (copying ~570 KiB of C into `third_party/plan9port/`) was the alternative;
   rejected per Addendum A because fetch keeps the ~15k lines out of our diffs/PRs while the
   content hash gives the same reproducibility guarantee vendoring would.
2. **A new, separate build step** (e.g. `zig build native`, distinct from `zig build` and
   `zig build test`) triggers the fetch and compiles the `devdraw` peer executable to
   `zig-out/bin/devdraw`. `zig build` and `zig build test` — which `core`/`ninep` must pass
   with no browser dependency (R-OV-03) — are untouched and still require no network access
   and no plan9port fetch; only building the actual native *runnable* needs it.
3. **`devdraw` ships unmodified.** No patches to the fetched source — preserves the pinned
   fork's compatibility clause; the `msec` bug and `Kdown` dialect stay absorbed entirely in
   our own adapter (`src/host/devdraw/*`, unchanged by this amendment).
4. **`Conn.devdrawPath` resolution order, with one deliberate change from Addendum A's
   suggestion.** Addendum A proposed checking the build-produced binary *before*
   `$DEVDRAW`/`$PLAN9`. This amendment proposes the opposite priority — explicit overrides
   win: `$DEVDRAW` (if set) → `$PLAN9/bin/devdraw` (if set) → the build-produced
   `zig-out/bin/devdraw` sitting next to the running `snarf-native` binary → bare `devdraw` on
   `$PATH` as the last resort. Rationale: an operator who explicitly sets an env var
   presumably wants that binary (debugging a different devdraw build, a patched one, a newer
   plan9port), and silently preferring our bundled default over an explicit override would be
   surprising. This flips the current code's actual order too — today `$DEVDRAW`/`$PLAN9`
   already come before bare `devdraw`; the only new entry is the bundled default, inserted
   between `$PLAN9` and the bare-`devdraw`-on-`$PATH` fallback. Flagging this explicitly since
   it's user-facing default-resolution behavior, not just an implementation detail — happy to
   take the Addendum A order instead if there's a reason it was specified that way.

### Consequences

- **Positive**: closes the gap SnarfProdd's roadmap v0.2 calls the "#1 native blocker" in
  spirit — a user who clones the repo and runs `zig build native` gets a working native host
  with no separate plan9port install, no env vars to set. Keeps ADR-0005 §3's "MUST NOT link
  plan9port code" intact (separate process, same as today). The fetched source is pinned to
  the exact commit already cited project-wide (CLAUDE.md citation policy) — no version drift
  risk beyond what already exists for every `acme/*.c:NNN` reference in the codebase.
- **Negative / costs**: `build.zig.zon`'s dependency table is no longer empty — the literal
  "Zig standard library only" framing in this ADR's original Decision section now needs the
  narrow carve-out above. First `zig build native` on a machine needs network access once
  (to populate the fetch cache); offline environments need to pre-seed Zig's global cache or
  vendor manually. ~15–18k lines of C/ObjC (Cocoa/Metal on macOS, X11 + a generated keysym
  table on Linux) enter the native build's compile graph, maintained upstream, not by us —
  same trust model as the existing pinned-fork citation policy, extended from "source we read"
  to "source we also compile."
- **Risks**: a future Zig toolchain change to C/ObjC interop (`-fobjc-arc`, framework linking)
  could break the devdraw build step without touching `core`/`ninep` at all — isolate the
  native build step so a `devdraw`-build failure never blocks `zig build test`'s green
  signal. Linux's X11 path needs its own file-list pass (Addendum A: "½ wave Linux") not yet
  done — macOS is the only target this amendment is sized against.

### Feedback into requirements (on acceptance)

- `docs/requirements/06-platform-and-build.md`: note that `zig build native` (not `zig
  build`/`zig build test`) is the one target with a network dependency on first run, and why.
- `agents/NEXT-PHASES.md`: promote "devdraw built in-tree" out of Parked into a scheduled
  phase once this amendment is accepted.
