# Phase 18 contract — ADR-0006: build the `devdraw` peer in-tree from the fetched, pinned plan9port

Status: **binding (fable, 2026-10-11).** Branch `phase18-devdraw-build` (worktree
`.worktrees/phase18-devdraw-build`), based on `main@88f6a59` (17 merged; ADR-0005 amendment and
ADR-0006 both accepted 2026-10-11). Decisions implemented: **ADR-0006** (fetch, not vendor; a
separate build step; `devdraw` unmodified; `$DEVDRAW` → bundled → `$PLAN9` → `$PATH`), under
ADR-0005's amendment (`devdraw` is the native host's display/input module indefinitely).
Requirements touched: R-OV-09 (native host), R-BLD-01/02/03 (build hosts — see §3f for the
honest revision-log entry), R-CON-02 (`core`/`ninep` still test with no browser and no network).
Roadmap: closes the first native daily-driver item (v0.2 M3): clone, `zig build native`, run —
no plan9port install, no env vars.

Pipeline: fable spec → **opus** codes §3 → **sonnet** writes §4 → **sonnet** runs the gate →
**fable** reviews → orchestrator applies nits → merge.

**Out of scope** (do not touch, do not "while I'm here"): Linux/X11 `devdraw` (ADR-0006 says it
needs its own file-list pass — §3e says what Linux does instead); cross-compiling the native host
(`-Dtarget` ≠ host); a macOS `.app` bundle; a `-v`/`ctl` query for the resolved path (the log line
is the deliverable); patching anything in the fetched tree; CI workflows (M0 item 11 — separate);
making `zig build` (default step) build `devdraw`; the self-drawn frame; anything under
`src/core`, `src/draw`, `src/ninep`, `src/dev`, `src/shim`, `web/`.

## 1. Ground truth (`larryr/plan9port@337c6ac`, local clone `~/proj/plan9port`; built on Larry's Mac, its `install.log` records every real compile/link line)

