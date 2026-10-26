# Acme color and visual-design research — 2026-10-26

Scope: what Acme's colors are (fact), who said what about them (statements), what 8½/rio
did before, and what other Acme-alikes chose. Hex values come from the pinned
`larryr/plan9port@337c6ac` `include/draw.h`; every line citation below was checked by
fetching that file at the pinned SHA. Note: in plan9port the color setup lives in
`src/cmd/acme/acme.c` (`iconinit`), not `file.c`; `file.c` has no color code.

**Bottom line:** the sources give the *what* exactly and the *why* not at all. No
statement by Rob Pike or Russ Cox explaining the yellow/blue palette was found.

## 1. Factual record

### 1.1 libdraw named colors (`include/draw.h:31-56`, plan9port @337c6ac)

Format is RGBA (`0xRRGGBBAA`); all are opaque (`FF` alpha) except `DTransparent`.

| Constant | Value | Constant | Value |
|----------|-------|----------|-------|
| `DOpaque` | 0xFFFFFFFF | `DPalebluegreen` | 0xAAFFFFFF |
| `DTransparent` | 0x00000000 | `DPaleblue` | 0x0000BBFF |
| `DBlack` | 0x000000FF | `DBluegreen` | 0x008888FF |
| `DWhite` | 0xFFFFFFFF | `DGreygreen` | 0x55AAAAFF |
| `DRed` | 0xFF0000FF | `DPalegreygreen` | 0x9EEEEEFF |
| `DGreen` | 0x00FF00FF | `DYellowgreen` | 0x99994CFF |
| `DBlue` | 0x0000FFFF | `DMedblue` | 0x000099FF |
| `DCyan` | 0x00FFFFFF | `DGreyblue` | 0x005DBBFF |
| `DMagenta` | 0xFF00FFFF | `DPalegreyblue` | 0x4993DDFF |
| `DYellow` | 0xFFFF00FF | `DPurpleblue` | 0x8888CCFF |
| `DPaleyellow` | 0xFFFFAAFF | `DDarkblue` | 0x000055FF |
| `DDarkyellow` | 0xEEEE9EFF | `DPalegreen` | 0xAAFFAAFF |
| `DDarkgreen` | 0x448844FF | `DMedgreen` | 0x88CC88FF |

The original Plan 9 header (`larryr/plan9@ed1a9c2` `sys/include/draw.h`) has the same
values for `DPaleyellow` (0xFFFFAAFF), `DPalegreen`, `DPalebluegreen`, `DPaleblue`, and its
`acme.c` makes identical color calls (lines 861-900), so plan9port did not alter the palette.

### 1.2 Acme's color slots (`src/cmd/acme/acme.c`, `iconinit`)

Five slots per `Text` kind (`include/frame.h:12-19`): `BACK, HIGH, BORD, TEXT, HTEXT`.

| Element | Call | Line | Nominal | Effective RGB |
|---------|------|-----:|---------|---------------|
| Tag background | `allocimagemix(display, DPalebluegreen, DWhite)` | acme.c:1044 | 0xAAFFFF mixed | **0xEAFFFF** (computed) |
| Tag selection (HIGH) | `allocimage(..., DPalegreygreen)` | 1045 | 0x9EEEEE | same |
| Tag border / scrollbar track (BORD) | `DPurpleblue` | 1046 | 0x8888CC | same |
| Tag text, tag selected text | `display->black` | 1047-1048 | 0x000000 | same |
| Body background | `allocimagemix(display, DPaleyellow, DWhite)` | acme.c:1051 | 0xFFFFAA mixed | **0xFFFFEA** (computed) |
| Body selection (HIGH) | `DDarkyellow` | 1052 | 0xEEEE9E | same |
| Body border / scrollbar track (BORD) | `DYellowgreen` | 1053 | 0x99994C | same |
| Body text, selected text | `display->black` | 1054-1055 | 0x000000 | same |
| Window button (clean) | tag BACK fill + `ButtonBorder` frame in tag BORD | 1068-1070 | | EAFFFF / 8888CC |
| Window button (modified/dirty) | as above plus inner square `DMedblue` | 1073-1079 (`DMedblue` at 1077) | 0x000099 | dark-blue square |
| Column-header box (`colbutton`) | `DPurpleblue` | 1082 | 0x8888CC | same |
| Mouse button 2 sweep (`but2col`) | literal `0xAA0000FF` | 1084 | dark red | same |
| Mouse button 3 sweep (`but3col`) | literal `0x006600FF` | 1085 | dark green | same |

