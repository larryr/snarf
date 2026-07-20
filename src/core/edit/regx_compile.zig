//! Regexp compilation — lex + operator-precedence parse + optimize + the two-pass
//! forward/backward build. Ported from acme's `regx.c` (larryr/plan9port@337c6ac):
//! `rxcompile` (196-227), `realcompile` (161-193), `operand`/`operator`/`pushand`/
//! `pushator`/`popand`/`popator`/`evaluntil` (229-377), `optimize` (380-391),
//! `lex`/`nextrec`/`bldcclass` (401-510). The `rechan`/thread mechanism (its only
//! purpose was to let `regerror` longjmp-exit a compile thread) is gone: errors are
//! a plain `CompileError` return.
//!
//! No globals (S-07 P-4): acme's parser globals (`andstack`, `atorstack`,
//! `subidstack`, `exprp`, `lastwasand`, `cursubid`, `backwards`, `nbra`,
//! `negateclass`) live on a transient `Compiler` built per pass; the program arena,
//! class store and cache live on `*Regx`.
const std = @import("std");
const Regx = @import("Regx.zig");
const Op = Regx.Op;
const ClassItem = Regx.ClassItem;
const CompileError = Regx.CompileError;
const nil_inst = Regx.nil_inst;
const nrange = Regx.nrange;

// Action/token encoding (regx.c:62-88). Operators carry OPERATOR + precedence
// (ascending: CAT binds tighter than OR, closures tightest); operand tokens carry
// the ANY bit; a bare rune value < OPERATOR is a literal. Kept as the C's integers
// so `evaluntil`'s `atorp[-1] >= pri` precedence test ports verbatim.
const OPERATOR: u32 = 0x1000000;
const START: u32 = OPERATOR + 0;
const RBRA: u32 = OPERATOR + 1;
const LBRA: u32 = OPERATOR + 2;
const OR: u32 = OPERATOR + 3;
const CAT: u32 = OPERATOR + 4;
const STAR: u32 = OPERATOR + 5;
const PLUS: u32 = OPERATOR + 6;
const QUEST: u32 = OPERATOR + 7;
const ANY: u32 = 0x2000000;
const NOP: u32 = ANY + 1;
const BOL: u32 = ANY + 2;
const EOL: u32 = ANY + 3;
const CCLASS: u32 = ANY + 4;
const END: u32 = ANY + 0x77;
const QUOTED: u32 = 0x4000000; // \-quoted lex char, inside classes (regx.c:88)

const NSTACK = 20; // parser stack depth (regx.c:100)

/// A parse-tree fragment: the first and last inst indices of a sub-machine
/// (regx.c:93-98).
const Node = struct { first: u16, last: u16 };

