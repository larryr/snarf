# M0-57: Undo/Redo repaint the body (issue #57)

**Owner:** SnarfDev2. **Fix:** SnarfDev1 (`snarfdev1/undo-repaint`). **Tests:** PR #61, `src/core/exec/undo_repaint_test.zig`.
**Flag:** `undo_repaint_fixed = false`. While it's false, a mismatch SKIPs and a match FAILs with `UnexpectedPassFlipFlag`.
**ACME:** `fileundo` (file.c:189) applies each reversed delta through `textdelete` (:236) and `textinsert` (:253) for every Text on the File, so the frame stays in step. `cmd_edit.undo` only calls `textshow`, which doesn't refill when the range is already visible.
**Assertion:** the frame draws only from its boxes. The concatenated box runes must equal `buffer[org, org+nchars)`, and the frame must be full or reach the end of the buffer.

| ID | Type | Case | Expected | Gated |
|---|---|---|---|---|
| UR-01 | unit (control) | Seed `banana alpha gamma\nsecond line (paren text) here\n`. One transaction does `s/a/A/g` through `deleteRange`/`insertAt` | Frame equals the buffer before and after | no |
| UR-02 | unit | UR-01's transaction, then Undo (`cmd_edit.undo`, from the tag) | Buffer is back to the seed, **and** the frame shows `banana…` (on main it still shows `bAnAnA…`) | yes |
| UR-03 | unit | UR-02, then a forced resync (resize), then Redo | Frame shows `bAnAnA…`. The resync stops a stale frame passing vacuously | yes |
| UR-04 | unit | Empty body. Type the seed as one transaction, then Undo | Buffer is empty and the frame has 0 runes (on main, 49 stale runes remain) | yes |
| UR-05 | manual | Checklist step 20 on the native host (Linux Xvfb and Mac) | Body repaints immediately after Undo/Redo, with no resize | (manual) |

Verified on main (ba5bc12):
- Flag forced to `true`: UR-02/03/04 fail with the #57 symptom.
- Flag `false`: 825/844 passed, 19 skipped, 0 fail.
- A throwaway refill probe makes all four pass. That probe also changes `FROZEN-ACCEPT-10` (`src/accept.zig:1091`), which was frozen with the non-repainting Undo, so the fix probably needs a re-freeze.
