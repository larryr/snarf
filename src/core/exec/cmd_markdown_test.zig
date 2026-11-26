//! Markdown opens one preview named `<path>+Markdown` and reuses it (ADR-0008).
const std = @import("std");
const testing = std.testing;
const draw = @import("draw");
const Frame = draw.Frame;
const proto = draw.proto;
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const Buffer = @import("../Buffer.zig");
const Window = @import("../Window.zig");
const boot = @import("../boot.zig");
const errors = @import("../errors.zig");
const markdown = @import("../markdown/markdown.zig");

const Scene = struct {
    fx: Frame.TestFixture,
    tree: boot.Tree,
    ed: Editor,

    fn init(body: []const u8) !*Scene {
        const a = testing.allocator;
        const h = try a.create(Scene);
        errdefer a.destroy(h);
        h.fx = try Frame.TestFixture.init();
        errdefer h.fx.deinit();
        h.tree = try boot.boot(a, h.fx.disp, h.fx.font, proto.Rect.make(0, 0, 800, 500), .{
            .win_name = "file.txt",
            .body = body,
        });
        errdefer h.tree.deinit();
        h.ed = Editor.init(a);
        h.ed.row = h.tree.row;
        return h;
    }
    fn deinit(h: *Scene) void {
        h.ed.deinit();
        h.tree.deinit();
        h.fx.deinit();
        testing.allocator.destroy(h);
    }
    fn win0(h: *Scene) *Window {
        return h.tree.row.col.items[0].w.items[0];
    }
};

fn bodyText(t: *Text) ![]u8 {
    const n = t.file.buffer.len();
    if (n == 0) return testing.allocator.alloc(u8, 0);
    const dest = try testing.allocator.alloc(u8, n * Buffer.max_bytes_per_rune);
    defer testing.allocator.free(dest);
    return testing.allocator.dupe(u8, t.file.buffer.read(0, n, dest));
}

test "markdown: opens path+Markdown once, with the rendered text and a marker" {
    const h = try Scene.init("# Title\n\n![pic](a.png)\n");
    defer h.deinit();
    const src = h.win0();
    try markdown.command(&h.ed, &src.body, "");
    const pv = errors.lookFile(h.tree.row, "file.txt+Markdown") orelse return error.MissingPreview;
    try testing.expect(pv.preview != null);
    try testing.expect(pv.isscratch);
    try testing.expect(!pv.filemenu);
    const body = try bodyText(&pv.body);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "Title") != null);
    try testing.expect(std.mem.indexOf(u8, body, "«image: pic»") != null);
    try markdown.command(&h.ed, &src.body, "");
    const again = errors.lookFile(h.tree.row, "file.txt+Markdown") orelse return error.MissingPreview;
    try testing.expectEqual(pv, again);
}

test "markdown: -web without the host hook warns" {
    const h = try Scene.init("# Title\n");
    defer h.deinit();
    try markdown.command(&h.ed, &h.win0().body, "-web");
    try testing.expect(std.mem.indexOf(u8, h.ed.warningText(), "native host") != null);
    try testing.expect(errors.lookFile(h.tree.row, "file.txt+Markdown") == null);
}
