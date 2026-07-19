# Phase 5 contract — browser bring-up (canvas backend + shim + wasm boot)

Reconciled from O9 (pixel path) + O10 (boot). Goal: the real pipeline renders on the
real canvas; pixel-identity with the frozen goldens BY CONSTRUCTION. Hard gates
unchanged, plus: `zig build` (wasm) green is itself a load-bearing gate this phase.

## Rulings

- **R-P5-1**: v1 canvas backend = software-composite wrapper around HeadlessBackend +
  one blit import. Per-image OffscreenCanvas (S-03 §3) would BREAK golden fidelity
  (canvas compositing cannot reproduce CALC11/12 +128 rounding) — it becomes a later
  performance phase. Orchestrator adds the S-03 §3 revision note.
- **R-P5-2 (divergence, flagged)**: module runs on the MAIN THREAD in phase 5 (S-00 §2
  mandates a Worker; nothing exists to block on yet). Worker + rings land with
  devinput. ABI survives the move. S-00 revision note by orchestrator.
- **R-P5-3**: display fixed 640×480 (matches goldens); duplicated in main_wasm and
  index.html; canvasResize + DPR (R-GFX-05) deferred to the input phase.
- **R-P5-4**: abi version 1→2; wasm exports `abi_version() u32` (export FN); shim.js
  checks it BEFORE init() and throws on mismatch. OQ-BLD-2 codegen stays deferred.
  S-06 §4's `blit(imgId,...)+flush(rectsPtr,n)` superseded by ONE merged blit
  (revision note by orchestrator).
- **R-P5-5**: draw_canvas is thin+trivial (≤120 impl lines, ZERO pixel/geometry logic —
  any compositing in it is a review error); abi.blit comptime-gates the extern behind
  `is_wasm` with a `pub var test_blit: ?BlitFn` native seam.
