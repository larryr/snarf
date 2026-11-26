//! Inline CommonMark subset: code, emphasis, strong, links, images, autolinks,
//! raw HTML, and `$math$`. The block parser owns the source; every returned
//! slice is allocated. Not the full flanking-delimiter rules — `*em*` and
//! `**strong**` (and the `_` forms) open when the next character is not a space.
//!
//! Imports: `std` only.
const std = @import("std");

/// An image. `src` is passed through to `-web`; the preview shows `alt` only.
pub const ImageRef = struct {
    alt: []u8,
    src: []u8,
};

pub const Inline = union(enum) {
    text: []u8,
    code: []u8,
    em: []Inline,
    strong: []Inline,
    link: struct { text: []Inline, href: []u8 },
    image: ImageRef,
    math: []u8,
    html: []u8,
};

pub fn freeInlines(a: std.mem.Allocator, inlines: []Inline) void {
    for (inlines) |item| {
        switch (item) {
            .text, .code, .math, .html => |s| a.free(s),
            .image => |im| {
                a.free(im.alt);
                a.free(im.src);
            },
            .em, .strong => |ch| freeInlines(a, ch),
            .link => |l| {
                freeInlines(a, l.text);
                a.free(l.href);
            },
        }
    }
    a.free(inlines);
}

pub fn parse(a: std.mem.Allocator, src: []const u8) error{OutOfMemory}![]Inline {
    var out: std.ArrayList(Inline) = .empty;
    errdefer {
        for (out.items) |item| {
            switch (item) {
                .text, .code, .math, .html => |s| a.free(s),
                .image => |im| {
                    a.free(im.alt);
                    a.free(im.src);
                },
                .em, .strong => |ch| freeInlines(a, ch),
                .link => |l| {
                    freeInlines(a, l.text);
                    a.free(l.href);
                },
            }
        }
        out.deinit(a);
    }
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '`') {
            if (try takeCode(a, src, &i)) |code| {
                try out.append(a, .{ .code = code });
                continue;
            }
        } else if (src[i] == '!' and i + 1 < src.len and src[i + 1] == '[') {
            if (try takeImage(a, src, &i)) |im| {
                try out.append(a, .{ .image = im });
                continue;
            }
        } else if (src[i] == '[') {
            if (try takeLink(a, src, &i)) |link| {
                try out.append(a, .{ .link = link });
                continue;
            }
        } else if (src[i] == '<') {
            if (try takeAngle(a, src, &i)) |item| {
                try out.append(a, item);
                continue;
            }
        } else if (src[i] == '$' and !(i + 1 < src.len and src[i + 1] == '$')) {
            if (try takeMath(a, src, &i)) |math| {
                try out.append(a, .{ .math = math });
                continue;
            }
        } else if (src[i] == '*' or src[i] == '_') {
            if (try takeEm(a, src, &i)) |item| {
                try out.append(a, item);
                continue;
            }
        } else if (src[i] == '\\' and i + 1 < src.len) {
            try out.append(a, .{ .text = try a.dupe(u8, src[i + 1 .. i + 2]) });
            i += 2;
            continue;
        }
        const start = i;
        i += 1;
        while (i < src.len and !isSpecial(src, i)) : (i += 1) {}
        try out.append(a, .{ .text = try a.dupe(u8, src[start..i]) });
    }
    return out.toOwnedSlice(a);
}

fn isSpecial(src: []const u8, i: usize) bool {
    return switch (src[i]) {
        '`', '[', '<', '$', '*', '_', '\\' => true,
        '!' => i + 1 < src.len and src[i + 1] == '[',
        else => false,
    };
}

fn takeCode(a: std.mem.Allocator, src: []const u8, i: *usize) error{OutOfMemory}!?[]u8 {
    var n: usize = 0;
    while (i.* + n < src.len and src[i.* + n] == '`') n += 1;
    if (n == 0) return null;
    const open = i.* + n;
    var k = open;
    while (k < src.len) : (k += 1) {
        if (src[k] != '`') continue;
        var m: usize = 0;
        while (k + m < src.len and src[k + m] == '`') m += 1;
        if (m == n) {
            i.* = k + m;
            return try a.dupe(u8, src[open..k]);
        }
        k += m - 1;
    }
    return null;
}

fn takeMath(a: std.mem.Allocator, src: []const u8, i: *usize) error{OutOfMemory}!?[]u8 {
    const close = std.mem.indexOfScalarPos(u8, src, i.* + 1, '$') orelse return null;
    if (close == i.* + 1) return null;
    if (std.mem.indexOfScalar(u8, src[i.* + 1 .. close], '\n') != null) return null;
    const body = try a.dupe(u8, src[i.* + 1 .. close]);
    i.* = close + 1;
    return body;
}