| Item | Where | What |
|---|---|---|
| What `devdraw` links on macOS | `install.log:2868` (`9l -o o.devdraw devdraw.o latin1.o mouseswap.o srv.o winsize.o mac-draw.o mac-screen.o`); `src/cmd/devdraw/mkfile:4-13` (`TARG=devdraw`, `SHORTLIB=draw memdraw`, `WSYSOFILES`); `mkwsysrules.sh:26-31,58` (Darwin ⇒ `WSYSTYPE=mac` ⇒ `+ mac-draw.o mac-screen.o`) | Seven objects. `nowsys.c`, `drawclient.c`, `macargv.m`, all `x11-*` are NOT part of the macOS binary. |
| Library order 9l actually used | `9l -v` on this Mac: `liborder -lmemdraw -lmemlayer -ldraw -lmux -lthread`, then `-l9 -lthread -l9 -lresolv`; frameworks `QuartzCore Metal CoreFoundation Cocoa Carbon` | Derived from `AUTOLIB`/`AUTOFRAMEWORK` markers (`include/u.h:174-175`): `mac-screen.m:27-30` (Cocoa, Metal, QuartzCore, CoreFoundation), `include/draw.h:9` (Carbon — needed: `mac-screen.m:1242` calls `GetCurrentProcess`), `include/memdraw.h:7-8`, `include/thread.h:7`. `libmux` is listed only because `libdraw.a(drawclient.o)` carries `AUTOLIB(mux)`. |
| Archive members the real link PULLS (linker map, 2026-10-11) | lib9 **57** (`_p9dialparse _p9dir announce argv0 atexit atnotify atoi await dirstat dofmt dup encodefmt errstr exitcode fltfmt fmt fmtfd fmtfdflush fmtlocale fmtlock2 fmtprint fmtstr fprint getenv getns getuser jmp main malloc mallocz nan64 notify open pin print qlock readn rune sleep smprint snprint sprint strdup strecpy strtod sysfatal time u16 u32 u64 utfecpy utflen vfprint vseprint vsmprint vsnprint write`); libdraw **9** (`arith bytesperline chan cursor drawfcall drawrepl icossin icossin2 rectclip`); libmemdraw **13**; libmemlayer **12** (all); libthread **5** (`bg daemonize pthread ref thread`); **libmux 0; libbio 0** | Informational, not the compile list: we compile each mkfile's full list into a static archive and let the linker pull members, exactly as 9l does. This is why archives, not loose objects (§3g R-P18-2): `libdraw/iprint.c` and `libmemdraw/iprint.c` both define `iprint`; loose objects would collide. |
| `main` / `p9main` | `include/libc.h:852` `#define main p9main` (under `#ifndef NOPLAN9DEFINES`); `lib9/main.c:2,8-11` (defines the real `main`, calls `p9main`); `libthread/thread.c:717` (its `main` IS `p9main` after the define, calls `threadmain`); `devdraw/srv.c:38` `threadmain` | Not a duplicate. 9l's `-l9 -lthread -l9` (`9l` "cycle" comment) exists because lib9 needs `p9main` from libthread and libthread needs lib9 — an archive-order cycle, resolved by listing twice. Zig's MachO linker resolves archives iteratively; if `p9main` or any lib9 symbol comes up undefined anyway, the fallback is §3b step 7. |
| Per-OS source selection | `lib9/mkfile`: no per-OS files (`_p9dir.c`, `dirfwstat.c`, `getns.c`, `sleep.c` use `#ifdef __APPLE__` internally); `libthread/mkfile:4-14`: ten `.c`, **no assembly on Darwin** (the `.S`/`.s` rules at `:36-43` are OpenBSD/sparc64 only — Addendum A's "per-arch `.s`" does not apply to macOS); `libmemdraw`, `libmemlayer`, `libdraw`, `libbio`: one list each, no OS switch | The six lists in §3c are transcribed from the mkfiles and cross-checked against the `9ar` lines in `install.log:157,180,895,1038,1052,1218`. |
| lib9's three source dirs | `lib9/mkfile:172-176` (`%.$O: fmt/%.c` with `-Ifmt`; `%.$O: utf/%.c`); resolution of every object in the real `lib9.a` against the tree: **93** in `src/lib9/`, **34** in `src/lib9/fmt/`, **20** in `src/lib9/utf/` = 147 | Note `fmtlock2.c` and `frexp.c` are top-level `lib9/` files even though the mkfile lists them under `FMTOFILES`; `fmt/errfmt.c`, `fmt/dorfmt.c`, `fmt/fmtlock.c`, `fmt/test*.c`, and top-level `debugmalloc.c fork.c lock.c priv.c udp.c test*.c` are deliberately NOT built (mkfile comment `lib9/mkfile:9`). |
| `get9root.c` | `lib9/mkfile:178-179`: `-DPLAN9_TARGET=\"$PLAN9_TARGET\"`; `INSTALL:37` defaults it to `$PLAN9` | Compile-time string, read only when `$PLAN9` is unset (`get9root.c:14`). None of the pulled members call it (`openfont.c`, `syslog.c`, `unsharp.c` are the only callers; none are pulled). §3b fixes the value. |
| Generated header | `devdraw/mkfile:36-37`: `latin1.h: $PLAN9/lib/keyboard $O.mklatinkbd` ⇒ `./$O.mklatinkbd -r $PLAN9/lib/keyboard \| sed 's/, }/ }/' >$target`; `latin1.c:14` `#include "latin1.h"`; `mklatinkbd.c` needs lib9 + libbio (`#include <bio.h>` ⇒ `AUTOLIB(bio)`) | `mklatinkbd` is a HOST TOOL run at build time; its `-r` output is 100 lines of `"ld", "si", { 0x…, 0x…, },`. The `sed` only strips the trailing comma inside `{ … , }`, which is legal C (initializer lists accept a trailing comma) — §3g R-P18-7 drops the sed. |
| ObjC compile rule | `devdraw/mkfile:42-43`: `$CC $CFLAGS $OBJCFLAGS -fobjc-arc -o $target $stem.m`; `install.log:2860` shows `$OBJCFLAGS` empty | Only `mac-screen.m` is ObjC. `-fobjc-arc` is binding. |
| C flags 9c uses on Darwin | `bin/9c:65-88` (`useclang`: `-O2 -c -Wall -Wno-parentheses -Wno-missing-braces -Wno-switch -Wno-comment -Wno-sign-compare -Wno-unknown-pragmas -Wno-empty-body -Wno-unused-value -Wno-array-bounds -Wno-gnu-designator -Wno-unneeded-internal-declaration -Wno-deprecated-pragma -Wno-unused-but-set-variable -fsigned-char -fno-caret-diagnostics -fno-common -g`), `:116-118` (Darwin adds `-g3 -m64`), `:154` (`-DPLAN9PORT -I"$PLAN9/include"`); `bin/osxvers` adds `-DOSX_VERSION=…` | **`OSX_VERSION` is referenced by nothing in the closure** (grepped `src/cmd/devdraw src/lib* include`) — not defined by us. `-lresolv` (`9l:32-35`, Darwin `extralibs`) — nothing in lib9 uses `res_*`; not linked by us. |
| Spawn/lookup today | `drawclient.c:101,124` (`getenv("DEVDRAW")`, else bare `devdraw`); `Conn.zig:153-160` `devdrawPath` (`$DEVDRAW` → `$PLAN9/bin/devdraw` → `devdraw`); `Conn.zig:166-198` `spawn`; `main_native.zig:84-99` prints the failure hint | `devdrawPath` has no caller outside `Conn.spawn`. It is replaced by §3d. |
| Our build today | `build.zig:114-138` (`snarf-native`, `zig build native`, `zig build run-native` via `addRunArtifact` — runs the CACHED exe, not `zig-out/bin/snarf-native`); `build.zig.zon` (`.dependencies = .{}`, `.paths`) | `run-native` must change (§3b step 9): a cached-exe path has no sibling `devdraw`. |
| Zig 0.16 facts (verified against `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig`, 2026-10-11) | `std/Build.zig:2035` `lazyDependency` (returns null + marks needed when the package is absent; the runner then fetches and re-runs `build()`); `:2055` `dependency` panics on a lazy entry; `Build/Module.zig:397-405` `AddCSourceFilesOptions{root, files, flags, language}`; `:392` `linkFramework(name, .{})`; `:470` `linkLibrary`; `:485` `addIncludePath`; `Module.CreateOptions.sanitize_c: ?std.zig.SanitizeC` (`off/trap/full`, `std/zig.zig:243`); `Build.zig:842` `addLibrary(.{.linkage=.static,…})`; `Step/Run.zig:675` `captureStdOut(.{ .basename = … })`; `Build.zig:1107` `addFail`; `std/process.zig:731` `executablePathAlloc(io, gpa)` (follows symlinks via `realpath`, `Io/Dispatch.zig:3951-3959`); `std.os.argv` **does not exist** in 0.16 and `build_runner.zig:111,435` keeps the requested step names in a local (`targets`) — **`build()` cannot learn which steps were requested**; `zig build --system <dir>` = "Disable package fetching" (`build_runner.zig:318-322`, `zig build --help`) | The last two facts decide the gating design (§2). |

## 2. What was proven before this contract was written (scratchpad, 2026-10-11 — do not re-derive, do reproduce)

1. **The hash.** `zig fetch https://github.com/larryr/plan9port/archive/337c6acbfed51d8d9f08598c6cd398f53abcca7d.tar.gz` ⇒
   `N-V-__8AAJxZ3wK-9yFlPu40838vwp3xUVQhAt1ebgXEhI3F` (the `N-V-` prefix = a package with no
   `build.zig.zon` of its own, which Zig accepts). Zig 0.16 keeps the **tarball** in the global
   cache (`~/.cache/zig/p/<hash>.tar.gz`, **22 MB**) and materializes the tree **in the project
   root** as `zig-pkg/<hash>/` (**63 MB** on disk; the fork is ~650k lines, we compile ~34k).
   `zig-pkg/` is therefore a build artifact next to `zig-out/` and MUST be git-ignored (§3a).
   Pre-seeding an offline machine = copying the tarball into `~/.cache/zig/p/`, or `--system
   <dir>` with `<dir>/<hash>/` unpacked.
2. **`zig fetch --save=plan9port`** writes exactly: `.plan9port = .{ .url = "…/archive/337c6ac…tar.gz", .hash = "N-V-__8AAJ…" }` — §3a adds `.lazy = true` by hand.
3. **Lazy gating works and `--system` proves it.** A `build.zig` that calls `b.lazyDependency` only
   under `-Dwant=true`: `zig build probe --system <empty dir>` ⇒ exit 0; `zig build probe -Dwant=true
   --system <empty dir>` ⇒ exit 3, `error: lazy dependency package not found: <dir>/N-V-__8AAJ…` +
   `info: remote package fetching disabled due to --system mode`; `ZIG_GLOBAL_CACHE_DIR=<fresh>
   zig build probe` ⇒ exit 0 and `<fresh>/p/` stays empty. **That is the no-network gate for §4.**
4. **Zig compiles the fetched C/ObjC.** Through `std.Build` (not `zig cc`): a static archive of
   five lib9 files (`.root = dep.path("src/lib9")`, `-DPLAN9PORT -fsigned-char -fno-common`,
   `sanitize_c = .off`, `link_libc`) and `mac-screen.m` as an object with `-fobjc-arc` +
   `linkFramework("Cocoa")` — both built in 4.9 s, SDK auto-detected (Zig runs `xcrun --sdk macosx
   --show-sdk-path`, `std/zig/system/darwin.zig:34-49`; this Mac resolved
   `MacOSX14.2.sdk` under `Xcode.app`). A trivial Cocoa+Metal+QuartzCore program linked with
   `zig cc -fobjc-arc -framework …` runs (`MTLCreateSystemDefaultDevice` non-nil). The one
   diagnostic was `-Wdeprecated-declarations` on `GetCurrentProcess` (`mac-screen.m:1242`).
5. **The gating problem and its ruling.** Because `build()` cannot see the requested steps and the
   fetch is a configure-time side effect of calling `lazyDependency`, "`zig build native` triggers
   the fetch while `zig build`/`zig build test` never do" cannot be expressed in one configure
   pass. Ruling R-P18-1: the call is gated on a build option `-Ddevdraw=true`; `zig build native`
   (and `zig build devdraw` without the option) satisfy ADR-0006 §2 by running a **nested**
   `zig build devdraw -Ddevdraw=true` as a `Step.Run`. Rejected: reading the runner's argv (gone in
   0.16), a sub-package with its own `build.zig.zon` (ADR-0006 §1 puts the entry in the root
   manifest), an unconditional `lazyDependency` (would fetch on every `zig build`).

