//! Native entry point (S-07 §4): a headless harness for running the core
//! against native devices — fuzzing, scripting, and the target of `zig build
//! run-native`. Imports everything EXCEPT `shim` (S-07 §6).
const std = @import("std");
const core = @import("core");

pub fn main() !void {
    var ed = core.Editor.init(std.heap.page_allocator);
    defer ed.deinit();
    std.debug.print("snarf headless harness — Editor up (seq={d})\n", .{ed.seq});
}
