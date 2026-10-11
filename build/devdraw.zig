//! `devdraw` — the build graph for the bundled `devdraw` peer (ADR-0006, phase
//! 18 contract §3b). BUILD-TIME ONLY: imported by `build.zig`, imports only
//! `std` (+ its sibling table), part of no S-07 module graph.
//!
//! What it builds, from the fetched, UNMODIFIED `larryr/plan9port@337c6ac`
//! (R-P18-3), for the build host (R-P18-4), at a fixed `ReleaseFast` (R-P18-6):
//!
//!   lib9 libbio libthread libdraw libmemdraw libmemlayer   static archives (R-P18-2)
//!   mklatinkbd                     host tool → latin1.h   (devdraw/mkfile:36-37)
//!   devdraw                        zig-out/bin/devdraw    (install.log:2868)
//!
//! This mirrors what `9c`/`9l` do on Darwin (`bin/9c:65-88,116-118,154`,
//! `bin/9l`), minus everything the closure does not use (the `OSX_VERSION`
//! define, `-lresolv`, `libmux`) — see the contract §1.
//!
//! `nested` is how `zig build native`/`zig build devdraw` reach `add` without
//! the default graph ever calling `lazyDependency` (R-P18-1): `build()` cannot
//! see which steps were requested, so the fetch is gated on `-Ddevdraw=true`
//! and those two steps run a second `zig build devdraw -Ddevdraw=true`.
const std = @import("std");
const files = @import("devdraw_files.zig");

/// Applied to every C and ObjC file (contract §3b.6, binding). `-DPLAN9PORT`
/// is `bin/9c:154`; the `-W` set is 9c's diagnostics set verbatim
/// (`bin/9c:65-88`) plus `-Wno-deprecated-declarations`, which 9c hides
/// textually instead (`bin/9c:55`; `mac-screen.m:1242` `GetCurrentProcess`).
/// No `-O`/`-g`/`-m64`/`-Werror`: the optimize mode is the module's.
const cflags = [_][]const u8{
    "-DPLAN9PORT",
    "-fsigned-char",
    "-fno-common",
    "-fno-sanitize=undefined",
    "-Wno-parentheses",
    "-Wno-missing-braces",
    "-Wno-switch",
    "-Wno-comment",
    "-Wno-sign-compare",
    "-Wno-unknown-pragmas",
    "-Wno-empty-body",
    "-Wno-unused-value",
    "-Wno-array-bounds",
    "-Wno-gnu-designator",
    "-Wno-unneeded-internal-declaration",
    "-Wno-deprecated-pragma",
    "-Wno-unused-but-set-variable",
    "-Wno-deprecated-declarations",
};

/// `lib9/mkfile:178-179` + `INSTALL:37`: the compile-time plan9 root, read
/// only when `$PLAN9` is unset (`get9root.c:14`) and by no pulled member.
/// plan9port's documented default install root (R-P18-6).
const get9root_flags = cflags ++ [_][]const u8{"-DPLAN9_TARGET=\"/usr/local/plan9\""};

/// `devdraw/mkfile:42-43`: `$CC $CFLAGS $OBJCFLAGS -fobjc-arc`.
const objc_flags = cflags ++ [_][]const u8{"-fobjc-arc"};

/// Frameworks, from the `AUTOFRAMEWORK` markers 9l reads (`include/u.h:174-175`):
/// `mac-screen.m:27-30` (Cocoa, Metal, QuartzCore, CoreFoundation) and
/// `include/draw.h:9` (Carbon — `mac-screen.m:1242` calls `GetCurrentProcess`).
const frameworks = [_][]const u8{ "Cocoa", "Metal", "QuartzCore", "CoreFoundation", "Carbon" };

