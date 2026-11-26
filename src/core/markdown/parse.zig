//! Block structure for the markdown preview (ADR-0008). A subset of CommonMark:
//! ATX headings, paragraphs, fenced and indented code, quotes, lists, rules,
//! images that stand alone, GFM tables, `$$` math, and raw HTML blocks. The
//! preview marks tables, images, math, and raw HTML; `-web` renders tables.
//!
//! Imports: `std`, `inline.zig`, `lines.zig`.
const std = @import("std");
const inl = @import("inline.zig");
const lines = @import("lines.zig");

pub const Inline = inl.Inline;

pub const Block = union(enum) {
    heading: struct { level: u3, inlines: []Inline },
    para: []Inline,
    code: []u8,
    quote: []Block,
    list: struct { ordered: bool, items: [][]Inline },
    rule,
    image: inl.ImageRef,
    table: struct { header: [][]Inline, rows: [][][]Inline },
    math: []u8,
    html: []u8,
};

pub const Doc = struct {
    blocks: []Block,

    pub fn deinit(self: *Doc, a: std.mem.Allocator) void {
        freeBlocks(a, self.blocks);
    }
};

pub fn parse(a: std.mem.Allocator, src: []const u8) error{OutOfMemory}!Doc {
    var p = Parser{ .a = a, .src = src, .i = 0 };
    return .{ .blocks = try p.blocks() };
}

fn freeBlock(a: std.mem.Allocator, b: Block) void {
    switch (b) {
        .heading => |h| inl.freeInlines(a, h.inlines),
        .para => |ins| inl.freeInlines(a, ins),
        .code, .math, .html => |s| a.free(s),
        .image => |im| {
            a.free(im.alt);
            a.free(im.src);
        },
        .quote => |qs| freeBlocks(a, qs),
        .list => |list| {
            for (list.items) |item| inl.freeInlines(a, item);
            a.free(list.items);
        },
        .rule => {},
        .table => |t| {
            freeRows(a, t.header);
            for (t.rows) |row| freeRows(a, row);
            a.free(t.rows);
        },
    }
}

fn freeBlocks(a: std.mem.Allocator, blocks: []Block) void {
    for (blocks) |b| freeBlock(a, b);
    a.free(blocks);
}

