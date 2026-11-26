//! Line classifiers for the markdown block parser (ADR-0008).
//!
//! Imports: `std` and `inline.zig`.
const std = @import("std");
const inl = @import("inline.zig");

pub const Inline = inl.Inline;

pub fn cells(a: std.mem.Allocator, line: []const u8) error{OutOfMemory}![][]Inline {
    var parts: std.ArrayList([]Inline) = .empty;
    errdefer {
        for (parts.items) |c| inl.freeInlines(a, c);
        parts.deinit(a);
    }
    var s = line;
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        try parts.append(a, try inl.parse(a, trimmed));
    }
    return parts.toOwnedSlice(a);
}

pub const Fence = struct { ch: u8, n: usize };

pub fn fenceOf(line: []const u8) ?Fence {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3) return null;
    const ch = t[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < t.len and t[n] == ch) n += 1;
    if (n < 3) return null;
    if (ch == '`' and std.mem.indexOfScalar(u8, t[n..], '`') != null) return null;
    return .{ .ch = ch, .n = n };
}

pub fn fenceInfo(line: []const u8) []const u8 {
    const t = std.mem.trim(u8, line, " \t");
    const mark = fenceOf(line) orelse return "";
    return std.mem.trim(u8, t[mark.n..], " \t");
}

pub fn isMathOpen(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "$$");
}

pub fn isHtmlLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 2 or t[0] != '<') return false;
    const c = t[1];
    return std.ascii.isAlphabetic(c) or c == '/' or c == '!';
}

pub fn headingLevel(line: []const u8) ?u3 {
    var n: usize = 0;
    while (n < line.len and line[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < line.len and line[n] != ' ' and line[n] != '\t') return null;
    return @intCast(n);
}

pub fn stripHeading(line: []const u8, level: u3) []const u8 {
    var s = std.mem.trim(u8, line[level..], " \t");
    while (s.len > 0 and s[s.len - 1] == '#') s = s[0 .. s.len - 1];
    return std.mem.trim(u8, s, " \t");
}

pub fn isRule(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == ch) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

pub const Marker = struct { ordered: bool, rest: []const u8 };

pub fn listMarker(line: []const u8) ?Marker {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t') and i < 3) i += 1;
    if (i >= line.len) return null;
    if (line[i] == '-' or line[i] == '*' or line[i] == '+') {
        if (i + 1 < line.len and (line[i + 1] == ' ' or line[i + 1] == '\t')) {
            return .{ .ordered = false, .rest = std.mem.trim(u8, line[i + 2 ..], " \t") };
        }
        return null;
    }
    var j = i;
    while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
    if (j == i or j >= line.len or line[j] != '.') return null;
    if (j + 1 >= line.len or (line[j + 1] != ' ' and line[j + 1] != '\t')) return null;
    return .{ .ordered = true, .rest = std.mem.trim(u8, line[j + 2 ..], " \t") };
}

pub fn isSep(line: []const u8) bool {
    var s = line;
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    if (std.mem.indexOfScalar(u8, s, '|') == null and std.mem.indexOfScalar(u8, s, '-') == null) return false;
    var any = false;
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        any = true;
        for (t) |c| if (c != '-' and c != ':') return false;
        if (std.mem.indexOfScalar(u8, t, '-') == null) return false;
    }
    return any;
}

pub fn aloneImage(line: []const u8) ?struct { alt: []const u8, src: []const u8 } {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 5 or t[0] != '!' or t[1] != '[') return null;
    const br = std.mem.indexOfScalar(u8, t, ']') orelse return null;
    if (br + 1 >= t.len or t[br + 1] != '(') return null;
    if (t[t.len - 1] != ')') return null;
    var src = t[br + 2 .. t.len - 1];
    if (std.mem.indexOfScalar(u8, src, ' ')) |sp| src = src[0..sp];
    return .{ .alt = t[2..br], .src = src };
}
