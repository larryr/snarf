const std = @import("std");
const devdraw_build = @import("build/devdraw.zig");

// Snarf build graph (S-06 §3). `zig build` is the ONLY build entry point and is
// identical on macOS and Linux (ADR-0001). No node/npm, no Emscripten, no WASI.
//
// The module graph below encodes the S-07 §6 import rules mechanically: a module
// can only @import the modules listed in its `.imports`, so `core` importing
// `shim` or `dev` is a compile error, not merely a convention (R-CON-02).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Module graph (leaf modules carry no target; they inherit it from
    //     whichever compilation — wasm or native test — consumes them). ---
    const ninep = b.addModule("ninep", .{
        .root_source_file = b.path("src/ninep/ninep.zig"),
    });
    const shim = b.addModule("shim", .{
        .root_source_file = b.path("src/shim/shim.zig"),
    });
    // Embedded font asset (public domain misc-fixed subfont; ADR-0002 license
    // note in assets/fonts/fixed/README.md). File-backed module so Font.zig can
    // @embedFile("font_fixed9x18") from outside its module root (phase-3 contract).
    const font_fixed9x18 = b.createModule(.{
        .root_source_file = b.path("assets/fonts/fixed/9x18.0000"),
    });
    const draw = b.addModule("draw", .{
        .root_source_file = b.path("src/draw/draw.zig"),
        .imports = &.{
            .{ .name = "ninep", .module = ninep },
            .{ .name = "font_fixed9x18", .module = font_fixed9x18 },
        },
    });
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .imports = &.{
            .{ .name = "draw", .module = draw },
            .{ .name = "ninep", .module = ninep },
        },
    });
    const dev = b.addModule("dev", .{
        .root_source_file = b.path("src/dev/dev.zig"),
        .imports = &.{
            .{ .name = "ninep", .module = ninep },
            .{ .name = "shim", .module = shim },
        },
    });
    // The NATIVE host's device layer (ADR-0005, phase 15): 9P devices that
    // forward to a plan9port `devdraw` child process over its `drawfcall` pipe.
    // Same layer as `dev` — it IS a host boundary, so `core` must never import
    // it (S-07 §6). It imports `dev` for one thing: the shared `/dev/mouse`
    // record formatter, so the two hosts cannot drift in what a record is.
    const host = b.addModule("host", .{
        .root_source_file = b.path("src/host/host.zig"),
        .imports = &.{
            .{ .name = "ninep", .module = ninep },
            .{ .name = "dev", .module = dev },
        },
    });
    // `/mnt/origin` boot glue (R-P12-5/6/7): the WebSocket transport (`shim`)
    // joined to the mount table and 9P client (`ninep`). Same layer as `dev` —
    // it sees the browser boundary, so `core` must never import it. Its own
    // module (rather than living in `src/main_wasm.zig`) so the mount state
    // machine is exercised NATIVELY by `zig build test`, with no browser.
    const origin = b.addModule("origin", .{
        .root_source_file = b.path("src/origin/origin.zig"),
        .imports = &.{
            .{ .name = "ninep", .module = ninep },
            .{ .name = "shim", .module = shim },
        },
    });

    // The host file system as 9P (phase 20, R-P20-1): `HostFs` + the atomic
    // Put + a root-level tree. Shared by the origin server (`fs/`) and the
    // native host (mounted at `/`). It touches the host file system, so it is
    // a host-side layer like `host`: `core`/`draw`/`ninep` never import it.
    const hostfs = b.addModule("hostfs", .{
        .root_source_file = b.path("src/hostfs/root.zig"),
        .imports = &.{
            .{ .name = "ninep", .module = ninep },
        },
    });

    // --- snarf.wasm: freestanding, exports init/wake/tick (S-06 §2). ---
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    // Bounds checks are cheap insurance in v1 (S-06 §2): default the wasm build
    // to ReleaseSafe rather than Debug; honour an explicit -Doptimize otherwise.
    const wasm_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseSafe else optimize;
    const wasm = b.addExecutable(.{
        .name = "snarf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_wasm.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "dev", .module = dev },
                .{ .name = "draw", .module = draw },
                .{ .name = "ninep", .module = ninep },
                .{ .name = "origin", .module = origin },
                .{ .name = "shim", .module = shim },
            },
        }),
    });
    // Reactor-style module: no _start; the shim drives the exported hooks.
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    // Assemble zig-out/www/: the wasm plus web/ verbatim (S-06 §3).
    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "www" } },
    });
    const install_web = b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .{ .custom = "www" },
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&install_wasm.step);
    b.getInstallStep().dependOn(&install_web.step);

    // --- snarf-native: the NATIVE HOST (ADR-0005). The same editor core, in a
    //     real window, through a plan9port `devdraw` child process. Everything
    //     except `shim` (S-07 §6); `core`/`draw`/`ninep` are the SAME module
    //     objects the wasm build consumes — no -D forks, no host #ifdefs. ---
    const native = b.addExecutable(.{
        .name = "snarf-native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_native.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "draw", .module = draw },
                .{ .name = "ninep", .module = ninep },
                .{ .name = "dev", .module = dev },
                .{ .name = "host", .module = host },
                .{ .name = "hostfs", .module = hostfs },
            },
        }),
    });
    b.installArtifact(native);
    const native_step = b.step("native", "Build the native host (snarf-native; on macOS also zig-out/bin/devdraw)");
    native_step.dependOn(&b.addInstallArtifact(native, .{}).step);

    // --- devdraw: the display-server PEER, built from the pinned plan9port
    //     (ADR-0006, phase 18). The ONLY `lazyDependency` call in the repo sits
    //     under both conditions: `build()` cannot see which steps were asked
    //     for, so the fetch is gated on `-Ddevdraw=true`, and `zig build
    //     native`/`zig build devdraw` reach it through a nested `zig build
    //     devdraw -Ddevdraw=true` (R-P18-1). `zig build`/`zig build test`
    //     never touch the dependency. macOS only, host == target (R-P18-4). ---
    const want_devdraw = b.option(bool, "devdraw", "Build the bundled devdraw peer from the pinned plan9port (macOS only; fetches ~22 MB once; implied by `zig build native`)") orelse false;
    const on_macos = target.result.os.tag == .macos;
    const devdraw_step = b.step("devdraw", "Build zig-out/bin/devdraw, the bundled display server");
    if (on_macos and want_devdraw) {
        if (b.lazyDependency("plan9port", .{})) |dep|
            devdraw_step.dependOn(&devdraw_build.add(b, dep).step);
    } else if (on_macos) {
        // `--system` can't be forwarded into the nested invocation (the pkgdir
        // is consumed by this process, not visible to build()), so without
        // this check `zig build native --system <dir>` would silently fetch
        // from the network through the nested build, defeating --system's
        // "disable package fetching" promise. Fail fast instead (fable review).
        if (b.graph.system_package_mode) {
            devdraw_step.dependOn(&b.addFail("--system: run `zig build devdraw -Ddevdraw=true --system <dir>` directly").step);
        } else {
            devdraw_step.dependOn(&devdraw_build.nested(b).step);
        }
    } else {
        devdraw_step.dependOn(&b.addFail("devdraw is built in-tree on macOS only (ADR-0006, phase 18); on this OS set $PLAN9 or $DEVDRAW to an installed devdraw").step);
    }
    if (on_macos) native_step.dependOn(devdraw_step);

    // R-P18-8: run the INSTALLED binary, so the bundled `devdraw` beside it is
    // what `DevdrawPath` finds (a cached exe has no sibling).
    const run_native = b.addSystemCommand(&.{b.getInstallPath(.bin, "snarf-native")});
    run_native.step.dependOn(native_step);
    const run_step = b.step("run-native", "Run the native host: the editor in a devdraw window");
    run_step.dependOn(&run_native.step);

    // --- zig build serve: the origin server (S-02 §5, S-06 §3) — static
    //     zig-out/www with application/wasm + COOP/COEP, plus 9P2000 over
    //     WebSocket at /9p exporting `-Dexport` (default: this repo). Host
    //     tool, outside the editor module graph; std + ninep + hostfs. ---
    const port = b.option(u16, "port", "Port for `zig build serve` (default 8017)") orelse 8017;
    const bind = b.option([]const u8, "bind", "Bind address for `zig build serve` (default 127.0.0.1; use 0.0.0.0 for all interfaces)") orelse "127.0.0.1";
    const export_dir = b.option([]const u8, "export", "Directory served read/write at /9p `fs/` (default: the repo root)") orelse b.build_root.path orelse ".";
    const serve_opts = b.addOptions();
    serve_opts.addOption([]const u8, "www_dir", b.getInstallPath(.prefix, "www"));
    serve_opts.addOption(u16, "port", port);
    serve_opts.addOption([]const u8, "bind", bind);
    serve_opts.addOption([]const u8, "export_dir", export_dir);
    const serve_exe = b.addExecutable(.{
        .name = "snarf-origin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/origin/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ninep", .module = ninep },
                .{ .name = "hostfs", .module = hostfs },
                .{ .name = "build_options", .module = serve_opts.createModule() },
            },
        }),
    });
    b.installArtifact(serve_exe);
    const run_serve = b.addRunArtifact(serve_exe);
    run_serve.step.dependOn(b.getInstallStep()); // assemble zig-out/www first
    const serve_step = b.step("serve", "Run the origin server: zig-out/www over HTTP + 9P over WebSocket at /9p");
    serve_step.dependOn(&run_serve.step);

    // --- Tests: every module's colocated `test` blocks, run natively. core,
    //     draw and ninep are compiled with NO shim on the path (S-07 §6). ---
    const test_step = b.step("test", "Run unit tests (core+draw+ninep have no shim)");
    addModuleTests(b, test_step, target, optimize, "src/ninep/ninep.zig", &.{});
    addModuleTests(b, test_step, target, optimize, "src/shim/shim.zig", &.{});
    addModuleTests(b, test_step, target, optimize, "src/draw/draw.zig", &.{
        .{ .name = "ninep", .module = ninep },
        .{ .name = "font_fixed9x18", .module = font_fixed9x18 },
    });
    addModuleTests(b, test_step, target, optimize, "src/core/core.zig", &.{
        .{ .name = "draw", .module = draw },
        .{ .name = "ninep", .module = ninep },
    });
    addModuleTests(b, test_step, target, optimize, "src/dev/dev.zig", &.{
        .{ .name = "ninep", .module = ninep },
        .{ .name = "shim", .module = shim },
    });
    // The native host's device layer (phase 15). CI has no window, so these are
    // codec + scripted-peer tests only: no child process, no thread.
    addModuleTests(b, test_step, target, optimize, "src/host/host.zig", &.{
        .{ .name = "ninep", .module = ninep },
        .{ .name = "dev", .module = dev },
    });
    // The bundled-devdraw file table's count assertions (phase 18, §3c). A
    // build-time helper, std-only; testing it touches no dependency.
    addModuleTests(b, test_step, target, optimize, "build/devdraw_files.zig", &.{});
    // The host file system as 9P, atomic Put included (phase 20).
    addModuleTests(b, test_step, target, optimize, "src/hostfs/root.zig", &.{
        .{ .name = "ninep", .module = ninep },
    });
    // The `/mnt/origin` state machine over a scripted browser (R-P12-9a).
    addModuleTests(b, test_step, target, optimize, "src/origin/origin.zig", &.{
        .{ .name = "ninep", .module = ninep },
        .{ .name = "shim", .module = shim },
    });
    // The origin server: unit tests per file plus a loopback acceptance test
    // (real listener, real WebSocket, real ninep.Client) rooted at accept.zig.
    addModuleTests(b, test_step, target, optimize, "tools/origin/accept.zig", &.{
        .{ .name = "ninep", .module = ninep },
        .{ .name = "hostfs", .module = hostfs },
        .{ .name = "build_options", .module = serve_opts.createModule() },
    });
    // Cross-module acceptance tests (orchestrator-owned): the one root where
    // the draw client and the dev servers meet natively (contract R-P2-2).
    addModuleTests(b, test_step, target, optimize, "src/accept.zig", &.{
        .{ .name = "core", .module = core },
        .{ .name = "draw", .module = draw },
        .{ .name = "ninep", .module = ninep },
        .{ .name = "dev", .module = dev },
        .{ .name = "hostfs", .module = hostfs }, // phase 20: the real HostTree behind accept_hostfs.zig
        .{ .name = "shim", .module = shim }, // test_blit seam (phase-5); core's no-shim boundary is separately guarded
        .{ .name = "font_fixed9x18", .module = font_fixed9x18 },
    });
}

/// Build a test executable rooted at `root` with exactly `imports` visible, and
/// hang its run step off `test_step`. The explicit import list is what makes an
/// out-of-layer @import a compile error rather than a lint.
fn addModuleTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
    imports: []const std.Build.Module.Import,
) void {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(t).step);
}
