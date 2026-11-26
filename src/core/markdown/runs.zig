//! Turns a parsed document into styled runs plus the plain text the preview
//! window's body holds (ADR-0008). Markers stand where an image, table, math
//! block, or raw HTML was. A link run carries its href; a heading's first run
//! carries a slug.
//!
//! Imports: `std` and `parse.zig`.
const std = @import("std");
const parse = @import("parse.zig");
const Inline = parse.Inline;

pub const Face = enum { text, emph, strong, code, h1, h2, h3, marker };

pub const Run = struct {
    text: []u8,
    face: Face,
    href: ?[]u8 = null,
    brk: bool = false,
    slug: ?[]u8 = null,
};

pub const Built = struct {
    runs: []Run,
    plain: []u8,

    pub fn deinit(self: *Built, a: std.mem.Allocator) void {
        freeRuns(a, self.runs);
        a.free(self.plain);
    }
};

pub fn freeRuns(a: std.mem.Allocator, runs: []Run) void {
    for (runs) |r| {
        a.free(r.text);
        if (r.href) |h| a.free(h);
        if (r.slug) |s| a.free(s);
    }
    a.free(runs);
}

pub fn build(a: std.mem.Allocator, doc: parse.Doc) error{OutOfMemory}!Built {
    var b = Builder{ .a = a };
    errdefer b.deinit();
    for (doc.blocks) |block| try b.block(block);
    const runs = try b.runs.toOwnedSlice(a);
    errdefer freeRuns(a, runs);
    return .{ .runs = runs, .plain = try b.plain.toOwnedSlice(a) };
}

/// Lowercase, and every non-alphanumeric run becomes one `-`.
pub fn slugify(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var dash = false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try buf.append(a, std.ascii.toLower(c));
            dash = false;
        } else if (!dash and buf.items.len != 0) {
            try buf.append(a, '-');
            dash = true;
        }
    }
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') _ = buf.pop();
    return buf.toOwnedSlice(a);
}

