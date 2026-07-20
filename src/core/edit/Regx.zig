//! Structural-regexp engine — the in-project port of acme's `regx.c`
//! (larryr/plan9port@337c6ac, `src/cmd/acme/regx.c`, 843 lines). file-as-struct
//! (S-07 P-1): this file *is* the `Regx` struct — types, owned state, lifecycle,
//! and the public method re-exports (the Text.zig alias pattern). The heavy
//! machinery lives in two siblings so no single file blows the ~400-line cap:
//!
//!   * `regx_compile.zig` — lex, operator-precedence parse (`andstack`/
//!     `atorstack`), `evaluntil`, `bldcclass`, `optimize`, and the two-pass
//!     forward+backward compile (regx.c:161-527).
//!   * `regx_exec.zig`    — the Pike-VM: `addinst`, `classmatch`, `execute`/
//!     `bexecute`, `newmatch`/`bnewmatch` (regx.c:534-843).
//!
//! No globals (S-07 P-4): everything acme kept in file-scope globals (`sel`,
//! `lastregexp`, `program`/`progp`, the parser stacks, `class`, `list[2]`) hangs
//! off this struct. The `rechan`/thread dance (regx.c:46,136-148) — which existed
//! only so `regerror` could longjmp out of a compile thread — is replaced wholesale
//! by a Zig error union (`CompileError`).
//!
//! Lifetime: `ed.regx: Regx` (R-P10-5). The `lastregexp` cache spans Edit
//! invocations, so the instance is C-global-lived; `deinit` frees the arena,
//! classes and cache.
//!
//! Imports: std + sibling `File.zig`/`Buffer.zig` only (S-07 §6 — core never
//! imports dev/shim). `Source` gives `execute` the C's `Text*`/`Rune*` duality
//! (regx.c:559): a live buffer search vs. a rune-string search (the latter is what
//! `filematch` uses, ecmd.c:1245).
const std = @import("std");
const File = @import("../File.zig");
const Buffer = @import("../Buffer.zig");

const Regx = @This();

// --- frozen public types (master §"Cross-contract interface", O20 §2.1) ---

/// NRange (dat.h:32): r[0] is the whole match, r[1..9] the `(` groups.
pub const nrange = 10;
pub const Range = File.Range;
/// [0] = whole match; unmatched groups read {0,0} (the zeroed `sempty`, regx.c:60).
pub const Rangeset = [nrange]Range;

/// `rxexecute`'s `Text*`/`Rune*` duality (regx.c:559): search a live buffer, or a
/// bare rune string (filematch, ecmd.c:1245).
pub const Source = union(enum) {
    buffer: *const Buffer,
    runes: []const u21,
};

/// regerror strings become typed errors (regx.c:141-148 longjmp path removed).
pub const CompileError = error{
    OutOfMemory,
    ExpressionTooLong, // "expression too long"    (regx.c:153-154)
    UnmatchedLeftParen, // "unmatched `('"          (regx.c:188-189)
    UnmatchedRightParen, // "unmatched `)'"         (regx.c:248-249)
    MissingOperand, // "missing operand for %c"     (regx.c:293-294)
    MalformedClass, // "malformed `[]'"             (regx.c:455,487)
    MalformedRegexp, // "malformed regexp"          (regx.c:296)
};

/// The regx.c:622 "regexp list overflow" warning path, surfaced as an error;
/// consumers (addr.nextMatch, the edit loops) map it to a warning + no-match,
/// faithful to regx.c:622-627 (master R-P10-2).
pub const ExecError = error{ListOverflow};

// --- internal program encoding (directed, not frozen — O20 §2.1) ---

/// One class-set element (sam's flat triple encoding collapsed to a tagged union).
/// A negated class carries a `'\n'` single so it never matches newline
/// (regx.c:477-480); the negation itself lives on the referencing `Op.class`.
pub const ClassItem = union(enum) {
    single: u21,
    range: [2]u21, // inclusive [lo, hi]
};

/// A compiled instruction. `next` is a u16 **index** into `prog` (no
/// self-referential pointers, O20 §2.1); `nil_inst` marks "unset". The C's
/// two overlaid unions (`u`={right/subid/class}, `u1`={left/next}) collapse to:
/// the payload here is `u`, and `next` is `u1` — for `alt` (the C's OR), the
/// payload holds the *right* branch and `next` holds the *left*/fall-through.
pub const Op = union(enum) {
    rune: u21, // literal (regx.c: type < OPERATOR)
    any, // ANY  `.`      (regx.c:77)
    bol, // BOL  `^`      (regx.c:79)
    eol, // EOL  `$`      (regx.c:80)
    end, // END          (regx.c:83)
    class: Class, // CCLASS/NCCLASS (regx.c:81-82)
    lbra: i8, // LBRA `(` carrying subid, -1 = ignored (regx.c:280-283)
    rbra: i8, // RBRA `)` carrying subid
    alt: u16, // OR: payload = right branch index; `next` = left (regx.c:336-338)
    nop, // NOP internal join (regx.c:78); optimize splices these out

    pub const Class = struct { idx: u16, negate: bool };
};

