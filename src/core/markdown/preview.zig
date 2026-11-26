//! Read-only multi-font layout for one markdown preview (ADR-0008). The body
//! `Text` keeps the plain rendering in its buffer. Paint, scroll, and typing
//! of that body go through here instead of the one-font frame. The scrollbar
//! is still drawn by the caller after `paint`.
//!
//! Imports: `std`, `draw`, and sibling core files (never dev/shim).
const std = @import("std");
const draw = @import("draw");
const Window = @import("../Window.zig");
const Text = @import("../text/Text.zig");
const faces = @import("faces.zig");
const runs = @import("runs.zig");

const Rect = draw.Rect;

pub const Frag = struct {
    run: u32,
    start: u32,
    end: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Anchor = struct {
    slug: []u8,
    y: i32,
};

pub const Preview = struct {
    /// Body-file name of the source window. Owned.
    source: []u8,
    live: bool = false,
    stale: bool = false,
    /// Set while the preview replaces its own body, so that write is allowed.
    updating: bool = false,
    scroll: i32 = 0,
    content_h: i32 = 0,
    runs: []runs.Run = &.{},
    frags: []Frag = &.{},
    anchors: []Anchor = &.{},
    faces: ?*faces.Session = null,

    pub fn deinit(self: *Preview, a: std.mem.Allocator) void {
        a.free(self.source);
        runs.freeRuns(a, self.runs);
        a.free(self.frags);
        for (self.anchors) |an| a.free(an.slug);
        a.free(self.anchors);
    }
};

/// True when a body edit on this text must be dropped.
pub fn blocksEdit(t: *Text) bool {
    if (!t.preview_body or t.what != .body) return false;
    const w = t.w orelse return false;
    const pv = w.preview orelse return false;
    return !pv.updating;
}

/// A real edit of a source body marks any opted-in preview of that file stale.
pub fn noteSourceEdit(src: *Window) void {
    const col = src.col orelse return;
    const row = col.row orelse return;
    const name = src.body.file.name.items;
    if (name.len == 0) return;
    for (row.col.items) |c| {
        for (c.w.items) |w| {
            const pv = w.preview orelse continue;
            if (pv.live and std.mem.eql(u8, pv.source, name)) pv.stale = true;
        }
    }
}

pub fn relayout(w: *Window) Text.Error!void {
    const pv = w.preview orelse return;
    const session = pv.faces orelse return;
    const width = w.body.fr.r.max.x - w.body.fr.r.min.x;
    try layout(pv, w.chrome.allocator, session, width);
}

pub fn paint(w: *Window) Text.Error!void {
    const pv = w.preview orelse return;
    const session = pv.faces orelse return;
    const t = &w.body;
    const r = t.fr.r;
    const saved = t.fr.b.clipr;
    t.fr.b.clipr = r;
    defer t.fr.b.clipr = saved;
    try t.fr.b.draw(r, t.fr.col(.back), null, .{});
    const view_h = @max(r.max.y - r.min.y, 0);
    clampScroll(pv, view_h);
    const top = pv.scroll;
    const bot = top + view_h;
    for (pv.frags) |fr| {
        if (fr.h <= 0 or fr.y + fr.h <= top or fr.y >= bot) continue;
        const sy = r.min.y + fr.y - top;
        const run = &pv.runs[fr.run];
        if (fr.end <= fr.start or fr.start > run.text.len or fr.end > run.text.len) continue;
        const slice = run.text[fr.start..fr.end];
        if (run.face == .code and fr.w > 0) {
            try t.fr.b.draw(Rect.make(r.min.x + fr.x, sy, r.min.x + fr.x + fr.w, sy + fr.h), &session.code_back, null, .{});
        }
        const color: *draw.Image = if (run.href != null)
            &session.link
        else if (run.face == .marker)
            &session.marker
        else
            t.fr.col(.text);
        _ = try session.font(run.face).drawString(t.fr.b, .{ .x = r.min.x + fr.x, .y = sy }, color, slice);
    }
}

pub fn scrollLines(w: *Window, n: i32) Text.Error!void {
    const pv = w.preview orelse return;
    pv.scroll += n * w.chrome.font.height;
    try paint(w);
    try scrDraw(&w.body);
}

pub fn scrDraw(t: *Text) Text.Error!void {
    const w = t.w orelse return;
    const pv = w.preview orelse return;
    const view_h: i32 = @max(t.fr.r.max.y - t.fr.r.min.y, 0);
    clampScroll(pv, view_h);
    const tot: usize = @intCast(@max(pv.content_h, 1));
    const p0: usize = @intCast(@max(pv.scroll, 0));
    const p1_i = @min(pv.scroll + view_h, @max(pv.content_h, 0));
    const p1: usize = @intCast(@max(p1_i, 0));
    const r2 = barPos(t.scrollr, p0, p1, tot);
    if (eqRect(r2, t.lastsr)) return;
    t.lastsr = r2;
    try t.fr.b.draw(t.scrollr, t.fr.col(.bord), null, .{});
    try t.fr.b.draw(r2, t.fr.col(.back), null, .{});
    var edge = r2;
    edge.min.x = r2.max.x - 1;
    try t.fr.b.draw(edge, t.fr.col(.bord), null, .{});
}

pub fn scrollClick(t: *Text, but: u3, pt: draw.Point) Text.Error!void {
    const w = t.w orelse return;
    const pv = w.preview orelse return;
    const s = inset(t.scrollr, 1);
    const h = s.max.y - s.min.y;
    if (h <= 0) return;
    var my = pt.y;
    if (my < s.min.y) my = s.min.y;
    if (my >= s.max.y) my = s.max.y - 1;
    const view_h = @max(t.fr.r.max.y - t.fr.r.min.y, 0);
    const span = @max(pv.content_h - view_h, 0);
    switch (but) {
        2 => pv.scroll = @intCast(@divTrunc(@as(i64, span) * (my - s.min.y), h)),
        1 => {
            const rows: i32 = @intCast(@divTrunc(my - s.min.y, @max(t.fr.font.height, 1)));
            pv.scroll -= rows * @max(t.fr.font.height, 1);
        },
        else => {
            const y = @divTrunc(@as(i64, @max(pv.content_h, 0)) * (my - s.min.y), h);
            pv.scroll = @intCast(y);
        },
    }
    try paint(w);
    t.lastsr = Rect.make(0, 0, 0, 0);
    try scrDraw(t);
}

pub fn hrefAt(w: *Window, pt: draw.Point) ?[]const u8 {
    const pv = w.preview orelse return null;
    const r = w.body.fr.r;
    if (pt.x < r.min.x or pt.x >= r.max.x or pt.y < r.min.y or pt.y >= r.max.y) return null;
    const x = pt.x - r.min.x;
    const y = pt.y - r.min.y + pv.scroll;
    for (pv.frags) |fr| {
        if (y < fr.y or y >= fr.y + fr.h or x < fr.x or x >= fr.x + fr.w) continue;
        if (pv.runs[fr.run].href) |href| return href;
    }
    return null;
}

pub fn scrollToSlug(w: *Window, slug: []const u8) Text.Error!void {
    const pv = w.preview orelse return;
    for (pv.anchors) |an| {
        if (!std.mem.eql(u8, an.slug, slug)) continue;
        pv.scroll = an.y;
        try paint(w);
        tInvalidate(&w.body);
        try scrDraw(&w.body);
        return;
    }
}

fn tInvalidate(t: *Text) void {
    t.lastsr = Rect.make(0, 0, 0, 0);
}

fn layout(pv: *Preview, a: std.mem.Allocator, session: *faces.Session, width: i32) Text.Error!void {
    a.free(pv.frags);
    pv.frags = &.{};
    for (pv.anchors) |an| a.free(an.slug);
    a.free(pv.anchors);
    pv.anchors = &.{};

    var frags: std.ArrayList(Frag) = .empty;
    errdefer frags.deinit(a);
    var anchors: std.ArrayList(Anchor) = .empty;
    errdefer {
        for (anchors.items) |an| a.free(an.slug);
        anchors.deinit(a);
    }

    var x: i32 = 0;
    var y: i32 = 0;
    var line_h: i32 = 0;
    const limit: i32 = @max(width, 1);

    for (pv.runs, 0..) |*run, ri| {
        if (run.slug) |slug| {
            try anchors.append(a, .{ .slug = try a.dupe(u8, slug), .y = y });
        }
        const font = session.font(run.face);
        const h = font.height;
        var i: usize = 0;
        while (i < run.text.len) {
            if (run.text[i] == '\n') {
                y += if (line_h == 0) h else line_h;
                x = 0;
                line_h = 0;
                i += 1;
                continue;
            }
            var j = i;
            while (j < run.text.len and run.text[j] != ' ' and run.text[j] != '\n') j += 1;
            const word_w = font.stringWidth(run.text[i..j]);
            if (x > 0 and x + word_w > limit) {
                y += if (line_h == 0) h else line_h;
                x = 0;
                line_h = 0;
            }
            if (j > i) {
                try frags.append(a, .{
                    .run = @intCast(ri),
                    .start = @intCast(i),
                    .end = @intCast(j),
                    .x = x,
                    .y = y,
                    .w = word_w,
                    .h = h,
                });
                x += word_w;
                if (h > line_h) line_h = h;
            }
            i = j;
            if (i < run.text.len and run.text[i] == ' ') {
                const sw = font.charWidth(' ');
                if (x > 0 and x + sw > limit) {
                    y += if (line_h == 0) h else line_h;
                    x = 0;
                    line_h = 0;
                } else {
                    try frags.append(a, .{
                        .run = @intCast(ri),
                        .start = @intCast(i),
                        .end = @intCast(i + 1),
                        .x = x,
                        .y = y,
                        .w = sw,
                        .h = h,
                    });
                    x += sw;
                    if (h > line_h) line_h = h;
                }
                i += 1;
            }
        }
        if (run.brk) {
            y += if (line_h == 0) h else line_h;
            x = 0;
            line_h = 0;
        }
    }
    if (line_h != 0) y += line_h;
    pv.content_h = y;
    pv.frags = try frags.toOwnedSlice(a);
    pv.anchors = try anchors.toOwnedSlice(a);
}

pub fn clampScroll(pv: *Preview, view_h: i32) void {
    const max = @max(pv.content_h - view_h, 0);
    if (pv.scroll < 0) pv.scroll = 0;
    if (pv.scroll > max) pv.scroll = max;
}

/// `scrpos` (scrl.c:17-44), pixel totals instead of rune totals.
fn barPos(r: Rect, p0_in: usize, p1_in: usize, tot_in: usize) Rect {
    var q = r;
    const h: i64 = r.max.y - r.min.y;
    if (tot_in == 0 or h <= 0) return q;
    var tot: i64 = @intCast(tot_in);
    var p0: i64 = @intCast(p0_in);
    var p1: i64 = @intCast(p1_in);
    if (tot > 1024 * 1024) {
        tot >>= 10;
        p0 >>= 10;
        p1 >>= 10;
    }
    if (p0 > 0) q.min.y += @intCast(@divTrunc(h * p0, tot));
    if (p1 < tot) q.max.y -= @intCast(@divTrunc(h * (tot - p1), tot));
    if (q.max.y < q.min.y + 2) {
        if (q.min.y + 2 <= r.max.y) q.max.y = q.min.y + 2 else q.min.y = q.max.y - 2;
    }
    return q;
}

fn eqRect(a: Rect, b: Rect) bool {
    return a.min.x == b.min.x and a.min.y == b.min.y and a.max.x == b.max.x and a.max.y == b.max.y;
}

fn inset(r: Rect, n: i32) Rect {
    return .{ .min = .{ .x = r.min.x + n, .y = r.min.y + n }, .max = .{ .x = r.max.x - n, .y = r.max.y - n } };
}
