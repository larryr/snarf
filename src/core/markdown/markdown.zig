//! The `Markdown` command (ADR-0008, D1–D7). One read-only preview per source,
//! named `<path>+Markdown`. `Markdown -web` asks the host to open HTML.
//! `Markdown -live` refreshes an opted-in preview from `Editor.frameEnd`
//! (there is no timer on wasm32-freestanding).
//!
//! Imports: `std` and sibling core files only (never dev/shim).
const std = @import("std");
const Column = @import("../Column.zig");
const Editor = @import("../Editor.zig");
const Row = @import("../Row.zig");
const Text = @import("../text/Text.zig");
const Window = @import("../Window.zig");
const Buffer = @import("../Buffer.zig");
const errors = @import("../errors.zig");
const openfile = @import("../openfile.zig");
const place = @import("../place.zig");
const faces = @import("faces.zig");
const html = @import("html.zig");
const parse = @import("parse.zig");
const preview = @import("preview.zig");
const runs = @import("runs.zig");

const suffix = "+Markdown";

pub fn command(ed: *Editor, et: *Text, arg: []const u8) Text.Error!void {
    const flags = parseFlags(std.mem.trim(u8, arg, " \t"));
    const acted = actedWindow(ed, et) orelse {
        ed.warning("Markdown: no file\n", .{});
        return;
    };
    if (acted.preview != null) {
        if (flags.live) acted.preview.?.live = true;
        if (flags.web) try openWebOf(ed, acted);
        try refresh(ed, acted);
        return;
    }
    const source = acted.body.file.name.items;
    if (source.len == 0) {
        ed.warning("Markdown: no file\n", .{});
        return;
    }
    const bytes = try readAll(ed.allocator, &acted.body.file.buffer);
    defer ed.allocator.free(bytes);
    // `-web` does not need the preview faces. A font failure must not block it.
    if (flags.web) try openWeb(ed, source, bytes);
    if (!ensure(ed, acted.chrome)) return;

    const row = ed.row orelse return;
    const name = try std.fmt.allocPrint(ed.allocator, "{s}{s}", .{ source, suffix });
    defer ed.allocator.free(name);
    if (errors.lookFile(row, name)) |w| {
        if (w.preview) |pv| {
            if (flags.live) pv.live = true;
            w.body.preview_body = true;
            try render(ed, w, bytes);
            return;
        }
        ed.warning("Markdown: {s} is not a preview\n", .{name});
        return;
    }
    if (flags.web) return;

    const focus = acted.col;
    const col = (try destColumn(ed, row, focus)) orelse return;
    const w = try place.mintWindow(ed, col, -1, name);
    const pv = try ed.allocator.create(preview.Preview);
    const owned = ed.allocator.dupe(u8, source) catch |err| {
        ed.allocator.destroy(pv);
        return err;
    };
    pv.* = .{ .source = owned, .live = flags.live, .faces = ed.md };
    w.preview = pv;
    w.body.preview_body = true;
    w.filemenu = false;
    try w.setTag1();
    try render(ed, w, bytes);
}

pub fn refresh(ed: *Editor, w: *Window) Text.Error!void {
    const pv = w.preview orelse return;
    const row = ed.row orelse return;
    const src = errors.lookFile(row, pv.source) orelse {
        ed.warning("Markdown: {s} is not open\n", .{pv.source});
        return;
    };
    if (!ensure(ed, w.chrome)) return;
    pv.faces = ed.md;
    const bytes = try readAll(ed.allocator, &src.body.file.buffer);
    defer ed.allocator.free(bytes);
    try render(ed, w, bytes);
}

pub fn onPut(ed: *Editor, w: *Window) Text.Error!void {
    if (w.preview != null) return;
    const source = w.body.file.name.items;
    if (source.len == 0) return;
    const row = ed.row orelse return;
    const name = try std.fmt.allocPrint(ed.allocator, "{s}{s}", .{ source, suffix });
    defer ed.allocator.free(name);
    const pvw = errors.lookFile(row, name) orelse return;
    try refresh(ed, pvw);
}