## 3. CONTRACT

### 3a. `build.zig.zon`

```zig
.dependencies = .{
    // ADR-0006 (accepted 2026-10-11) — the ONE permitted entry, superseding ADR-0002's
    // empty-table clause narrowly: the pinned reference fork, LAZY, consumed only by
    // `zig build devdraw -Ddevdraw=true` (which `zig build native` runs) to build the
    // devdraw PEER PROCESS. Nothing from it is linked into snarf or snarf-native; the
    // wasm build graph and `zig build test` never touch it. Hash from `zig fetch <url>`.
    .plan9port = .{
        .url = "https://github.com/larryr/plan9port/archive/337c6acbfed51d8d9f08598c6cd398f53abcca7d.tar.gz",
        .hash = "N-V-__8AAJxZ3wK-9yFlPu40838vwp3xUVQhAt1ebgXEhI3F",
        .lazy = true,
    },
},
.paths = .{ "build.zig", "build.zig.zon", "build", "src", "tools", "web", "assets" },
```
`.name`, `.version`, `.fingerprint`, `.minimum_zig_version` unchanged. The old "stays EMPTY"
comment is replaced by the one above. **`.gitignore` gains `zig-pkg/`** (the materialized
package store, §2.1) — do this in the same commit as the manifest change so no session ever
sees 63 MB of plan9port as untracked files.

### 3b. Build graph — `build.zig` (+≤40 lines) and two new build-time files

New directory **`build/`** — build-time helpers, imported only by `build.zig`, importing only
`std` (no project module may import them; they are not part of any S-07 module graph):

- **`build/devdraw.zig`** (namespace module, ≤ ~250 lines): `pub fn add(b: *std.Build, dep:
  *std.Build.Dependency) *std.Build.Step.InstallArtifact` (the whole devdraw graph below) and
  `pub fn nested(b: *std.Build) *std.Build.Step.Run` (step 8).
- **`build/devdraw_files.zig`** (≤ ~400 lines): the §3c lists as `pub const` slices of
  `[]const u8`, one per plan9port directory, each preceded by the mkfile citation it was
  transcribed from. Several names per line (zig fmt keeps them when there is no trailing comma)
  — this is a table, not prose. Contains `test` blocks asserting the counts in §3c.

`build.zig` changes, in order:

1. `const want_devdraw = b.option(bool, "devdraw", "Build the bundled devdraw peer from the pinned plan9port (macOS only; fetches ~22 MB once; implied by `zig build native`)") orelse false;`
2. `const on_macos = target.result.os.tag == .macos;` (the standard `-Dtarget`; cross-building
   is unsupported — §3e, R-P18-4.)
