# Phase 2 report — draw (rectangle on a headless framebuffer)

Merged to `main` (see merge commit; revert = revert that one commit). Contract +
rulings: `agents/contracts/phase2-draw.md`. Suite: **115/115**; boundary negative-check
verified; wasm target builds.

## Delivered

The first pixels. A draw client and a devdraw server that meet byte-for-byte over 9P,
rendering into a hashable headless framebuffer — the same protocol path the browser
canvas will use in Phase 5.

- `draw/proto.zig` — wire encoder for verbs b/d/f/v with golden byte tests; chan codes
  comptime-derived from the `__DC` arithmetic; colors/refresh constants per draw.h.
- `draw/Display.zig` + `draw/Image.zig` — libdraw-faithful client: /dev/draw/new
  handshake (144-byte conn line parsed by a pure function), the bufimage/doflush write
  buffer discipline, eager-flushed allocs, white/black solids with white as the opaque
  nil-mask substitute.
- `dev/draw_backend.zig` — Backend vtable + HeadlessBackend: RGBA8888 framebuffer,
  integer-exact SoverD compositor (CALC11 arithmetic pinned by a hand-derived test),
  drawclip clipping with source-point shift, dirty tracking, Wyhash golden hashing,
  PPM dump for eyeballing.
- `dev/draw.zig` — devdraw over the phase-1 Srv framework: draw dir served at root,
  open-of-new fid morph, drawmesg dispatch loop (concatenated messages per write,
  partial = error, mid-batch faults leave prior ops applied), single exclusive
  connection with clunk-reset.
- `src/accept.zig` — new cross-module acceptance root: white fill + red rect
  (100,100)-(300,200) on 640×480 through the ENTIRE stack
  (Display→Client→Pipe→Server→DevDraw→HeadlessBackend). Composed on first run.
- `ninep/errors.zig` gained BadDraw/ShortDraw/NoDrawImage (S-03 §2 wire strings;
  additive, ruling R-P2-4).

Frozen goldens: FROZEN-A `0xfe503a5e74e711df`, FROZEN-B `0x1963cfd1efb1dcf7` (backend),
FROZEN-C `0x49b12df243bfe36f` (devdraw batch), FROZEN-ACCEPT `0x1a99dc0d115ae2bf`
(acceptance scene) — each frozen only after pixel spot-checks passed (R-P2-7).

## Notable ground truth (all triple-verified against pinned sources)

- **Draw protocol is little-endian** despite the `BGLONG` macro names
  (`sys/man/3/draw:111`; `draw.h:508-511`).
- Connection number is 1, not 0 (kernel pre-increments). Bare `'v'` (the 4-byte suffix
  is a plan9port variant). Opening `new` morphs the fid into ctl.

## Wave C catches / patches

1. B2's `flush()` could exceed the msize write budget by the appended 'v' byte when
   msize (not the 8000 cap) bounds the buffer — patched (`buf_size` reserves the byte).
2. Deferred-list items recorded: `Display.emit`'s `catch unreachable` assumes ops fit
   the buffer (must be revisited for Phase-3+ 'y' pixel loads); headless solid fills
   don't force A=0xFF for non-alpha chans (unreachable with sane colors in Phase 2);
   `mount.resolve` doesn't police empty components in queried paths.
3. Walk-path composition mismatch between the two outline contracts caught at
   reconciliation (Display now takes the draw-dir fid, R-P2-1) — would have been a
   build-wave integration failure otherwise.

## Pipeline stats

2 outline agents (fable) → reconciled contract with 7 rulings + 10 ground-truth items;
4 build agents (sonnet: proto; opus: backend, devdraw, Display/Image) in worktrees;
zero contract-signature conflicts reported by any build agent; acceptance composed
first-try. Zig 0.16 finding (recorded in HANDOFF): `{d:>11}` prints a `+` for positive
signed ints — kernel `%11d` doesn't; format then pad manually.

## Deferred (tracked for later phases)

Font verbs 'i'/'l'/'s'/'k'/'N' + refresh file (Phase 3); OffscreenCanvas backend
`draw_canvas.zig` (Phase 5); 'y' pixel loads + emit chunking; general masks/tiled repl
(full memimagedraw); screens ('A'); /dev/draw/colormap; ctl infoid writes; per-rect
dirty lists.
