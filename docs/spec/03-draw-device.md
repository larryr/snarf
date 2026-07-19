# S-03 — Draw Device Specification (/dev/draw)

Satisfies: R-GFX-01..08, R-OV-05. Decision record: [adr/0003-graphics-dev-draw.md](adr/0003-graphics-dev-draw.md).

## 1. Shape of the device

Follows Plan 9 draw(3):

```
/dev/draw/new              open+read → connection line (client id, display info)
/dev/draw/N/ctl            read display/image info; write control msgs
/dev/draw/N/data           write compiled draw messages; read replies
/dev/draw/N/refresh        blocking read → exposure/resize rectangles
/dev/draw/colormap         legacy; present, constant
/dev/cursor                write 72-byte Plan 9 cursor (or "name <css>") ; empty write resets
```

`read /dev/draw/new` returns the standard 12×12-byte decimal fields: client id, display
image id, channel (`x8r8g8b8`), rect of the display, clip rect. The display rect tracks the
canvas size (CSS pixels × devicePixelRatio, R-GFX-05).

## 2. Message subset (written to `data`)

Byte-compatible with Plan 9's draw protocol; the v1-mandatory verbs (R-GFX-02):

| Verb | Meaning |
|------|---------|
| `b id[4] screenid[4] refresh[1] chan[4] repl[1] r[4*4] clipr[4*4] color[4]` | allocate image |
| `f id[4]` | free image |
| `d dstid[4] srcid[4] maskid[4] r[4*4] sp[2*4] mp[2*4]` | general draw (SoverD composite) |
| `r id[4] r[4*4] color[4]` | *(via `d` with repl color images — no separate verb; noted for readers)* |
| `L dstid[4] p0 p1 end0 end1 radius srcid sp` | line |
| `k id[4] n[1] name[n]` / `N ...` | attach/name font & subfont images |
| `l cacheid srcid index r sp left width` | load glyph into font cache |
| `s dstid srcid fontid p r sp n index[2*n]` | draw string from cache |
| `v` | flush: present all changes to the visible display |
| `y id[4] r[4*4] buf[...]` / `Y` | load raw pixels into image (compressed `y` optional v2) |
| `c dstid repl clipr` | set clip |
| `o id[4] r.min[2*4] screenr.min[2*4]` | origin change (window move — used by columns drag) |
| `A id imageid fillid public` / screens | screen alloc — **deferred**: Snarf manages its own window rects client-side in v1; `A` returns error |

Unknown verbs → the write fails with `Rerror "bad draw message"` and the connection notes
the offset (readable from `ctl`) — same debuggability the real devdraw gives.

## 3. Backend: OffscreenCanvas / Canvas2D (R-GFX-03)

The server keeps every allocated image as pixels it owns:

- **Display image & large images**: an `OffscreenCanvas` each (GPU-friendly blits via
  `drawImage`).
- **Small images / masks / fonts**: `ImageData` in WASM-adjacent memory; glyph cache
  subfont strips live as a single canvas atlas per font.
- `d` compositing: `SoverD` maps to `globalCompositeOperation="source-over"` + mask
  handling; the general src/mask/dst case falls back to a software composite in Zig for
  correctness (masks are rare outside fonts; fonts use the atlas path).
- `v` (flush) transfers only dirty rects to the visible canvas
  (`commit`/`transferToImageBitmap` per browser support), then clears the dirty list.

![draw-pipeline](diagrams/draw-pipeline.puml)

Diagram source: [diagrams/draw-pipeline.puml](diagrams/draw-pipeline.puml)

## 4. Fonts (R-GFX-04)

Plan 9 font/subfont model verbatim: a `.font` file lists ranges → subfont files; subfonts
are images plus glyph metrics, loaded with `k`/`l` messages by the libdraw client. Snarf
ships Go Regular + Go Mono pre-converted to subfonts (license check: OQ-GFX-2) embedded via
`@embedFile`, and can load additional fonts from the namespace (e.g.
`/mnt/host/fonts/...`). No browser text APIs are used for editor text (deterministic
metrics; headless tests render identically).

## 5. Resize & refresh (R-GFX-05)

Shim observes canvas resize → device updates display rect → writes an exposure rect to
every `refresh` reader. libdraw client's `getwindow()` equivalent re-reads `ctl`, the
editor relays out. `devicePixelRatio` changes are resizes. The refresh file also carries
`visibilitychange` hints so Snarf can stop drawing in hidden tabs.

## 6. Performance notes (R-GFX-06)

- All draw messages for one input event are batched into one `data` write; one `v` per
  frame max, driven by `requestAnimationFrame` on the shim side (worker gets a vsync tick).
- Scrolling uses `d` self-copy on the display (blit) + redraw of the exposed band — ACME's
  own strategy; no per-frame allocation in `s`/`d` paths (fixed message buffer).
- Budget: ≤ 1 ms typical for a keystroke redraw at 1080p, leaving frame headroom.

## 7. Headless backend (R-CON-02)

`main_native.zig` links the same devdraw with a plain memory framebuffer backend; tests
assert against golden-image hashes. This is the proof that the core never touched the
browser.