3. A top-level step **`devdraw`** ("Build zig-out/bin/devdraw, the bundled display server").
   - `if (on_macos and want_devdraw)`: `if (b.lazyDependency("plan9port", .{})) |dep|
     devdraw_step.dependOn(&devdraw_build.add(b, dep).step);` — **this is the only call site of
     `lazyDependency` in the repo**, and it is inside both conditions.
   - `else if (on_macos)`: `devdraw_step.dependOn(&devdraw_build.nested(b).step);`
   - `else`: `devdraw_step.dependOn(&b.addFail("devdraw is built in-tree on macOS only (ADR-0006, phase 18); on this OS set $PLAN9 or $DEVDRAW to an installed devdraw").step);`
4. **`native`** keeps installing `snarf-native` and additionally `dependOn(devdraw_step)` **when
   `on_macos`**. On other OSes `native` behaves exactly as today.
5. `zig build` (install) and `zig build test`: **no new dependencies, no new steps** — diff of
   those two subgraphs is nil except that `snarf-native`'s module gains nothing either (the
   resolution code is in `host`, already a dependency).
6. `build/devdraw.zig add(b, dep)` builds, all with `.target = b.graph.host`, `.optimize =
   .ReleaseFast` (9c uses `-O2`; **never Debug/ReleaseSafe for this C** — UBSan traps on
   plan9port's pointer games), `.link_libc = true`, `.sanitize_c = .off`:
   - `cflags` (binding, one slice, applied to every C and ObjC file): `-DPLAN9PORT`,
     `-fsigned-char`, `-fno-common`, `-fno-sanitize=undefined`, and 9c's diagnostics set
     verbatim: `-Wno-parentheses -Wno-missing-braces -Wno-switch -Wno-comment -Wno-sign-compare
     -Wno-unknown-pragmas -Wno-empty-body -Wno-unused-value -Wno-array-bounds -Wno-gnu-designator
     -Wno-unneeded-internal-declaration -Wno-deprecated-pragma -Wno-unused-but-set-variable`, plus
     `-Wno-deprecated-declarations` (9c hides that class textually, `9c:55`; we use the flag).
     **No `-Werror`, no `-O`, no `-g`, no `-m64`, no `-DOSX_VERSION`.** Every file gets
     `addIncludePath(dep.path("include"))`.
   - Static archives via `b.addLibrary(.{ .linkage = .static, … })`, one per plan9port library,
     each `addCSourceFiles(.{ .root = dep.path("src/<lib>"), .files = files.<lib>, .flags = cflags })`:
     `lib9` (three calls: top-level list, `fmt/…` list, `utf/…` list; plus
     `addIncludePath(dep.path("src/lib9/fmt"))` for the mkfile's `-Ifmt`; **`get9root.c` in a
     fourth call of its own** with `cflags ++ "-DPLAN9_TARGET=\"/usr/local/plan9\""`, plan9port's
     documented default install root — R-P18-6), `libbio`, `libthread`
     (`addIncludePath(dep.path("src/libthread"))` for its `-I.`), `libdraw`, `libmemdraw`,
     `libmemlayer`.
   - **`mklatinkbd`** host tool: `b.addExecutable(.{ .name = "mklatinkbd", … })` from
     `src/cmd/devdraw/mklatinkbd.c`, `linkLibrary(libbio)`, `linkLibrary(lib9)`. Then
     `run = b.addRunArtifact(mklatinkbd); run.addArg("-r"); run.addFileArg(dep.path("lib/keyboard"));
     const latin1_h = run.captureStdOut(.{ .basename = "latin1.h" });` and the devdraw module gets
     `addIncludePath(latin1_h.dirname())`. (`WriteFile.addCopyFile` is the fallback if `basename`
     does not produce a file literally named `latin1.h`.)
   - **`devdraw`** executable: `src/cmd/devdraw/{devdraw.c, latin1.c, mouseswap.c, srv.c, winsize.c,
     mac-draw.c}` with `cflags`; `mac-screen.m` in its own `addCSourceFiles` with `cflags ++
     "-fobjc-arc"` (language inferred from `.m`); `linkLibrary` in 9l's order `libmemdraw,
     libmemlayer, libdraw, libthread, lib9`; `linkFramework` `Cocoa`, `Metal`, `QuartzCore`,
     `CoreFoundation`, `Carbon` (all five; `otool -L ~/proj/plan9port/bin/devdraw` confirms them);
     **not** linked: `libmux`, `libbio`, `resolv` (§1). `return b.addInstallArtifact(devdraw, .{})`
     ⇒ `zig-out/bin/devdraw`, beside `zig-out/bin/snarf-native`.
7. **Link fallbacks, in this order, only if the link fails, each recorded in the report:**
   (a) undefined `p9main`/lib9 symbols from archive ordering ⇒ compile `libthread`'s ten files
   directly into the devdraw module instead of as an archive (devdraw needs most of it anyway);
   (b) undefined symbols naming `libmux` members ⇒ add a `libmux` archive (`src/libmux/mkfile`:
   `io.c mux.c queue.c thread.c`); (c) undefined `res_*` ⇒ `linkSystemLibrary("resolv")`.
   Nothing else is a permitted deviation; in particular no source edits (R-P18-3), no `-D` beyond
   the two named (`PLAN9PORT`, `PLAN9_TARGET`), no `-w`/`-Wno-everything`.
8. **`nested(b)`**: `b.addSystemCommand(&.{ b.graph.zig_exe, "build", "devdraw", "-Ddevdraw=true",
   "--build-file", b.pathFromRoot("build.zig"), "--prefix", b.install_path, "--cache-dir",
   <b.cache_root.path>, "--global-cache-dir", <b.graph.global_cache_root.path> })`, `stdio =
   .inherit` (so the one-time fetch progress and any C diagnostics are visible), no captured
   output (Run steps without outputs are not cached — it runs every time; the inner build is
   fully cached so a no-op costs the configure phase only). `-Doptimize`/`-Dtarget` are
   **not** forwarded (R-P18-4/-6). Recursion is impossible: with `-Ddevdraw=true` the `devdraw`
   step depends on the real artifact, never on `nested`.
9. **`run-native`** runs the INSTALLED binary: `const run = b.addSystemCommand(&.{
   b.getInstallPath(.bin, "snarf-native") }); run.step.dependOn(native_step);` — replacing
   `addRunArtifact(native)`, whose cached exe has no `devdraw` sibling. Keep `b.args`
   pass-through if present today (it is not; do not add).

### 3c. The file lists (binding; counts are test-asserted)

Transcribed from the mkfiles and cross-checked against the archives actually built on this Mac
(`install.log` `9ar` lines). Every name is a real file in the fetched tree.

- **`src/cmd/devdraw`** (7 + 1): `devdraw.c latin1.c mouseswap.c srv.c winsize.c mac-draw.c
  mac-screen.m`; host tool `mklatinkbd.c`. (`devdraw/mkfile:8-13`, `mkwsysrules.sh:58`.)
- **`src/libmemdraw`** (24, `libmemdraw/mkfile:5-30`): `alloc.c alloc-stub.c arc.c cload.c
  cload-stub.c cmap.c cread.c draw.c draw-stub.c ellipse.c fillpoly.c hwdraw.c iprint.c line.c
  load.c load-stub.c openmemsubfont.c poly.c read.c string.c subfont.c unload.c unload-stub.c
  write.c`.
- **`src/libmemlayer`** (12, `libmemlayer/mkfile:5-17`): `draw.c lalloc.c layerop.c ldelete.c
  lhide.c line.c load.c lorigin.c lsetrefresh.c ltofront.c ltorear.c unload.c`.
- **`src/libdraw`** (57, `libdraw/mkfile:5-63`; Addendum A's "59" counted the directory, not the mkfile): `alloc.c allocimagemix.c arith.c bezier.c
  border.c buildfont.c bytesperline.c chan.c cloadimage.c computil.c creadimage.c cursor.c
  debug.c draw.c drawclient.c drawfcall.c drawrepl.c egetrect.c ellipse.c emenuhit.c event.c
  font.c freesubfont.c getrect.c getsubfont.c icossin.c icossin2.c init.c iprint.c keyboard.c
  line.c loadimage.c menuhit.c mkfont.c mouse.c openfont.c poly.c readimage.c readsubfont.c
  rectclip.c replclipr.c rgb.c scroll.c snarf.c string.c stringbg.c stringsubfont.c
  stringwidth.c subfont.c subfontcache.c subfontname.c unloadimage.c window.c writeimage.c
  writesubfont.c wsys.c unix.c`. (`drawclient.c` and `event.c` include `<mux.h>`/`<bio.h>`; they
  compile against the headers and are never pulled — §1.)
- **`src/libthread`** (10, `libthread/mkfile:4-15`): `bg.c channel.c daemonize.c exec.c
  ioproc.c iorw.c pthread.c ref.c thread.c wait.c`.
- **`src/libbio`** (17, `libbio/mkfile:5-23`; `mklatinkbd` only): `bbuffered.c bfildes.c
  bflush.c bgetc.c bgetrune.c bgetd.c binit.c boffset.c bprint.c bputc.c bputrune.c brdline.c
  brdstr.c bread.c bseek.c bvprint.c bwrite.c`.
- **`src/lib9`** top level (93, `lib9/mkfile:69-161` `LIB9OFILES` + the two `FMTOFILES` entries
  that live here): `_exits.c _p9dialparse.c _p9dir.c announce.c argv0.c atexit.c atoi.c atol.c
  atoll.c atnotify.c await.c cistrcmp.c cistrncmp.c cistrstr.c cleanname.c convD2M.c convM2D.c
  convM2S.c convS2M.c crypt.c ctime.c dial.c dirfstat.c dirfwstat.c dirmodefmt.c dirstat.c
  dirwstat.c dup.c encodefmt.c errstr.c exec.c execl.c exitcode.c fcallfmt.c frand.c
  getcallerpc.c getenv.c getfields.c getnetconn.c getns.c getuser.c getwd.c jmp.c lrand.c
  lnrand.c main.c malloc.c malloctag.c mallocz.c nan.c needsrcquote.c needstack.c netcrypt.c
  netmkaddr.c notify.c nrand.c nulldir.c open.c opentemp.c pin.c pipe.c post9p.c postnote.c
  qlock.c quote.c rand.c read9pmsg.c readcons.c readn.c rfork.c searchpath.c sendfd.c sleep.c
  strdup.c strecpy.c sysfatal.c syslog.c sysname.c time.c tm2sec.c tokenize.c truerand.c u16.c
  u32.c u64.c unsharp.c wait.c waitpid.c write.c zoneinfo.c fmtlock2.c frexp.c` — **plus
  `get9root.c` in its own call (§3b.6)**, 93 in total including it.
- **`src/lib9/fmt`** (34, `lib9/mkfile:10-46` minus the two above; `charstod`/`pow10` are
  `NUM`): `dofmt.c fltfmt.c fmt.c fmtfd.c fmtfdflush.c fmtlocale.c fmtnull.c fmtprint.c
  fmtquote.c fmtrune.c fmtstr.c fmtvprint.c fprint.c nan64.c print.c runefmtstr.c runeseprint.c
  runesmprint.c runesnprint.c runesprint.c runevseprint.c runevsmprint.c runevsnprint.c
  seprint.c smprint.c snprint.c sprint.c strtod.c vfprint.c vseprint.c vsmprint.c vsnprint.c
  charstod.c pow10.c`.
- **`src/lib9/utf`** (20, `lib9/mkfile:47-68`): `rune.c runestrcat.c runestrchr.c runestrcmp.c
  runestrcpy.c runestrdup.c runestrlen.c runestrecpy.c runestrncat.c runestrncmp.c runestrncpy.c
  runestrrchr.c runestrstr.c runetype.c utfecpy.c utflen.c utfnlen.c utfrrune.c utfrune.c
  utfutf.c`.

lib9 total **147** = the member count of the real `lib9.a`. Not built, on purpose: `lib9/fmt/
{errfmt,dorfmt,fmtlock,test,test2,test3}.c`, `lib9/{debugmalloc,fork,lock,priv,udp,test,
testfltfmt,testfmt,testfork,testprint}.c`, `devdraw/{nowsys,drawclient,macargv,x11-*}`.

### 3d. Resolution — `src/host/devdraw/DevdrawPath.zig` (new), `Conn.zig`, `main_native.zig`

`Conn.zig` is at 466 lines (over the soft cap) and `devdrawPath` is policy, not transport, so it
moves out:

- **`DevdrawPath.zig`** (file-as-struct, ≤ ~200 lines with tests): fields `path: []u8`,
  `source: Source`; `pub const Source = enum { env_devdraw, bundled, plan9, path }`; `pub const
  Probe = struct { ctx: *anyopaque, exists: *const fn (ctx: *anyopaque, path: []const u8) bool }`
  (the test seam, same shape as `Conn.Sink`); `pub fn resolve(gpa, env: *const
  std.process.Environ.Map, self_exe_dir: ?[]const u8, probe: Probe) !DevdrawPath`; `pub fn
  deinit(self, gpa)`; `pub fn describe(self) []const u8` returning exactly one of `"$DEVDRAW"`,
  `"bundled"`, `"$PLAN9/bin"`, `"$PATH"`. Order and rules (ADR-0006 §4, binding):
  1. `env.get("DEVDRAW")` non-empty ⇒ `.env_devdraw`, **no existence probe** (it names one
     binary deliberately; a wrong value fails loudly at spawn, as `drawclient.c:101` does).
  2. `self_exe_dir` non-null ⇒ candidate `<self_exe_dir>/devdraw`; `probe.exists` ⇒ `.bundled`.
  3. `env.get("PLAN9")` non-empty ⇒ candidate `<PLAN9>/bin/devdraw`; `probe.exists` ⇒ `.plan9`.
     (Probing is new relative to today's `Conn.devdrawPath`: a derived path that does not exist
     must not shadow `$PATH` — R-P18-5.)
  4. else `"devdraw"` ⇒ `.path` (the OS's `PATH` search at spawn).
  No cwd, no hardcoded `zig-out`, no `std.fs.cwd()` anywhere in this file.
- **`Conn.zig`**: delete `devdrawPath`; `SpawnOptions` gains `path: []const u8` (no default);
  `spawn` uses it. Doc comment at `:153-155` moves to `DevdrawPath.zig`. Net line count goes down.
- **`host.zig`**: `pub const DevdrawPath = @import("devdraw/DevdrawPath.zig");` + add to the
  file list in its header and to the `test {}` block.
- **`main_native.zig`** (`:84-99` region): obtain `self_exe_dir` as
  `std.fs.path.dirname(std.process.executablePathAlloc(init.io, gpa) catch null)` (a failure ⇒
  `null` ⇒ step 2 skipped, never fatal); build a `Probe` over `init.io` (an `access`/`stat` of
  the path through the `Io` API — whichever 0.16 call is the cheapest existence check; it must
  not open the file for writing); call `resolve`; **print, before spawning, exactly**
  `snarf-native: devdraw: <path> (<source>)\n` to stderr via the file's existing
  `std.debug.print` convention; pass `.path`. The failure hint text becomes: first line unchanged
  (`cannot start devdraw ({t})`), then `Run \`zig build native\` to build the bundled devdraw
  (macOS), or set $DEVDRAW to a devdraw binary, or $PLAN9 to a plan9port tree.`

### 3e. Non-macOS (`target.result.os.tag != .macos`)

`zig build`, `zig build test`, `zig build native`, `zig build run-native` behave exactly as on
`main` today (snarf-native builds; at runtime `DevdrawPath` resolves `$DEVDRAW`/bundled/`$PLAN9`/
`$PATH` the same way — a Linux user who drops an X11 `devdraw` next to `snarf-native` gets
"bundled" for free). `zig build devdraw` fails with the §3b.3 message. **No `lazyDependency` call
and therefore no fetch happens off macOS, even with `-Ddevdraw=true`** (both conditions). The
X11 closure (`x11-*.c`, `x11-keysym2ucs.c`, `-lX11`) is a later phase with its own file-list
pass; nothing in this phase may reference it.

### 3f. Docs / records (Opus, same branch)

- `docs/spec/adr/0006-devdraw-fetch-dependency.md`: **Status line only** → `Accepted (2026-10-11,
  Larry's sign-off relayed by the orchestrator) · implemented by phase 18
  (agents/contracts/phase18-devdraw-build.md)`; in "Feedback into requirements" mark each item
  Done with the file touched. No other line of the ADR changes (immutability convention).
- `docs/spec/adr/0002-external-libraries.md`: Status line → `Accepted · Superseded in part by
  ADR-0006 (one lazy build.zig.zon entry: the pinned plan9port snapshot, consumed only by the
  devdraw peer build, never linked) — see there`. Nothing else.
- `CLAUDE.md` item 2: replace "The `build.zig.zon` dependency table stays empty." with "The
  `build.zig.zon` dependency table holds exactly one entry — ADR-0006's lazy, pinned plan9port
  snapshot, consumed only by `zig build native`/`zig build devdraw` to build the `devdraw` peer
  process, never linked into snarf or snarf-native." Keep the rest of the item verbatim.
- `docs/requirements/06-platform-and-build.md`: revision log **v2** + a note paragraph under §2:
  `zig build native`/`zig build devdraw` (macOS) additionally need (a) network once, to fetch the
  pinned snapshot into Zig's global cache (22 MB tarball; Zig then unpacks it to the git-ignored
  `zig-pkg/<hash>/`, 63 MB; offline: copy `~/.cache/zig/p/N-V-….tar.gz` or use `--system
  <dir>`), and (b) the macOS SDK from Xcode Command Line Tools for the Cocoa/Metal headers and
  frameworks. R-BLD-02's "no system C compiler" still holds (Zig's clang compiles
  everything); `zig build` and `zig build test` need neither — enforced by §4 T1/T2.
