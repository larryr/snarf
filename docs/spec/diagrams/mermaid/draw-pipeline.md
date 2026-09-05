# Draw pipeline — one frame of typing (spec 03)

Mermaid review mirror of [`draw-pipeline.puml`](../draw-pipeline.puml) — the PlantUML source remains authoritative.

<!-- Divergence: PlantUML `->` (solid) / `-->` (dashed reply) map to Mermaid `->>` / `-->>`.
     Self-messages (`L -> L`) keep the solid form. -->
<!-- Divergence: the PlantUML trailing comment on `L -> D : Twrite [v]  ' flush` is folded
     into the message text here, since Mermaid has no inline comment on a message line. -->
<!-- Divergence: Mermaid's sequence parser treats `;` and `<`/`>` as syntax, so the literal
     `;` in the note and the angle brackets of `<canvas>` are written as the numeric escapes
     `#59;`, `#lt;` and `#gt;`. They render as the intended characters. -->

```mermaid
sequenceDiagram
    participant E as Editor core
    participant L as libdraw client
    participant D as /dev/draw server
    participant W as JS shim (worker side)
    participant O as OffscreenCanvas<br/>(Canvas2D)
    participant MC as Main thread #lt;canvas#gt;

    E->>L: string(win, pt, font, "x")
    L->>L: compile draw ops into buffer
    L->>D: 9P Twrite /dev/draw/1/data<br/>[load subfont glyphs?, draw ops]
    D->>D: validate, update image state
    D->>W: hostcall draw_blit(imageId, rect, pixels*)<br/>(*or retained-canvas ops)
    W->>O: ctx.putImageData / drawImage
    D-->>L: Rwrite count
    E->>L: flushimage(display)
    L->>D: Twrite [v] — flush
    D->>W: hostcall draw_flush(dirtyRects)
    W->>O: commit()
    O->>MC: transferToImageBitmap /<br/>placeholder auto-present
    MC->>MC: browser composites next vsync

    Note over D,W: The 9P layer carries the *protocol*#59;<br/>pixels cross to JS once, at the backend<br/>boundary, batched per flush.
```