pub const Inst = struct { op: Op, next: u16 };

/// The u16 index space bounds the program; `nil_inst` is the "unset next" sentinel
/// and doubles as the ExpressionTooLong cap (O20 §2.1's "ArrayList with the
/// ExpressionTooLong cap"). NOTE: acme's fixed `program[NPROG=1024]` (regx.c:41)
/// is too small for the hand-derived test 23 (`a?`×128`a`×128 ⇒ ~1026 insts across
/// the shared fwd+bwd arena, which acme itself would reject as "expression too
/// long"); the growable arena lets that pattern compile so its thread-list
/// overflow can be observed. See the report.
pub const nil_inst: u16 = std.math.maxInt(u16);
pub const prog_cap: usize = nil_inst; // len must stay < nil_inst so indices fit u16

/// Pike-VM thread-list bound (regx.c:56). `list[2][nlist+1]` — the +1 is the
/// trailing-null terminator slot addinst relies on (regx.c:59).
pub const nlist = 127;

/// A signed range used *inside* the machine: the sentinel `q0 = -1` means "no
/// match" (regx.c:579) and bexecute seeds `q0 = -p` (regx.c:758) so addinst's
/// `<` preference reads as "closest below startp". Converted to the unsigned
/// public `Range` only on return.
pub const SRange = struct { q0: isize = 0, q1: isize = 0 };
pub const SRangeset = [nrange]SRange;

/// One Pike-VM thread (regx.c:48-54; the unused `startp` field is dropped).
pub const Ilist = struct { inst: ?u16 = null, se: SRangeset = zero_srangeset };

pub const zero_srangeset: SRangeset = [_]SRange{.{}} ** nrange;

// --- owned state ---

allocator: std.mem.Allocator,
/// The shared instruction arena: forward program first, backward program appended
/// after (regx.c:209-223 never resets progp between the two passes).
prog: std.ArrayList(Inst) = .empty,
/// Character classes, in build order; a CCLASS inst's `idx` selects one. Owned;
/// freed and rebuilt each (non-cached) compile.
classes: std.ArrayList(std.ArrayList(ClassItem)) = .empty,
/// The `lastregexp` cache (regx.c:16,203-204): an identical pattern is a no-op.
lastpat: std.ArrayList(u21) = .empty,
/// Entry insts for the forward / backward machines (regx.c:44-45). null ⇒ no valid
/// program (rxnull, regx.c:552-556).
startinst: ?u16 = null,
bstartinst: ?u16 = null,
/// The two Pike-VM thread lists (regx.c:59), in-struct rather than file-scope.
/// Left `undefined`: `execute`/`bexecute` null-terminate `[flag][0]` before any read.
list: [2][nlist + 1]Ilist = undefined,

pub fn init(allocator: std.mem.Allocator) Regx {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Regx) void {
    self.prog.deinit(self.allocator);
    for (self.classes.items) |*cl| cl.deinit(self.allocator);
    self.classes.deinit(self.allocator);
    self.lastpat.deinit(self.allocator);
    self.* = undefined;
}

/// rxnull (regx.c:552-556): true when there is no compiled program.
pub fn isNull(self: *const Regx) bool {
    return self.startinst == null or self.bstartinst == null;
}

/// Static message for warnings, matching acme's `regerror` strings.
pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.OutOfMemory => "out of memory",
        error.ExpressionTooLong => "expression too long",
        error.UnmatchedLeftParen => "unmatched `('",
        error.UnmatchedRightParen => "unmatched `)'",
        error.MissingOperand => "missing operand",
        error.MalformedClass => "malformed `[]'",
        error.MalformedRegexp => "malformed regexp",
        error.ListOverflow => "regexp list overflow",
        else => "regexp error",
    };
}

// --- method re-exports (the Text.zig alias pattern) ---

/// rxcompile (regx.c:196): builds forward+backward programs; identical pattern
/// = cached no-op.
pub const compile = @import("regx_compile.zig").compile;
/// rxexecute (regx.c:559). `eof == null` ⇒ the C's Infinity: search to end AND
/// wrap once; a bounded `eof` never wraps.
pub const execute = @import("regx_exec.zig").execute;
/// rxbexecute (regx.c:702). Always wraps (end←) exactly as the C.
pub const bexecute = @import("regx_exec.zig").bexecute;

test {
    _ = @import("regx_compile.zig");
    _ = @import("regx_exec.zig");
}
