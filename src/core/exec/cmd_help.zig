//! The `Help` builtin (#88) and the bytes `snarf -h` / `snarf --help` print.
//! Namespace module (S-07 P-1). Snarf-only: acme has no Help command.
//!
//! One window named `+Help`, scratch like `+Errors`. An already-open `+Help`
//! is shown from the top and not rewritten. Otherwise it is minted in the
//! column beside the focused one (`destColumn`). `mark` is false: this does
//! not bump `ed.seq` and does not edit the focused file or the row tag.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Column = @import("../Column.zig");
const Editor = @import("../Editor.zig");
const Row = @import("../Row.zig");
const Text = @import("../text/Text.zig");
const errors = @import("../errors.zig");
const place = @import("../place.zig");

/// The cheat sheet. `Help` inserts it; `snarf -h` and `snarf --help` print it.
pub const text: []const u8 =
    \\Snarf — mouse, touchpad, and keys
    \\
    \\The top tag ends with Help. B2 on that word opens this window.
    \\
    \\Buttons
    \\  B1  Select. Click sets the caret. Drag to sweep a range. A double
    \\      click selects a word, or the text between matching brackets.
    \\  B2  Execute the word under the pointer, or the text you sweep.
    \\  B3  Look. A file name opens. Any other text is searched for.
    \\      Sweep to look for the swept text.
    \\
    \\Chords (hold the first button, then press the second)
    \\  Cut    B1, then B2. The selection is cut and saved.
    \\  Paste  B1, then B3. The saved text is pasted at the selection.
    \\  Snarf  There is no snarf chord. B2 on the word Snarf copies the
    \\         selection and leaves it in place.
    \\  2-1    B2, then B1. The B2 command runs with the B1 selection as
    \\         its argument.
    \\  3-1    B3, then B1. Look for the B1 selection.
    \\
    \\macOS (devdraw)
    \\  Click                         B1
    \\  Option-click                  B2
    \\  Command-click                 B3
    \\  Hold the click, then Option   Cut
    \\  Hold the click, then Command  Paste
    \\  Option-click, then Control    2-1 (command with an argument)
    \\  Three-finger tap              a B2 click
    \\  Four-finger tap               a 2-1 chord
    \\  A middle button is B2. A right button is B3.
    \\
    \\Linux (devdraw, X11)
    \\  Click                         B1
    \\  Ctrl-click                    B2
    \\  Alt-click                     B3
    \\  Hold the click, then Ctrl     Cut
    \\  Hold the click, then Alt      Paste
    \\  A middle button is B2. A right button is B3.
    \\
    \\Browser
    \\  Alt is B2. Ctrl, or Cmd on a Mac, is B3.
    \\
    \\Commands (point at the word and press B2)
    \\  Put       write the window to its file
    \\  Get       replace the window with the file
    \\  Undo      undo the last change
    \\  Redo      redo it
    \\  New       an empty window in this column
    \\  Newcol    a new column
    \\  Del       close this window (a dirty window asks twice)
    \\  Delcol    close this column
    \\  Dump      save the layout
    \\  Load      restore a layout
    \\  Edit      edit the window or the selection
    \\  Look      search this window
    \\  Snarf     copy the selection
    \\  Cut       cut the selection
    \\  Paste     paste the saved text
    \\  Help      open this window
    \\  Reconnect re-dial the origin server
    \\
    \\Keys
    \\  Left Right   move the caret one character
    \\  Up Down      scroll
    \\  PgUp PgDn    scroll a page
    \\  Home End     start or end of the text
    \\  Ctrl-A       start of the line
    \\  Ctrl-E       end of the line
    \\  Backspace    erase one character
    \\
    \\Esc selects what you just typed in acme. Snarf does not do that yet.
    \\Ctrl-U, Ctrl-W, and the command-key cut, copy, paste, and undo
    \\shortcuts are not in snarf yet. Use the chords above.
    \\
    \\The same text is printed by:  snarf -h     snarf --help
    \\
;

/// True iff some argument after argv0 is exactly `-h` or `--help`.
/// `-help`, `--h`, and `--version` are not help.
pub fn wantsHelp(argv: []const []const u8) bool {
    if (argv.len < 2) return false;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    }
    return false;
}

/// `Help` (#88). No argument. `t`, `argt`, and the flags are unused.
pub fn help(
    ed: *Editor,
    et: *Text,
    _: ?*Text,
    _: ?*Text,
    _: bool,
    _: bool,
    _: []const u8,
) Text.Error!void {
    const focus = focusColumn(ed, et);
    const row: *Row = ed.row orelse blk: {
        if (focus) |c| if (c.row) |r| break :blk r;
        break :blk place.rowOf(et) orelse return;
    };

    // Already open anywhere in the row: show the top, leave the body alone.
    if (errors.lookFile(row, "+Help")) |w| {
        try w.body.show(0, 0, false);
        return;
    }

    const col = (try destColumn(ed, row, focus)) orelse return;
    const w = try place.mintWindow(ed, col, -1, "+Help");
    // filemenu before the insert, setTag1 after, so a dirty body grows no Put.
    // isscratch comes from setName (`+Help`, same suffix rule as `+Errors`).
    w.filemenu = false;
    try w.body.insertAt(0, text, true);
    try w.setTag1();
}

/// `ed.seltext`'s window column when that text has one, else `et`'s.
fn focusColumn(ed: *Editor, et: *Text) ?*Column {
    if (ed.seltext) |st| {
        if (place.colOf(st)) |c| return c;
    }
    return place.colOf(et);
}

/// Column for a new `+Help`. To the right of `focus`; the column to its left
/// when `focus` is the rightmost of two or more. No focus is treated as the
/// leftmost column. A new column only when that column is the only one, or
/// the row has none — and that column holds `+Help` only. `row.add` null
/// falls back to `focus`, else column 0.
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

test {
    _ = @import("cmd_help_test.zig");
}