/// One compile pass's transient parser state (regx.c's parser globals).
const Compiler = struct {
    rx: *Regx,
    src: []const u21, // the pattern (no trailing NUL; end-of-input ⇒ END)
    pos: usize,
    andstack: [NSTACK]Node,
    andp: usize,
    atorstack: [NSTACK]u32,
    atorp: usize,
    subidstack: [NSTACK]i8,
    subidp: usize,
    lastwasand: bool,
    cursubid: i32,
    backwards: bool,
    nbra: i32,
    negateclass: bool,

    fn init(rx: *Regx, src: []const u21, backwards: bool) Compiler {
        return .{
            .rx = rx,
            .src = src,
            .pos = 0,
            .andstack = undefined,
            .andp = 0,
            .atorstack = undefined,
            .atorp = 0,
            .subidstack = undefined,
            .subidp = 0,
            .lastwasand = false,
            .cursubid = 0,
            .backwards = backwards,
            .nbra = 0,
            .negateclass = false,
        };
    }

    /// newinst (regx.c:150-159): append an inst with an unset `next`, return its
    /// index. Overflow of the u16 index space ⇒ "expression too long".
    fn newinst(c: *Compiler, op: Op) CompileError!u16 {
        if (c.rx.prog.items.len >= Regx.prog_cap) return error.ExpressionTooLong;
        const idx: u16 = @intCast(c.rx.prog.items.len);
        try c.rx.prog.append(c.rx.allocator, .{ .op = op, .next = nil_inst });
        return idx;
    }

    fn setNext(c: *Compiler, idx: u16, target: u16) void {
        c.rx.prog.items[idx].next = target;
    }

    // --- parser stacks (regx.c:264-307) ---

    fn pushand(c: *Compiler, f: u16, l: u16) CompileError!void {
        if (c.andp >= NSTACK) return error.ExpressionTooLong; // C: error() abort
        c.andstack[c.andp] = .{ .first = f, .last = l };
        c.andp += 1;
    }

    fn pushator(c: *Compiler, t: u32) CompileError!void {
        if (c.atorp >= NSTACK) return error.ExpressionTooLong; // C: error() abort
        c.atorstack[c.atorp] = t;
        c.atorp += 1;
        // cap subid at NRange ⇒ -1 "silently ignored" (regx.c:280-283).
        c.subidstack[c.subidp] = if (c.cursubid >= nrange) -1 else @intCast(c.cursubid);
        c.subidp += 1;
    }

    /// popand (regx.c:286-298): `op != 0` ⇒ "missing operand for op", else
    /// "malformed regexp".
    fn popand(c: *Compiler, op: u8) CompileError!Node {
        if (c.andp == 0) return if (op != 0) error.MissingOperand else error.MalformedRegexp;
        c.andp -= 1;
        return c.andstack[c.andp];
    }

    fn popator(c: *Compiler) u32 {
        c.subidp -= 1;
        c.atorp -= 1;
        return c.atorstack[c.atorp];
    }

    // --- lexer (regx.c:393-465) ---

    fn startlex(c: *Compiler) void {
        c.pos = 0;
        c.nbra = 0;
    }

    fn lex(c: *Compiler) CompileError!u32 {
        if (c.pos >= c.src.len) return END; // NUL ⇒ END, don't advance (regx.c:412-414)
        var ch: u32 = c.src[c.pos];
        c.pos += 1;
        switch (ch) {
            '\\' => { // backslash-quote: next char is a literal (\n ⇒ newline)
                if (c.pos < c.src.len) {
                    ch = c.src[c.pos];
                    c.pos += 1;
                    if (ch == 'n') ch = '\n';
                }
            },
            '*' => ch = STAR,
            '?' => ch = QUEST,
            '+' => ch = PLUS,
            '|' => ch = OR,
            '.' => ch = ANY,
            '(' => ch = LBRA,
            ')' => ch = RBRA,
            '^' => ch = BOL,
            '$' => ch = EOL,
            '[' => {
                ch = CCLASS;
                try c.bldcclass();
            },
            else => {},
        }
        return ch;
    }

    /// nextrec (regx.c:451-465): the next class char, backslash-quotes carrying the
    /// QUOTED bit so `[\-]` is a literal dash.
    fn nextrec(c: *Compiler) CompileError!u32 {
        if (c.pos >= c.src.len or (c.src[c.pos] == '\\' and c.pos + 1 >= c.src.len))
            return error.MalformedClass;
        if (c.src[c.pos] == '\\') {
            c.pos += 1;
            if (c.src[c.pos] == 'n') {
                c.pos += 1;
                return '\n';
            }
            const r: u32 = c.src[c.pos];
            c.pos += 1;
            return r | QUOTED;
        }
        const r: u32 = c.src[c.pos];
        c.pos += 1;
        return r;
    }

    /// bldcclass (regx.c:467-510): build one `[...]` set. A leading `^` sets the
    /// negate flag and prepends `'\n'` so a negated class never matches newline
    /// (regx.c:477-480). Ranges are `c1-c2`; a leading/dangling `-` is malformed.
    /// DIVERGENCE from the C: range endpoints have the QUOTED bit stripped (the C
    /// keeps it on ranges, regx.c:497-500, which makes an escaped endpoint match
    /// nothing — a latent bug); stripping only affects escaped range endpoints,
    /// which are pathological and untested.
    fn bldcclass(c: *Compiler) CompileError!void {
        var items: std.ArrayList(ClassItem) = .empty;
        errdefer items.deinit(c.rx.allocator);
        // we have already consumed the '['.
        if (c.pos < c.src.len and c.src[c.pos] == '^') {
            try items.append(c.rx.allocator, .{ .single = '\n' });
            c.negateclass = true;
            c.pos += 1;
        } else {
            c.negateclass = false;
        }
        while (true) {
            const c1 = try c.nextrec();
            if (c1 == ']') break; // unquoted ']' terminates; \] is QUOTED, a literal
            if (c1 == '-') return error.MalformedClass; // leading/dangling dash
            if (c.pos < c.src.len and c.src[c.pos] == '-') {
                c.pos += 1; // eat '-'
                const c2 = try c.nextrec();
                if (c2 == ']') return error.MalformedClass;
                try items.append(c.rx.allocator, .{ .range = .{ @intCast(c1 & ~QUOTED), @intCast(c2 & ~QUOTED) } });
            } else {
                try items.append(c.rx.allocator, .{ .single = @intCast(c1 & ~QUOTED) });
            }
        }
        try c.rx.classes.append(c.rx.allocator, items);
    }

    // --- parser (regx.c:229-377) ---

    /// operand (regx.c:229-243): emit an operand inst, inserting an implicit CAT
    /// when the previous token was also an operand.
    fn operand(c: *Compiler, t: u32) CompileError!void {
        if (c.lastwasand) try c.operator(CAT);
        const op: Op = if (t < OPERATOR) .{ .rune = @intCast(t) } else switch (t) {
            ANY => .any,
            BOL => .bol,
            EOL => .eol,
            END => .end,
            NOP => .nop,
            CCLASS => .{ .class = .{
                .idx = @intCast(c.rx.classes.items.len - 1),
                .negate = c.negateclass,
            } },
            else => unreachable,
        };
        const i = try c.newinst(op);
        try c.pushand(i, i);
        c.lastwasand = true;
    }

    /// operator (regx.c:245-262): parens bookkeep + evaluate higher-precedence
    /// pending operators before pushing this one.
    fn operator(c: *Compiler, t: u32) CompileError!void {
        if (t == RBRA) {
            c.nbra -= 1;
            if (c.nbra < 0) return error.UnmatchedRightParen;
        }
        if (t == LBRA) {
            c.cursubid += 1; // counts `(` in parse order (regx.c:251)
            c.nbra += 1;
            if (c.lastwasand) try c.operator(CAT);
        } else {
            try c.evaluntil(t);
        }
        if (t != RBRA) try c.pushator(t);
        // STAR/QUEST/PLUS/RBRA "look like operands" for implicit-CAT purposes.
        c.lastwasand = (t == STAR or t == QUEST or t == PLUS or t == RBRA);
    }

    /// evaluntil (regx.c:309-377): pop and emit while the operator on top of the
    /// stack has precedence ≥ `pri` (or unconditionally when closing an RBRA).
    fn evaluntil(c: *Compiler, pri: u32) CompileError!void {
        while (pri == RBRA or c.atorstack[c.atorp - 1] >= pri) {
            switch (c.popator()) {
                LBRA => {
                    const op1 = try c.popand('(');
                    const subid = c.subidstack[c.subidp];
                    const inst2 = try c.newinst(.{ .rbra = subid });
                    c.setNext(op1.last, inst2);
                    const inst1 = try c.newinst(.{ .lbra = subid });
                    c.setNext(inst1, op1.first);
                    try c.pushand(inst1, inst2);
                    return; // must have been an RBRA close
                },
                OR => {
                    const op2 = try c.popand('|');
                    const op1 = try c.popand('|');
                    const join = try c.newinst(.nop);
                    c.setNext(op2.last, join);
                    c.setNext(op1.last, join);
                    // OR: payload = right (op1.first); next = left (op2.first).
                    const alt = try c.newinst(.{ .alt = op1.first });
                    c.setNext(alt, op2.first);
                    try c.pushand(alt, join);
                },
                CAT => {
                    var op2 = try c.popand(0);
                    var op1 = try c.popand(0);
                    // The whole backward machine is just reversed concatenation
                    // (regx.c:344-348): swap CAT operands (never the END terminator).
                    if (c.backwards and std.meta.activeTag(c.rx.prog.items[op2.first].op) != .end) {
                        const tmp = op1;
                        op1 = op2;
                        op2 = tmp;
                    }
                    c.setNext(op1.last, op2.first);
                    try c.pushand(op1.first, op2.last);
                },
                STAR => { // loop-back OR, node = the OR (regx.c:352-357)
                    const op2 = try c.popand('*');
                    const alt = try c.newinst(.{ .alt = op2.first });
                    c.setNext(op2.last, alt);
                    try c.pushand(alt, alt);
                },
                PLUS => { // a+ == aa*: node starts at the operand (regx.c:359-364)
                    const op2 = try c.popand('+');
                    const alt = try c.newinst(.{ .alt = op2.first });
                    c.setNext(op2.last, alt);
                    try c.pushand(op2.first, alt);
                },
                QUEST => { // OR with left = the NOP join (regx.c:366-373)
                    const op2 = try c.popand('?');
                    const alt = try c.newinst(.{ .alt = op2.first });
                    const join = try c.newinst(.nop);
                    c.setNext(alt, join); // next = left = join
                    c.setNext(op2.last, join);
                    try c.pushand(alt, join);
                },
                else => return error.MalformedRegexp, // "unknown regexp operator"
            }
        }
    }

    /// realcompile (regx.c:161-193): drive lex → operator/operand, close with a
    /// low-priority operator, force END, and return the entry inst.
    fn run(c: *Compiler) CompileError!u16 {
        c.startlex();
        c.atorp = 0;
        c.andp = 0;
        c.subidp = 0;
        c.cursubid = 0;
        c.lastwasand = false;
        try c.pushator(START - 1); // prime the parser
        while (true) {
            const token = try c.lex();
            if (token == END) break;
            if ((token & OPERATOR) == OPERATOR) try c.operator(token) else try c.operand(token);
        }
        try c.evaluntil(START);
        try c.operand(END); // force END
        try c.evaluntil(START);
        if (c.nbra != 0) return error.UnmatchedLeftParen;
        c.andp -= 1; // points to the first and only operand
        return c.andstack[c.andp].first;
    }
};