const Builder = struct {
    a: std.mem.Allocator,
    runs: std.ArrayList(Run) = .empty,
    plain: std.ArrayList(u8) = .empty,
    quote: bool = false,

    fn deinit(self: *Builder) void {
        for (self.runs.items) |r| {
            self.a.free(r.text);
            if (r.href) |h| self.a.free(h);
            if (r.slug) |s| self.a.free(s);
        }
        self.runs.deinit(self.a);
        self.plain.deinit(self.a);
    }

    fn block(self: *Builder, b: parse.Block) error{OutOfMemory}!void {
        switch (b) {
            .heading => |h| try self.heading(h.level, h.inlines),
            .para => |ins| {
                try self.prefix();
                try self.inlines(ins, .text, null);
                try self.endLine();
            },
            .code => |s| try self.add(s, .code, null, true),
            .quote => |qs| {
                const saved = self.quote;
                self.quote = true;
                defer self.quote = saved;
                for (qs) |inner| try self.block(inner);
            },
            .list => |items| try self.listItems(items),
            .rule => try self.add("--------", .text, null, true),
            .image => |im| try self.marker("image", im.alt, true),
            .table => try self.marker("table", "", true),
            .math => try self.marker("math", "", true),
            .html => try self.marker("html", "", true),
        }
    }

    fn heading(self: *Builder, level: u3, items: []Inline) error{OutOfMemory}!void {
        const face: Face = switch (level) {
            1 => .h1,
            2 => .h2,
            else => .h3,
        };
        const start = self.runs.items.len;
        const at = self.plain.items.len;
        try self.prefix();
        try self.inlines(items, face, null);
        if (self.runs.items.len == start) try self.addPiece("", face, null, false);
        try self.endLine();
        const text = self.plain.items[at..];
        const body = if (text.len > 0 and text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
        const slug = try slugify(self.a, body);
        if (self.runs.items.len > start) self.runs.items[start].slug = slug else self.a.free(slug);
    }

    fn listItems(self: *Builder, list: @FieldType(parse.Block, "list")) error{OutOfMemory}!void {
        for (list.items, 0..) |item, n| {
            try self.prefix();
            if (list.ordered) {
                var buf: [16]u8 = undefined;
                const p = std.fmt.bufPrint(&buf, "{d}. ", .{n + 1}) catch "1. ";
                try self.add(p, .text, null, false);
            } else {
                try self.add("- ", .text, null, false);
            }
            try self.inlines(item, .text, null);
            try self.endLine();
        }
    }

    fn inlines(self: *Builder, items: []const Inline, face: Face, href: ?[]const u8) error{OutOfMemory}!void {
        for (items) |item| switch (item) {
            .text => |s| try self.add(s, face, href, false),
            .code => |s| try self.add(s, .code, href, false),
            .em => |ch| try self.inlines(ch, if (headingFace(face)) face else .emph, href),
            .strong => |ch| try self.inlines(ch, if (headingFace(face)) face else .strong, href),
            .link => |l| try self.inlines(l.text, face, l.href),
            .image => |im| try self.marker("image", im.alt, false),
            .math => try self.marker("math", "", false),
            .html => try self.marker("html", "", false),
        };
    }

    fn marker(self: *Builder, kind: []const u8, alt: []const u8, brk: bool) error{OutOfMemory}!void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.a);
        try buf.appendSlice(self.a, "«");
        try buf.appendSlice(self.a, kind);
        if (alt.len != 0) {
            try buf.appendSlice(self.a, ": ");
            try buf.appendSlice(self.a, alt);
        }
        try buf.appendSlice(self.a, "»");
        try self.add(buf.items, .marker, null, brk);
    }

    fn prefix(self: *Builder) error{OutOfMemory}!void {
        if (!self.quote or !self.atLineStart()) return;
        try self.addPiece("| ", .text, null, false);
    }

    fn atLineStart(self: *Builder) bool {
        if (self.plain.items.len == 0) return true;
        return self.plain.items[self.plain.items.len - 1] == '\n';
    }

    fn endLine(self: *Builder) error{OutOfMemory}!void {
        if (self.runs.items.len == 0 or self.runs.items[self.runs.items.len - 1].brk) {
            try self.addPiece("", .text, null, true);
            return;
        }
        self.runs.items[self.runs.items.len - 1].brk = true;
        try self.plain.append(self.a, '\n');
    }

    /// Split on newlines. Inside a quote, each new line starts with `| `.
    fn add(self: *Builder, text: []const u8, face: Face, href: ?[]const u8, brk: bool) error{OutOfMemory}!void {
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
            try self.addPiece(rest[0..i], face, href, true);
            rest = rest[i + 1 ..];
            if (self.quote) try self.addPiece("| ", .text, null, false);
        }
        try self.addPiece(rest, face, href, brk);
    }

    fn addPiece(self: *Builder, text: []const u8, face: Face, href: ?[]const u8, brk: bool) error{OutOfMemory}!void {
        if (text.len == 0 and !brk) return;
        const owned = try self.a.dupe(u8, text);
        errdefer self.a.free(owned);
        const h = if (href) |s| try self.a.dupe(u8, s) else null;
        errdefer if (h) |p| self.a.free(p);
        try self.runs.append(self.a, .{ .text = owned, .face = face, .href = h, .brk = brk });
        try self.plain.appendSlice(self.a, text);
        if (brk) try self.plain.append(self.a, '\n');
    }
};

fn headingFace(face: Face) bool {
    return face == .h1 or face == .h2 or face == .h3;
}

const testing = std.testing;

test "runs: heading slug and image marker" {
    var doc = try parse.parse(testing.allocator, "# Title\n\n![pic](a.png)\n");
    defer doc.deinit(testing.allocator);
    var built = try build(testing.allocator, doc);
    defer built.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, built.plain, "Title\n") != null);
    try testing.expect(std.mem.indexOf(u8, built.plain, "«image: pic»") != null);
    try testing.expectEqualStrings("title", built.runs[0].slug.?);
}
