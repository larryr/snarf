//! The WASM env ABI: extern imports/exports + a version hash that both this
//! file and `web/shim.js` must agree on (S-06 §4). Drift becomes a build error
//! once the JS mirror + generated checksum land (OQ-BLD-2, still deferred).
//!
//! Phase 5 wires the first import: `blit`, the single merged present operation
//! (R-P5-4 — S-06 §4's `blit(imgId,…)+flush(rectsPtr,n)` collapses to one call).
//! R-P5-5/R-P5-7: the extern lives behind an `is_wasm` comptime gate so the
//! native shim test root (build.zig:134 compiles this file for the host) never
//! references the symbol; `test_blit` is the native recording seam that stands
//! in for the browser import under `zig build test`.
const builtin = @import("builtin");

/// Bumped whenever the import/export surface changes (1→2 this phase, R-P5-4).
/// `web/shim.js` carries the mirror of this value; the two must match, and the
/// wasm module re-exports it via `abi_version()` so the shim can check before
/// calling `init()`.
pub const version: u32 = 2;

/// True only for the freestanding wasm build. A comptime const, so the `blit`
/// dispatch below prunes the extern branch entirely in native builds — the
/// `env.blit` symbol is therefore never referenced when this file is compiled
/// for the host (R-P5-5).
pub const is_wasm = builtin.cpu.arch == .wasm32;

/// Present a dirty rectangle of the framebuffer. `ptr` points at RGBA8888
/// row-major pixels covering the full `fb_w × fb_h` display; `(x,y,w,h)` is the
/// half-open damage rect within it (R-P5-7).
pub const BlitFn = *const fn (ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void;

/// Native seam (R-P5-5): tests install a recorder here; `blit` calls it when it
/// is set and no wasm import exists. Null in production native builds ⇒ no-op.
pub var test_blit: ?BlitFn = null;

/// The browser-provided import, referenced ONLY under wasm (see `blit`). Kept
/// private so nothing outside this file can reach the raw extern.
const js = struct {
    extern "env" fn blit(ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void;
};

/// Blit dispatch (R-P5-5/R-P5-7). Under wasm this calls the `env.blit` import;
/// natively it routes to `test_blit` if installed, else does nothing. Because
/// `is_wasm` is comptime-known, exactly one branch is analyzed per target — the
/// extern is unreachable (and unemitted) in the native shim test root.
pub fn blit(ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void {
    if (is_wasm) {
        js.blit(ptr, fb_w, fb_h, x, y, w, h);
    } else if (test_blit) |f| {
        f(ptr, fb_w, fb_h, x, y, w, h);
    }
}

test "abi version is present and bumped to 2" {
    try @import("std").testing.expectEqual(@as(u32, 2), version);
}