- **R-P5-6 (reconciled)**: consoleLog IS provided (O10 wins over O9's flag 6): root-only
  `extern "env" fn consoleLog(ptr, len)` declared in main_wasm.zig (NOT abi.zig — the
  native shim test root must never reference the symbol); shim.js env.consoleLog logs
  to the browser console; the panic handler consoleLogs then @trap().
- **R-P5-7 (frozen interface names — both agents build against these)**:
  - `dev.draw_canvas.CanvasBackend.init(allocator, width: u32, height: u32)
    draw_backend.Error!CanvasBackend`; `.deinit()`; `.backend() draw_backend.Backend`;
    pub field `headless: draw_backend.HeadlessBackend`.
  - `abi.blit(ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32)`
    — extern "env" fn blit(...) under wasm; test_blit seam natively.
  - shim.js env = { blit(ptr,fbW,fbH,x,y,w,h), consoleLog(ptr,len) }.
- **R-P5-8**: demo rect = Rect.make(20,20,620,470) → the 33-rune text renders as
  2 lines ("hello, acme wraps" / "second line⇥tab"); wrap is already golden-locked
  natively. main_native.zig untouched this phase (accept.zig already proves the boot
  path natively, more strongly).
- **R-P5-9**: tools/smoke_wasm.mjs is a MANUAL dev tool (node), never wired into
  `zig build` (R-BLD-02 intact).

## B1 (opus) — the pixel path. Files: src/shim/abi.zig (replace stub), src/dev/draw_canvas.zig (new), src/dev/dev.zig (+1 line), web/shim.js, web/index.html.

abi.zig (~40 lines): version=2; `is_wasm` const; BlitFn type; private `js` struct with
the extern; `pub var test_blit`; `pub fn blit(...)` dispatching per R-P5-5/7. Keep the
OQ-BLD-2 header note.

draw_canvas.zig (≤120 impl): CanvasBackend per R-P5-7 — one `headless` field; nine
vtable trampolines (eight one-line delegations through `self.headless.backend().<op>`);
vFlush: if `headless.dirty` |r| call abi.blit(fb.ptr, width, height, r.min.x, r.min.y,
r.dx(), r.dy()) with @intCast (dirty rect is invariantly within bounds — cite
draw_backend clip sites), then delegate flush (resets dirty, bumps count). Header notes:
display XRGB32 forces A=0xFF so premultiplied==straight for putImageData (byte-exact);
SAB caveat (ImageData rejects shared buffers — future copy needed).
Named tests: "canvas: eight ops delegate to the wrapped headless backend" ·
"canvas: flush blits the dirty rect then resets it" (recording test_blit, defer-restored:
exactly one call, right ptr/dims/rect; dirty null + flush_count 1 after; no-damage flush
⇒ no call, count bumps).

shim.js: ABI_VERSION=2; `let memory`; canvas 2d ctx; env.blit (fresh Uint8ClampedArray
view per call — buffer detaches on memory growth — ImageData, putImageData(img, 0, 0,
x, y, w, h)); env.consoleLog (TextDecoder → console.log("[snarf]", msg)); after
instantiation: memory = exports.memory, abi check via exports.abi_version() (throw on
mismatch), THEN init(); keep the rAF tick pump.
index.html: canvas width="640" height="480" attributes; CSS canvas {display:block;
width:640px; height:480px;} (replace 100vw/100vh); optional image-rendering: pixelated.

## B2 (opus) — the boot. Files: src/main_wasm.zig (rewrite), tools/smoke_wasm.mjs (new).

main_wasm.zig (~90 lines) — implement O10's §2 structure EXACTLY (it is 0.16-verified):
consoleLog root extern + `pub const panic = std.debug.FullPanic(panicHandler)` (handler
consoleLogs msg then @trap()); `const alloc = std.heap.wasm_allocator` (heap.zig:358;
BrkAllocator single-threaded); demo_text = "hello, acme wraps\nsecond line\ttab";
width/height 640/480; text_rect per R-P5-8; pumpServer verbatim from accept.zig; App
struct with fields in init order (doc comment carries the reverse-teardown contract:
text→black→file→font→display→cl→srv→pipe→dd→canvas) — canvas: CanvasBackend, dd,
pipe: *Pipe, srv, cl, display: *Display, font, file, black: draw.Image, text;
`var app: ?*App = null` (the ONE sanctioned module-level var — doc-comment it as the
entry point's context, P-3 analog of main_native's frame, absorbed by future
core/boot.zig); export init() = boot() catch panic with @errorName; boot() = heap-create
App FIRST then build every field IN PLACE (captured pointers: &a.canvas→dd,
&a.dd→srv, &a.srv→pump, &a.cl→display, &a.font/&a.black/&a.file→text) — the accept.zig
phase-4 assembly with the white ground fill, black solid, Text.init cols
{white,white,black,black,black}, text.fill(), display.flush(); app = a; export wake()
no-op; export tick(now_ms) = if (app) |a| guarded srv.poll() catch panic. Drop the
stub's comptime link-forcing block. NO build.zig changes.

tools/smoke_wasm.mjs — O10's script with the R-P5-7 blit signature: env = { consoleLog
(decode+record+log), blit: (ptr,fbW,fbH,x,y,w,h) => record } + auto-stub loop for
unknown env imports (warn, record); assertions: memory/init/wake/tick exports;
abi_version() === 2; init() returns without trap and no /panic|failed/ consoleLog;
blit called >=1; last call fbW===640 && fbH===480; dirty rect in bounds AND covers
(20,20)..(620,56) (2 lines, R-P5-8); ptr+fbW*fbH*4 <= memory size; pixel spot-checks
straight from wasm memory ((0,0) white; any-black in the 'h' cell (20..29,20..38));
tick(16)/tick(32)/wake() no trap; print blit count + wasm byte size.

## Wave C (orchestrator)

accept.zig: "phase-5: canvas backend reproduces the frozen phase-2 scene and blits it"
(phase-2 scene against CanvasBackend via test_blit recording; assert
canvas.headless.hash() == 0x1a99dc0d115ae2bf + blit args). Run smoke_wasm.mjs manually;
report wasm size (expect ~100-300 KB, investigate >1 MB); zig build serve + browser
screenshot; spec revision notes (S-00 §2, S-03 §3, S-06 §4); report + merge.
