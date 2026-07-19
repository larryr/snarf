//! 9P Qid: the server's unique identity for a file. [ref: 9P2000 §Qid]
//! file-as-struct (S-07 P-1): this file *is* the Qid.
const std = @import("std");

const Qid = @This();

/// Qid.type bits (subset; full set filled in when fsys/xfid land).
pub const Type = packed struct(u8) {
    tmp: bool = false,
    _pad: u5 = 0,
    append: bool = false,
    dir: bool = false,
};

path: u64,
vers: u32 = 0,
qtype: Type = .{},

test "qid dir bit" {
    const q = Qid{ .path = 1, .qtype = .{ .dir = true } };
    try std.testing.expect(q.qtype.dir);
    try std.testing.expectEqual(@as(u64, 1), q.path);
}