- `docs/spec/07-source-layout.md`: §4 tree gains `build/` ("build-time helpers for `build.zig`;
  import only `std`; not in any module graph"); §6's `host/devdraw/{…}` list gains
  `DevdrawPath.zig`.
- `agents/NEXT-PHASES.md`: "devdraw built in-tree" leaves Parked (done, phase 18); the Linux/X11
  pass becomes a new, separate backlog line ("devdraw in-tree, Linux/X11 file list").
- `agents/HANDOFF.md`: in-flight claim while the branch is open (files: `build.zig`,
  `build.zig.zon`, `build/`, `src/host/devdraw/{Conn,DevdrawPath}.zig`, `src/host/host.zig`,
  `src/main_native.zig`); after merge: environment facts (cache tarball path/size, SDK
  requirement, nested-build shape, the `--system` gate recipe) and the session entry.
- `agents/REVIEW-NOTES.md`: a "for you" entry per §5.
- Report: `agents/reports/phase18-devdraw-build.md` — shape of `phase15-native-spike.md`; must
  include: the final `otool -L zig-out/bin/devdraw`, `codesign -dv` summary, binary size,
  first-run wall time of `zig build native` (fetch + compile) and a warm no-op time, which of the
  §3b.7 fallbacks were needed (ideally none), the full diagnostic count from the C compile, test
  counts before/after, and the §4 T1/T2 transcripts.

### 3g. Rulings

- **R-P18-1 Gate = `-Ddevdraw` option + nested run.** The only `lazyDependency` call sits under
  `on_macos and want_devdraw`; `zig build native`/`zig build devdraw` reach it through
  `nested(b)`. Rationale in §2.5. CI/scripts may call `zig build devdraw -Ddevdraw=true`
  directly.
- **R-P18-2 Archives, not loose objects.** One static library per plan9port library, full mkfile
  list each; the linker pulls members (9l semantics; avoids `iprint` and friends colliding).
- **R-P18-3 Unmodified means unmodified.** No file from the fetched tree is copied into the repo,
  patched, pre-processed (beyond `mklatinkbd`, which is upstream's own generator), or compiled
  with defines other than `-DPLAN9PORT` and `get9root.c`'s `-DPLAN9_TARGET`. `-Wno-*` flags are
  diagnostics, not semantics, and are the only flag class Opus may add beyond §3b.6 if a new
  warning class floods the log (record it).
- **R-P18-4 macOS only; host == target.** devdraw and `mklatinkbd` build for `b.graph.host`; the
  native-host build is unsupported under `-Dtarget` ≠ host this phase (SDK detection is
  native-only anyway). Linux per §3e.
- **R-P18-5 Resolution probes derived paths, not explicit ones.** `$DEVDRAW` and bare `devdraw`
  are never probed; bundled and `$PLAN9/bin/devdraw` are. `self_exe_dir` comes from
  `std.process.executablePathAlloc` (follows symlinks), never cwd.
- **R-P18-6 Fixed `ReleaseFast`, `PLAN9_TARGET="/usr/local/plan9"`.** devdraw's optimize mode
  ignores `-Doptimize`; the compile-time plan9 root is upstream's documented default and is
  unreachable by any pulled member anyway.
- **R-P18-7 `latin1.h` is generated at build time by `mklatinkbd -r`, sed-free.** The dropped
  `sed 's/, }/ }/'` removes a legal trailing comma; the generated header is a build artifact,
  not a source. If clang rejects it (it will not), the fix is a Zig post-processing step applying
  exactly that substitution — never an edit to the generator.
- **R-P18-8 `run-native` runs `zig-out/bin/snarf-native`.** So that bundled resolution is
  exercised by the dev loop and not only by a packaged layout.
- **R-P18-9 Startup line is part of the interface.** `snarf-native: devdraw: <path> (<source>)`,
  `<source>` ∈ {`$DEVDRAW`, `bundled`, `$PLAN9/bin`, `$PATH`}; printed once, before `Tinit`.

### 3h. Acceptance (what "phase 18 passed" means)

1. `zig build --system <empty dir>` and `zig build test --system <empty dir>` exit 0 on macOS
   (and, structurally, would on Linux: no `lazyDependency` outside the §3b.3 guard — review
   checks the diff). Test count = main's count + the new `DevdrawPath` and `devdraw_files` tests.
2. `zig build native` on macOS (networked, cold cache): exit 0; `zig-out/bin/devdraw` and
   `zig-out/bin/snarf-native` exist, Mach-O arm64 (or x86_64 on Intel); `otool -L
   zig-out/bin/devdraw` lists Cocoa, Metal, QuartzCore, CoreFoundation, Carbon; `codesign -dv`
   reports a signature (Zig ad-hoc signs arm64 — if it does not, `codesign -s -` is a permitted
   install-time step, recorded). Running it again is a no-op (nested configure only).
   `zig-pkg/N-V-__8AAJ…/` now exists in the repo root and `git status` does not show it.
3. `zig build devdraw -Ddevdraw=true --system <empty dir>` exits non-zero with Zig's
   `lazy dependency package not found` (the negative control: nothing but the option stands
   between the test graph and the fetch); `zig build devdraw -Dtarget=x86_64-linux --system
   <empty dir>` exits non-zero with **our** §3b.3 message (no fetch attempted off macOS).
4. `DevdrawPath` unit tests (§4 T4) pass; `DEVDRAW=/usr/bin/true zig-out/bin/snarf-native` prints
   `snarf-native: devdraw: /usr/bin/true ($DEVDRAW)` and then fails (peer closed) — the line is
   printed before the spawn's outcome is known.
5. `git diff main -- src/core src/draw src/ninep src/dev src/shim web assets` is empty; no
   `*.c|*.m|*.h|*.s` file is added anywhere in the repo; `build.zig.zon`'s hash equals a fresh
   `zig fetch <url>` (run once by Sonnet).
6. `zig fmt --check build.zig build/ src/host src/main_native.zig` clean; `build/devdraw.zig`,
   `DevdrawPath.zig` under cap; `Conn.zig` shorter than before.

## 4. Named tests (sonnet)

- **T1 no-network gate**: `zig build --system "$(mktemp -d)"` and `zig build test --system
  "$(mktemp -d)"` exit 0. `ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)" zig build test` exits 0 and that
  cache's `p/` directory is absent or empty afterwards. (`--system` also enables "system
  integration" mode for `linkSystemLibrary`; nothing in the install/test graphs uses it — if a
  test exe starts failing under `--system` for that reason, that is a finding, not a gate tweak.)
- **T2 negative control**: `zig build devdraw -Ddevdraw=true --system "$(mktemp -d)"` fails and
  stderr contains `lazy dependency package not found`; `zig build devdraw -Dtarget=x86_64-linux
  --system "$(mktemp -d)"` fails and stderr contains `macOS only`.
- **T3 the binaries**: after `zig build native`: both files exist in `zig-out/bin/`; `file`,
  `otool -L`, `codesign -dv` as §3h.2; `ls -l` size recorded. `zig build run-native --help`-style
  smoke is not possible; instead T5.
- **T4 `DevdrawPath.resolve`** (headless, `Environ.Map` built in the test, a table-driven `Probe`):
  (a) `DEVDRAW=/x/devdraw` + bundled exists + `PLAN9` set ⇒ `/x/devdraw`, `.env_devdraw`;
  (b) no `DEVDRAW`, `self_exe_dir=/opt/snarf/bin`, probe says `/opt/snarf/bin/devdraw` exists,
  `PLAN9=/p9` ⇒ bundled wins (`.bundled`) — **the ADR's whole point**; (c) same but bundled
  absent, `/p9/bin/devdraw` exists ⇒ `.plan9`; (d) bundled absent, `PLAN9` set, `/p9/bin/devdraw`
  absent ⇒ `"devdraw"`, `.path`; (e) nothing set, `self_exe_dir=null` ⇒ `.path` and the probe was
  never called; (f) `DEVDRAW=""` (empty) is treated as unset; (g) `describe()` strings match
  R-P18-9 exactly. Allocation-checked with `testing.allocator`.
- **T5 startup line**: `DEVDRAW=/usr/bin/true zig-out/bin/snarf-native 2>&1 | head -1` equals
  `snarf-native: devdraw: /usr/bin/true ($DEVDRAW)`; exit status non-zero. (Shell step in the
  gate script, not a `zig test`.)
- **T6 unmodified source**: `git diff --stat main -- '*.c' '*.m' '*.h' '*.s'` empty;
  `grep -rn "\-D" build/devdraw.zig` shows only `PLAN9PORT` and `PLAN9_TARGET`; `zig fetch
  <url>` prints the manifest's hash.
- **T7 counts**: `build/devdraw_files.zig` tests assert lib9 top = 93 (incl. `get9root.c`), fmt =
  34, utf = 20, libdraw = 57, libmemdraw = 24, libmemlayer = 12, libthread = 10, libbio = 17,
  devdraw = 7; every entry ends in `.c` except exactly one `.m`.
- **T8 boundary**: `git diff main -- src/core src/draw src/ninep src/dev src/shim web assets`
  empty; wasm goldens and `tools/smoke_wasm.mjs` untouched (`zig build` output byte-identical).
- **T9 fmt + caps**: as §3h.6; `wc -l` reported for every new/changed file.

## 5. Manual check (Larry, after merge — not something the pipeline can do headlessly)

With `PLAN9=~/proj/plan9port` still set in the shell, as it is today:
`zig build native && zig build run-native` — the first line on stderr must read
`snarf-native: devdraw: …/zig-out/bin/devdraw (bundled)` (**not** `$PLAN9/bin`), a `snarf`
window opens, `Look` warps the pointer. Then `DEVDRAW=~/proj/plan9port/bin/devdraw zig build
run-native` ⇒ `($DEVDRAW)`; `rm zig-out/bin/devdraw && zig-out/bin/snarf-native` ⇒
`($PLAN9/bin)`. If the bundled window opens but behaves differently from the installed one
(fonts, HiDPI, cursor), that is a finding for REVIEW-NOTES — the two binaries are built from the
same source at the same SHA and should be indistinguishable.

## 6. For Opus: things to verify while coding, and report either way

- That `captureStdOut(.{ .basename = "latin1.h" })` yields a file literally named `latin1.h` and
  `.dirname()` on it is accepted by `addIncludePath`; else use `WriteFile.addCopyFile`.
- That Zig's MachO linker resolves the lib9↔libthread archive cycle without §3b.7(a).
- The exact 0.16 `Io` call used for the existence probe, and that `executablePathAlloc`
  returns the `zig-out/bin` path (not a `.zig-cache/o/...` path) when run via `run-native`.
- The wall-clock of the first `zig build native` and the size of `zig-out/bin/devdraw`
  (plan9port's own is a few hundred KB; an order of magnitude more means something unneeded was
  pulled — investigate, do not ship).
- Whether `--summary` noise or `stdio = .inherit` makes the nested run's output confusing; the
  user-facing contract is "one command, one window", so tidy if cheap, report if not.
