# Phase 2 contract — draw (rectangle on a headless framebuffer)

Approved build spec for `src/draw/{proto,Display,Image}.zig` + `src/dev/{draw,draw_backend}.zig`.
Produced by outline agents O3 (client) and O4 (device), reconciled by the orchestrator.
Build agents implement these signatures and named tests **as written**; deviations need
orchestrator sign-off. Specs: S-03 (primary), S-07 §3/§4/§6. Phase scope: allocate a
color image, SoverD a rectangle onto the display through /dev/draw, flush, golden-hash
the headless framebuffer. Fonts = Phase 3; OffscreenCanvas backend = Phase 5.

## §0 Ground-truth rulings (violating any of these is a review failure)

- **G1 — LITTLE-ENDIAN.** Draw wire format is little-endian, same as 9P, despite the
  `BG*` macro names: `BGSHORT(p)=((p)[0]<<0)|((p)[1]<<8)` (`plan9 draw.h:508-511`;
  identical plan9port `draw.h:527-530`); draw(3) man page: "multibyte integers are
  transmitted with the low order byte first" (`sys/man/3/draw:111`). Use
  `std.mem.writeInt/readInt(..., .little)`. Coordinates are **signed i32**
  (devdraw.c:871-877); ids/chan/color are u32.
- **G2 — Colors** are 32-bit `rrggbbaa`, alpha-premultiplied (red bits 31-24 … alpha
  7-0). `DRed=0xFF0000FF`, `DWhite=0xFFFFFFFF`. Read at devdraw.c:1480.
- **G3 — Connection number N=1** (kernel first client: `++sdraw.clientid`,
  devdraw.c:805). Client parses N from the connection line — never hardcodes.
- **G4 — Nil mask is a real image on the wire**: libdraw substitutes display white
  (1×1 repl GREY1 filled 0xFFFFFFFF) for a nil mask (libdraw/draw.c:31-32,
  init.c:313-320). Server recognizes exactly "1×1 repl, fill all-ones" as opaque
  (libmemdraw/draw.c:1952); other masks ⇒ Unsupported in Phase 2.
- **G5 — Partial messages are an error, never buffered** (`if(n<m) error(Eshortdraw)`
  per verb, devdraw.c:1471-1472). Ops applied before a mid-batch error stay applied
  (no rollback; devdraw.c:1456-1466).
- **G6 — Image id 0 is the display**, pre-installed at connection (devdraw.c:1078).
  'b' with an existing id (incl. 0) errors; 'd'/'f' with unknown id errors.
- **G7 — Verb sizes/layouts** (offsets from the verb byte; all multi-byte fields LE):
  - `'b'` (0x62), **51 B**: id[4]@1 screenid[4]@5 refresh[1]@9 chan[4]@10 repl[1]@14
    r[16]@15 clipr[16]@31 color[4]@47. (devdraw.c:1467-1540; alloc.c:43-67)
  - `'d'` (0x64), **45 B**: dstid[4]@1 srcid[4]@5 maskid[4]@9 r[16]@13 sp[8]@29
    mp[8]@37. Always SoverD in Phase 2. (devdraw.c:1578-1594; draw.c:26-45)
  - `'f'` (0x66), **5 B**: id[4]@1. (devdraw.c:1640-1650)
  - `'v'` (0x76), **1 B**, bare — the 4-byte suffix is a plan9port variant; do not
    emit or require it. (devdraw.c:2075-2080)
  - Rect on wire = min.x min.y max.x max.y (4×i32); Point = x y (2×i32).
- **G8 — Connection line**: kernel format `"%11d %11d %11s %11d ..."` — 12 fields ×
  12 bytes = **144 bytes**, each value right-justified in 11 cols + one space, no
  newline (devdraw.c:1197-1204). Field order: clientid, infoid(0), chan string,
  repl, r.min.x, r.min.y, r.max.x, r.max.y, clipr×4. Opening `new` **morphs the fid
  into the connection's ctl file** (devdraw.c:1056-1060); reading it returns the line.
- **G9 — Chan codes** (`draw.h:112-146`): GREY1("k1")=0x31, GREY8("k8")=0x38,
  XRGB32("x8r8g8b8")=0x68081828, RGBA32("r8g8b8a8")=0x08182848, RGB24("r8g8b8")=
  0x00081828. Display chan is XRGB32 (S-03 §1). Add comptime asserts re-deriving each.
