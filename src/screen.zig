//! screen — the wasm entry point's display-resize adapter (R-GFX-05, S-03 §5).
//!
//! This is acme's `MResize` arm (acme.c:548-555) split across the layers Snarf
//! actually has, in the one place allowed to see all of them: a namespace module
//! beside `main_wasm.zig`, inside the entry-point compilation. It exists as its
//! own file only so `main_wasm.zig` stays near the ~400-line cap (S-07, R-P12c-5);
//! it takes explicit pointers rather than the entry point's `App` struct, so it
//! has no view of the boot context and adds no state of its own (no globals).
//!
//! Layering (R-P12c-4): every hop below already existed — the backend owns the
//! framebuffer, the device owns `ctl`/`refresh`, `src/draw` is a pure 9P client
//! that learns the new size by RE-READING `ctl` (never by being told), and the
//! core is handed a rectangle and knows nothing else. Nothing here reaches into
//! a browser API: the shim already resized the canvas before it pushed the event.
const dev = @import("dev");
const draw = @import("draw");
const core = @import("core");

const CanvasBackend = dev.draw_canvas.CanvasBackend;
const DevDraw = dev.draw.DevDraw;
const Display = draw.Display;

/// Floor a display dimension arriving through `init(w, h)` at 1: a zero-area
/// display would mean a zero-length framebuffer and a degenerate screen rect,
/// and the browser really does report 0 for a window that is minimized or in a
/// hidden tab.
pub fn clampDim(v: u32) u32 {
    return if (v == 0) 1 else v;
}

/// The same floor for a dimension arriving through `pushEvent`'s SIGNED scalars
/// (they are pointer coordinates for every other event kind), so a nonsensical
/// negative size becomes 1 rather than a multi-gigabyte width.
pub fn dimOf(v: i32) u32 {
    return if (v <= 0) 1 else @intCast(v);
}

/// The display is now `w × h` device pixels: resize the framebuffer, expose the
/// new rectangle on the device, re-attach the client to it, and re-tile the
/// window tree. In acme this is
///
///     if(getwindow(display, Refnone) < 0) error("attach to window");
///     draw(screen, screen->r, display->white, nil, ZP);
///     iconinit(); scrlresize();
///     rowresize(&row, screen->clipr);              — acme.c:549-555
///
/// with the first line split in two here, because Snarf's "window system" is the
/// device in the same address space: the backend has to be resized before the
/// client re-reads `ctl`, or `getWindow` would report the old rect right back.
///
/// The whole screen repaints: `CanvasBackend.resize` marks every pixel dirty
/// (the browser cleared the canvas when `canvas.width` was assigned), and
/// `Tree.resize` redraws the tree over it. The caller sets `needs_flush` so the
/// tick's `frameEnd` presents it.
///
/// Every step is fatal on failure, matching `error("attach to window")`
/// (acme.c:550) — a display we cannot resize leaves the editor painting into a
/// framebuffer that no longer matches the canvas.
pub fn resize(
    canvas: *CanvasBackend,
    dd: *DevDraw,
    display: *Display,
    tree: *core.boot.Tree,
    w: u32,
    h: u32,
) !void {
    try canvas.resize(w, h);
    dd.noteResize(dev.draw_backend.Rect.init(0, 0, @intCast(w), @intCast(h)));
    const clipr = try display.getWindow(); // acme.c:549 getwindow(display, Refnone)
    try tree.resize(clipr); // acme.c:551-555 white fill + rowresize
}
