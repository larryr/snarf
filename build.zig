const std = @import("std");

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

    // --- snarf-headless: native harness (everything except shim, S-07 §6). ---
    const native = b.addExecutable(.{
        .name = "snarf-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_native.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "draw", .module = draw },
                .{ .name = "ninep", .module = ninep },
                .{ .name = "dev", .module = dev },
            },
        }),
    });
    b.installArtifact(native);
    const run_native = b.addRunArtifact(native);
    const run_step = b.step("run-native", "Run the native headless harness");
    run_step.dependOn(&run_native.step);

    // --- zig build serve: std-only dev server over zig-out/www (S-06 §3),
    //     setting application/wasm + COOP/COEP. Host tool, not in the editor
    //     module graph. Port via -Dport (default 8017). ---
    const port = b.option(u16, "port", "Port for `zig build serve` (default 8017)") orelse 8017;
    const bind = b.option([]const u8, "bind", "Bind address for `zig build serve` (default 127.0.0.1; use 0.0.0.0 for all interfaces)") orelse "127.0.0.1";
    const serve_opts = b.addOptions();
    serve_opts.addOption([]const u8, "www_dir", b.getInstallPath(.prefix, "www"));
    serve_opts.addOption(u16, "port", port);
    serve_opts.addOption([]const u8, "bind", bind);
    const serve_exe = b.addExecutable(.{
        .name = "snarf-serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = serve_opts.createModule() }},
        }),
    });
    const run_serve = b.addRunArtifact(serve_exe);
    run_serve.step.dependOn(b.getInstallStep()); // assemble zig-out/www first
    const serve_step = b.step("serve", "Serve zig-out/www over HTTP (application/wasm + COOP/COEP)");
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
    // The serve dev tool has its own tests (path resolution, content types).
    addModuleTests(b, test_step, target, optimize, "tools/serve.zig", &.{
        .{ .name = "build_options", .module = serve_opts.createModule() },
    });
    // Cross-module acceptance tests (orchestrator-owned): the one root where
    // the draw client and the dev servers meet natively (contract R-P2-2).
    addModuleTests(b, test_step, target, optimize, "src/accept.zig", &.{
        .{ .name = "core", .module = core },
        .{ .name = "draw", .module = draw },
        .{ .name = "ninep", .module = ninep },
        .{ .name = "dev", .module = dev },
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
