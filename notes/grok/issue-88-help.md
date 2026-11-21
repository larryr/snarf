# Issue #88 — Help / +Help

Design for the branch `grok/issue-88-help`. The test plan is the second half.
Both are binding for the implementation and the tests. Do not reopen the
product choices below; record a disagreement in the PR instead.

## What this is

A B2 builtin `Help` opens one window named `+Help` containing a mouse and
touchpad cheat sheet. `snarf -h` and `snarf --help` print that same text and
exit 0 before devdraw is started. One source owns the bytes:
`src/core/exec/cmd_help.zig` `pub const text`.

Acme has no Help command. This is a snarf command, wired like the other
builtins (`exec.c` table, `mark = false`).

## Verified button mapping

The issue's parenthetical ("macOS: Ctrl-click = B2, Alt- or Cmd-click = B3")
does not match devdraw. The sheet must follow the sources, not that guess.

macOS, `larryr/plan9port` `src/cmd/devdraw/mac-screen.m` `getmouse:` (692–712)
and `flagsChanged:` (622–649), `touchesEndedWithEvent:` (669–685). Default
`mouseswap` is identity (`mouseswap.c`).

- Click (left button) is B1. A real middle button is B2. A real right button
  is B3 (Apple's right/middle bits are swapped before `mouseswap`).
- Option held at click time turns B1 into B2. Command does the same for B3.
  Option wins when both are held (`getmouse:` checks Option first).
- While a button is already down, a newly pressed Option adds B2 (cut) and
  Command adds B3 (paste). Control adds B1, which is how a B2 click becomes
  the 2-1 argument chord: Option-click, then Control.
- A three-finger tap sends button 2, then 0: a B2 click.
- A four-finger tap sends 2, then 1, then 0: the 2-1 chord.

Linux X11, `src/cmd/devdraw/x11-screen.c` `ButtonPress` (415–422) and the
modifier arm (500–512).

- Ctrl held at button-1 press remaps that button to 2. Alt (`Mod1`) remaps
  it to 3. Physical buttons 2 and 3 are not remapped.
- While any button is down, pressing Ctrl adds B2 and Alt adds B3.

Browser (the core command runs there too; the host is frozen, the text is
shared): `src/dev/profiles.zig` boots Alt as B2 and Meta/Ctrl as B3. One line
in the sheet says so. Do not describe the browser as the macOS or Linux map.

Esc, Ctrl-U, Ctrl-W, and the command-key cut/copy/paste/undo keys are
deferred no-ops (`src/core/text/typing.zig` header). The sheet says Esc does
not select the just-typed text yet, and that those shortcuts are not in
snarf. It does not describe them as working.

`Zerox`, `Sort`, `Kill`, and `Exit` are not builtins on `main` (they are on
unmerged PR #74). The sheet lists only commands that run today. It does not
mention the four missing ones. The row tag still shows `Kill` and `Exit`;
that tag is not changed by this issue.

## Behavior

`Help` is an `exectab` entry, alphabetical, between `Get` and `Load`.
`mark`, `flag1`, and `flag2` are all false. Executing it must not bump
`ed.seq` and must not mark or dirty the focused file.

Placement is relative to the focused window, which is `ed.seltext`'s window
when that text has a column, otherwise the executing text's window.

- `+Help` already open anywhere in the row: reuse that window. Do not create
  another, do not move it, do not rewrite its body (the user may have typed
  in it). `body.show(0, 0, false)` so the top is on screen.
- Otherwise the destination column is the column to the right of the focused
  one. If the focused column is the rightmost of two or more, use the column
  to its left. A new column is created only when the focused window's column
  is the only column (or the row has no column). The new column contains
  `+Help` only, not an extra empty window. `Row.add` returning null (the row
  is too narrow) falls back to the focused column, or column 0 if there is
  no focus. The command still opens the window.
- The focused window stays in its column. Its body is not edited. The row
  tag is not edited. `mintWindow` may warp when no button is held; a B2
  click has a button down, so the warp is suppressed. Do not add a warp of
  your own.

The window is minted with `place.mintWindow(ed, col, -1, "+Help")`.

`+Help` is scratch, the same way `+Errors` is. `wintag.setName` treats a
name ending in `+Help` like one ending in `+Errors` (`isscratch`: Del does
not two-strike, Putall skips it). `filemenu = false`, then `setTag1`, so the
tag has no Undo/Redo/Put. Set `filemenu` before inserting the body, and call
`setTag1` again after the insert, so a dirty body does not grow a Put word.
The body is `text`, inserted once at rune 0 on creation only.

`Help` is not added to the row tag or to a new window's tag. That is the
discoverability decision, made so this PR does not change the acme tag
surface. Larry can overturn it in review.

## CLI

In `main` (`src/main_native.zig`), before palette parsing and before any
devdraw work: if any argument after argv0 is `-h` or `--help`, write `text`
to stdout and return. `-help`, `--h`, and `--version` are not help.
`--version` stays unimplemented (that is #77, not this issue).

Stdout is `std.Io.File.stdout().writer(init.io, &buf)` (Zig 0.16), flushed.
Not `std.debug.print` (that is stderr).

`pub fn wantsHelp(argv: []const []const u8) bool` lives next to `text` and
is what `main` uses, skipping element 0. `core.zig` exports
`pub const help = @import("exec/cmd_help.zig");`.

## Files

Implementation owns these and nothing else:

- `src/core/exec/cmd_help.zig` — `text`, `wantsHelp`, `help`, and
  `test { _ = @import("cmd_help_test.zig"); }`
- `src/core/exec/builtins.zig` — one table row, and the existing shape test
  (length 19, `Help` in the name list)
- `src/core/exec/exec.zig` — import `cmd_help.zig` from the test block
- `src/core/core.zig` — `pub const help`
- `src/core/wintag.zig` — the `+Help` scratch suffix, comment included
- `src/main_native.zig` — the early exit

Tests own `src/core/exec/cmd_help_test.zig` only. `zig fmt` clean. No file
pushed past the ~400 line cap. `core` does not import `dev` or `shim`.

## Sheet

`text` is exactly the following, including the final newline. Lines are
plain text, under 72 columns.

```
Snarf — mouse, touchpad, and keys

Buttons
  B1  Select. Click sets the caret. Drag to sweep a range. A double
      click selects a word, or the text between matching brackets.
  B2  Execute the word under the pointer, or the text you sweep.
  B3  Look. A file name opens. Any other text is searched for.
      Sweep to look for the swept text.

Chords (hold the first button, then press the second)
  Cut    B1, then B2. The selection is cut and saved.
  Paste  B1, then B3. The saved text is pasted at the selection.
  Snarf  There is no snarf chord. B2 on the word Snarf copies the
         selection and leaves it in place.
  2-1    B2, then B1. The B2 command runs with the B1 selection as
         its argument.
  3-1    B3, then B1. Look for the B1 selection.

macOS (devdraw)
  Click                         B1
  Option-click                  B2
  Command-click                 B3
  Hold the click, then Option   Cut
  Hold the click, then Command  Paste
  Option-click, then Control    2-1 (command with an argument)
  Three-finger tap              a B2 click
  Four-finger tap               a 2-1 chord
  A middle button is B2. A right button is B3.

Linux (devdraw, X11)
  Click                         B1
  Ctrl-click                    B2
  Alt-click                     B3
  Hold the click, then Ctrl     Cut
  Hold the click, then Alt      Paste
  A middle button is B2. A right button is B3.

Browser
  Alt is B2. Ctrl, or Cmd on a Mac, is B3.

Commands (point at the word and press B2)
  Put       write the window to its file
  Get       replace the window with the file
  Undo      undo the last change
  Redo      redo it
  New       an empty window in this column
  Newcol    a new column
  Del       close this window (a dirty window asks twice)
  Delcol    close this column
  Dump      save the layout
  Load      restore a layout
  Edit      edit the window or the selection
  Look      search this window
  Snarf     copy the selection
  Cut       cut the selection
  Paste     paste the saved text
  Help      open this window
  Reconnect re-dial the origin server

Keys
  Left Right   move the caret one character
  Up Down      scroll
  PgUp PgDn    scroll a page
  Home End     start or end of the text
  Ctrl-A       start of the line
  Ctrl-E       end of the line
  Backspace    erase one character

Esc selects what you just typed in acme. Snarf does not do that yet.
Ctrl-U, Ctrl-W, and the command-key cut, copy, paste, and undo
shortcuts are not in snarf yet. Use the chords above.

The same text is printed by:  snarf -h     snarf --help
```

## Test plan

File: `src/core/exec/cmd_help_test.zig`. Colocated style: `std.testing`,
a booted tree (`boot.boot` + `Frame.TestFixture` + `Editor`, rect at least
800×500 so a second column fits), no network, no devdraw. Run `Help` through
`exec.execute` on the runes of the word `Help`. Put that word on the row tag
by appending `" Help"` in the test setup. The command itself must not change
the row tag: after the run, the row tag equals the snapshot taken after the
append. Set `ed.seltext` to the focused body before executing.

Helpers the tests need: read a Text to an allocated `[]u8`; find every
window whose body name is `+Help` by walking `row.col`; `exec.execute`.

| Id | Assert |
|---|---|
| H-01 | One column, `seltext` on its window. `Help` adds a column. `+Help` is in the new column, not the focused one. The focused window is still in column 0 and its body bytes are unchanged. Exactly one `+Help`. |
| H-02 | Two columns (run `Newcol` first), focus stays in column 0. `Help` does not add a third column. `+Help`'s column is column 1. |
| H-03 | Two columns, `seltext` is the window in column 1. `Help` does not add a third column. `+Help`'s column is column 0. |
| H-04 | After H-01's window exists, append `MARK` to its body. `Help` again. The same `*Window` is found, still exactly one `+Help`, body still ends with `MARK`, column count unchanged. |
| H-05 | A fresh `+Help` body's bytes equal `help.text`. |
| H-06 | `help.text` contains `Option-click`, `Command-click`, `Ctrl-click`, `Alt-click`, `Three-finger tap`, `Four-finger tap`, `Cut`, `Paste`, and `Snarf`. It contains the line `Ctrl-click                    B2` only inside the Linux section (the macOS section must not say Ctrl-click). It contains `Esc selects what you just typed` and `does not do that yet`. |
| H-07 | `wantsHelp` is true for `&.{"snarf","-h"}`, `&.{"snarf","--help"}`, and `&.{"snarf","file","--help"}`. False for `&.{"snarf"}`, `&.{"snarf","-help"}`, `&.{"snarf","--h"}`, `&.{"snarf","--version"}`, `&.{"snarf","-colors=sunapee"}`. |
| H-08 | `Help` is in `exectab` between `Get` and `Load`, and `mark` is false. Sweeping the word through `execute` opens `+Help` (this can be H-01; do not add a second dispatch path). |
| H-09 | The new `+Help` has `isscratch` true and `filemenu` false. Its tag bytes do not contain `Put` or `Undo`. |
| H-10 | `ed.seq` and the focused file's `mod` are unchanged by `Help`. |

Do not duplicate `text` inside the tests. Compare against `help.text`.

## Gates

After both halves land, from a clean tree:

1. `zig build test --summary all` — every H-* test runs and passes, and the
   suite stays green.
2. `zig fmt --check` on the touched files (or `zig build` fmt if that is how
   this tree checks; the CI fmt job is `zig fmt --check .` — match CI).
3. `zig build` (wasm still compiles).
4. `node tools/smoke_wasm.mjs`.
5. `zig build native`, then `zig-out/bin/snarf-native --help` and `-h` print
   `text` to stdout, exit 0, and do not print `snarf: devdraw:`.

The X11/devdraw visual check in the issue (open the window, try the chords)
is not part of these gates. It needs a display and a person.
