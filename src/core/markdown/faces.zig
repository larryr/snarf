//! Preview faces (ADR-0008). Body is the window's 9x18. Emphasis is an oblique
//! of that strip, strong a bold of it, h2 the embedded 10x20, h1 a bold of
//! that. h3 uses the 9x18 bold. Code is the body face on `code_back`. Links
//! and markers are solid colours chosen so they read on a light or dark body.
//!
//! The session hangs off `Editor` and is freed in `Editor.deinit`, while the
//! display is still alive. The body font is borrowed from chrome.
//!
//! Imports: `std`, `draw`, `Chrome`.
const std = @import("std");
const draw = @import("draw");
const Chrome = @import("../Chrome.zig");
const runs = @import("runs.zig");

pub const Session = struct {
    body: *draw.Font,
    emph: draw.Font,
    strong: draw.Font,
    h1: draw.Font,
    h2: draw.Font,
    link: draw.Image,
    marker: draw.Image,
    code_back: draw.Image,

    pub fn font(self: *Session, face: runs.Face) *draw.Font {
        return switch (face) {
            .text, .code, .marker => self.body,
            .emph => &self.emph,
            .strong, .h3 => &self.strong,
            .h1 => &self.h1,
            .h2 => &self.h2,
        };
    }

    pub fn deinit(self: *Session) void {
        self.emph.deinit();
        self.strong.deinit();
        self.h1.deinit();
        self.h2.deinit();
        self.link.free() catch {};
        self.marker.free() catch {};
        self.code_back.free() catch {};
    }
};

pub fn create(a: std.mem.Allocator, chrome: *const Chrome) !Session {
    const display = chrome.display;
    var body_sub = try draw.Font.Subfont.parse(a, draw.Font.default_subfont);
    defer body_sub.deinit(a);
    var head_sub = try draw.Font.Subfont.parse(a, draw.Font.heading_subfont);
    defer head_sub.deinit(a);
    var emph_sub = try draw.fontsynth.oblique(a, body_sub);
    defer emph_sub.deinit(a);
    var strong_sub = try draw.fontsynth.bold(a, body_sub);
    defer strong_sub.deinit(a);
    var h1_sub = try draw.fontsynth.bold(a, head_sub);
    defer h1_sub.deinit(a);

    var emph = try draw.Font.initSubfont(a, display, emph_sub);
    errdefer emph.deinit();
    var strong = try draw.Font.initSubfont(a, display, strong_sub);
    errdefer strong.deinit();
    var h2 = try draw.Font.initSubfont(a, display, head_sub);
    errdefer h2.deinit();
    var h1 = try draw.Font.initSubfont(a, display, h1_sub);
    errdefer h1.deinit();

    const chan = display.image.chan;
    const dark = @as(u8, @truncate(chrome.pal.body_text >> 24)) > 0x80;
    var link = try solid(display, chan, if (dark) 0x8CB4FFFF else 0x0033AAFF);
    errdefer link.free() catch {};
    var marker = try solid(display, chan, if (dark) 0x6B5A3EFF else 0xC4B49AFF);
    errdefer marker.free() catch {};
    const code_back = try solid(display, chan, chrome.pal.body_high);

    return .{
        .body = chrome.font,
        .emph = emph,
        .strong = strong,
        .h1 = h1,
        .h2 = h2,
        .link = link,
        .marker = marker,
        .code_back = code_back,
    };
}

fn solid(display: *draw.Display, chan: draw.proto.Chan, color: draw.proto.Color) !draw.Image {
    return display.allocImage(draw.Rect.make(0, 0, 1, 1), chan, true, color);
}
