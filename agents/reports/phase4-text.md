# Phase 4 report — text (a real Buffer rendered as wrapped lines)

Merged to `main` (revert = the one merge commit). Contracts:
`agents/contracts/phase4-text{,-data,-frame}.md`. Suite: **192/192**; boundary
negative-check verified; wasm builds.

## Delivered

The editor's heart plus its display path. A 33-rune document travels
Buffer → File → Text.fill → Frame (wrap/tab/newline layout) → Font → 9P → devdraw →
verified pixels (FROZEN-ACCEPT-3 `0x7f16941423defd73`). Fourth consecutive first-try
composition.

- `core/Buffer.zig` + `core/RuneIndex.zig` — the piece table: verbatim original store +
  append-only add store + flat piece list with prefix-sum index. Invalid UTF-8 stored
  byte-for-byte, decoded as U+FFFD at read (one rune per bad byte) — so a future Put is
  non-destructive BY CONSTRUCTION. NULs kept (flagged divergence from acme's stripping).
  Verified by a 1200-op fixed-seed property storm against a naive reference model.
- `core/File.zig` — faithful file.c undo/redo port: delta/epsilon stacks of tagged-union
  records, seq-grouped transactions, per-record mod restoration (the survives-Put core
  of R-EDIT-11). Fixed-seed storm against per-transaction snapshots.
- `draw/frame/{Frame,insert,draw,util}.zig` — the libframe port: box tagged unions,
  full three-pass frinsert, the exact tab-stop rule, ptOfChar/charOfPt, with the C's
  quirks deliberately preserved (the '\n' box's 5000px width placeholder that charOfPt
  depends on; kernel-faithful lastlinefull semantics).
- `core/text/Text.zig` — minimal Text = File + Frame binding with the textfill loop.

## Integration highlights

- File's tests were written against a contract-mandated placeholder Buffer; at merge
  the placeholder was discarded and the tests ran against A1's REAL piece table —
  all green. Two independently-built halves of the data model composed exactly.
- A3 flagged that the contract's prose for one test contradicted the C's actual
  lastlinefull semantics and implemented the C faithfully (tests realized via the
  fill-loop, as textfill does) — fidelity-over-contract, correctly.

## Flagged divergences (reviewable)

- NULs kept verbatim (acme strips; stripping is silent data destruction against
  S-05 §1's spirit).
- Undo of invalid-byte regions re-inserts decoded U+FFFD bytes — matches acme's own
  rune-typed deltas; documented in File.zig.

## Deferred

frame/delete.zig + select.zig (phase 6/7); tick/scroll machinery; Text
typing/select/scroll; multi-file Editor wiring; Put/Get + put-seq bookkeeping;
cache eviction. Deferred-lists from earlier phases unchanged.
