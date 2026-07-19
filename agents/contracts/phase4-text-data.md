# Phase 4 data contract (O7) — Buffer, RuneIndex, File

Read with the master `phase4-text.md` (rulings R-P4-1..3, R-P4-7 bind). All three files
import **std only**. Zig 0.16 idioms as in the merged repo (unmanaged ArrayList `.empty`
+ `append(alloc, ...)`; `*std.Io.Writer` params; std.unicode). Tests colocated,
std.testing.allocator. C anchors: plan9port/src/cmd/acme/{buff.c,file.c}, dat.h:128-150.

## Rulings (from master; details)

- **A — invalid UTF-8**: original store keeps loaded bytes byte-for-byte; decode paths
  (read/runeAt) substitute U+FFFD on the fly; each invalid byte = ONE rune (matches
  cvttorunes' one-Runeerror-per-bad-byte). Pieces carry `clean`; clean pieces (and all
  add pieces) take a zero-scan/memcpy fast path. Stored-bytes vs decoded-bytes never
  conflated: writeRaw/rawByteLen speak stored; read speaks decoded (sizing rule
  dest.len >= 4*nrunes). Edited regions lose invalid-byte fidelity (undo re-inserts
  decoded U+FFFD — same as acme file.c:126-134); untouched pieces (incl. split halves)
  preserve raw bytes by construction. NULs (0x00) are valid UTF-8 and KEPT.
