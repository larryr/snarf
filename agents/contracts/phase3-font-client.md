# Phase 3 client contract (O5) — Font.zig, proto extensions, embedded subfont

Extends merged `src/draw/{proto,Display,Image,draw}.zig`; adds `src/draw/Font.zig`.
Read with the master `phase3-font.md` (rulings override) and the device contract's
G11–G20 (shared wire ground truth). Zig 0.16, std only.

## §1 Asset (already landed by the orchestrator — use it, don't re-create)

`assets/fonts/fixed/9x18.0000` (verbatim from the pinned plan9 tree; sha256
`ac0b4bccf24c92471b0aab8e025fe56c1dcb58f5b8c27c32bf6a1dd49b589481`; license note in
`assets/fonts/fixed/README.md`). Compressed image(6) GREY1 strip r=(0,0,1728,18), ONE
compression block; font(6) trailer n=256 height=18 ascent=13, 257×6B Fontchars;
monospace width 9 ('a'=0x61 has x=594; info[256].x=1728). Reachable in the draw module
and its test roots as `@embedFile("font_fixed9x18")` (build.zig wiring done).

## §2 `src/draw/proto.zig` additions (extend; existing four variants untouched)

Wire (LE; offsets from verb byte — must byte-match the device contract G17):

| Verb | Layout | Size |
|---|---|---|
| 'i' 0x69 | fontid[4]@1 nchars[4]@5 ascent[1]@9 | 10 |
| 'l' 0x6C | fontid[4]@1 srcid[4]@5 index[2]@9 r[16]@11 sp[8]@27 left[1]@35(i8) width[1]@36 | 37 |
| 's' 0x73 | dstid[4]@1 srcid[4]@5 fontid[4]@9 p[8]@13 clipr[16]@21 sp[8]@37 ni[2]@45 + ni×u16 | 47+2·ni |
| 'y' 0x79 | id[4]@1 r[16]@5 + row data | 21+len |

New Op variants:
```zig
pub const Load = struct { id: u32, r: Rect, data: []const u8 };           // 'y'
pub const InitFont = struct { id: u32, nchars: u32, ascent: u8 };         // 'i'
pub const LoadChar = struct { fontid: u32, srcid: u32, index: u16,
    r: Rect, sp: Point, left: i8, width: u8 };                            // 'l'
pub const String = struct { dstid: u32, srcid: u32, fontid: u32,
    p: Point, clipr: Rect, sp: Point = .{}, indices: []const u16 };       // 's'
// union arms: load, init_font, load_char, string
```
encodedSize: load ⇒ 21+data.len; init_font ⇒ 10; load_char ⇒ 37; string ⇒
47+2·indices.len. `left` encodes via @bitCast i8→u8. String asserts indices.len ≤ 0xFFFF.

Two pure helpers:
```zig
pub fn chanDepth(c: Chan) ?u32;                 // chantodepth chan.c:69-80
pub fn bytesPerLine(r: Rect, depth: u32) usize; // bytesperline.c:6-33 incl. negative min.x
```

Golden bytes (normative):
- 'i' InitFont{3, 256, 13} ⇒ `69 03 00 00 00 00 01 00 00 0D`.
- 'l' LoadChar{fontid=3, srcid=4, index=0x61, r=make(594,0,603,18), sp=(594,0), left=0,
  width=9} ⇒ `6C 03 00 00 00 04 00 00 00 61 00 52 02 00 00 00 00 00 00 5B 02 00 00
  12 00 00 00 52 02 00 00 00 00 00 00 00 09`.
- 's' String{dstid=0, srcid=5, fontid=3, p=(10,23), clipr=make(0,0,640,480), sp={},
  indices={0x61,0x62}} ⇒ `73 00 00 00 00 05 00 00 00 03 00 00 00 0A 00 00 00 17 00 00
  00 00 00 00 00 00 00 00 00 80 02 00 00 E0 01 00 00 00 00 00 00 00 00 00 00 02 00
  61 00 62 00` (51 B).
- 'y' Load{id=4, r=make(0,0,4,2), data={0xF0,0x90}} ⇒ `79 04 00 00 00 00 00 00 00 00
  00 00 00 04 00 00 00 02 00 00 00 F0 90` (23 B).

## §3 `Display.zig` / `Image.zig` deltas (granted, ruling R-P3-2)