/// optimize (regx.c:380-391): splice NOPs out of `next` chains, walking the arena
/// region sequentially from `start` until END.
fn optimize(self: *Regx, start: u16) void {
    var idx: u16 = start;
    while (std.meta.activeTag(self.prog.items[idx].op) != .end) : (idx += 1) {
        var target = self.prog.items[idx].next;
        if (target != nil_inst) {
            while (std.meta.activeTag(self.prog.items[target].op) == .nop)
                target = self.prog.items[target].next;
            self.prog.items[idx].next = target;
        }
    }
}

/// rxcompile (regx.c:196-227): identical pattern ⇒ cached no-op; otherwise free the
/// old classes and build the forward program then the backward program into the
/// same arena (the backward pass only swaps CAT operands).
pub fn compile(self: *Regx, pattern: []const u21) CompileError!void {
    if (self.startinst != null and self.bstartinst != null and
        std.mem.eql(u21, self.lastpat.items, pattern)) return;

    // Any failure leaves the engine "null" and the cache cleared, so a later retry
    // recompiles (regx.c:144 `lastregexp[0] = 0`).
    self.lastpat.clearRetainingCapacity();
    for (self.classes.items) |*cl| cl.deinit(self.allocator);
    self.classes.clearRetainingCapacity();
    self.prog.clearRetainingCapacity();
    self.startinst = null;
    self.bstartinst = null;
    errdefer {
        self.startinst = null;
        self.bstartinst = null;
    }

    var fc = Compiler.init(self, pattern, false);
    self.startinst = try fc.run();
    optimize(self, 0);

    const bwd_base: u16 = @intCast(self.prog.items.len);
    var bc = Compiler.init(self, pattern, true);
    self.bstartinst = try bc.run();
    optimize(self, bwd_base);

    try self.lastpat.appendSlice(self.allocator, pattern);
}

// ---------------------------------------------------------------------------
// Tests — compile-error surface (side contract §3 test 16). Match semantics live
// in regx_exec.zig alongside the machine.
// ---------------------------------------------------------------------------
const testing = std.testing;

fn L(comptime s: []const u8) [s.len]u21 {
    var out: [s.len]u21 = undefined;
    for (s, 0..) |ch, i| out[i] = ch;
    return out;
}

test "regx: compile errors" {
    var rx = Regx.init(testing.allocator);
    defer rx.deinit();

    {
        const p = L("a(");
        try testing.expectError(error.UnmatchedLeftParen, rx.compile(&p));
    }
    {
        const p = L(")");
        try testing.expectError(error.UnmatchedRightParen, rx.compile(&p));
    }
    {
        const p = L("*");
        try testing.expectError(error.MissingOperand, rx.compile(&p));
    }
    {
        const p = L("[a-]");
        try testing.expectError(error.MalformedClass, rx.compile(&p));
    }
    {
        const p = L("[");
        try testing.expectError(error.MalformedClass, rx.compile(&p));
    }
    // isNull holds after a failed compile (rxnull, regx.c:552-556).
    try testing.expect(rx.isNull());
}