- **G10 — Repl clip rect** = (-0x3FFFFFFF,-0x3FFFFFFF,0x3FFFFFFF,0x3FFFFFFF)
  (alloc.c:58-62).

## Orchestrator rulings

- **R-P2-1** `Display.init(allocator, client, draw_dir_fid)` takes the fid of the
  **draw directory itself** (what mount resolve("/dev/draw") will yield) and walks
  `["new"]`, later `["<N>","data"]`, relative to it. Never walks a literal "draw".
- **R-P2-2** The cross-module acceptance test lives in a NEW test-only root
  `src/accept.zig` (imports draw+ninep+dev), wired into build.zig **by the
  orchestrator in Wave C**. Build agents do not touch build.zig or accept.zig.
- **R-P2-3** `src/draw/draw.zig` (namespace root) MAY use `ninep.server` **in test
  blocks only** (FakeDrawTree), with a comment citing this ruling — same precedent as
  ninep.zig's acceptance test. Non-test draw code stays client-only (S-07 §6).
- **R-P2-4 (OQ-1 granted, already applied)**: `ninep/errors.zig` now has `BadDraw` →
  "bad draw message" (S-03 §2 wording), `ShortDraw` → "short draw message",
  `NoDrawImage` → "unknown id for draw image" (devdraw.c:174-178). Use them — do NOT
  map draw faults onto BadMessage. Mapping table (§4 of dev spec below): unknown verb
  / short msg / split write ⇒ BadDraw resp. ShortDraw; unknown image id ⇒ NoDrawImage;
  id in use ⇒ BadDraw; ctl read < 144 ⇒ ShortDraw; busy connection / data-без-conn ⇒
  PermissionDenied; backend OOM ⇒ IoError; bad chan / nonzero screenid / unsupported
  mask/tiling ⇒ BadDraw.
- **R-P2-5** Both sides define their own Point/Rect/chan constants (dev cannot import
  draw); each adds comptime asserts deriving chan codes from the `__DC` arithmetic so
  drift is impossible.
- **R-P2-6** DevDraw's tree root IS the draw directory: `/new`, `/1/{ctl,data,refresh}`.
  `colormap` omitted (S-03 legacy; O4 OQ-6). One exclusive connection guarded by
  `busy`; clunk of last open ctl fid resets (frees images allocated since open).
- **R-P2-7** Frozen-hash protocol (§6 of O4, normative): every golden case has pixel
  spot-checks AND a `std.hash.Wyhash.hash(0, fb)` frozen literal, frozen only after
  spot-checks pass, with a scene comment; never re-freeze alongside render changes
  without orchestrator re-verification. Build agents freeze their own module-local
  hashes; the acceptance hash (FROZEN-ACCEPT) is orchestrator-frozen.

## Sub-wave assignments

- **2a (concurrent):** A1 sonnet `src/draw/proto.zig` (§P below) ∥ A2 opus
  `src/dev/draw_backend.zig` (§B below; also adds `pub const draw_backend = ...` line
  to `src/dev/dev.zig` — its only edit outside its file).
- **2b (concurrent, after 2a merges):** B1 opus `src/dev/draw.zig` (§D) ∥ B2 opus
  `src/draw/Display.zig`+`src/draw/Image.zig`+`src/draw/draw.zig` re-exports (§C).
- **Wave C (orchestrator):** accept.zig + build.zig wiring + FROZEN-ACCEPT + report.

---

## §P `src/draw/proto.zig` — client encoder (sonnet; replaces stub; ~250 impl)

Pure, imports std only. Public surface (implement exactly; doc comments cite G-rulings):