```zig
pub const Error = ninep.Client.Error || ParseError || proto.EncodeError; // grows
pub fn emit(self: *Display, op: proto.Op) Error!void {
    const size = proto.encodedSize(op);
    if (size > self.buf_size) return error.ShortBuffer; // NEW guard: oversized op is
        // an error (chunking discipline violated), never UB. Phase-2 ops always fit.
    if (self.bufn + size > self.buf_size) try self.doFlush();
    const written = proto.encode(op, self.buf[self.bufn..self.buf_size]) catch unreachable;
    self.bufn += written.len;
}
pub fn doFlush(...) // promoted private→pub: Image.load / Font.init need libdraw's
                    // "flush without 'v'" for error attribution (loadimage.c:51,
                    // font.c:301,372). Body unchanged.
```

Image.zig gains the client loadimage:
```zig
pub const LoadError = Display.Error || error{ BadRect, ShortData };
/// Upload raw rows into `r` of this image (loadimage.c:5-54). data =
/// bytesPerLine(r,depth) per row, top row first. CHUNKED: chunk = buf_size - 64;
/// dy = @min(rows left, chunk / bpl) per 'y'; dy==0 ⇒ BadRect (row too wide).
/// r ⊄ self.r ⇒ BadRect; data.len < bpl*Dy ⇒ ShortData. Ends with
/// display.doFlush() (no 'v') for error attribution.
pub fn load(self: *Image, r: proto.Rect, data: []const u8) LoadError!void;
```

## §4 `src/draw/Font.zig` — NEW file-as-struct

```zig
pub const Fontchar = struct { x: u16, top: u8, bottom: u8, left: i8, width: u8 };
pub const ParseError = error{ BadHeader, BadChan, BadCompression, ShortData, OutOfMemory };
pub const Subfont = struct {
    chan: proto.Chan, r: proto.Rect, n: u32, height: u8, ascent: u8,
    info: []Fontchar,   // n+1 entries; info[n].x closes the last glyph
    bits: []u8,         // decompressed rows, bytesPerLine(r,depth)*Dy(r)
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!Subfont;
    pub fn deinit(self: *Subfont, allocator: std.mem.Allocator) void;
};
pub const default_subfont: []const u8 = @embedFile("font_fixed9x18");
pub const string_chunk: usize = 100;                 // string.c:7 Max=100

allocator, display: *Display,
cache: Image,          // server-side font cache image ('b' then 'i')
n: u32, height: u8, ascent: u8,
info: []Fontchar,      // owned copy, n+1 entries

pub const InitError = Display.Error || Image.LoadError || ParseError;
pub fn init(allocator, display: *Display, subfont_data: []const u8) InitError!Font;
pub fn deinit(self: *Font) void;                     // best-effort 'f' cache; free info
pub fn cacheIndex(self: *const Font, c: u21) u16;    // identity if c<n and width!=0, else 0
pub fn charWidth(self: *const Font, c: u21) i32;
pub fn stringWidth(self: *const Font, s: []const u8) i32;  // PURE; invalid UTF-8 ⇒ slot 0
/// Draw UTF-8 s; pt is the TOP-LEFT of the line (wire p.y = pt.y + ascent,
/// string.c:105-107; clipr = dst.clipr). Chunks at string_chunk, advancing pt.x by the
/// chunk's width between chunks. Buffered; pixels appear on next Display.flush().
/// Returns the advanced point.
pub fn drawString(self: *Font, dst: *Image, pt: proto.Point, src: *Image, s: []const u8) Display.Error!proto.Point;
```

**Subfont.parse (normative):**
1. `"compressed\n"` magic (readimage.c:21-22) ⇒ 5×12B image header at offset 11; else
   at 0. chan string via proto.strToChan (reject old 1-digit-ldepth ⇒ BadChan); r fields
   decimal.
2. Uncompressed: payload = bpl×Dy immediately after header.
3. Compressed (creadimage.c:74-80): blocks until y = r.max.y — each block: 12B decimal
   maxy + 12B decimal nbytes (≤ 6000) + data; each decompresses independently (fresh
   window) into rows [y, maxy). Decompressor per cloadmemimage (cload.c:6-67), NMEM=1024
   NMATCH=3 NDUMP=128 (draw.h:516-518): control ≥ 0x80 ⇒ literal run (c-128+1 bytes);
   else copy run ((c>>2)+3 bytes) from offset ((c&3)<<8 | next)+1 back, window wraps at
   1024, overlapping copies legal. Errors ⇒ BadCompression. Private
   `fn decompressBlock(dst: []u8, src: []const u8) error{BadCompression}!void`.
