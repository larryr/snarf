# ADR-0006 — Fetch pinned plan9port to build a devdraw peer executable

Status: **Proposed (2026-10-11), pending Larry's sign-off** · Supersedes: ADR-0002's Decision
clause "`build.zig.zon` keeps an empty dependency table" — **only** for the single, narrowly
scoped entry below; ADR-0002 otherwise stands. Satisfies: none yet (feedback into requirements
on acceptance, below). Related: ADR-0001 (build entry point), ADR-0005 (two hosts, `devdraw`
indefinitely).

Prompted by ADR-0005's amendment (accepted 2026-10-11): `devdraw` is now the native host's
rendering/input module *indefinitely*, which makes removing its separate plan9port-install
requirement worth doing now rather than leaving it Parked. Source analysis:
`agents/reports/spike-rhun-self-drawn-frame.md` Addendum A (2026-10-03).

## Context

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

## Decision (proposed)

1. **Fetch, not vendor.** `build.zig.zon` gains one dependency entry — a tarball of the
   pinned commit `larryr/plan9port@337c6ac`, content-hash-verified by Zig's normal fetch
   mechanism, cached after first fetch like any Zig dependency (not re-fetched every build;
   CI and offline rebuilds after the first fetch need no network). This is the entry that
   supersedes ADR-0002's empty-dependency-table clause — narrowly: *the pinned reference
   implementation, used solely to build a `devdraw` peer executable for the native host
   build; nothing from it is linked into `snarf`/`snarf-native`, and the WASM module's build
   graph never touches it.* Vendoring (copying ~570 KiB of C into `third_party/plan9port/`)
   was the alternative; rejected per Addendum A because fetch keeps the ~15k lines out of our
   diffs/PRs while the content hash gives the same reproducibility guarantee vendoring would.
2. **A new, separate build step** (e.g. `zig build native`, distinct from `zig build` and
   `zig build test`) triggers the fetch and compiles the `devdraw` peer executable to
   `zig-out/bin/devdraw`. `zig build` and `zig build test` — which `core`/`ninep` must pass
   with no browser dependency (R-OV-03) — are untouched and still require no network access
   and no plan9port fetch; only building the actual native *runnable* needs it.
3. **`devdraw` ships unmodified.** No patches to the fetched source — preserves the pinned
   fork's compatibility clause; the `msec` bug and `Kdown` dialect stay absorbed entirely in
   our own adapter (`src/host/devdraw/*`, unchanged by this decision).
4. **`Conn.devdrawPath` resolution order: `$DEVDRAW` → bundled → `$PLAN9` → bare `devdraw` on
   `$PATH`.** Neither Addendum A's original order (bundled first) nor this ADR's first draft
   (every env var before the bundled binary) is quite right, per SnarfProdd review: most
   ACME users — Larry included — already have `$PLAN9` set system-wide, so putting it ahead of
   the bundled binary would silently shadow the pinned, tested build with whatever plan9port
   happens to be installed, defeating the point of bundling. `$DEVDRAW` is different: it names
   one specific binary, so setting it is an unambiguous, deliberate override and should still
   win outright. Final order: **`$DEVDRAW`** (exact binary, always wins) → **bundled**
   `devdraw` resolved relative to `snarf-native`'s own executable path (not the cwd and not a
   hardcoded `zig-out/bin` — `std.fs.selfExePath` or equivalent, so this rule carries over
   unchanged to a future packaged layout, e.g. a macOS `.app`'s `Contents/MacOS/`, without a
   new ADR) → **`$PLAN9/bin/devdraw`** (a general plan9port install, lowest-priority env
   signal) → bare `devdraw` on `$PATH` as the last resort. `snarf-native` SHALL print which
   `devdraw` it resolved and from where (startup log line or a `-v`/`ctl` query) so the choice
   is never silent.

## Consequences

- **Positive**: closes the first native daily-driver item in roadmap v0.2 (M3) — a user who
  clones the repo and runs `zig build native` gets a working native host
  with no separate plan9port install, no env vars to set. Keeps ADR-0005 §3's "MUST NOT link
  plan9port code" intact (separate process, same as today). The fetched source is pinned to
  the exact commit already cited project-wide (CLAUDE.md citation policy) — no version drift
  risk beyond what already exists for every `acme/*.c:NNN` reference in the codebase.
- **Negative / costs**: `build.zig.zon`'s dependency table is no longer empty — ADR-0002's
  literal "Zig standard library only" framing now carries this narrow, named exception. First
  `zig build native` on a machine needs network access once (to populate the fetch cache);
  offline environments need to pre-seed Zig's global cache or vendor manually. ~15–18k lines
  of C/ObjC (Cocoa/Metal on macOS, X11 + a generated keysym table on Linux) enter the native
  build's compile graph, maintained upstream, not by us — same trust model as the existing
  pinned-fork citation policy, extended from "source we read" to "source we also compile."
- **Risks**: a future Zig toolchain change to C/ObjC interop (`-fobjc-arc`, framework linking)
  could break the devdraw build step without touching `core`/`ninep` at all — isolate the
  native build step so a `devdraw`-build failure never blocks `zig build test`'s green
  signal. Linux's X11 path needs its own file-list pass (Addendum A: "½ wave Linux") not yet
  done — macOS is the only target this decision is sized against.

## Feedback into requirements (on acceptance)

- `docs/requirements/06-platform-and-build.md`: note that `zig build native` (not `zig
  build`/`zig build test`) is the one target with a network dependency on first run, and why.
- `agents/NEXT-PHASES.md`: promote "devdraw built in-tree" out of Parked into a scheduled
  phase once this ADR is accepted.