```zig
pub const Point = struct { x: i32 = 0, y: i32 = 0,
    pub const wire_size: usize = 8;
    pub fn encode(self: Point, buf: *[wire_size]u8) void; };
pub const Rect = struct { min: Point = .{}, max: Point = .{},
    pub const wire_size: usize = 16;
    pub fn encode(self: Rect, buf: *[wire_size]u8) void;
    pub fn make(x0: i32, y0: i32, x1: i32, y1: i32) Rect; };
pub const repl_clipr: Rect; // G10
pub const Chan = u32;
pub const GREY1: Chan = 0x31; pub const GREY8: Chan = 0x38;
pub const XRGB32: Chan = 0x68081828; pub const RGBA32: Chan = 0x08182848;
pub fn strToChan(s: []const u8) ?Chan; // mirrors strtochan chan.c:40-66; null on bad
pub const Color = u32;
pub const DOpaque=0xFFFFFFFF; DTransparent=0; DBlack=0x000000FF; DWhite=0xFFFFFFFF;
pub const DRed=0xFF0000FF; DGreen=0x00FF00FF; DBlue=0x0000FFFF; DCyan=0x00FFFFFF;
pub const DMagenta=0xFF00FFFF; DYellow=0xFFFF00FF; DPaleyellow=0xFFFFAAFF;
pub const DNotacolor=0xFFFFFF00; pub const DNofill=DNotacolor; // all : Color
pub const Refresh = enum(u8) { backup = 0, none = 1, mesg = 2 };
pub const Op = union(enum) {
    alloc: Alloc, draw: Draw, free: Free, flush,
    pub const Alloc = struct { id: u32, screenid: u32 = 0, refresh: Refresh = .backup,
        chan: Chan, repl: bool = false, r: Rect, clipr: Rect, color: Color };
    pub const Draw = struct { dstid: u32, srcid: u32, maskid: u32, r: Rect,
        sp: Point = .{}, mp: Point = .{} };
    pub const Free = struct { id: u32 };
};
pub const EncodeError = error{ShortBuffer};
pub fn encodedSize(op: Op) usize;                 // 51/45/5/1 per G7
pub fn encode(op: Op, buf: []u8) EncodeError![]u8; // returns written sub-slice
```

Delete the stub's placeholder `Op` (its Qid field is bogus). Wire offsets per G7
verbatim. repl/refresh encode as single bytes.

Named tests (implement exactly; golden bytes are normative):
- **"proto: point/rect wire encode"** — Point{-1,2} → `FF FF FF FF 02 00 00 00`;
  Rect.make(0,0,1,1) → zeros/ones LE as computed.
- **"proto: encode b golden"** — Alloc{id=1, chan=GREY1, repl=true,
  r=make(0,0,1,1), clipr=repl_clipr, color=DWhite} → exactly:
  `62 01 00 00 00 00 00 00 00 00 31 00 00 00 01 00 00 00 00 00 00 00 00 01 00 00 00
   01 00 00 00 01 00 00 C0 01 00 00 C0 FF FF FF 3F FF FF FF 3F FF FF FF FF` (51 B).
- **"proto: encode d golden"** — Draw{dstid=0, srcid=3, maskid=1,
  r=make(10,10,20,20), sp/mp={}} → exactly:
  `64 00 00 00 00 03 00 00 00 01 00 00 00 0A 00 00 00 0A 00 00 00 14 00 00 00 14 00
   00 00` + 16 zero bytes (45 B).
- **"proto: encode f and v golden"** — `66 01 00 00 00`; `76`.
- **"proto: encodedSize matches encode"** — one op per variant.
- **"proto: short buffer"** — alloc into 50 B ⇒ ShortBuffer; 51 succeeds.
- **"proto: strToChan"** — the four constants round-trip; "q8"/"k"/""/5-channel ⇒ null.
- **"proto: chan constants derive"** — comptime re-derivation asserts (G9).

## §B `src/dev/draw_backend.zig` — backend + headless (opus; new; ~250 impl)

Imports **std ONLY** (never shim — the canvas impl is a separate Phase-5 file
`draw_canvas.zig`). Runtime vtable shaped like `ninep.transport.Transport`. Public
surface — implement O4's §1 exactly:

- Geometry: `Point{x,y: i32}`, `Rect{min,max: Point}` with `init(x0,y0,x1,y1)`, `dx`,
  `dy`, `isEmpty`, `clip(*Rect, Rect) bool` (intersect-in-place, false if empty),
  `contains`, `translate`. Half-open, top-left origin, y down.
- Chans: `GREY1=0x31, RGB24=0x00081828, RGBA32=0x08182848, XRGB32=0x68081828` +
  comptime derivation asserts (G9).
- `pub const display_id: u32 = 0;` (G6)
- `pub const Error = error{ UnknownImage, ImageExists, BadChan, BadRect, Unsupported,
  OutOfMemory };`
- `pub const DisplayInfo = struct { chan: u32, r: Rect, clipr: Rect };`
- `pub const Backend = struct { ctx: *anyopaque, vtable: *const VTable, ... }` with
  VTable fns exactly: `allocImage(ctx, id, r, chan, repl, clipr, color) Error!void`
  (!repl ⇒ store clipr∩r; repl ⇒ verbatim; devdraw.c:1533-1535), `freeImage(ctx, id)
  Error!void` (unknown ⇒ UnknownImage; id 0 ⇒ Unsupported), `draw(ctx, dst, src, mask,
  r, sp, mp) Error!void`, `flush(ctx) void`, `displayInfo(ctx) DisplayInfo` — plus the
  five convenience wrappers.