4. Trailer (readsubfont.c:21-45): 3×12B decimal n/height/ascent, then 6·(n+1) bytes per
   _unpackinfo (defont.c:389-401): x = p[0]|p[1]<<8, top, bottom, left(@bitCast i8),
   width. Truncation ⇒ ShortData; height==0 or n==0 or n>4095 ⇒ BadHeader.

**Cache layout (ruling R-P3-5 — identity strip, no repacking):** cache image =
allocImage(sub.r, sub.chan, false, 0); strip likewise; strip.load(sub.r, sub.bits);
'i' with nchars=n, ascent; for each i with info[i].width != 0: 'l' fontid=cache.id
srcid=strip.id index=i **r = make(info[i].x, info[i].top, info[i+1].x, info[i].bottom)**
**sp = (info[i].x, info[i].top)** left=info[i].left width=info[i].width. Then
strip.free() ('l' copied pixels), final display.doFlush() (no 'v'). This makes FChar
minx/maxx/miny/maxy land on strip coordinates so G19 renders identically to libdraw.

**Chunking (normative — keeps the emit guard unreachable):** 'y' only via Image.load
(dy·bpl ≤ buf_size−64); 's' ≤ 100 indices, advancing p.x by the chunk's width sum
between chunks; 'i'/'l' fixed.

## §5 Named tests

proto.zig: "proto: encode i golden", "proto: encode l golden", "proto: encode s golden"
(+ empty-indices 47B case), "proto: encode y golden", "proto: encodedSize matches encode
(fonts)", "proto: variable ops short buffer" ('s' at 50/51, 'y' at 22/23), "proto:
chanDepth and bytesPerLine" (GREY1⇒1, XRGB32⇒32, 0⇒null; make(0,0,1728,18),1 ⇒ 216;
make(0,0,4,2),1 ⇒ 1; a negative-min case).

Font.zig:
- "font: parse tiny subfont" — hand-built uncompressed file: header cells k1,0,0,4,2;
  rows `A0 50`; trailer n=2 height=2 ascent=1; Fontchars `00 00 00 02 00 02`,
  `02 00 00 02 00 02`, `04 00 00 00 00 00`. Assert all fields; info[1] =
  {x=2,top=0,bottom=2,left=0,width=2}; bits = {0xA0,0x50}.
- "font: parse compressed tiny subfont" — same via `"compressed\n"` + block (maxy=2,
  nbytes=3) + `81 A0 50`.
- "font: decompress copy run" — `80 AA 00 00` into 4B dst ⇒ `AA AA AA AA` (overlapping
  copy); truncated src ⇒ BadCompression; overshooting run ⇒ BadCompression.
- "font: parse embedded fixed 9x18" — chan GREY1, r=(0,0,1728,18), n=256, height=18,
  ascent=13, info[0x61].x==594, info[256].x==1728 (pins asset integrity).
- "font: metrics width" — charWidth('a')==9; stringWidth("ab")==18; ""==0; control char
  ⇒ slot 0 (width 9); U+4E00 ⇒ slot 0.
- "image: chunked y load discipline" — small-msize Display: load with bpl·rows > chunk ⇒
  multiple 'y' writes each ≤ buf_size, rows partitioned, data byte-exact; too-wide row ⇒
  BadRect; short data ⇒ ShortData.
- "display: oversized op is an error" — direct emit of a too-big .load ⇒
  error.ShortBuffer, buffer untouched.

draw.zig (FakeDrawTree extension, R-P2-3):
- "phase-3: font draws a string through a fake devdraw" — Font.init with the tiny
  2-glyph subfont, drawString(display.image, (10,10), red, "\x00\x01"), flush. Assert
  the write stream: 'b' strip / 'y' / 'b' cache (own writes), then one write =
  'i'(2,1) + 'l'×2 (identity rects (0,0,2,2)/(2,0,4,2)) + 'f' strip, then one write =
  's' (p=(10,11) — ascent added; ni=2, indices 00 00 01 00) + `76`. deinit ⇒ 'f' cache;
  fid count restored.
- "phase-3: string chunks at 100 indices" — 150-char string ⇒ two 's' messages, second
  with p.x advanced by 100·width; counts 100/50.

Deferred: multi-subfont .font files; runes beyond latin1 (⇒ slot 0); cache
eviction/aging; Go fonts; 'Y'/'x'/'n'/'N'; non-GREY subfonts (parser accepts).
