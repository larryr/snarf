//! The `Markdown` builtin (ADR-0008). `mark` is false: it does not bump
//! `ed.seq` and it does not edit the source. The preview window is scratch.
//!
//! Imports: `std` and sibling core files only (never dev/shim).
const Editor = @import("../Editor.zig");
const Text = @import("../text/Text.zig");
const markdown = @import("../markdown/markdown.zig");

pub fn markdownCmd(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    _: ?*Text,
    _: bool,
    _: bool,
    arg: []const u8,
) Text.Error!void {
    try markdown.command(ed, et, arg);
}

test {
    _ = @import("../markdown/inline.zig");
    _ = @import("../markdown/parse.zig");
    _ = @import("../markdown/html.zig");
    _ = @import("../markdown/runs.zig");
    _ = @import("cmd_markdown_test.zig");
}