- `pub const HeadlessBackend = struct { ... }` per O4 §1.3: RGBA8888 `[R,G,B,A]`
  row-major fb (zero-init), `images: AutoHashMapUnmanaged(u32, Image)` (id 0 = fb, not
  in map), `dirty: ?Rect`, `flush_count: u32`, `init(alloc,w,h)`, `deinit`,
  `backend(*Self) Backend` (self must be pinned), `pixels() []const u8`,
  `pixelAt(x,y) u32` (packed 0xRRGGBBAA), `hash() u64` = `std.hash.Wyhash.hash(0, fb)`,
  `writePpm(w: *std.Io.Writer)`.
- Pixel semantics: storage always RGBA8888 holding premultiplied values; chans without
  alpha force A=0xFF on fill. 1×1 repl solids carry no pixel buffer (fill color only).

**draw() semantics (normative, §1.4 of O4):** resolve ids (else UnknownImage); mask
must be opaque-equivalent (1×1 repl fill all-ones) else Unsupported; clip r to dst.r ∩
dst.clipr, translating sp by the min shift (drawclip, libmemdraw/draw.c:236-245);
Case A solid fill (src 1×1 repl — sp irrelevant, drawreplxy draw.c:292-298); Case B
non-repl copy (sr = (sp, sp+Δr) ∩ src.r ∩ src.clipr, reflect shrink back, draw.c:
251-253, 284-290); Case C anything else ⇒ Unsupported. SoverD per channel with
`CALC11(a,v) = (t = a*v + 128; (t + (t>>8)) >> 8)`: `out_c = src_c + CALC11(255-src_a,
dst_c)` (draw.c:1035-1058); src_a==0xFF short-circuits to store. Dirty = union of
display-touching clipped rects; flush clears dirty, ++flush_count.

Also: add `pub const draw_backend = @import("draw_backend.zig");` to `src/dev/dev.zig`
(your only edit outside your file).

Named tests 1-9 from O4 §5 (implement exactly, names verbatim): "headless: fill full
display red", "headless: fill sub-rect — spot checks + frozen hash" (FROZEN-A),
"headless: overlapping second fill — frozen hash" (FROZEN-B), "headless: repl solid
ignores sp", "headless: clip to display and clipr", "headless: non-repl copy with
source clipping", "headless: SoverD translucent fill" (0x7F00007F over white ⇒
exactly 0xFF8080FF — pins the arithmetic), "headless: alloc/free lifecycle errors",
"headless: ppm dump shape". Fixture 64×48. Frozen hashes per R-P2-7.

## §C `src/draw/Display.zig` + `src/draw/Image.zig` (opus, one agent; ~250+~200 impl)

Implement O3's §2/§3 exactly, with R-P2-1 applied. Key points:

- `Display` file-as-struct; fields: allocator, `client: *ninep.Client` (borrowed),
  `ctl_fid` (the morphed `new` fid; owned), `data_fid` (owned), `conn: ConnInfo`,
  `image: Image` (id 0), `white: Image`, `black: Image` (1×1 repl GREY1, ids 1,2,
  allocated at init like initdisplay init.c:313-317; white doubles as opaque mask),
  `buf: []u8` (len = buf_size+1, one byte reserved for 'v'), `bufn`, `buf_size` =
  min(client.msize - IOHDRSZ, 8000), `imageid: u32 = 0` (pre-increment ⇒ user ids
  start after white/black).
- `pub const ConnInfo = struct { conn: u32, image_id: u32, chan: proto.Chan,
  repl: bool, r: proto.Rect, clipr: proto.Rect };`
- `pub const ParseError = error{ ShortInfo, BadInfo };`
  `pub const Error = ninep.Client.Error || ParseError;`
  `pub const info_size: usize = 144;`
- `pub fn parseConnInfo(info: []const u8) ParseError!ConnInfo` — PURE (unit-testable):
  12 fields × 12 bytes, trim spaces, parse decimal (field 2 via proto.strToChan;
  negative coords legal). <144 ⇒ ShortInfo; bad field ⇒ BadInfo.
