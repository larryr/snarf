//! A color scheme: the values `Chrome.init` allocates its solids from.
//! file-as-struct (S-07 P-1): this file *is* the Palette. Four named schemes
//! ship (ADR-0007); `snarf-native -colors=NAME` selects one by name, every
//! other boot takes `default`.
//!
//! The slot STRUCTURE is acme's `iconinit` (acme.c:1036-1086): per region a
//! BACK/HIGH/BORD/TEXT quartet (HTEXT == TEXT in every scheme), the dirty-button
//! square, the column button, the B2/B3 sweeps. DIVERGENCE (ADR-0007): the
//! VALUES are snarf's own except in `acme`, which is byte-exact; `ground` and
//! `rule` name what acme hard-wires as `display->white`/`display->black` (the
//! empty-space fill and the column/row separator bands, rows.c:31,45).
//!
//! Colors are rrggbbaa. The light backs are `allocimagemix(nominal, DWhite)`
//! pre-computed (c·63/255 + white·192/255 per channel); the tests prove each.
//!
//! Imports: `draw` only (S-07 §6).
const std = @import("std");
const draw = @import("draw");

const Palette = @This();
const Color = draw.proto.Color;

body_back: Color,
body_high: Color,
body_bord: Color,
body_text: Color,
tag_back: Color,
tag_high: Color,
tag_bord: Color,
tag_text: Color,
/// The modified-button center (acme.c:1077).
mod: Color,
/// The column/row tag button (acme.c:1082).
col_button: Color,
/// B2 sweep highlight (acme.c:1084).
but2: Color,
/// B3 sweep highlight (acme.c:1085).
but3: Color,
/// Empty space under the tree (acme.c:551, cols.c:32, rows.c:31 `display->white`).
ground: Color,
/// Column/row separator bands (cols.c:45, rows.c:45 `display->black`).
rule: Color,

/// The default: manila body (mix 0xFFCC99), periwinkle tag (mix 0xBBBBFF).
pub const sunapee: Palette = .{
    .body_back = 0xFFF2E5FF,
    .body_high = 0xF2D2A8FF,
    .body_bord = 0xA47F54FF,
    .body_text = 0x000000FF,
    .tag_back = 0xEEEEFFFF,
    .tag_high = 0xCCCCEEFF,
    .tag_bord = 0x7C7CC4FF,
    .tag_text = 0x000000FF,
    .mod = 0x000099FF,
    .col_button = 0x7C7CC4FF,
    .but2 = 0xAA0000FF,
    .but3 = 0x006600FF,
    .ground = 0xFFFFFFFF,
    .rule = 0x000000FF,
};

/// rio's greys: white body, rio's title-bar tag family (mix 0x9EEEEE).
pub const whiteface: Palette = .{
    .body_back = 0xFFFFFFFF,
    .body_high = 0xCCCCCCFF,
    .body_bord = 0x999999FF,
    .body_text = 0x000000FF,
    .tag_back = 0xE7FAFAFF,
    .tag_high = 0x9EEEEEFF,
    .tag_bord = 0x55AAAAFF,
    .tag_text = 0x000000FF,
    .mod = 0x000099FF,
    .col_button = 0x55AAAAFF,
    .but2 = 0xAA0000FF,
    .but3 = 0x006600FF,
    .ground = 0xEEEEEEFF,
    .rule = 0x000000FF,
};

/// Dark: light text on near-black backs; the dirty square turns amber
/// because 0x000099 fails on a dark tag.
pub const monadnock: Palette = .{
    .body_back = 0x22201CFF,
    .body_high = 0x4A4436FF,
    .body_bord = 0x7A7258FF,
    .body_text = 0xE6E2D6FF,
    .tag_back = 0x1C2228FF,
    .tag_high = 0x3A4654FF,
    .tag_bord = 0x707A94FF,
    .tag_text = 0xDCE4EEFF,
    .mod = 0xE8B04AFF,
    .col_button = 0x707A94FF,
    .but2 = 0xAA0000FF,
    .but3 = 0x006600FF,
    .ground = 0x141414FF,
    .rule = 0x000000FF,
};

/// acme's own palette, byte-exact (acme.c:1044-1085).
pub const acme: Palette = .{
    .body_back = 0xFFFFEAFF, // mix(DPaleyellow) acme.c:1051
    .body_high = 0xEEEE9EFF, // DDarkyellow acme.c:1052
    .body_bord = 0x99994CFF, // DYellowgreen acme.c:1053
    .body_text = 0x000000FF, // display->black acme.c:1054
    .tag_back = 0xEAFFFFFF, // mix(DPalebluegreen) acme.c:1044
    .tag_high = 0x9EEEEEFF, // DPalegreygreen acme.c:1045
    .tag_bord = 0x8888CCFF, // DPurpleblue acme.c:1046
    .tag_text = 0x000000FF, // display->black acme.c:1047
    .mod = 0x000099FF, // DMedblue acme.c:1077
    .col_button = 0x8888CCFF, // DPurpleblue acme.c:1082
    .but2 = 0xAA0000FF, // acme.c:1084
    .but3 = 0x006600FF, // acme.c:1085
    .ground = 0xFFFFFFFF, // display->white acme.c:551
    .rule = 0x000000FF, // display->black cols.c:45
};

