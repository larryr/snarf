//! 9P message tagged union + encode/decode. Stub: only the shape is here;
//! the full T/R message set lands with the client/server (S-07 §4). (P-6)
const std = @import("std");

/// 9P2000 message type codes (Tversion=100 … Rwstat=127). Stubbed subset.
pub const Kind = enum(u8) {
    tversion = 100,
    rversion = 101,
    terror = 106, // reserved (never sent), kept for completeness
    rerror = 107,
    _,
};

test "message kind values" {
    try std.testing.expectEqual(@as(u8, 100), @intFromEnum(Kind.tversion));
    try std.testing.expectEqual(@as(u8, 107), @intFromEnum(Kind.rerror));
}