- `pub fn init(allocator, client: *ninep.Client, draw_dir_fid: u32) Error!*Display` —
  (R-P2-1) walk draw_dir_fid→["new"], open ORDWR, read 144+1 at offset 0 (n<144 ⇒
  ShortInfo), parse; format conn number with bufPrint; walk draw_dir_fid→["<N>",
  "data"], open ORDWR; alloc white+black (eager-flushed 'b' each). Heap *Display so
  Image back-pointers stay stable. draw_dir_fid is borrowed.
- `pub fn deinit(self: *Display) void` — best-effort free white/black/flush, clunk
  ctl+data fids, free buf, destroy.
- `pub fn allocImage(self, r, chan, repl, color) Error!Image` — id = ++imageid (+2
  offset scheme is fine as long as ids are unique and non-zero; document); clipr = r
  or repl_clipr; emit 'b'; **eager doFlush** (error attribution, alloc.c:42,68).
- `pub fn emit(self, op: proto.Op) Error!void` — bufimage discipline: if op doesn't
  fit, doFlush first; encode into buf.
- `pub fn flush(self) Error!void` — append 'v' (reserved byte), doFlush.
- `fn doFlush(self) Error!void` — ONE client.write(data_fid, 0, buf[0..bufn]); short
  ack ⇒ error.IoError; reset bufn. An op reaches the wire only on: overflow, flush(),
  allocImage eager flush, deinit.
- `Image` file-as-struct: `display: *Display, id: u32, r, clipr: proto.Rect,
  chan: proto.Chan, repl: bool`;
  `pub fn draw(dst: *Image, r: proto.Rect, src: *Image, mask: ?*Image, p: proto.Point)
  Display.Error!void` — emits 'd' with maskid = (mask orelse &dst.display.white).id,
  sp = mp = p (draw.c:48-51); buffered.
  `pub fn free(self: *Image) Display.Error!void` — emit 'f'; assert id != 0.
- Display↔Image import cycle is intended (legal in Zig); do not "fix".
- `src/draw/draw.zig` root: re-export proto, Display, Image, Point, Rect; keep
  refAllDecls test; add the FakeDrawTree acceptance-style test below.

Named tests (O3 §5, names verbatim): "display: parse connection line" (canned 144-byte
string, fields 1,0,x8r8g8b8,0, 0,0,800,600, 0,0,800,600 — build it as 12 concatenated
"%11s " fields), "display: parse short info" (143 bytes ⇒ ShortInfo), "display: parse
bad decimal field", "display: parse bad chan", "display: negative rect coords parse";
and in draw.zig: **"phase-2: display draws a rect through a fake devdraw"** — a
minimal FakeDrawTree over ninep.chan.Pipe + ninep.server (test-only, R-P2-3): serves
`new` (open morph semantics not required in the fake — read returns the canned line)
and `1/data` (records raw written bytes); assert: init produces 2 recorded writes
(white+black 'b's), allocImage(red) eager-flushes its 'b', image.draw(...) buffers
(write count unchanged), flush() writes exactly the 'd' golden bytes + `76`, deinit
clunks (server fid count back). Plus an Rerror surfacing case: server answers a data
write with Rerror "bad draw message" ⇒ client sees error.BadDraw (R-P2-4 — note this
means the fake tree returns error.BadDraw from its write op).

## §D `src/dev/draw.zig` — DevDraw server (opus; replaces stub; ~400 impl)

Implement O4's §2/§3/§4 exactly, with R-P2-4/R-P2-6 applied. Key points:

- Imports: std, ninep (server/errors/stat/Qid), `@import("draw_backend.zig")`.
  **DELETE the stub's shim import and abi_version** — devdraw has no shim business.
- Tree (R-P2-6): root(dir, qid 0x00) / new(0x01) / 1(dir, 0x12) / ctl(0x13),
  data(0x14), refresh(0x15). `Node = enum(u4) { root=0, new=1, conn=2, ctl=3, data=4,
  refresh=5 }`; qid path = (conn_number<<4) | node for connection nodes.
- `pub const DevDraw = struct { allocator, backend: draw_backend.Backend, busy: bool,
  open_count: u32, allocated: ArrayListUnmanaged(u32), pub fn init(alloc, backend)
  DevDraw; pub fn deinit(*Self) void; pub const ops: ninep.server.Ops = ...; }` —
  per-fid state NONE (node kind lives in fid.qid.path; fid.ctx stays null).
