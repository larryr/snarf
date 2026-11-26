//! HTML for `Markdown -web` (ADR-0008, D6). Raw HTML is escaped, so a script
//! in the file is text. Image `src` and link `href` are passed through after
//! a scheme check: `javascript:` and `data:` are dropped. The page loads no
//! remote script. Math is the source in a `<pre>`, not a typeset formula.
//!
//! Imports: `std` and `parse.zig`.
const std = @import("std");
const parse = @import("parse.zig");
const Inline = parse.Inline;
const Block = parse.Block;

pub fn render(a: std.mem.Allocator, doc: parse.Doc, title: []const u8) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a,
        \\<!DOCTYPE html>
        \\<meta charset="utf-8">
        \\<title>
    );
    try escape(a, &buf, title);
    try buf.appendSlice(a,
        \\</title>
        \\<style>
        \\body { font-family: system-ui, sans-serif; max-width: 42em; margin: 2em auto; line-height: 1.45; }
        \\code, pre { font-family: ui-monospace, monospace; }
        \\pre { background: #f4f1ea; padding: 0.6em 0.8em; }
        \\</style>
        \\
    );
    for (doc.blocks) |b| try block(a, &buf, b);
    return buf.toOwnedSlice(a);
}

fn block(a: std.mem.Allocator, buf: *std.ArrayList(u8), b: Block) error{OutOfMemory}!void {
    switch (b) {
        .heading => |h| {
            const tag = switch (h.level) {
                1 => "h1",
                2 => "h2",
                3 => "h3",
                4 => "h4",
                5 => "h5",
                else => "h6",
            };
            try open(a, buf, tag);
            try inlines(a, buf, h.inlines);
            try close(a, buf, tag);
        },
        .para => |ins| {
            try buf.appendSlice(a, "<p>");
            try inlines(a, buf, ins);
            try buf.appendSlice(a, "</p>\n");
        },
        .code => |s| {
            try buf.appendSlice(a, "<pre><code>");
            try escape(a, buf, s);
            try buf.appendSlice(a, "</code></pre>\n");
        },
        .quote => |qs| {
            try buf.appendSlice(a, "<blockquote>\n");
            for (qs) |inner| try block(a, buf, inner);
            try buf.appendSlice(a, "</blockquote>\n");
        },
        .list => |list| {
            const tag = if (list.ordered) "ol" else "ul";
            try open(a, buf, tag);
            for (list.items) |item| {
                try buf.appendSlice(a, "<li>");
                try inlines(a, buf, item);
                try buf.appendSlice(a, "</li>\n");
            }
            try close(a, buf, tag);
        },
        .rule => try buf.appendSlice(a, "<hr>\n"),
        .image => |im| try image(a, buf, im.alt, im.src),
        .table => |t| {
            try buf.appendSlice(a, "<table>\n<tr>");
            for (t.header) |cell| {
                try buf.appendSlice(a, "<th>");
                try inlines(a, buf, cell);
                try buf.appendSlice(a, "</th>");
            }
            try buf.appendSlice(a, "</tr>\n");
            for (t.rows) |row| {
                try buf.appendSlice(a, "<tr>");
                for (row) |cell| {
                    try buf.appendSlice(a, "<td>");
                    try inlines(a, buf, cell);
                    try buf.appendSlice(a, "</td>");
                }
                try buf.appendSlice(a, "</tr>\n");
            }
            try buf.appendSlice(a, "</table>\n");
        },
        .math => |s| {
            try buf.appendSlice(a, "<pre class=\"math\">");
            try escape(a, buf, s);
            try buf.appendSlice(a, "</pre>\n");
        },
        .html => |s| {
            try buf.appendSlice(a, "<pre class=\"html\">");
            try escape(a, buf, s);
            try buf.appendSlice(a, "</pre>\n");
        },
    }
}

fn inlines(a: std.mem.Allocator, buf: *std.ArrayList(u8), items: []const Inline) error{OutOfMemory}!void {
    for (items) |item| switch (item) {
        .text => |s| try escape(a, buf, s),
        .code => |s| {
            try buf.appendSlice(a, "<code>");
            try escape(a, buf, s);
            try buf.appendSlice(a, "</code>");
        },
        .em => |ch| {
            try buf.appendSlice(a, "<em>");
            try inlines(a, buf, ch);
            try buf.appendSlice(a, "</em>");
        },
        .strong => |ch| {
            try buf.appendSlice(a, "<strong>");
            try inlines(a, buf, ch);
            try buf.appendSlice(a, "</strong>");
        },
        .link => |l| {
            try buf.appendSlice(a, "<a href=\"");
            try attr(a, buf, l.href);
            try buf.appendSlice(a, "\">");
            try inlines(a, buf, l.text);
            try buf.appendSlice(a, "</a>");
        },
        .image => |im| try image(a, buf, im.alt, im.src),
        .math => |s| {
            try buf.appendSlice(a, "<code>");
            try escape(a, buf, s);
            try buf.appendSlice(a, "</code>");
        },
        .html => |s| try escape(a, buf, s),
    };
}

fn image(a: std.mem.Allocator, buf: *std.ArrayList(u8), alt: []const u8, src: []const u8) error{OutOfMemory}!void {
    try buf.appendSlice(a, "<img alt=\"");
    try attr(a, buf, alt);
    try buf.appendSlice(a, "\" src=\"");
    try attr(a, buf, src);
    try buf.appendSlice(a, "\">\n");
}

fn open(a: std.mem.Allocator, buf: *std.ArrayList(u8), tag: []const u8) error{OutOfMemory}!void {
    try buf.append(a, '<');
    try buf.appendSlice(a, tag);
    try buf.appendSlice(a, ">");
}

fn close(a: std.mem.Allocator, buf: *std.ArrayList(u8), tag: []const u8) error{OutOfMemory}!void {
    try buf.appendSlice(a, "</");
    try buf.appendSlice(a, tag);
    try buf.appendSlice(a, ">\n");
}

fn escape(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    for (s) |c| switch (c) {
        '&' => try buf.appendSlice(a, "&amp;"),
        '<' => try buf.appendSlice(a, "&lt;"),
        '>' => try buf.appendSlice(a, "&gt;"),
        else => try buf.append(a, c),
    };
}

fn attr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    if (blocked(s)) return;
    for (s) |c| switch (c) {
        '&' => try buf.appendSlice(a, "&amp;"),
        '<' => try buf.appendSlice(a, "&lt;"),
        '"' => try buf.appendSlice(a, "&quot;"),
        else => try buf.append(a, c),
    };
}

fn blocked(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return startsScheme(t, "javascript:") or startsScheme(t, "data:");
}

fn startsScheme(s: []const u8, scheme: []const u8) bool {
    if (s.len < scheme.len) return false;
    for (scheme, 0..) |c, i| {
        if (std.ascii.toLower(s[i]) != c) return false;
    }
    return true;
}

const testing = std.testing;

test "html: raw html is escaped and a script url is dropped" {
    var doc = try parse.parse(testing.allocator, "<script>alert(1)</script>\n\n[x](javascript:alert(1))\n");
    defer doc.deinit(testing.allocator);
    const html = try render(testing.allocator, doc, "t");
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "javascript:") == null);
}
