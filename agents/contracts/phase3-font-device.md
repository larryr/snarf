# Phase 3 device contract (O6) — devdraw font verbs + real mask compositing

Extends merged `src/dev/draw_backend.zig` and `src/dev/draw.zig`. Read with the master
`phase3-font.md` (rulings override). Zig 0.16, std only. Cite pinned C as shown.

## §0 Ground truth (G11–G20)

- **G11 bytes-per-line** (libdraw/bytesperline.c:5-34; image(6)): BYTE-aligned, anchored
  to absolute x. `min.x>=0`: `l = (max.x*d+7)/8 - (min.x*d)/8`; `min.x<0`:
  `l = (-min.x*d+7)/8 + (max.x*d+7)/8`. NOT `ceil(Dx*d/8)`. 'y' payload =
  `Dy(r) * bytesperline(r, depth)` (libmemdraw/load.c:14-17).
- **G12 sub-byte bit order**: HIGH bit is leftmost (image(6); readnbit
  libmemdraw/draw.c:1319-1365). Byte `0b10100000` at x≡0 (mod 8) ⇒ pixels x+0, x+2 set.
- **G13 pixel byte order**: low byte of the chan-packed word first (image(6): "r8g8b8
  pixels have byte ordering blue, green, red"). Per pixel on the wire: GREY8 `[k]`;
  RGB24 `[b,g,r]`; XRGB32 `[b,g,r,x]`; RGBA32 `[a,b,g,r]`.
- **G14 general SoverD with mask** (alphacalc11 libmemdraw/draw.c:1022-1071; macros
  :20-24): `fd = 255 - CALC11(sa, ma)`; `out_c = CALC12(ma, src_c, fd, dst_c)`;
  `out_a = CALC12(ma, sa, fd, dst_a)`. `CALC12(a1,v1,a2,v2) = (t=a1*v1+a2*v2+128;
  (t+(t>>8))>>8)`. It is CALC12 (ONE combined rounding), NOT two CALC11s summed.
- **G15 mask alpha**: alpha chan present ⇒ pixel alpha (draw.c:697-699); else grey value
  relabeled as alpha (greymaskread draw.c:1307-1315). Grey conversion `RGB2K(r,g,b) =
  (156763*r + 307758*g + 59769*b) >> 19` (draw.c:10); `RGB2K(k,k,k)==k` exactly.
- **G16 mask geometry** (drawclip draw.c:226-306): clip r to dst.r∩dst.clipr shifting sp
  AND mp by the min delta; map r into `sr=(sp,sp+Δr)`, clip to src.r∩src.clipr shifting
  mp along; map into `mr=(mp,mp+Δsr)`, clip to mask.r∩mask.clipr, reflect shrink into
  sr; reflect sr into r. Non-repl masks index at `(x,y) - r.min + mp` after all clips.
- **G17 verb layouts** (offsets from verb byte; LE):
  - `'i'` (0x69), **10 B**: fontid[4]@1 nchars[4]@5 ascent[1]@9 (devdraw.c:1662-1686).
  - `'l'` (0x6C), **37 B**: fontid[4]@1 srcid[4]@5 index[2]@9 r[16]@11 sp[8]@27
    left[1]@35 (SIGNED i8) width[1]@36 (devdraw.c:1688-1713).
  - `'s'` (0x73), **47 + 2·ni B**: dstid[4]@1 srcid[4]@5 fontid[4]@9 p[8]@13 clipr[16]@21
    sp[8]@37 ni[2]@45, indices u16 LE @47. Two-stage short check: 47 first, then
    `+2·ni` (devdraw.c:1949-1975).
  - `'y'` (0x79), **21 B + payload**: id[4]@1 r[16]@5 then `Dy*bpl` bytes; the loop
    advances past exactly that many, so more verbs may follow (devdraw.c:2082-2101).
- **G18 per-font state** = `{ascent: u8, fchar[]}` on the image (devdraw.c:107-115,
  130-132). `FChar{minx,maxx: i32, miny,maxy: u8 (TRUNCATED from int — kernel behavior),
  left: i8, width: u8}`. `'i'` zeroes/reallocs an existing table (:1679-1684). The font
  image is a normal 'b' image; `'l'` fills it via **op-S copy** with an opaque mask
  (:1705).
- **G19 drawchar** (devdraw.c:887-929): for index ci: `r.min = (q.x+left,
  q.y-(ascent-miny))`; `r.max = r.min + (maxx-minx, maxy-miny)`; source point
  `(sp.x+left, sp.y+miny)`; mask = font image at `(minx, miny)`; SoverD; then
  `q.x += width; sp.x += width`. `'s'` REPLACES dst.clipr with the wire clipr for the
  op's duration and restores it on every exit path incl. errors (:1976-1977, 2011).
- **G20 error strings** (devdraw.c:174-184, 2098): "image not a font", "character index
  out of range", "writeimage outside image", "bad writeimage call" — now in
  ninep/errors.zig as NotFont/BadIndex/WriteOutside/BadWriteImage (granted, R-P3-4).

## §1 RULING — GREY storage unchanged; mask alpha computed at READ time

Phase-2 storage rule stays exactly: buffered non-alpha chans store A=0xFF; 1×1 repl
solids keep their fill word verbatim. Mask alpha:
`ma = if (chanHasAlpha(mask.chan)) pixel.a else rgb2k(pixel.r, pixel.g, pixel.b)`.
White solids ⇒ ma=255 (phase-2 opaque case, bit-identical); black ⇒ ma=0 (true no-op:
`CALC12(0,s,255,d)=d` exactly). No phase-2 test or frozen hash changes (verified).
Documented deviation (accepted, doc-comment it): a buffered GREY image 'b'-filled with a
COLORED value stores rgb verbatim rather than pre-converting to grey; ma still matches
the kernel (RGB2K at read).

## §2 `src/dev/draw_backend.zig` extensions (additive; existing five vtable fns unchanged)

```zig
pub const Error = error{ UnknownImage, ImageExists, BadChan, BadRect, Unsupported,
    OutOfMemory, WriteOutside, ShortData };           // two new members
pub const ImageInfo = struct { chan: u32, r: Rect, clipr: Rect, repl: bool };
```

Four new VTable fns appended after `displayInfo` (+ convenience wrappers):

```zig
/// 'y': raw pixel upload. r ⊄ image.r ⇒ WriteOutside (devdraw.c:2094);
/// data.len < Dy*bpl ⇒ ShortData (load.c:14-16). Returns bytes CONSUMED (Dy*bpl)
/// so the verb loop advances past the payload; trailing bytes belong to the
/// next verb.
loadPixels: *const fn (ctx: *anyopaque, id: u32, r: Rect, data: []const u8) Error!usize,
/// op-S straight copy (bytes stored verbatim incl. alpha; non-alpha dst forces
/// A=0xFF). Used by 'l' (devdraw.c:1705). Case-B clip geometry. dst==src ⇒
/// Unsupported.
copy: *const fn (ctx: *anyopaque, dst: u32, src: u32, r: Rect, sp: Point) Error!void,
/// Replace an image's clipr (assignment, NOT intersection — devdraw.c:1976).
/// id 0 sets the display's clipr.
setClipr: *const fn (ctx: *anyopaque, id: u32, clipr: Rect) Error!void,
/// Introspection for 's' (save/restore clipr; validate ids, devdraw.c:1960-62).
imageInfo: *const fn (ctx: *anyopaque, id: u32) Error!ImageInfo,
```

`draw()` signature unchanged; semantics grow (Case C shrinks):
1. Clip r to dst.r∩dst.clipr shifting **both sp and mp** (G16 — phase 2 discarded mp).
2. Source: Case A (1×1 repl solid) or Case B (non-repl; sr clip; **mp shifts by
   sr.min−sp** before the shrink reflects into r). Repl non-1×1 ⇒ Unsupported.
3. Mask: (a) 1×1 repl solid ⇒ constant `ma = maskAlpha(chan, unpack(fill))`; ma==255
   takes the phase-2 path VERBATIM (frozen hashes preserved by construction); ma==0 ⇒
   no-op; else constant-ma blend. (b) non-repl buffered ⇒ `mr=(mp,mp+Δr)` clipped to
   mask.r∩mask.clipr, shrink reflected into r (and sp), mp=mr.min; per pixel
   `ma = maskAlpha(mask.chan, maskPixelAt((x,y)−r.min+mp))`. (c) repl non-solid ⇒
   Unsupported.
4. Per pixel: ma==0 skip; ma==255 ⇒ existing phase-2 composite; else G14 with
   `@min(255, …)` guards; non-alpha dst forces A=0xFF (unchanged).

Helpers (exact):
```zig
fn calc12(a1: u32, v1: u32, a2: u32, v2: u32) u32 { // draw.c:23-24
    const t = a1 * v1 + a2 * v2 + 128;
    return (t + (t >> 8)) >> 8;
}
fn rgb2k(r: u8, g: u8, b: u8) u8 { // RGB2K draw.c:10
    return @intCast((156763 * @as(u32, r) + 307758 * @as(u32, g) + 59769 * @as(u32, b)) >> 19);
}
fn maskAlpha(chan: u32, p: Rgba) u8;   // per G15
fn bytesPerLine(r: Rect, depth: u32) usize; // G11 incl. negative-min branch
fn chanDepth(chan: u32) u32; // GREY1⇒1, GREY8⇒8, RGB24⇒24, RGBA32/XRGB32⇒32
```
`View` gains a `chan` field. HeadlessBackend gains `display_clipr: Rect` (init=bounds;
`dstSurface(0)` uses it; `setClipr(0,·)` sets it).

`loadPixels` decode (G12/G13) into RGBA storage: GREY1 bit⇒k∈{0,255}⇒`[k,k,k,FF]`
(first byte of each row contains pixel min.x at bit position `min.x&7` counting from the
HIGH bit); GREY8 `[k]`⇒`[k,k,k,FF]`; RGB24 `[b,g,r]`⇒`[r,g,b,FF]`; XRGB32
`[b,g,r,x]`⇒`[r,g,b,FF]`; RGBA32 `[a,b,g,r]`⇒`[r,g,b,a]` (already premultiplied).
Special cases: id 0 = display (r ⊂ bounds else WriteOutside; marks dirty); a 1×1 repl
solid has no buffer — decode the single pixel and UPDATE `img.fill`.

## §3 `src/dev/draw.zig` dispatch extensions

Font state (mirrors G18):
```zig
const FChar = struct { minx: i32, maxx: i32, miny: u8, maxy: u8, left: i8, width: u8 };
const FontRec = struct { ascent: u8, chars: []FChar };
fonts: std.AutoHashMapUnmanaged(u32, FontRec) = .empty,
```
Lifecycle: 'f' on a font id also frees its FontRec; reset()/deinit free all.

- **'y'**: `const consumed = backend.loadPixels(id, r, a[21..]) catch |e| return
  opError(e); i += 21 + consumed;`. Fixed check is the 21-byte header only; payload
  shortfall = backend ShortData ⇒ "bad writeimage call" (NOT ShortDraw — kernel-faithful).
- **'i'**: fontid==0 ⇒ BadDraw; id must be in `self.allocated` else NoDrawImage;
  nchars==0 or >4096 ⇒ BadDraw; replace any existing FontRec with zeroed chars;
  ascent = a[9].
- **'l'**: font ladder — `fonts` has id ⇒ ok; else id in `allocated` ⇒ NotFont; else
  NoDrawImage. `ci = rdU16(a,9)`; ci >= chars.len ⇒ BadIndex. Then
  `backend.copy(fontid, srcid, rdRect(a,11), rdPoint(a,27))` (op-S). Store FChar with
  miny/maxy = @truncate of the rect's y values (kernel truncation, G18), left =
  @bitCast(a[35]), width = a[36].
- **'s'**: 47-byte check; ni = rdU16(a,45); second check `a.len >= 47+2*ni` ⇒ else
  ShortDraw. Upfront imageInfo(dstid) + imageInfo(srcid) (NoDrawImage); font ladder.
  Save old = imageInfo(dstid).clipr; setClipr(dstid, wire clipr); loop indices: index
  >= nfchar ⇒ restore clipr, BadIndex (prior glyphs stay, G5); per glyph G19 geometry
  then `backend.draw(dstid, srcid, fontid, r, sp1, .{ .x = fc.minx, .y = fc.miny })`,
  advance q.x += width, sp.x += width; restore clipr on ALL exits. Zero-width unloaded
  slots ⇒ empty rect ⇒ no-op, advance 0. Dirty tracking = per-glyph union (benign
  deviation from the kernel's textbox rect — **'s' tests must not pin `hb.dirty`**).
- opError additions: WriteOutside⇒error.WriteOutside, ShortData⇒error.BadWriteImage.
- 'x' stringbg, 'n'/'N', ctl writes: NOT phase 3.

## §4 Named tests

draw_backend.zig (64×48 fixture):
1. "headless: GREY8 gradient mask blend" — GREY8 4×1 mask {0x00,0x40,0x80,0xFF} via
   loadPixels; RED through it over white ⇒ pixels exactly
   {0xFFFFFFFF, 0xFFBFBFFF, 0xFF7F7FFF, 0xFF0000FF} (hand-derived per G14/G15).
2. "headless: GREY1 mask bit order" — one byte `0b10100000` ⇒ x=0,2 red, x=1,3..7
   untouched (pins G12).
3. "headless: general mask formula pin" — src 0x7F00007F, GREY8 solid mask 0x80 over
   white ⇒ exactly 0xFFBFBFFF (sa=127, ma=128, CALC11(127,128)=64, fd=191 — pins CALC12).
4. "headless: solid grey mask constant alpha" — GREY8 solid 0x808080FF mask: RED over
   white ⇒ 0xFF7F7FFF; black GREY1 solid mask ⇒ hash unchanged; white GREY1 solid ⇒
   phase-2 path exact.
5. "headless: loadPixels round-trip" — 2×2 RGBA32 wire `[a,b,g,r]` order; GREY8 2×2;
   XRGB32 direct to display id 0 (marks dirty); loadPixels into a 1×1 repl solid updates
   fill.
6. "headless: loadPixels bytes-per-line math" — GREY1 r=(1,0,3,1) ⇒ consumed 1 (byte
   `0b01100000` sets x=1,2); GREY1 r=(−3,0,2,1) ⇒ consumed 2 (negative branch); GREY8
   r=(0,0,3,2) ⇒ 6.
7. "headless: loadPixels errors" — outside ⇒ WriteOutside; short ⇒ ShortData; long ⇒
   returns exactly needed.
8. "headless: copy is a straight store" — translucent RGBA32 pixel copied onto white ⇒
   dst bytes == src bytes (distinguishes S from SoverD); dst==src ⇒ Unsupported.
9. "headless: mask subrect via mp" — GREY1 4×1 mask bits `1010…`; draw with mp=(2,0) ⇒
   only mask columns 2..3 gate (pins the mp fix).
10. "headless: setClipr and imageInfo" — display clipr limits fills; imageInfo
    round-trips; unknown id ⇒ UnknownImage.

draw.zig (Harness 640×480):
11. "devdraw: y upload then draw round-trip" — 'b'+'y'(16B RGBA32 2×2)+'d'+'v' in ONE
    Twrite (pins payload advance); spot-checks; flush_count 1.
12. "devdraw: y errors" — outside ⇒ "writeimage outside image"; short payload ⇒ "bad
    writeimage call"; unknown id ⇒ "unknown id for draw image".
13. "devdraw: i/l/s two-glyph string — spot checks + frozen hash" (FROZEN-D) — exact
    scene: 'b' id1 GREY1 1×1 repl white; 'b' id2 RGBA32 1×1 repl RED; 'b' id3 GREY8
    (0,0,8,4) non-repl 0 (strip); 'b' id4 GREY8 (0,0,8,4) (cache); 'y' id3 32 bytes rows
    `FF 00 FF 00 FF FF 00 00 / 00 FF 00 FF FF FF 00 00 / FF 00 FF 00 FF FF 00 00 /
    00 FF 00 FF FF FF 00 00`; 'i' font=4 nchars=2 ascent=3; 'l' font=4 src=3 idx=0
    r=(0,0,4,4) sp=(0,0) left=0 width=5; 'l' idx=1 r=(4,0,8,4) sp=(4,0) left=1 width=6;
    's' dst=0 src=2 font=4 p=(100,100) clipr=(0,0,640,480) sp=(0,0) ni=2 idx {0,1}; 'v'.
    Expected (G19): glyph0 box (100,97)-(104,101) checkerboard red at
    (100,97),(102,97),(101,98),(103,98),(100,99),(102,99),(101,100),(103,100); pen → 105;
    glyph1 box (106,97)-(110,101) red columns x=106,107 for y=97..100; x=108,109 clear.
    Spot-checks incl. (105,97)=0 gap, (100,96)=0, (100,101)=0. flush_count 1. Freeze
    after spot-checks pass.
14. "devdraw: font errors" — 'i' fontid=0 ⇒ "bad draw message"; 'i' unknown ⇒ "unknown
    id for draw image"; 'i' nchars 0 / 4097 ⇒ "bad draw message"; 'l' on non-'i' image ⇒
    "image not a font"; 'l' index ≥ nchars ⇒ "character index out of range"; 's' unknown
    fontid ⇒ "unknown id for draw image"; 's' on non-font ⇒ "image not a font"; 's'
    indices {0, 99} ⇒ "character index out of range" AND glyph0 pixels stay AND clipr
    restored (a follow-up 'd' outside the wire clipr still paints).
15. "devdraw: s short checks two-stage" — 46 bytes ⇒ "short draw message"; ni=3 with 2
    indices ⇒ "short draw message".
16. "devdraw: clunk resets fonts" — after 'i', clunk ctl ⇒ fonts map empty; reconnect +
    re-'i' works.