/// Opted-in previews marked stale by a source edit. Called from `frameEnd`.
/// Per frame, which stands in for the 500 ms debounce on a host with no timer.
pub fn flushLive(ed: *Editor) Text.Error!void {
    const row = ed.row orelse return;
    for (row.col.items) |c| {
        for (c.w.items) |w| {
            const pv = w.preview orelse continue;
            if (!pv.live or !pv.stale) continue;
            pv.stale = false;
            try refresh(ed, w);
        }
    }
}

pub fn openHref(ed: *Editor, w: *Window, href: []const u8) Text.Error!void {
    const t = std.mem.trim(u8, href, " \t");
    if (t.len == 0) return;
    if (schemeIs(t, "http:") or schemeIs(t, "https:")) {
        ed.warning("{s}: opening URLs is deferred (R-EDIT-13)\n", .{t});
        return;
    }
    if (schemeOf(t)) |_| {
        ed.warning("{s}: will not open\n", .{t});
        return;
    }
    var path = t;
    var frag: []const u8 = "";
    if (std.mem.indexOfScalar(u8, t, '#')) |i| {
        path = t[0..i];
        frag = t[i + 1 ..];
    }
    if (path.len == 0) {
        if (frag.len != 0) {
            const slug = try runs.slugify(ed.allocator, frag);
            defer ed.allocator.free(slug);
            try preview.scrollToSlug(w, slug);
        }
        return;
    }
    const pv = w.preview orelse return;
    const abs = try resolve(ed.allocator, pv.source, path);
    defer ed.allocator.free(abs);
    _ = openfile.openFile(ed, &w.body, .{ .name = abs, .jump = true }) catch |e| {
        ed.warning("Markdown: {s}: {s}\n", .{ abs, @errorName(e) });
        return;
    };
    if (frag.len != 0) {
        const slug = try runs.slugify(ed.allocator, frag);
        defer ed.allocator.free(slug);
        try preview.scrollToSlug(w, slug);
    }
}

pub fn hrefAt(w: *Window, pt: @import("draw").Point) ?[]const u8 {
    return preview.hrefAt(w, pt);
}

fn render(ed: *Editor, w: *Window, src: []const u8) Text.Error!void {
    const pv = w.preview orelse return;
    pv.faces = ed.md;
    var doc = try parse.parse(ed.allocator, src);
    defer doc.deinit(ed.allocator);
    var built = try runs.build(ed.allocator, doc);
    defer built.deinit(ed.allocator);
    runs.freeRuns(ed.allocator, pv.runs);
    pv.runs = built.runs;
    built.runs = &.{};
    pv.updating = true;
    defer pv.updating = false;
    const n = w.body.file.buffer.len();
    if (n != 0) try w.body.deleteRange(0, n, true);
    if (built.plain.len != 0) try w.body.insertAt(0, built.plain, true);
    w.body.file.mod = false;
    w.dirty = false;
    pv.scroll = 0;
    w.body.lastsr = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 0, .y = 0 } };
    try preview.relayout(w);
    try preview.paint(w);
    try w.body.scrDraw();
    ed.needs_flush = true;
}

fn openWebOf(ed: *Editor, preview_w: *Window) Text.Error!void {
    const pv = preview_w.preview orelse return;
    const row = ed.row orelse return;
    const src = errors.lookFile(row, pv.source) orelse {
        ed.warning("Markdown: {s} is not open\n", .{pv.source});
        return;
    };
    const bytes = try readAll(ed.allocator, &src.body.file.buffer);
    defer ed.allocator.free(bytes);
    try openWeb(ed, pv.source, bytes);
}