pub const default: *const Palette = &sunapee;

/// The selectable names, sorted.
pub const names = [_][]const u8{ "acme", "monadnock", "sunapee", "whiteface" };

const table = [_]struct { name: []const u8, pal: *const Palette }{
    .{ .name = "acme", .pal = &acme },
    .{ .name = "monadnock", .pal = &monadnock },
    .{ .name = "sunapee", .pal = &sunapee },
    .{ .name = "whiteface", .pal = &whiteface },
};

pub fn fromName(name: []const u8) ?*const Palette {
    for (table) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.pal;
    }
    return null;
}

/// One command-line argument against the `-colors=NAME` flag (ADR-0007 §2:
/// exact `=` form only).
pub const Flag = union(enum) {
    /// Not the flag at all.
    other,
    palette: *const Palette,
    /// `-colors` without `=`, or `=NAME` naming no scheme (possibly empty).
    unknown: []const u8,
};

pub const flag_prefix = "-colors=";

pub fn parseFlag(arg: []const u8) Flag {
    if (std.mem.eql(u8, arg, "-colors")) return .{ .unknown = "" };
    if (!std.mem.startsWith(u8, arg, flag_prefix)) return .other;
    const name = arg[flag_prefix.len..];
    return if (fromName(name)) |p| .{ .palette = p } else .{ .unknown = name };
}

// ===========================================================================
// Tests.
// ===========================================================================
const testing = std.testing;

/// `allocimagemix(c1, DWhite)` on a deep display (allocimagemix.c:28-42): blend
/// `c1` over white through a 0x3F (63/255) alpha mask, per channel.
fn mix(c1: u32) u32 {
    var out: u32 = 0;
    var shift: u5 = 24;
    while (true) {
        const c1b: u32 = (c1 >> shift) & 0xFF;
        const v: u32 = (c1b * 63 + 0xFF * 192) / 255;
        out |= (v & 0xFF) << shift;
        if (shift == 0) break;
        shift -= 8;
    }
    return out;
}

test "palette: fromName resolves the four names, default is sunapee" {
    for (names) |n| try testing.expect(fromName(n) != null);
    try testing.expectEqual(&acme, fromName("acme").?);
    try testing.expectEqual(&sunapee, fromName("sunapee").?);
    try testing.expectEqual(&monadnock, fromName("monadnock").?);
    try testing.expectEqual(&whiteface, fromName("whiteface").?);
    try testing.expect(fromName("bogus") == null);
    try testing.expect(fromName("") == null);
    try testing.expect(fromName("Acme") == null);
    try testing.expectEqual(&sunapee, default);
    for (names[1..], 0..) |n, i| try testing.expect(std.mem.lessThan(u8, names[i], n));
    try testing.expectEqual(names.len, table.len);
}

test "palette: light backs are allocimagemix tints of their nominals" {
    try testing.expectEqual(sunapee.body_back, mix(0xFFCC99FF));
    try testing.expectEqual(sunapee.tag_back, mix(0xBBBBFFFF));
    try testing.expectEqual(acme.body_back, mix(0xFFFFAAFF)); // mix(DPaleyellow)
    try testing.expectEqual(acme.tag_back, mix(0xAAFFFFFF)); // mix(DPalebluegreen)
    try testing.expectEqual(@as(Color, 0xE7FAFAFF), mix(0x9EEEEEFF));
    try testing.expectEqual(whiteface.tag_back, mix(0x9EEEEEFF));
}

test "palette: acme is the iconinit palette; sweeps are invariant" {
    // draw.h names (acme.c:1045-1082).
    try testing.expectEqual(@as(Color, 0x9EEEEEFF), acme.tag_high); // DPalegreygreen
    try testing.expectEqual(@as(Color, 0x8888CCFF), acme.tag_bord); // DPurpleblue
    try testing.expectEqual(@as(Color, 0xEEEE9EFF), acme.body_high); // DDarkyellow
    try testing.expectEqual(@as(Color, 0x99994CFF), acme.body_bord); // DYellowgreen
    try testing.expectEqual(@as(Color, 0x000099FF), acme.mod); // DMedblue
    try testing.expectEqual(@as(Color, 0x8888CCFF), acme.col_button); // DPurpleblue
    inline for (.{ sunapee, whiteface, monadnock, acme }) |p| {
        try testing.expectEqual(@as(Color, 0xAA0000FF), p.but2);
        try testing.expectEqual(@as(Color, 0x006600FF), p.but3);
        try testing.expectEqual(@as(Color, 0x000000FF), p.rule);
    }
}

test "palette: parseFlag takes only the exact -colors=NAME form" {
    try testing.expectEqual(Flag{ .palette = &acme }, parseFlag("-colors=acme"));
    try testing.expectEqual(Flag{ .palette = &monadnock }, parseFlag("-colors=monadnock"));
    try testing.expectEqualStrings("bogus", parseFlag("-colors=bogus").unknown);
    try testing.expectEqualStrings("", parseFlag("-colors=").unknown);
    try testing.expectEqualStrings("", parseFlag("-colors").unknown);
    try testing.expectEqual(Flag.other, parseFlag("--colors=acme"));
    try testing.expectEqual(Flag.other, parseFlag("-colorsacme"));
    try testing.expectEqual(Flag.other, parseFlag("acme"));
}