`allocimagemix` (`src/libdraw/allocimagemix.c`): on displays deeper than 8 bits it
blends `color1` over `color3` through a constant mask of 0x3F/255 (about 24.7%); at
8 bits or fewer it builds a 2x2 dither texture instead. The "Effective RGB" column is
my arithmetic from that: 255 - (255 - c) x 63/255 gives 234 = 0xEA where the constant
has 0xAA. These are the familiar `#FFFFEA` / `#EAFFFF`; they are derived, not
printed in any source file.

Where each slot is used (all plan9port @337c6ac):
- Tag text objects use `tagcols`, bodies use `textcols`: wind.c:44, wind.c:71; column and
  row tags use `tagcols`: cols.c:41, rows.c:38.
- Selection: `frdrawsel0(..., f->cols[HIGH], f->cols[HTEXT])` text.c:1170, 1188;
  unselected redraw uses BACK/TEXT, text.c:1165, 1178, 1184.
- Scrollbar: track `cols[BORD]`, thumb `cols[BACK]`, 1-px thumb edge `cols[BORD]`:
  scrl.c:73-76. So the body thumb is pale yellow on a yellow-green track; the tag
  scrollbar region is pale cyan on purple-blue (and the button is drawn there).
- Line separating tag from body: `tagcols[BORD]`, wind.c:74. Window-border redraw during
  layout: wind.c:233 (BORD), wind.c:238 (body BACK).
- Column/row header separator rules and gaps between columns: `display->black`
  (cols.c:45, cols.c:120, rows.c:45, rows.c:84); empty space `display->white`
  (cols.c:32, rows.c:31) and `textcols[BACK]` (cols.c:114, 130, 200).
- Dirty-file button: `windrawbutton` chooses `modbutton` when the file is modified or
  has cached text and is not a directory/scratch window: wind.c:101-103.
- Button 2 / 3 sweeps: `textselect2` passes `but2col`, text.c:1367; `textselect3` passes
  `but3col`, text.c:1382; during the sweep the text is redrawn with that color as
  background and `display->white` as foreground, text.c:1294, 1299, 1307.
- Acme draws no syntax coloring; the only other colors are those above.
- Frame cursor (tick) color is internal to libframe and was not traced.

## 2. Statements about the colors

**Pike: none found.** Searched: Pike's Acme paper (local `docs/acme/acme.md`), the 8½
paper (local `8half.ms`), "A Minimalist Global User Interface" (read via
`https://research.swtch.com/help.pdf`, text extracted; no color vocabulary beyond a
caption about black squares, since Help ran on a black-and-white screen), his 2004
Slashdot interview, and 9fans. The Acme paper says only that a selection is "marked on
the screen by reversing its color" and mentions blue text and border (acme.md:283, 356)
- description, not rationale.

Pike statements that touch color or appearance, none explaining the palette:
- 9fans, "Re: [9fans] sam chatter", 2003-07-05,
  `https://marc.info/?l=9fans&m=111558891922244`. A poster asked that Unix `samterm`
  look like "the (much more asthetically pleasing) Plan 9 version ... in terms of color
  schemes". Pike's whole reply on that point: "(3) is of course trivial and of course
  long since done in plan 9." The aesthetic judgment is the poster's, not Pike's.
- Slashdot, "Rob Pike Responds", 2004-10-18,
  `https://interviews.slashdot.org/story/04/10/18/1153211/rob-pike-responds`. He says he
  "started over and built the much more radical Acme, which I'm using to write these
  answers." No color content (first ~100k of 131k characters read).

**Cox: none found on color.** "A Tour of Acme" (`https://research.swtch.com/acme`,
2012-09-17) mentions the look only in passing: colleagues recognize his computer by
"nothing but yellow windows and blue bars on the screen." That is description, not
design rationale. His plan9port `CHANGES` (archived in `docs/acme/p9p-changes/`) has no
color entries.

