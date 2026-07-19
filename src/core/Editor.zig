//! The editor context: owns what ACME's `dat.c` declared as 60 globals (P-3).
//! No globals anywhere else — state hangs off this struct, allocator stored
//! explicitly (P-4). file-as-struct (P-1): this file *is* the Editor.
//! [ref: acme/dat.c + globals]
const std = @import("std");
const draw = @import("draw");
const ninep = @import("ninep");

const Editor = @This();

/// The allocator every long-lived editor allocation flows through (P-4).
allocator: std.mem.Allocator,
/// Global edit sequence number (ACME `seq`); bumped per user command.
seq: u32 = 0,

pub fn init(allocator: std.mem.Allocator) Editor {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Editor) void {
    self.* = undefined;
}

// Compile-time proof the allowed dependencies resolve through this module.
comptime {
    std.debug.assert(@hasDecl(draw, "proto"));
    std.debug.assert(@hasDecl(ninep, "msg"));
}

test "editor init/deinit round-trip" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try std.testing.expectEqual(@as(u32, 0), ed.seq);
    ed.seq += 1;
    try std.testing.expectEqual(@as(u32, 1), ed.seq);
}