- Ops (exact phase-1 signatures, R8): attach ⇒ root qid; walk1 per tree ("..": conn→
  root, root→root); open: `.new` ⇒ busy? PermissionDenied : **mutate fid.qid to the
  ctl qid** and treat as ctl-open (kernel Qnew morph, devdraw.c:1056-1061; framework
  replies with the returned qid — return the NEW ctl qid); `.ctl` ⇒ busy guard, busy=
  true, open_count+=1; `.data`/`.refresh` ⇒ require busy (else PermissionDenied),
  refresh write-mode ⇒ PermissionDenied; read: ctl @offset 0 ⇒ buf.len<144 ⇒
  ShortDraw, else the 144-byte line (idempotent; offset!=0 ⇒ 0); data ⇒ BadDraw;
  refresh ⇒ 0; dirs ⇒ 0; write: data ⇒ dispatch(data) then return data.len; ctl ⇒
  BadDraw (Phase-3 accepts infoid writes); clunk: open ctl fid ⇒ open_count-=1, at 0
  reset (free `allocated` ids via backend, clear, busy=false); stat: name table
  ("draw","new","1","ctl","data","refresh"), dirs DMDIR|0o555, new/ctl/data 0o666,
  refresh 0o444, length 0.
- Connection line (G8): `"{d:>11} "` × 12 into a `[144]u8`; values: 1, 0, "x8r8g8b8",
  0, then r and clipr from `backend.displayInfo()`. For 640×480 the exact literal is
  the one in test 10 below.
- `dispatch(data)`: drawmesg loop (devdraw.c:1457-1466) — multiple concatenated
  messages per write; per verb check remaining ≥ size (else ShortDraw, G5); parse LE
  (G1, G7); backend call; error stops the loop (G6 — прior ops stay). Verb 'b':
  screenid != 0 ⇒ BadDraw; chan outside {GREY1,GREY8,RGB24,RGBA32,XRGB32}… backend
  returns BadChan ⇒ map BadDraw. Unknown verb ⇒ BadDraw. Fault mapping through ONE
  private `opError()` fn per R-P2-4 table.
- Backend error map: UnknownImage⇒NoDrawImage, ImageExists⇒BadDraw, BadChan⇒BadDraw,
  BadRect⇒BadDraw, Unsupported⇒BadDraw, OutOfMemory⇒IoError.

Named tests 10-17 from O4 §5 (names verbatim, hand-encoded frames over a
ninep.chan.Pipe + Server + transact helper — do NOT import src/draw):
"devdraw: walk, open new, read connection line" (exact 144-byte literal for 640×480:
`"          1           0    x8r8g8b8           0           0           0         640         480           0           0         640         480 "`;
second read same; count 143 ⇒ Rerror "short draw message"; offset 144 ⇒ 0),
"devdraw: b+b+d+v batch in one Twrite" (148-byte batch, Rwrite 148, spot-checks,
flush_count 1, FROZEN-C),
"devdraw: bad verb ⇒ Rerror, prior ops applied" (Rerror "bad draw message"),
"devdraw: two whole messages in two Twrites",
"devdraw: op split across two Twrites ⇒ both fail" (both Rerror, hash unchanged),
"devdraw: single connection is exclusive",
"devdraw: clunk resets images",
"devdraw: stat and walk table".

## Acceptance (Wave C, orchestrator)

`src/accept.zig` (new test root; build.zig wiring by orchestrator): full stack —
draw.Display/Image + ninep.Client over chan.Pipe → Server(DevDraw.ops) →
HeadlessBackend 640×480. Scene: fill display white; red 1×1 repl; draw r =
(100,100)-(300,200) SoverD; flush. Assert corner/inside pixels, client-side parsed
rect == (0,0,640,480), flush_count == 1, FROZEN-ACCEPT hash (R-P2-7).

## Hard gates (unchanged from phase 1)

Zig 0.16; `zig build test --summary all` green + `zig fmt --check build.zig src/
tools/` clean IN YOUR WORKTREE before returning (verify your worktree has the phase-1
ninep files AND `src/ninep/errors.zig` containing `BadDraw` — else
`git rebase phase2-draw` first); only assigned files (+ the single dev.zig line for
A2); colocated tests, named tests not weakened; cite pinned C (`devdraw.c:NNN`,
`libmemdraw/draw.c:NNN`, `alloc.c:NNN`); ~400-line soft cap per impl (tests excluded);
STOP and report if a signature cannot work as written.