fn openWeb(ed: *Editor, title: []const u8, src: []const u8) Text.Error!void {
    var doc = try parse.parse(ed.allocator, src);
    defer doc.deinit(ed.allocator);
    const page = try html.render(ed.allocator, doc, title);
    defer ed.allocator.free(page);
    if (ed.open_html) |open| {
        const ctx = ed.open_html_ctx orelse {
            ed.warning("Markdown -web needs the native host\n", .{});
            return;
        };
        open(ctx, page);
    } else {
        ed.warning("Markdown -web needs the native host\n", .{});
    }
}

/// True when preview faces are ready. A failure warns and returns false.
/// Font synthesis errors are not out-of-memory, so they must not pretend to be.
fn ensure(ed: *Editor, chrome: *const @import("../Chrome.zig")) bool {
    if (ed.md != null) return true;
    var session = faces.create(ed.allocator, chrome) catch |err| {
        ed.warning("Markdown: {s}\n", .{@errorName(err)});
        return false;
    };
    const p = ed.allocator.create(faces.Session) catch {
        session.deinit();
        ed.warning("Markdown: OutOfMemory\n", .{});
        return false;
    };
    p.* = session;
    ed.md = p;
    return true;
}

fn readAll(a: std.mem.Allocator, buf: *Buffer) Text.Error![]u8 {
    const n = buf.len();
    const dest = try a.alloc(u8, n * Buffer.max_bytes_per_rune);
    errdefer a.free(dest);
    if (n == 0) return dest;
    const bytes = buf.read(0, n, dest);
    if (bytes.len == dest.len) return dest;
    const out = try a.dupe(u8, bytes);
    a.free(dest);
    return out;
}

fn resolve(a: std.mem.Allocator, source: []const u8, rel: []const u8) Text.Error![]u8 {
    if (rel.len > 0 and rel[0] == '/') return try a.dupe(u8, rel);
    const dir = std.fs.path.dirname(source) orelse return try a.dupe(u8, rel);
    if (dir.len == 1 and dir[0] == '/') return try std.fmt.allocPrint(a, "/{s}", .{rel});
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, rel });
}

const Flags = struct { web: bool = false, live: bool = false };

fn parseFlags(arg: []const u8) Flags {
    var s = arg;
    var flags = Flags{};
    while (s.len > 0) {
        if (std.mem.startsWith(u8, s, "-web")) {
            flags.web = true;
            s = std.mem.trimStart(u8, s[4..], " \t");
        } else if (std.mem.startsWith(u8, s, "-live")) {
            flags.live = true;
            s = std.mem.trimStart(u8, s[5..], " \t");
        } else break;
    }
    return flags;
}

fn schemeIs(s: []const u8, name: []const u8) bool {
    if (s.len < name.len) return false;
    for (name, 0..) |c, i| {
        if (std.ascii.toLower(s[i]) != c) return false;
    }
    return true;
}

fn schemeOf(s: []const u8) ?[]const u8 {
    for (s, 0..) |c, i| {
        if (c == '/' or c == '#' or c == '?') return null;
        if (c == ':') return s[0..i];
    }
    return null;
}

fn actedWindow(ed: *Editor, et: *Text) ?*Window {
    if (et.w) |w| return w;
    if (ed.seltext) |t| if (t.w) |w| return w;
    return null;
}

fn destColumn(ed: *Editor, row: *Row, focus: ?*Column) Text.Error!?*Column {
    const cols = row.col.items;
    const i = colIndex(cols, focus) orelse 0;
    if (cols.len <= 1) {
        if (try row.add(ed, -1)) |made| return made;
        if (focus) |c| return c;
        if (row.col.items.len != 0) return row.col.items[0];
        return null;
    }
    if (i + 1 == cols.len) return cols[i - 1];
    return cols[i + 1];
}

fn colIndex(cols: []const *Column, focus: ?*Column) ?usize {
    const c = focus orelse return null;
    for (cols, 0..) |it, i| {
        if (it == c) return i;
    }
    return null;
}