fn freeRows(a: std.mem.Allocator, row: [][]Inline) void {
    for (row) |cell| inl.freeInlines(a, cell);
    a.free(row);
}

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    i: usize,

    fn blocks(self: *Parser) error{OutOfMemory}![]Block {
        var out: std.ArrayList(Block) = .empty;
        errdefer {
            for (out.items) |b| freeBlock(self.a, b);
            out.deinit(self.a);
        }
        while (self.peek()) |line| {
            if (line.len == 0) {
                self.advance();
                continue;
            }
            if (lines.fenceOf(line)) |_| {
                try out.append(self.a, .{ .code = try self.fence() });
                continue;
            }
            if (lines.isMathOpen(line)) {
                try out.append(self.a, .{ .math = try self.mathBlock() });
                continue;
            }
            if (lines.isHtmlLine(line)) {
                try out.append(self.a, .{ .html = try self.htmlBlock() });
                continue;
            }
            if (self.tableHere()) {
                try out.append(self.a, .{ .table = try self.table() });
                continue;
            }
            if (lines.headingLevel(line)) |level| {
                const text = lines.stripHeading(line, level);
                try out.append(self.a, .{ .heading = .{
                    .level = level,
                    .inlines = try inl.parse(self.a, text),
                } });
                self.advance();
                continue;
            }
            if (lines.isRule(line)) {
                try out.append(self.a, .rule);
                self.advance();
                continue;
            }
            if (line[0] == '>') {
                try out.append(self.a, .{ .quote = try self.quote() });
                continue;
            }
            if (lines.listMarker(line) != null) {
                try out.append(self.a, try self.list());
                continue;
            }
            if (std.mem.startsWith(u8, line, "    ")) {
                try out.append(self.a, .{ .code = try self.indented() });
                continue;
            }
            if (lines.aloneImage(line)) |im| {
                const alt = try self.a.dupe(u8, im.alt);
                errdefer self.a.free(alt);
                const src = try self.a.dupe(u8, im.src);
                try out.append(self.a, .{ .image = .{ .alt = alt, .src = src } });
                self.advance();
                continue;
            }
            try out.append(self.a, .{ .para = try self.paragraph() });
        }
        return out.toOwnedSlice(self.a);
    }

    fn peek(self: *Parser) ?[]const u8 {
        if (self.i >= self.src.len) return null;
        return self.lineAt(self.i).text;
    }

    fn advance(self: *Parser) void {
        if (self.i >= self.src.len) return;
        self.i = self.lineAt(self.i).next;
    }

    fn lineAt(self: *Parser, at: usize) struct { text: []const u8, next: usize } {
        var end = at;
        while (end < self.src.len and self.src[end] != '\n') : (end += 1) {}
        var text = self.src[at..end];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        const next = if (end < self.src.len) end + 1 else end;
        return .{ .text = text, .next = next };
    }

    fn fence(self: *Parser) error{OutOfMemory}![]u8 {
        const open = self.peek().?;
        const mark = lines.fenceOf(open).?;
        self.advance();
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.a);
        while (self.peek()) |line| {
            if (lines.fenceOf(line)) |m| if (m.ch == mark.ch and m.n >= mark.n and lines.fenceInfo(line).len == 0) {
                self.advance();
                break;
            };
            if (buf.items.len != 0) try buf.append(self.a, '\n');
            try buf.appendSlice(self.a, line);
            self.advance();
        }
        return buf.toOwnedSlice(self.a);
    }

    fn mathBlock(self: *Parser) error{OutOfMemory}![]u8 {
        const open = self.peek().?;
        const rest = std.mem.trim(u8, open, " \t");
        self.advance();
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.a);
        if (rest.len > 2) try buf.appendSlice(self.a, std.mem.trim(u8, rest[2..], " \t"));
        while (self.peek()) |line| {
            const t = std.mem.trim(u8, line, " \t");
            if (std.mem.eql(u8, t, "$$")) {
                self.advance();
                break;
            }
            if (std.mem.endsWith(u8, t, "$$") and t.len > 2) {
                if (buf.items.len != 0) try buf.append(self.a, '\n');
                try buf.appendSlice(self.a, t[0 .. t.len - 2]);
                self.advance();
                break;
            }
            if (buf.items.len != 0) try buf.append(self.a, '\n');
            try buf.appendSlice(self.a, line);
            self.advance();
        }
        return buf.toOwnedSlice(self.a);
    }

    fn htmlBlock(self: *Parser) error{OutOfMemory}![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.a);
        while (self.peek()) |line| {
            if (line.len == 0) break;
            if (buf.items.len != 0) try buf.append(self.a, '\n');
            try buf.appendSlice(self.a, line);
            self.advance();
        }
        return buf.toOwnedSlice(self.a);
    }

    fn quote(self: *Parser) error{OutOfMemory}![]Block {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.a);
        while (self.peek()) |line| {
            if (line.len == 0 or line[0] != '>') break;
            var rest = line[1..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            if (buf.items.len != 0) try buf.append(self.a, '\n');
            try buf.appendSlice(self.a, rest);
            self.advance();
        }
        const owned = try buf.toOwnedSlice(self.a);
        defer self.a.free(owned);
        var inner = Parser{ .a = self.a, .src = owned, .i = 0 };
        return inner.blocks();
    }

    fn list(self: *Parser) error{OutOfMemory}!Block {
        const first = lines.listMarker(self.peek().?).?;
        var items: std.ArrayList([]Inline) = .empty;
        errdefer {
            for (items.items) |it| inl.freeInlines(self.a, it);
            items.deinit(self.a);
        }
        while (self.peek()) |line| {
            const marker = lines.listMarker(line) orelse break;
            if (marker.ordered != first.ordered) break;
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(self.a);
            try text.appendSlice(self.a, marker.rest);
            self.advance();
            while (self.peek()) |cont| {
                if (cont.len == 0 or lines.listMarker(cont) != null or lines.headingLevel(cont) != null) break;
                if (!(cont[0] == ' ' or cont[0] == '\t')) break;
                try text.append(self.a, ' ');
                try text.appendSlice(self.a, std.mem.trim(u8, cont, " \t"));
                self.advance();
            }
            try items.append(self.a, try inl.parse(self.a, text.items));
        }
        return .{ .list = .{ .ordered = first.ordered, .items = try items.toOwnedSlice(self.a) } };
    }

    fn indented(self: *Parser) error{OutOfMemory}![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.a);
        while (self.peek()) |line| {
            if (!std.mem.startsWith(u8, line, "    ") and line.len != 0) break;
            if (buf.items.len != 0) try buf.append(self.a, '\n');
            if (line.len >= 4) try buf.appendSlice(self.a, line[4..]) else try buf.appendSlice(self.a, line);
            self.advance();
        }
        return buf.toOwnedSlice(self.a);
    }

    fn paragraph(self: *Parser) error{OutOfMemory}![]Inline {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.a);
        while (self.peek()) |line| {
            if (line.len == 0) break;
            if (lines.fenceOf(line) != null or lines.headingLevel(line) != null or lines.isRule(line) or line[0] == '>') break;
            if (lines.listMarker(line) != null or lines.isMathOpen(line) or lines.isHtmlLine(line)) break;
            if (buf.items.len != 0) try buf.append(self.a, '\n');
            try buf.appendSlice(self.a, line);
            self.advance();
        }
        return inl.parse(self.a, buf.items);
    }

    fn tableHere(self: *Parser) bool {
        const line = self.peek() orelse return false;
        if (std.mem.indexOfScalar(u8, line, '|') == null) return false;
        const next_at = self.lineAt(self.i).next;
        if (next_at >= self.src.len) return false;
        return lines.isSep(self.lineAt(next_at).text);
    }

    fn table(self: *Parser) error{OutOfMemory}!@FieldType(Block, "table") {
        const header_line = self.peek().?;
        const header = try lines.cells(self.a, header_line);
        errdefer freeRows(self.a, header);
        self.advance();
        self.advance(); // separator
        var rows: std.ArrayList([][]Inline) = .empty;
        errdefer {
            for (rows.items) |row| freeRows(self.a, row);
            rows.deinit(self.a);
        }
        while (self.peek()) |line| {
            if (line.len == 0 or std.mem.indexOfScalar(u8, line, '|') == null) break;
            try rows.append(self.a, try lines.cells(self.a, line));
            self.advance();
        }
        return .{ .header = header, .rows = try rows.toOwnedSlice(self.a) };
    }
};

const testing = std.testing;

test "parse: heading, paragraph link, fence, list, markers" {
    const src =
        \\# Title
        \\
        \\See [notes](notes.txt) and *go*.
        \\
        \\```
        \\code
        \\```
        \\
        \\- one
        \\- two
        \\
        \\![pic](a.png)
        \\
        \\| a | b |
        \\| --- | --- |
        \\| 1 | 2 |
        \\
        \\$$
        \\x
        \\$$
        \\
        \\<div>
        \\hi
        \\
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), doc.blocks.len);
    try testing.expectEqual(@as(u3, 1), doc.blocks[0].heading.level);
    try testing.expectEqualStrings("code", doc.blocks[2].code);
    try testing.expectEqual(@as(usize, 2), doc.blocks[3].list.items.len);
    try testing.expectEqualStrings("pic", doc.blocks[4].image.alt);
    try testing.expectEqualStrings("a.png", doc.blocks[4].image.src);
    try testing.expectEqual(@as(usize, 1), doc.blocks[5].table.rows.len);
    try testing.expectEqualStrings("x", doc.blocks[6].math);
    try testing.expect(std.mem.startsWith(u8, doc.blocks[7].html, "<div>"));
}
