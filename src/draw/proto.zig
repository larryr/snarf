//! Draw-protocol message encoding (tagged union, P-6). [ref: 9/port/devdraw.c,
//! S-03]. Stub: one representative verb so the tagged-union shape is exercised.
const std = @import("std");
const ninep = @import("ninep");

/// A draw-protocol operation. The full verb set (S-03 §2) fills in with Display.
pub const Op = union(enum) {
    /// Allocate an image with the given qid-addressed backing.
    alloc: struct { id: u32, qid: ninep.Qid },
    /// Flush pending draws to the device.
    flush,
};

test "draw op tagged union" {
    const op: Op = .{ .alloc = .{ .id = 7, .qid = .{ .path = 3 } } };
    switch (op) {
        .alloc => |a| try std.testing.expectEqual(@as(u32, 7), a.id),
        .flush => try std.testing.expect(false),
    }
}