fn takeAngle(a: std.mem.Allocator, src: []const u8, i: *usize) error{OutOfMemory}!?Inline {
    const rest = src[i.*..];
    const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
    const inner = rest[1..close];
    if (std.mem.startsWith(u8, inner, "http://") or std.mem.startsWith(u8, inner, "https://")) {
        const href = try a.dupe(u8, inner);
        errdefer a.free(href);
        const text = try a.dupe(u8, inner);
        const kids = try a.alloc(Inline, 1);
        kids[0] = .{ .text = text };
        i.* += close + 1;
        return .{ .link = .{ .text = kids, .href = href } };
    }
    if (inner.len == 0) return null;
    const c = inner[0];
    if (!(std.ascii.isAlphabetic(c) or c == '/' or c == '!')) return null;
    const html = try a.dupe(u8, rest[0 .. close + 1]);
    i.* += close + 1;
    return .{ .html = html };
}

fn takeImage(a: std.mem.Allocator, src: []const u8, i: *usize) error{OutOfMemory}!?ImageRef {
    // ![alt](url) — alt is literal, including no nested ']'.
    if (!(i.* + 1 < src.len and src[i.*] == '!' and src[i.* + 1] == '[')) return null;
    const alt_s = i.* + 2;
    const bracket = std.mem.indexOfScalarPos(u8, src, alt_s, ']') orelse return null;
    if (bracket + 1 >= src.len or src[bracket + 1] != '(') return null;
    const paren = std.mem.indexOfScalarPos(u8, src, bracket + 2, ')') orelse return null;
    var dest = src[bracket + 2 .. paren];
    if (std.mem.indexOfScalar(u8, dest, ' ')) |sp| dest = dest[0..sp];
    const alt = try a.dupe(u8, src[alt_s..bracket]);
    errdefer a.free(alt);
    const url = try a.dupe(u8, dest);
    i.* = paren + 1;
    return .{ .alt = alt, .src = url };
}

fn takeLink(a: std.mem.Allocator, src: []const u8, i: *usize) error{OutOfMemory}!?@FieldType(Inline, "link") {
    if (src[i.*] != '[') return null;
    const text_s = i.* + 1;
    var depth: usize = 1;
    var k = text_s;
    var bracket: ?usize = null;
    while (k < src.len) : (k += 1) {
        if (src[k] == '[') depth += 1;
        if (src[k] == ']') {
            depth -= 1;
            if (depth == 0) {
                bracket = k;
                break;
            }
        }
    }
    const br = bracket orelse return null;
    if (br + 1 >= src.len or src[br + 1] != '(') return null;
    const dest_s = br + 2;
    const paren = std.mem.indexOfScalarPos(u8, src, dest_s, ')') orelse return null;
    var dest = src[dest_s..paren];
    if (std.mem.indexOfScalar(u8, dest, ' ')) |sp| dest = dest[0..sp];
    if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
    const href = try a.dupe(u8, dest);
    errdefer a.free(href);
    const text = try parse(a, src[text_s..br]);
    i.* = paren + 1;
    return .{ .text = text, .href = href };
}

fn takeEm(a: std.mem.Allocator, src: []const u8, i: *usize) error{OutOfMemory}!?Inline {
    const mark = src[i.*];
    if (mark != '*' and mark != '_') return null;
    const two = i.* + 1 < src.len and src[i.* + 1] == mark;
    const n: usize = if (two) 2 else 1;
    if (i.* + n >= src.len or src[i.* + n] == ' ' or src[i.* + n] == '\n') return null;
    const from = i.* + n;
    var k = from;
    while (k + n <= src.len) : (k += 1) {
        if (!std.mem.eql(u8, src[k..][0..n], if (n == 2) src[i.* .. i.* + 2] else src[i.* .. i.* + 1])) continue;
        if (k == from) continue;
        if (src[k - 1] == ' ') continue;
        const inner = try parse(a, src[from..k]);
        i.* = k + n;
        if (n == 2) return .{ .strong = inner };
        return .{ .em = inner };
    }
    return null;
}

const testing = std.testing;

test "inline: emphasis, code, link, image, math, html" {
    const a = testing.allocator;
    const items = try parse(a, "say *em* and **st** `x` [a](b.txt) ![p](q.png) $y$ <b>");
    defer freeInlines(a, items);
    var saw_em = false;
    var saw_st = false;
    var saw_code = false;
    var saw_link = false;
    var saw_img = false;
    var saw_math = false;
    var saw_html = false;
    for (items) |item| switch (item) {
        .em => |ch| {
            saw_em = true;
            try testing.expectEqualStrings("em", ch[0].text);
        },
        .strong => |ch| {
            saw_st = true;
            try testing.expectEqualStrings("st", ch[0].text);
        },
        .code => |s| {
            saw_code = true;
            try testing.expectEqualStrings("x", s);
        },
        .link => |l| {
            saw_link = true;
            try testing.expectEqualStrings("b.txt", l.href);
        },
        .image => |im| {
            saw_img = true;
            try testing.expectEqualStrings("p", im.alt);
            try testing.expectEqualStrings("q.png", im.src);
        },
        .math => |s| {
            saw_math = true;
            try testing.expectEqualStrings("y", s);
        },
        .html => |s| {
            saw_html = true;
            try testing.expectEqualStrings("<b>", s);
        },
        .text => {},
    };
    try testing.expect(saw_em and saw_st and saw_code and saw_link and saw_img and saw_math and saw_html);
}