**Community folklore (not documented fact, no sources given):**
- David Yates, "Text editors II: Acme", 2015-11-13,
  `https://davidyat.es/2015/11/13/text-editors-ii-acme/`: "Pike read somewhere that the
  distinctive shades of yellow and blue that colour Acme are the best colours for people
  to stare at all day. Maybe this is true." Unsourced and hedged; do not cite as Pike.
- Satyajit Ranjeev, "Bitter Sweet Acme", 2014-05-25,
  `https://satran.in/b/bitter-sweet-acme`: "The colours are picked using the triad
  colour scheme of the base background colour" and "The background causes the least
  strain to the eye on prolonged usage." No source for either; the same post says
  "Whether it was intentionally or out of randomness the colours are almost perfect."
- Unverified repeats: eye-strain / glare claims on forums found by search. Not traced to
  any primary source.

**My inference (labelled as such):** the nominal constants are fully saturated pastels
(AAFFFF, FFFFAA); the 25% blend with white is what makes them near-white. That looks like
a deliberate "tint, don't color" choice made when the system had to run on 8-bit
displays (hence the 2x2 dither branch in `allocimagemix`), but no source states this.

## 3. 8½ / rio lineage

- 8½ paper (`docs/acme/8half/8half.ms`, around line 50): works "on black-and-white,
  grey-scale, or color displays"; at line 780: "8½'s support for color was added by
  Howard Trickey." Confirmed. The paper gives no palette.
- Plan 9 `rio` (`larryr/plan9@ed1a9c2` `sys/src/cmd/rio/wind.c:43-56`, `data.c:178-179`):
  window text area is white (`cols[BACK] = display->white`); selection grey 0xCCCCCC;
  border grey 0x999999; text black; `grey` 0xEEEEEE and `darkgrey` 0x666666; title bars
  use `DGreygreen` (0x55AAAA) and `DPalegreygreen` (0x9EEEEE, the same constant Acme uses
  for tag selection); "hold" mode text uses `DMedblue`, `DGreyblue`, `DPalegreyblue`;
  desktop background 0x777777; error/"red" 0xDD0000. A comment at wind.c:44 says greys
  are "multiples of 0x11111100+0xFF". So rio is mostly grey with the same cyan/blue
  family of libdraw constants as accents; Acme's yellow is new relative to rio.
- The same constant set (`Paleyellow`, `Darkyellow`, `Yellowgreen`, `Palebluegreen`,
  `Palegreygreen`, `Purpleblue`) already existed in libdraw when Acme was written; who
  defined the names was not determined here.
- Help (1991, the Acme precursor) screenshots are black and white; no color.

## 4. Other Acme-alikes (palette, for the later design exercise)

- Inferno Acme (`inferno-os/inferno-os` `appl/acme/acme.b:955-965`): identical to Acme:
  `colormix(Palebluegreen, White)` tags, `colormix(Paleyellow, White)` body, same HIGH and BORD.
- acme-sac (`caerwynj/acme-sac` `appl/acme/acme.b:959-966`): same as Inferno, i.e. same palette.
- plan9port acme: the palette above (the source this project cites).
- Edwood (`rjkroege/edwood`): Go port with a `-palette` flag (names `acme`, `vampira`)
  and a `theme/` package, so it supports a dark alternative; palette values not read.
- Wily: its README does not state default colors; not checked further (X resources).
- Vim colorschemes `vacme`, `acme4real` (adds syntax highlighting), Sublime "Acme Color
  Scheme", Emacs acme theme, `mariusae/acme-neo-theme`: editor themes imitating the yellow body
  look; found by search only, not inspected.
- Anvil (Go, acme-like, per pkgsrc listing; not the web "Anvil"): claims theme support;
  values not read.
- Acme3k (`bubstance/acme3k`): patch to make colors/fonts configurable at compile time.

Unreachable or not found: no usesthis/"The Setup" interview with Pike was found; no 9fans
thread with Pike explaining the palette surfaced (search-engine coverage of 9fans is
poor, so absence is weak evidence). Wikipedia's Acme page has no color content.
