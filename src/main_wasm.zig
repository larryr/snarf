//! Freestanding WASM entry point (S-07 §4). Exports the three lifecycle hooks
//! the shim calls; imports the whole graph so the binary links end to end.
//! No allocation yet — this is the "empty but loading" scaffold.
const core = @import("core");
const dev = @import("dev");

comptime {
    // Force the graph to link so `zig build` proves the wiring, not just a stub.
    _ = core.Editor;
    _ = dev.draw;
}

/// Called once after instantiation. (S-06 §2: exports init/wake/tick.)
export fn init() void {}

/// Called by the shim when inbound events are waiting in the ring buffer.
export fn wake() void {}

/// Called on each animation-frame tick with the current time in milliseconds.
export fn tick(now_ms: u32) void {
    _ = now_ms;
}
