# Phase 4 contract — text (a real Buffer rendered as wrapped lines)

Master reconciliation for O7 (data model — `phase4-text-data.md`) and O8 (frame —
`phase4-text-frame.md`). Build agents read the master FIRST, then their side file.
Hard gates unchanged (in-worktree `zig build test --summary all` green + `zig fmt
--check build.zig src/ tools/` clean; named tests exact; cite pinned C; STOP on
unimplementable signatures; impl-line budgets bind the NON-TEST portion only).

## Rulings

- **R-P4-1 (read shape, resolves O8's R4-Q1)**: Buffer.read stays exactly O7's
  `read(pos, nrunes, dest) []u8` (asserts in-bounds + dest.len >= 4*nrunes; returns the
  filled prefix). Text.fill computes its own rune count (`min(remaining, 2000)`) and
  gets byte count from the returned slice — no second return value needed.
- **R-P4-2 (O7 Ruling A affirmed)**: original bytes stored verbatim; U+FFFD substituted
  at READ time; one rune per invalid byte; `writeRaw` byte-identical. NULs KEPT verbatim
  (divergence from acme's cvttorunes stripping — flagged in the phase report). Undo of
  invalid-byte regions re-inserts decoded U+FFFD bytes (matches acme's rune deltas;
  documented in File.zig header).
- **R-P4-3 (O7 Rulings B/C affirmed)**: flat ArrayList piece list, 64 KiB load split;
  eager index rebuild; RuneIndex not exported from core.zig (Buffer and File only).
- **R-P4-4 (O8 R4-Q2)**: Text binds `*File` (reads via file.buffer.read/len).
- **R-P4-5 (O8 R4-Q3)**: the FakeDrawTree+Pipe fixture may live ONCE as a test-only
  `pub const TestFixture` in frame/Frame.zig, shared by frame/* sibling test blocks
  (R-P2-3 lineage). Pixel goldens stay in src/accept.zig.
- **R-P4-6 (O8 R4-Q4/Q5/Q6/Q7)**: full frinsert port now; 5-slot cols at init with
  P4 callers passing `.{white, white, black, black, black}`; tick/scroll fields omitted
  (tick() is a no-op stub); rune counts usize, pixel math i32.
- **R-P4-7**: initFromBytes copies (owned dup); seq stays u32; put-seq bookkeeping
  deferred to the Put phase.

## Sub-wave assignments

- **4a (concurrent, three agents):**
  - A1 opus — `src/core/RuneIndex.zig` + `src/core/Buffer.zig` (data contract §1-§2,
    Buffer tests + RuneIndex tests) + add `pub const Buffer = @import("Buffer.zig");`
    to src/core/core.zig (ONE line; A2 adds its own line — orchestrator resolves).
  - A2 opus — `src/core/File.zig` (data contract §3 + File tests; code strictly to the
    frozen Buffer signatures in the data contract — do not wait for A1) + add
    `pub const File = @import("File.zig");` to src/core/core.zig (ONE line).
  - A3 opus — ALL of `src/draw/frame/{Frame,insert,draw,util}.zig` per the frame
    contract (tests 1-11) + `pub const Frame = @import("frame/Frame.zig");` in
    src/draw/draw.zig. The box invariants couple the four files: one agent, one mind.
- **4b (after 4a merges): sonnet** — `src/core/text/Text.zig` (frame contract §5,
  tests 12-15) + `pub const Text = @import("text/Text.zig");` in core.zig.
- **Wave C (orchestrator)**: acceptance scene (frame contract §7) + FROZEN-ACCEPT-3 +
  report + merge.

## Cross-contract interface (frozen)

Text.fill's loop against Buffer (via File.buffer): `len() usize` (runes);
`read(pos, nrunes, dest) []u8` with dest sized 4*nrunes. Frame.insert takes UTF-8
`[]const u8` + rune offset. Font surface used by frame: height/ascent (u8),
charWidth(u21) i32, stringWidth([]const u8) i32, drawString(dst, pt, src, s).
No Font/Display/proto changes in this phase.