/// The whole devdraw graph. Returns the install step for
/// `zig-out/bin/devdraw`, which lands beside `zig-out/bin/snarf-native`.
pub fn add(b: *std.Build, dep: *std.Build.Dependency) *std.Build.Step.InstallArtifact {
    const include = dep.path("include");

    // ---- lib9: three source dirs (lib9/mkfile:172-176) + get9root alone ----
    const lib9 = archive(b, "9", include);
    lib9.root_module.addIncludePath(dep.path("src/lib9/fmt")); // the mkfile's -Ifmt
    addFiles(lib9, dep.path("src/lib9"), &files.lib9, &cflags);
    addFiles(lib9, dep.path("src/lib9/fmt"), &files.lib9_fmt, &cflags);
    addFiles(lib9, dep.path("src/lib9/utf"), &files.lib9_utf, &cflags);
    addFiles(lib9, dep.path("src/lib9"), &files.lib9_get9root, &get9root_flags);

    const libbio = archive(b, "bio", include);
    addFiles(libbio, dep.path("src/libbio"), &files.libbio, &cflags);

    const libthread = archive(b, "thread", include);
    libthread.root_module.addIncludePath(dep.path("src/libthread")); // its -I.
    addFiles(libthread, dep.path("src/libthread"), &files.libthread, &cflags);

    const libdraw = archive(b, "draw", include);
    addFiles(libdraw, dep.path("src/libdraw"), &files.libdraw, &cflags);

    const libmemdraw = archive(b, "memdraw", include);
    addFiles(libmemdraw, dep.path("src/libmemdraw"), &files.libmemdraw, &cflags);

    const libmemlayer = archive(b, "memlayer", include);
    addFiles(libmemlayer, dep.path("src/libmemlayer"), &files.libmemlayer, &cflags);

    // ---- latin1.h: upstream's own generator, sed-free (R-P18-7) ----
    // `./o.mklatinkbd -r $PLAN9/lib/keyboard | sed 's/, }/ }/'`
    // (devdraw/mkfile:36-37); the sed only strips a trailing comma inside an
    // initializer list, which C accepts, so it is dropped.
    const mklatinkbd = b.addExecutable(.{ .name = "mklatinkbd", .root_module = cModule(b, include) });
    mklatinkbd.root_module.addCSourceFiles(.{
        .root = dep.path("src/cmd/devdraw"),
        .files = &.{files.mklatinkbd},
        .flags = &cflags,
    });
    mklatinkbd.root_module.linkLibrary(libbio);
    mklatinkbd.root_module.linkLibrary(lib9);
    const gen = b.addRunArtifact(mklatinkbd);
    gen.addArg("-r");
    gen.addFileArg(dep.path("lib/keyboard"));
    const latin1_h = gen.captureStdOut(.{ .basename = "latin1.h" });

    // ---- devdraw itself: seven objects (install.log:2868) ----
    const exe = b.addExecutable(.{ .name = "devdraw", .root_module = cModule(b, include) });
    const m = exe.root_module;
    m.addIncludePath(latin1_h.dirname()); // latin1.c:14 `#include "latin1.h"`
    addFiles(exe, dep.path("src/cmd/devdraw"), &files.devdraw_c, &cflags);
    addFiles(exe, dep.path("src/cmd/devdraw"), &files.devdraw_objc, &objc_flags);
    // 9l's order (`liborder`): memdraw memlayer draw thread 9. Not linked:
    // libmux, libbio, resolv (nothing in the closure pulls them, contract §1).
    for ([_]*std.Build.Step.Compile{ libmemdraw, libmemlayer, libdraw, libthread, lib9 }) |lib|
        m.linkLibrary(lib);
    for (frameworks) |fw| m.linkFramework(fw, .{});

    return b.addInstallArtifact(exe, .{});
}

/// A second `zig build devdraw -Ddevdraw=true` against this same build file,
/// prefix and caches (contract §3b.8). Inherits stdio so the one-time fetch
/// progress and any C diagnostics are visible; has no outputs, so it runs
/// every time — the inner build is fully cached, so a no-op costs only its
/// configure phase. `-Doptimize`/`-Dtarget` are deliberately not forwarded
/// (R-P18-4/-6). It cannot recurse: under `-Ddevdraw=true` the `devdraw` step
/// depends on `add`'s artifact, never on this.
pub fn nested(b: *std.Build) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,          "build",              "devdraw",
        "-Ddevdraw=true",         "--build-file",       b.pathFromRoot("build.zig"),
        "--prefix",               b.install_path,       "--cache-dir",
        dirPath(b, b.cache_root), "--global-cache-dir", dirPath(b, b.graph.global_cache_root),
    });
    run.setName("zig build devdraw -Ddevdraw=true");
    run.stdio = .inherit;
    return run;
}

fn dirPath(b: *std.Build, dir: std.Build.Cache.Directory) []const u8 {
    return dir.path orelse b.pathFromRoot(".");
}

/// The module every devdraw C/ObjC compilation shares: host target, fixed
/// `ReleaseFast` (9c is `-O2`; never Debug/ReleaseSafe — UBSan traps on
/// plan9port's pointer games), libc, no C sanitizer, plan9port's `include/`.
fn cModule(b: *std.Build, include: std.Build.LazyPath) *std.Build.Module {
    const m = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .sanitize_c = .off,
    });
    m.addIncludePath(include);
    return m;
}

/// One static archive per plan9port library (`lib<name>.a`), like `9ar`.
fn archive(b: *std.Build, name: []const u8, include: std.Build.LazyPath) *std.Build.Step.Compile {
    return b.addLibrary(.{ .name = name, .linkage = .static, .root_module = cModule(b, include) });
}

fn addFiles(c: *std.Build.Step.Compile, root: std.Build.LazyPath, names: []const []const u8, flags: []const []const u8) void {
    c.root_module.addCSourceFiles(.{ .root = root, .files = names, .flags = flags });
}