- **B — flat piece list**: std.ArrayList(Piece); load splits original into pieces of
  <= 64 KiB stored bytes at rune boundaries (`max_load_piece = 64 << 10`). O(pieces)
  memmove per edit is fine at this scale (acme's own flat block array, buff.c:37);
  public API leaks nothing — a tree can replace it behind identical signatures.
- **C — eager rebuild**: Buffer rebuilds RuneIndex at the end of every successful
  insert/delete/init; all queries are `*const`. RuneIndex is Buffer-facing only; do NOT
  export it from core.zig.

## §1 src/core/Buffer.zig (~300 impl)

```zig
pub const max_load_piece: usize = 64 << 10;
pub const max_bytes_per_rune: usize = 4;

allocator: std.mem.Allocator,
original: []u8,                          // owned; verbatim; empty for initEmpty
add: std.ArrayList(u8) = .empty,         // append-only; always valid UTF-8
pieces: std.ArrayList(Piece) = .empty,   // private
index: RuneIndex = .empty,
invalid_bytes: usize = 0,                // count found at load (caller warns later)

const Piece = struct {
    src: enum(u1) { original, add },
    off: usize, bytes: usize, runes: usize, newlines: usize, clean: bool,
};

pub fn initEmpty(allocator: std.mem.Allocator) Buffer;
pub fn initFromBytes(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Buffer;
pub fn deinit(self: *Buffer) void;
pub fn len(self: *const Buffer) usize;                 // runes, O(1)
pub fn rawByteLen(self: *const Buffer) usize;          // stored bytes, O(1)
pub fn insert(self: *Buffer, pos: usize, bytes: []const u8) error{OutOfMemory}!void;
    // caller guarantees valid UTF-8 (debug assert utf8ValidateSlice); asserts pos <= len()
pub fn delete(self: *Buffer, pos: usize, nrunes: usize) error{OutOfMemory}!void;
pub fn read(self: *const Buffer, pos: usize, nrunes: usize, dest: []u8) []u8;
    // asserts in-bounds + dest.len >= 4*nrunes; returns filled prefix; U+FFFD for invalid
pub fn runeAt(self: *const Buffer, pos: usize) u21;
pub fn lineCount(self: *const Buffer) usize;           // '\n' count + 1, O(1)
pub fn lineOfRune(self: *const Buffer, pos: usize) usize;
pub fn runeOfLine(self: *const Buffer, line: usize) usize;
pub fn writeRaw(self: *const Buffer, w: *std.Io.Writer) std.Io.Writer.Error!void;
```

Implementation notes: mid-piece insert splits into two references to the same backing
range (halves keep src/off; recompute runes/newlines/clean by scanning ONLY the split
piece); factor the count walk into `fn scanCounts(bytes) struct{runes,newlines,clean}`;
ASCII fast path (piece.runes == piece.bytes ⇒ byte off = rune off); trailing-add-piece
coalescing on append is allowed but optional; error set exactly error{OutOfMemory} on
mutators/init — bounds are asserts (P-5).

## §2 src/core/RuneIndex.zig (~200 impl)

Prefix sums over per-piece Counts; binary search. Exact API:

```zig
pub const empty: RuneIndex = .{};
pub const Counts = struct { runes: usize, bytes: usize, newlines: usize };
pub const Location = struct { piece: usize, rune_off: usize };
rune_starts/byte_starts/line_starts: std.ArrayList(usize) = .empty, // len = pieces+1
pub fn deinit(self: *RuneIndex, allocator: std.mem.Allocator) void;
pub fn rebuild(self: *RuneIndex, allocator: std.mem.Allocator, counts: []const Counts) error{OutOfMemory}!void;
pub fn totalRunes/totalBytes/totalNewlines(self) usize;             // O(1)
pub fn pieceOfRune(self, pos: usize) Location;   // boundary → FOLLOWING piece; pos==total ⇒ end sentinel {pieceCount(),0}
pub fn pieceOfLine(self, line: usize) struct { piece: usize, newlines_before: usize };
pub fn runeStart/byteStart/lineStart(self, i: usize) usize;
pub fn pieceCount(self) usize;
```

rebuild may clearRetainingCapacity. No allocator field (passed per call).

## §3 src/core/File.zig (~250 impl)

```zig
pub const Range = struct { q0: usize, q1: usize };
pub const Delta = union(enum) {
    insert: struct { seq: u32, mod_before: bool, p0: usize, nrunes: usize },
    delete: struct { seq: u32, mod_before: bool, p0: usize, text: []u8 }, // owned decoded UTF-8
};
allocator: std.mem.Allocator,
buffer: Buffer,                              // pub: read-only access direct; mutation via File
delta: std.ArrayList(Delta) = .empty,        // undo stack
epsilon: std.ArrayList(Delta) = .empty,      // redo stack
seq: u32 = 0,                                // 0 ⇒ transparent (records nothing)
mod: bool = false,

pub fn init(allocator: std.mem.Allocator, buffer: Buffer) File;
pub fn deinit(self: *File) void;
pub fn mark(self: *File, seq: u32) void;     // stamp + DISCARD epsilon (file.c:305); asserts seq>0 and >= self.seq
pub fn insert(self: *File, p0: usize, bytes: []const u8) error{OutOfMemory}!void;
pub fn delete(self: *File, p0: usize, nrunes: usize) error{OutOfMemory}!void; // captures doomed text via buffer.read BEFORE deleting
pub fn undo(self: *File) error{OutOfMemory}!?Range;
pub fn redo(self: *File) error{OutOfMemory}!?Range;
pub fn undoSeq(self: *const File) u32;
pub fn redoSeq(self: *const File) u32;       // file.c:176
pub fn reset(self: *File) void;              // drop stacks, seq=0; keeps text+mod (file.c:281)
```

Semantics (verified in file.c — honor exactly): (1) seq==0 ⇒ no records (file.c:79,105);
(2) equal-seq records = one transaction; one mark per user action per file; (3) undo
pops+inverts every top-seq record, pushing inverses onto epsilon with the SAME seq;
self.seq := next-older seq or 0; returns Range of the LAST inversion (file.c:188-275);
redo is the mirror (implement both as one private `unwind(from,to)`); (4) records carry
mod_before, restored on undo/redo (file.c:93,117,233,244) — this is what survives Put;
(5) redo invalidation lives in mark, not insert; (6) inversions apply newest-first;
(7) OOM mid-unwind: document "stacks may be partially unwound; treated as fatal";
(8) no Text list/notify/name yet.

## §4 Named tests (all as specified by O7 — implement exactly)

Buffer: "buffer: empty init — len 0, lineCount 1, rawByteLen 0" · "buffer: insert at 0,
middle, end" · "buffer: delete spanning piece boundaries" · "buffer: scripted 100-op
storm matches []u8 reference" · "buffer: randomized ops match reference model (seed
0x5eed)" (>=1000 ops, mixed 1-4-byte runes, cross-check len/lineCount/runeAt) ·
"buffer: rune vs byte addressing with multibyte runes" · "buffer: invalid UTF-8 decodes
as U+FFFD, writeRaw preserves bytes" · "buffer: edits beside invalid bytes preserve
untouched raw bytes" · "buffer: 256 KiB load splits pieces and round-trips" · "buffer:
line index correct across edits" · "buffer: lineOfRune/runeOfLine are consistent
inverses".

RuneIndex: "runeindex: prefix sums and totals over synthetic counts" · "runeindex:
pieceOfRune boundary convention incl. end sentinel" · "runeindex: pieceOfLine across
multi-newline pieces" · "runeindex: rebuild reuses and replaces prior state".

File: "file: unmarked edits record nothing (acts like Buffer)" · "file: single-op undo
restores text, seq, and mod" · "file: grouped transaction undoes as one unit" · "file:
undo then redo round-trips text and mod" · "file: undo across many transactions in
order" · "file: new mark invalidates redo" · "file: mod flag transitions across
edit/undo/redo" (incl. simulated Put mod=false then undo restores) · "file:
undoSeq/redoSeq report pending transactions" · "file: reset clears stacks and seq,
keeps text and mod" · "file: randomized edit/undo/redo storm matches snapshots (seed
0xf11e)".
