//! PLACEHOLDER — B1's real file wins at merge.
//!
//! Minimal stand-in implementing exactly the R-P5-7 CanvasBackend surface so
//! B2's `main_wasm.zig` and `tools/smoke_wasm.mjs` can be built and exercised
//! before B1's pixel path lands. It wraps a HeadlessBackend and delegates every
//! op — including flush — straight through, WITHOUT the abi.blit import. The
//! orchestrator discards this file at merge; do not add pixel/geometry logic or
//! tests here (keep it refAllDecls-safe).
const draw_backend = @import("draw_backend.zig");

pub const CanvasBackend = struct {
    /// The wrapped software framebuffer (R-P5-7: pub field named `headless`).
    headless: draw_backend.HeadlessBackend,

    const Self = @This();

    pub fn init(allocator: @import("std").mem.Allocator, width: u32, height: u32) draw_backend.Error!Self {
        return .{ .headless = try draw_backend.HeadlessBackend.init(allocator, width, height) };
    }

    pub fn deinit(self: *Self) void {
        self.headless.deinit();
    }

    /// Real file blits on flush; this placeholder just hands back the wrapped
    /// headless backend so every op (flush included) delegates with no blit.
    pub fn backend(self: *Self) draw_backend.Backend {
        return self.headless.backend();
    }
};
