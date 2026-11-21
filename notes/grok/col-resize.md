# Column drag — `rowdragcol`

Design for the branch `grok/col-resize`. The test plan is the second half.
Both are binding for the implementation and the tests. Do not reopen the
product choices below; record a disagreement in the PR instead.

There is no GitHub issue. The PR does not say `Fixes`.

## What this is

Dragging the button square at the left of a **column** tag resizes that
column against the column on its left, or moves the column to a new place
in the row. This is acme's `rowdragcol` (`rows.c:140-206`), reached from
`acme.c:630-641` when the pointer is in a `Columntag`'s `scrollr`.

Window drag (`coldragwin`, `cols.c:474`, the window tag's square) is not
this change. A window-tag button stays the no-op it is today. So does the
row tag's scrollbar strip. A body's scrollbar still scrolls.

The layout moves on button-up, as in acme. There is no live rubber-band
while the button is held.

The host cursor does not change during the drag. Acme's `setcursor2` of
`boxcursor` (`rows.c:151`) is a known visual gap: `/dev/cursor` exists on
the native host, and the core has no writer for it. Do not add one here.

The Help sheet is not changed. `cmd_help.zig`, the accept goldens, and
`Column.zig` are not touched. `Column.resize` already exists.

## Event model

Acme blocks in `readmouse` (`rows.c:154-160`). Snarf is edge-triggered, the
same divergence `Gesture.zig` already documents for `textselect`. One sample
is one `Editor.handleMouse` call.

A drag is pinned the way a text gesture is: once it starts, every sample
routes to it until every button is up, including samples that have moved
off the button and onto a body. A body under the pointer must not take a
selection from those samples.

`but` in `acme.c:596-601` is set only when `buttons` is exactly 1, 2, or 4.
Any one of those three starts a column drag (`rowdragcol` ignores the
button number, `rows.c:148`). A chord on the press does not start one, and
it still returns from the scrollbar arm: it does not fall through into
`textselect`. A sample with no buttons does not start one.

Tracking, translated:

- Press (the sample that starts it): `restoremouse.clear(ed)` immediately
  (`rows.c:150`). Remember the column, the button set, and the point.
  Do not change layout. Do not set `activecol` yet.
- A later sample whose buttons still equal the remembered set: ignore it.
  Layout stays put (`while (mouse->buttons == b)`).
- The first sample whose buttons differ, and the new set is 0: this is the
  release. Apply the layout from this sample's point, then the gesture ends.
- The first sample whose buttons differ, and the new set is not 0: cancel
  (`rows.c:157-160`). Do not apply. Drain every following sample until
  buttons are 0, then end. A B1 press, a move, then B1+B2, then all up,
  leaves the columns where they were.

When the gesture ends and the column is still in the row, set
`ed.activecol` to it (`acme.c:639-640`). Do this for a click, a cancel, a
leftmost no-op, a resize, and a shuffle. Do not set `seltext`, `argtext`,
`focus`, or `gesture_text`. If the column was destroyed (the failure path
below), do not read it and do not assign it to `activecol`.

`ed.needs_flush = true` only when the release paints (resize, shuffle, or
the destroy path). A click, a leftmost no-op, and a cancel do not.

## Release rules

Find the column's index in `row.col`. If it is no longer there, end the
gesture and do not paint. Do not `unreachable`.

Let `op` be the press point and `p` the release point. If
`abs(p.x-op.x) < 5` and `abs(p.y-op.y) < 5`, return (`rows.c:170-171`).
Five pixels on one axis is enough to act. Four on both is not. Use a
non-negative difference, compared with `< 5`. Do not use a Euclidean
distance.

Otherwise, with `c` the dragged column and `i` its index
(`rows.c:172-184`):

- Shuffle when `(i > 0 and p.x < col[i-1].r.min.x)` or
  `(i + 1 < ncol and p.x > c.r.max.x)`.
- Else if `i == 0`, return. The leftmost column is resized by dragging the
  column to its right. Dragging the leftmost button past that column's own
  `r.max.x` is the shuffle above, not a resize.
- Else resize against `d = col[i-1]`.

Shuffle (`rows.c:174-183`), in this order:

1. Remember `x = c.r.min.x`.
2. `row.close(ed, c, false)`. The column and its windows stay allocated.
   Snarf's `Row.close` already does this when `dofree` is false.
3. Reattach at `p.x`. If that returns null, reattach at `x`. If that
   returns null, reattach at `-1`. Reattach is `rowadd`'s existing-column
   branch (`rows.c:91-92`), which `Row.add` does not implement today.
4. If all three return null, `row.close(ed, c, true)` and return. After
   that call, `c` is freed. Do not warp, do not set `activecol`, do not
   read `c`.
5. Otherwise `colmousebut(c)`.

Resize (`rows.c:185-205`):

Clamp `p.x` to `[d.r.min.x + 80 + Scrollwid, c.r.max.x - 80 - Scrollwid]`,
lower bound first, then upper, so the upper bound wins when the two
columns are too narrow to satisfy both (`rows.c:188-191`). `Scrollwid` is
`Chrome.scrollwid` (12). The `80` is acme's literal.

Then, using the rects from before the clamp is applied to them:

1. Fill `d.r` extended to `max.x = c.r.max.x` with `chrome.ground`. Acme
   uses `display->white`. Snarf's other layout fills use the palette
   ground (ADR-0007). Do the same here. The rule color is `chrome.rule`,
   not a literal black.
2. `d.resize(ed, d's rect with max.x = p.x)`.
3. Fill the band `{min.x = p.x, max.x = p.x + Border, y from c.r}` with
   `chrome.rule`. `Border` is `Chrome.border` (2).
4. `c.resize(ed, {min.x = p.x + Border, max.x = c.r.max.x, y from c.r})`.
5. `colmousebut(c)`.

If the clamped `x` would make either column narrower than the floor
`Row.resize` already uses (`Scrollwid + Scrollgap + font.height`, 34px at
the 9×18 font), do not draw and do not resize. Return as a no-op: no warp,
no `needs_flush`, and `activecol` is still set. Acme would die in
`frinsert` on that width. A browser window is allowed to be that narrow
(the same divergence as `Row.resize`, R-GFX-05). The 80px margins and the
lower-then-upper order stay when both sides still fit.

`colmousebut` (`cols.c:230-233`) is `warp.to` of the center of
`c.tag.scrollr` after the resize:

```
x = (scrollr.min.x + scrollr.max.x) / 2
y = (scrollr.min.y + scrollr.max.y) / 2
```

Integer division toward zero, matching `divpt(addpt(min, max), 2)`. Call it
only after a resize or a shuffle that actually reattached. `warp.to` is a
no-op without `/dev/mouse`, which is the right behavior in a headless test
that does not mount one.

## Reattach

`Row.add` / `addAtBoot` stay no-clone (they pass no existing column). Add
the other branch of `rowadd` as `Row.attach(row, ed, c, x) !*Column` or
`!?*Column` (null means "refused", the column was not inserted and was not
resized). Share `addImpl`'s split math. Do not copy it.

`addImpl` grows an `existing: ?*Column` parameter.

- `null`: today's path. `add` and `addAtBoot` pass null. The
  `clearmouse` on `add`'s success stays where it is. `addAtBoot` still
  does not clear.
- non-null: the caller has already detached `c`. Do not `init` a column
  and do not allocate one. Run the same landing-column split. A landing
  column narrower than 100px returns null before resizing anyone
  (`rows.c:74-75`), including `c`. Otherwise `c.resize(ed, r)` into the
  carved rect (`rows.c:92`), `c.row = row`, splice `c` in at the same
  index the new-column path uses, then `restoremouse.clear(ed)`
  (`rows.c:99`). Return `c`.

When `ncol == 0`, `rowadd` skips the 100px check and places the column in
the full column region. Keep that for both branches.

`attach` assumes `c` is not already in `row.col`. The drag detaches first.

The existing test `row: add steals 3/5 split and refuses <100px` must keep
passing with the same numbers. Do not change default boot geometry. Do not
re-freeze accept hashes.

## Where the code goes

`Gesture.handleMouse`, after `mouse_pt` / `buttons` are updated and after
the buttons-up `scroll_but = 0` line, and **before** the pinned
`gesture_text` arm:

- If a column drag is active, give it this sample. When it says the gesture
  is over, clear the drag state. Return. Do not hit-test.

In the scrollbar arm (`Gesture.zig` step 5): the body arm is unchanged.
Before the unconditional `return`, if `t.what == .columntag` and `buttons`
is exactly `B1`, `B2`, or `B3`, start a drag on `t.col` (it is non-null for
a column tag that `rowwhich` returned). Then return, as today, for every
other scrollbar hit (window tag, row tag, chord, buttons up).

The drag value lives on `Gesture` so it hangs off `Editor` (no globals).
The struct and the functions live in `src/core/dragcol.zig`. `Gesture`
imports `dragcol`. `dragcol` imports `Editor` and does not import
`Gesture`. That is the same cycle shape as `textselect` / `Editor` /
`Gesture`, which already compiles. Do not also store a copy of the column
on `Editor`.

`dragcol.zig` ends with `test { _ = @import("dragcol_test.zig"); }`.

## Files

Implementation owns these and nothing else:

- `src/core/dragcol.zig` — new. The state struct, `begin`, the per-sample
  step, resize, shuffle, `colmousebut`.
- `src/core/Gesture.zig` — the field, the owner check, the columntag arm.
  Update the step-5 comment that says drag is deferred: column drag is
  this port; window drag is still deferred.
- `src/core/Row.zig` — `existing` on `addImpl`, `attach`, and the file
  header. The header currently says `rowdragcol` waits. It no longer does.
  `rowclose` is already ported; do not rewrite `close`.
- `src/core/Editor.zig` — the comment on `activecol` (the fourth writer,
  around the `acme.c:640` sentence). Column-tag drags now set it when the
  gesture ends. `coldragwin` still does not. Do not change behavior in
  this file. PR #74 also edits `Editor.zig`; touch only that comment.
- `src/core/restoremouse.zig` — the `REMAINING GAP` comment. `rowdragcol`'s
  `clearmouse` is ported. `colsort` and `coldragwin` are still not.
- `docs/requirements/02-editor-functional.md` — R-EDIT-25 wording and a v12
  revision-log line, below. Do not renumber. Do not bump the "Draft v4"
  status. R-EDIT-01's sentence already says columns are resized with the
  mouse; leave the sentence, record the delivery in the log.

R-EDIT-25, replace this clause:

> the remaining layout/scroll `moveto`s (`cols.c:206/232`, `scrl.c`, `wind.c`) are not ported yet on any host.

with:

> the remaining layout/scroll `moveto`s (`cols.c:206`, `scrl.c`, `wind.c`) are not ported yet on any host. `colmousebut` (`cols.c:232`) is ported: a successful column drag warps to the center of that column's tag button (v12).

Replace this clause:

> the `clearmouse` sites in the unported `colsort`, `coldragwin` and `rowdragcol` (`cols.c:303/484`, `rows.c:150`) arrive with those functions.

with:

> the `clearmouse` at the start of `rowdragcol` (`rows.c:150`) is ported (v12). The sites in the unported `colsort` and `coldragwin` (`cols.c:303/484`) arrive with those functions.

Revision log, newest entry, directly above v11:

> **v12** (2026-11-21, column drag) — no IDs added or renumbered. **R-EDIT-01**: dragging a column tag's button resizes the shared border, or reorders the column when the release is outside it (`rowdragcol`, `rows.c:140-206`). Window drag (`coldragwin`) is still unported. **R-EDIT-25**: that drag's `clearmouse` (`rows.c:150`) and its `colmousebut` warp (`cols.c:232`) are ported. `colsort` and `coldragwin` are still not.

Tests own `src/core/dragcol_test.zig` only. If that file passes about 450
lines, split the shuffle and destroy cases into
`src/core/dragcol_shuffle_test.zig` and import both from `dragcol.zig`.
`zig fmt` clean. `core` does not import `dev` or `shim`.

Do not edit `agents/contracts/` or `agents/reports/`. Those record the
phase in which drag was deferred.

## Worked geometry

9×18 font, `Border` 2, `Scrollwid` 12. Screen `(0,0,600,400)`. Columns
start at y = 20 (row tag 0..18, band 18..20) and run to y = 400.

`boot.boot` makes one column `(0,20,600,400)` and one window in it. Then
`row.add(ed, -1)` splits at `3/5`: the first column's `max.x` becomes 358,
the new column is `(360,20,600,400)`. The 2px between 358 and 360 is the
band. This is the layout every two-column test starts from. Call the
original columns `c0` and `c1`. The boot window stays in `c0`.

Button centers, integer, from `tag.scrollr` after that split:

- `c0`: `(6, 29)`. `scrollr` is x 0..12, y 20..38.
- `c1`: `(366, 29)`. `scrollr` is x 360..372, y 20..38.

Clamp span for a drag of `c1`: low `0+80+12 = 92`, high `600-80-12 = 508`.

| Release of `c1` from `(366, 29)` | `c0.r` | `c1.r` |
|---|---|---|
| `(200, 29)`, B1 or B3 | `(0,20,200,400)` | `(202,20,600,400)` |
| `(371, 29)` (exactly 5px in x) | `(0,20,371,400)` | `(373,20,600,400)` |
| `(10, 29)` | `(0,20,92,400)` | `(94,20,600,400)` |
| `(590, 29)` | `(0,20,508,400)` | `(510,20,600,400)` |
| `(370, 33)` (dx 4, dy 4) | unchanged | unchanged |

After the `(200, 29)` resize, `c1.tag.scrollr` is x 202..214, y 20..38, so
`colmousebut` warps to `(208, 29)`.

Shuffle, drag `c0` from `(6, 29)` to `(400, 29)` (`400 > c0.r.max.x`):

- `row.col.items[0]` is the old `c1`, rect `(0,20,398,400)`.
- `row.col.items[1]` is the old `c0`, rect `(400,20,600,400)`.
- The boot window's `r.min.x` is 400 and `r.max.x` is 600. Its `col` is
  the old `c0`.

Drag `c1` to `(-10, 29)`. That shuffles (`p.x < c0.r.min.x`), `rowadd`
then treats a negative x as the 3/5 steal, and the rects come back as
`(0,20,358,400)` and `(360,20,600,400)` with the same pointers. Still two
columns. This is a successful reattach, so it does warp.

Destroy: from the two-column layout, `row.resize(ed, (0,0,80,400))`. The
proportional split plus the 34px floor leaves `c0` at x 0..47 and `c1` at
x 49..83. Drag `c0`'s button (still centered near `(6, 29)`) to `(100, 29)`.
`100 > 47`, so this shuffles. After `close(false)`, `c1` is 83px wide, and
all three reattaches refuse a landing column under 100px. `close(true)`
frees `c0` and the boot window. One column remains, and it is the old
`c1`. Do not dereference `c0` after that.

## Test plan

File: `src/core/dragcol_test.zig`. Colocated style: `std.testing`,
`Frame.TestFixture`, `boot.boot` on `(0, 0, 600, 400)`, `Editor.init`,
`ed.row = tree.row`. No network and no devdraw, except C-15 which mounts
`warp.MouseSink` the way `src/core/warp_focus_test.zig` does. Drive
everything through `ed.handleMouse`. `MouseEvent.msec` is 0.
`Editor.mev` is fine.

A press point is the center of the live `tag.scrollr`, and C-01 asserts
that center is `(366, 29)` for `c1` so a wrong split fails in setup.
Release points are the coordinates in the table. "Unchanged" means both
column rects and `row.col.items.len`.

| Id | Assert |
|---|---|
| C-01 | Setup centers as above. B1 down at `(366, 29)`, then B1 still down at `(200, 29)`: rects unchanged, `activecol` still null. Release `(200, 29)`. Rects are the table's first row. The boot window's `r.min.x`/`r.max.x` equal `c0`'s. `needs_flush` is true. `seltext` is still null. `activecol` is `c1`. Column-tag bytes are still `New Cut Paste Snarf Sort Zerox Delcol `. |
| C-02 | Release at `(370, 33)`. Rects unchanged. `activecol` is `c1`. `needs_flush` is false. |
| C-03 | Release at `(371, 29)`. Rects are the table's second row. |
| C-04 | B1 on `c0` at `(6, 29)`, release `(100, 29)`. Rects unchanged. `activecol` is `c0`. |
| C-05 | One column only. Drag its button from its center to x = 200. Its rect is unchanged. `activecol` is that column. |
| C-06 | Release `(10, 29)` on `c1`. Rects are the low-clamp row. |
| C-07 | Release `(590, 29)` on `c1`. Rects are the high-clamp row. |
| C-08 | B1 down, B1 move to `(200, 29)`, then buttons `B1\|B2` at `(200, 29)`, then buttons 0. Rects unchanged. `activecol` is `c1`. A following C-01 release still resizes (the drag state is not stuck). |
| C-09 | Drag the boot window's `tag.scrollr` center 80px to the right, button up there. That window's rect and both column rects are unchanged. |
| C-10 | Record the boot body's `q0`/`q1`. Drag from `c1`'s button to `(200, 29)` along y = 200 so the path crosses the body. Release there. Body `q0`/`q1` are unchanged. Column rects are C-01's. |
| C-11 | Drag `c0` from `(6, 29)` to `(400, 29)`. Pointers and rects are the shuffle paragraph. `activecol` is the old `c0`. Window count in that column is still 1. |
| C-12 | Drag `c1` to `(-10, 29)`. Same two pointers, rects back to 358/360 and 360/600. `activecol` is `c1`. |
| C-13 | `restoremouse.save(ed, boot window)`, then B1 down on `c1`'s button and no release yet. `ed.mousew` is null. Release inside the deadzone. It is still null. Rects unchanged. |
| C-14 | B3 press/release of `c1` at `(200, 29)` matches C-01's rects. A separate scene: press `B1\|B2` on `c1`'s button and release at `(200, 29)` with buttons 0. Rects unchanged. |
| C-15 | Mount `warp.MouseSink`. After C-01's release, the sink's last warp is `(208, 29)` and `gesture.mouse_pt` is that point. A deadzone release writes no warp. |
| C-16 | Two columns, `row.resize` to `(0,0,80,400)`, drag `c0`'s button to `(100, 29)`. `row.col.items.len` is 1 and the remaining pointer is the old `c1`. `activecol` is null. Do not read the freed column or its window. `ed.handleMouse` of a later deadzone click on the survivor's button sets `activecol` to that survivor. |
| C-17 | B2 click (deadzone) on `c1`'s button does not add a window or a column. |
| C-18 | Drag the row tag's `scrollr` center to x = 200. Column rects unchanged. |
| C-19 | Two columns, `row.resize` to `(0,0,80,400)`. Drag `c1`'s button to x = 20 (a resize, not a shuffle, and outside the deadzone). Both rects unchanged. `activecol` is `c1`. `needs_flush` is false. This is the panic guard: the acme clamp would ask for a column narrower than one glyph. |

C-15 may follow `warp_focus_test.zig`'s rig (`MouseSink` ops, a 9P pipe,
`ed.ns`). The other tests leave `ed.ns` null.

## Gates

After both halves land, from a clean tree:

1. `zig fmt --check .`
2. `zig build test --summary all` — every C-* test runs and passes, and
   the suite stays green. No accept hash is updated.
3. `zig build` (wasm).
4. `node tools/smoke_wasm.mjs`.
5. `zig build native`.

No display check is required for the gates. The box cursor will not
change; the columns will.
