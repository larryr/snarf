# Phase 18 report — ADR-0006: `devdraw` built in-tree from the fetched, pinned plan9port

**Branch:** `phase18-devdraw-build` (not yet merged) · **Tests:** 749/749 (743 + 3
`devdraw_files` + 2 `DevdrawPath` + 1 `Conn` double-kill regression; the §4 named tests are
the gate's) · `zig build native` OK
on macOS arm64, cold and warm · `zig fmt` clean · **Contract:**
`agents/contracts/phase18-devdraw-build.md` (rulings R-P18-1..9).

## The result

Clone, `zig build native`, `zig build run-native`: a `snarf` window, with no plan9port install
and no env vars. `zig-out/bin/devdraw` is built from `larryr/plan9port@337c6ac`, unmodified,
by Zig's own clang, beside `zig-out/bin/snarf-native`, and `snarf-native` finds it first
unless `$DEVDRAW` says otherwise. `zig build` and `zig build test` never touch the dependency
(proven with `--system <empty dir>`, below).

## What exists now

- **`build.zig.zon`**: one lazy entry, `.plan9port` (url = the fork's archive at `337c6ac`,
  hash `N-V-__8AAJxZ3wK-9yFlPu40838vwp3xUVQhAt1ebgXEhI3F`). `.gitignore` gains `zig-pkg/`.
- **`build/devdraw.zig`** (167 lines): `add(b, dep)` — six static archives (lib9 with its
  three source dirs + `get9root.c` alone with `-DPLAN9_TARGET`, libbio, libthread, libdraw,
  libmemdraw, libmemlayer), the `mklatinkbd` host tool whose `-r` stdout becomes `latin1.h`,
  and the `devdraw` exe (six `.c` + `mac-screen.m` with `-fobjc-arc`, 9l's library order,
  five frameworks); `nested(b)` — the `zig build devdraw -Ddevdraw=true` sub-build.
- **`build/devdraw_files.zig`** (151 lines): the §3c lists with mkfile citations + count tests.
- **`build.zig`** (+32): `-Ddevdraw`, step `devdraw` (lazyDependency under `on_macos and
  want_devdraw`; nested otherwise on macOS; `addFail` off macOS), `native` depends on it on
  macOS, `run-native` runs `zig-out/bin/snarf-native`, `build/devdraw_files.zig` added to
  `test`.
- **`src/host/devdraw/DevdrawPath.zig`** (150 lines): `resolve(gpa, env, self_exe_dir, probe)`
  → `$DEVDRAW` (unprobed) → `<exe dir>/devdraw` → `$PLAN9/bin/devdraw` → `devdraw`;
  `describe()`. `Conn.devdrawPath` deleted; `SpawnOptions.path` added (Conn.zig 466 → 461,
  then 473 with the gate's double-kill regression test — review-accepted, contract §3h.6).
- **`main_native.zig`**: resolves before spawning, prints `snarf-native: devdraw: <path>
  (<source>)`, new failure hint.

## Measurements (2026-10-11, this Mac, arm64, MacOSX14.2 SDK)

| | |
|---|---|
| cold `zig build native` (fresh global + local cache, no `zig-pkg/`; fetch + compile everything) | **19.4 s** wall |
| warm no-op rerun | **0.45 s** wall |
| `zig-out/bin/devdraw` | **372,632 bytes** at the gate (coder's first build: 375,832; plan9port's own: 332,456) — Mach-O 64-bit arm64. Review: `__TEXT` 165,796 vs 163,840, `__LINKEDIT` identical, 745 vs 865 defined symbols — same closure, not a red flag |
| C/ObjC diagnostics with our flags (275 compilations re-run via `zig cc` with identical flags) | **0** |
| §3b.7 link fallbacks needed | **none** |

`otool -L zig-out/bin/devdraw`: Cocoa, Metal, QuartzCore, CoreFoundation, Carbon, libSystem,
AppKit, libobjc, ApplicationServices, Foundation, CoreGraphics — the same set as
`~/proj/plan9port/bin/devdraw` minus `libresolv` (deliberately not linked, §1).
`codesign -dv`: `flags=0x20002(adhoc,linker-signed)`, `Signature=adhoc` — no extra signing step.

## Gate transcripts (as run by the coder; the gate re-runs them)

- `zig build --system "$(mktemp -d)"` → 0; `zig build test --system "$(mktemp -d)"` → 0,
  749/749; `ZIG_GLOBAL_CACHE_DIR=$(mktemp -d) zig build test` → 0, `p/` empty.
- `zig build devdraw -Ddevdraw=true --system "$(mktemp -d)"` → 3, `error: lazy dependency
  package not found: …/N-V-__8AAJ…` + `info: remote package fetching disabled due to --system
  mode`.
- `zig build devdraw -Dtarget=x86_64-linux --system "$(mktemp -d)"` → 1, `error: devdraw is
  built in-tree on macOS only (ADR-0006, phase 18); …`. (`-Ddevdraw=true` added: same.)
  `zig build native -Dtarget=x86_64-linux --system …` → 0 (unchanged behavior).
- `DEVDRAW=/usr/bin/true zig-out/bin/snarf-native` → first line `snarf-native: devdraw:
  /usr/bin/true ($DEVDRAW)`, then the hint, exit 1.
- `zig build run-native` (no `$DEVDRAW`, `$PLAN9` unset) → `snarf-native: devdraw:
  …/zig-out/bin/devdraw (bundled)`, and the bundled devdraw stayed up serving it until killed.
  With `PLAN9=~/proj/plan9port` set, `zig-out/bin/snarf-native` still says `(bundled)`.
- `git diff main -- src/core src/draw src/ninep src/dev src/shim web assets` → empty.

## The contract's §6 questions, answered

1. **`captureStdOut(.{ .basename = "latin1.h" })`** produces
   `.zig-cache/o/<digest>/latin1.h` (100 lines, starts `" ", " i", { 0x2423, 0x0131, },`);
   `.dirname()` is accepted by `addIncludePath` and `latin1.c` compiles. No `WriteFile`
   fallback.
2. **lib9 ↔ libthread cycle**: Zig's MachO linker resolved it from single archives in 9l's
   order; no fallback (a), (b) or (c).
3. **Existence probe**: `std.Io.Dir.cwd().access(io, path, .{})` (default `AccessOptions` =
   F_OK, follows symlinks; no open). `cwd()` only so a relative `$PLAN9` resolves as the spawn
   would; it lives in `main_native.zig`, not `DevdrawPath.zig`.
   **`executablePathAlloc`** returns `…/zig-out/bin/snarf-native` under `zig build run-native`
   (the run step now execs the installed path), so "bundled" resolves.
4. Size: see the table — same order as upstream's.
5. **Nested-run noise**: none in a non-TTY log (the inner build prints nothing on success);
   in a TTY the inner build has its own progress line. Left as is.

## Deviations

- `build.zig` adds `build/devdraw_files.zig` to `zig build test` (§3b.5 says "no new steps"
  for the test graph, but §3h.1 counts those tests in the total). A pure-std test exe; touches
  no dependency.
- `Conn.spawn` errdefer now also nulls `self.child`: a peer that dies during `Tinit` was
  killed twice (the local copy, then `deinit`'s stored copy), which panicked (`ESRCH`) in
  Debug. Pre-existing on `main`; surfaced by T5's `DEVDRAW=/usr/bin/true`.
- ADR-0006: Status line only; the "Feedback into requirements" items were NOT marked Done
  (orchestrator instruction: no other line of the ADR changes). `agents/NEXT-PHASES.md` not
  edited (open PR #6 owns it).
- T6's `grep -- -D build/devdraw.zig` also matches `-Ddevdraw=true` (the nested command), which
  is a build option, not a C define.

## Pipeline

fable spec → opus (this) → sonnet §4 tests → sonnet gate → fable review → merge.
