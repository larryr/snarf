# Phase 10 side contract (O20) — structural regexp engine + Edit address machinery

All C cites `larryr/plan9port@337c6ac`. Master supersessions: Address.t ruling is
R-P10-1; eval/nextMatch signatures per R-P10-3 (no *Editor param); F1..F5 resolved
in the master (R-P10-9, R-P10-5, R-P10-2, R-P10-7, R-P10-1 respectively).

## 1. C ground truth

### 1.1 The engine (`acme/regx.c`, 843 lines)

**Program encoding.** `Inst` (regx.c:24-39): `type < OPERATOR (0x1000000)` => the type
IS the literal rune; otherwise an action opcode. Two overlaid unions: `u` = {sid,
subid, class index, other/right Inst*}, `u1` = {left/next Inst*}. Fixed arena
`program[NPROG=1024]` (regx.c:41-42); overflow => `regerror("expression too long")`
(regx.c:153-154). Opcodes (regx.c:68-83): operators START/RBRA/LBRA/OR/CAT/STAR/PLUS/
QUEST (value == precedence, ascending — CAT binds tighter than OR, closures tightest),
operands ANY(`.`)/NOP/BOL(`^`)/EOL(`$`)/CCLASS/NCCLASS/END. **`+` and `?` ARE
supported** (lex, regx.c:419-424: `*`->STAR, `?`->QUEST, `+`->PLUS).

**Compilation.** `rxcompile` (regx.c:196-227): caches `lastregexp` — identical pattern
=> no-op return TRUE (regx.c:203-204); frees classes; compiles **twice** — forward,
then with `backwards=TRUE` a second program into the same arena for the backward
machine (`startinst`/`bstartinst`, regx.c:209-223). `realcompile` (regx.c:161-193) is
a classic operator-precedence parser: `lex` (regx.c:401-449; `\n` escape at 407-410,
everything else backslash-quotes to a literal rune; NUL => END), implicit CAT insertion
when `lastwasand` (regx.c:233-234), `operator`/`operand` push onto
`andstack`/`atorstack[NSTACK=20]`, `evaluntil` (regx.c:309-377) pops and emits:
- LBRA/RBRA emit LBRA/RBRA insts carrying `subid` (regx.c:317-326); `cursubid` counts
  `(` in parse order, capped at NRange => subid -1 "silently ignored" (regx.c:251,
  280-283); unmatched paren errors at regx.c:248-249 / 188-189.
- OR: two-way split inst + shared NOP join (regx.c:330-339). STAR: loop-back OR, node
  = the OR (regx.c:352-357). PLUS: same OR but node starts at the operand
  (`a+ == aa*`, regx.c:359-364). QUEST: OR with left=NOP-join (regx.c:366-373).
- **The backward trick**: CAT swaps its operands when `backwards` (regx.c:344-348) —
  the whole reversal of the machine is just reversed concatenation.
- `optimize` (regx.c:380-391) splices NOPs out of `next` chains.

**Classes.** `bldcclass` (regx.c:467-510): `[^...]` sets `negateclass` and **prepends
`'\n'` to the set** so a negated class never matches newline (regx.c:477-480). Ranges
stored as flat triples `(Runemax, lo, hi)` in a NUL-terminated rune string; singles
stored bare with the QUOTED bit stripped (regx.c:493-502). Leading/dangling `-` =>
"malformed `[]`" (regx.c:484-488, 495-496); escapes inside via `nextrec`
(regx.c:451-465, QUOTED bit so `[\-]` is a literal dash). `classmatch` (regx.c:512-527)
walks the encoding; negation inverts the return.

**Execution.** Pike-VM thread lists `Ilist{inst, se: Rangeset, startp}` in
`list[2][NLIST=127 +1]` (regx.c:48-59). `addinst` (regx.c:534-550) dedupes by inst
pointer, keeping the thread with **smaller `se.r[0].q0`** — leftmost preference.
`rxexecute(Text *t, Rune *r, startp, eof, Rangeset *rp)` (regx.c:559-692) — the
`t`/`r` duality serves buffer search vs rune-string search (`filematch` uses the `r`
mode, ecmd.c:1245):
- One machine step per char; `startchar` fast path when the program begins with a
  literal (regx.c:576-577, 610-611).
- **End/wrap machinery** (regx.c:587-601): on `p>=eof||p>=nc`, `wrapped++`: case 0
  (and 2) run one extra click with `c=0` so END/RBRA can fire at eof; case 1: if a
  match exists **or `eof != Infinity` return** — otherwise reset lists, `p=0`,
  continue from the top. So **regx itself wraps, but only when called with
  `eof==Infinity` (0x7FFFFFFF)**. One-lap stop: `(wrapped && p>=startp ||
  sel.r[0].q0>0) && nnl==0 => break` (regx.c:603).
- New threads seeded only while no match committed and not past the start point
  (regx.c:618-628); list overflow => warning "regexp list overflow", abort with no
  match (regx.c:622-627).
- Semantics: ANY excludes `'\n'` (regx.c:651-654); BOL: `p==0` or previous char `'\n'`
  (regx.c:655-660); **EOL: current char `=='\n'` only** (regx.c:662-664) — at eof
  `c==0`, so `$` does NOT match at end of a file lacking a trailing newline;
  LBRA/RBRA record `se.r[subid].q0/q1` and step without consuming (regx.c:641-650);
  END sets `q1=p`, `newmatch` keeps leftmost-then-longest (regx.c:694-700).
- `rxbexecute(Text*, startp, rp)` (regx.c:702-831): p decrements, reads
  `textreadc(t, p-1)`; wrap goes 0->end (`p = nc`, regx.c:731-736); seeds record
  `q0 = -p` (regx.c:757-758) so addinst's `<` preference becomes "closest below
  startp"; BOL fires when `c=='\n' || p==0` (regx.c:793-798), EOL when the char AT p
  is `'\n'` (regx.c:800-802); END negates q0 back and `bnewmatch` **swaps every
  q0/q1** to restore q0<=q1 (regx.c:820-824, 833-843).

Globals to kill per S-07: `sel`, `lastregexp`, `program/progp/startinst/bstartinst`,
parser stacks, `class` storage, `list[2]`, `rechan` (the thread+channel dance exists
only because `regerror` longjmp-exits a thread — a Zig error union replaces the
entire mechanism, regx.c:141-148).

### 1.2 Address machinery (`acme/ecmd.c`, `acme/edit.c`, edit.h)

**AST** (edit.h:16-31): `Addr{ char type in {'#','l','/','?','.','$','+','-',',',';',
'\'','"','*'}; u.re | u.left; num; next }` — `next` is both "concatenated address"
and the right side of `,`/`;`. `Address{ Range r; File *f }`. `String{n, Rune*}`
(edit.h:9-14).

**Parser** (O21's file, but it shapes the AST): `simpleaddr` (edit.c:601-668) accepts
`#n`, digits=>type `'l'`, `/ ? "`+regexp, `. $ + - '`; then chains and **inserts a
missing `'+'`** between e.g. `/x/2` => `/x/+2`, `3/x/` => `3+/x/` (edit.c:644-657);
`.`/`$`/`'` following anything but `"` is "bad address syntax" (edit.c:634-643).
`compoundaddr` (edit.c:670-686): `simpleaddr (','|';') compoundaddr`, either side
optional. `getregexp` (edit.c:565-599): empty regexp reuses `lastpat`.

**Evaluator** `cmdaddress(Addr*, Address a, int sign)` (ecmd.c:1064-1146), a do-while
over `next` threading `sign`:
- `'l'`/`'#'` => `lineaddr`/`charaddr` (ecmd.c:1072-1075); `'.'` => `mkaddr` =
  curtext's q0/q1 (ecmd.c:54-60); `'$'` => `(nc,nc)`; `'\''` => **editerror "can't
  handle '"** (ecmd.c:1085-1088); `'*'` => `(0,nc)` (used for defaddr aAll,
  ecmd.c:86-97).
- `'?'` negates sign (0=>-1) and falls into `'/'`: `nextmatch(f, re, sign>=0 ?
  a.r.q1 : a.r.q0, sign)` (ecmd.c:1090-1098). So `-/x/` searches backward from q0,
  and `-?x?` searches **forward** — faithful quirk.
- `'"'` => `matchfile` across all windows (ecmd.c:1100-1103, 1211-1248) — v1
  Unsupported (master R-P10-7).
- `','`/`';'`: missing left => `(0,0)`, missing right => `(nc,nc)` (ecmd.c:1109-1124);
  **`';'` sets dot mid-evaluation**: `f->curtext->q0/q1 = a1` and evaluates the right
  side from a1, while `,` evaluates the right from the incoming a (ecmd.c:1115-1122);
  different files => error; `q1<q0` => "addresses out of order" (ecmd.c:1125-1129).
- `'+'`/`'-'` set sign for the NEXT term; bare or followed by another sign => implicit
  `lineaddr(1,...)` (ecmd.c:1132-1139).

`charaddr` (ecmd.c:1250-1262): sign 0 => point `l`; +- => collapse to q1+l / q0-l;
range-check 0..nc else "address out of range". `lineaddr` (ecmd.c:1264-1325):
forward — absolute (sign 0 or q1==0) counts newlines from 0, line 1 at p=0; relative
starts at `q1-1` counting a newline at dot-end as the first boundary
(ecmd.c:1287-1288); result spans line start to just past its `\n`; `+0` =
dot-end->end-of-line, `l==0` absolute => `(0,0)` (ecmd.c:1275-1281); running off the
end mid-count => error (ecmd.c:1291-1292). Backward — counts newlines from q0
(ecmd.c:1301-1323), `-0` = line-start->dot-start.

**Empty-match advance + who wraps.** `nextmatch` (ecmd.c:1034-1058): compiles ("bad
regexp in command address"), calls `rxexecute(..., 0x7FFFFFFF, ...)` — **wrap happens
inside regx**; if the match is empty and equals the start point, advance p by one
(wrapping nc->0 / 0->nc) and re-search once (ecmd.c:1042-1047, 1051-1056); failure =>
editerror. (`acme/addr.c` `address/number/regexp` — the B3/xfid incremental
string evaluator, addr.c:58-297 — is a *separate* code path, NOT in this phase;
master R-P10-9a.) Line/char reporting helpers `nlcount` (ecmd.c:663-692) belong to
O21's `=` command; in snarf `Buffer.lineOfRune`/`runeOfLine` (Buffer.zig:224-236)
already do this in O(log n).

**Rangeset model**: `Range{int q0,q1}`, `Rangeset{ Range r[NRange=10] }` (dat.h:32,
65, 437-439). r[0] = whole match, r[1..9] = `(` groups in parse order; threads start
from zeroed `sempty` so unmatched groups read `{0,0}`. Edit `s` uses r[1..9] for
`\1`-`\9` (O21).

### 1.3 What snarf already has (verified)

- `Buffer.zig:213 runeAt`, `:84 len`, `:169 read` (chunked), `:224/:236
  lineOfRune/runeOfLine`; rune-addressed via RuneIndex. Replaces textreadc/RBUFSIZE
  windows outright.
- `File.zig:36 pub const Range = struct { q0: usize, q1: usize }`; File has **no**
  `curtext` back-pointer (Text->File only).
- `look.zig:27/82` — literal search only; regx replaces nothing there.
- ADR-0002: engine written in-project. Layout plan `07-source-layout.md:129-134,
  183-199`: `core/edit/{parse,cmd,addr,regx,Elog}.zig` — regx budgeted ~400,
  addr ~250.

## 2. Contract (frozen signatures)

### 2.1 `src/core/edit/Regx.zig` — file-as-struct, instance owned by `Editor`
(`ed.regx: Regx`, R-P10-5)

```zig
pub const nrange = 10;                                   // dat.h:32
pub const Range = File.Range;
pub const Rangeset = [nrange]Range;                      // [0]=match; unmatched groups {0,0} (sempty, regx.c:60)
pub const Source = union(enum) {                         // rxexecute's t/r duality, regx.c:559
    buffer: *const Buffer,
    runes: []const u21,
};
pub const CompileError = error{ OutOfMemory, ExpressionTooLong, UnmatchedLeftParen,
    UnmatchedRightParen, MissingOperand, MalformedClass, MalformedRegexp };
pub const ExecError = error{ListOverflow};               // regx.c:622 warning path, surfaced

pub fn init(allocator: std.mem.Allocator) Regx
pub fn deinit(self: *Regx) void
/// rxcompile (regx.c:196): builds fwd+bwd programs; identical pattern = cached no-op.
pub fn compile(self: *Regx, pattern: []const u21) CompileError!void
pub fn isNull(self: *const Regx) bool                    // rxnull, regx.c:552-556
/// rxexecute (regx.c:559). eof==null => C's Infinity: search to end AND wrap once.
pub fn execute(self: *Regx, src: Source, startp: usize, eof: ?usize) ExecError!?Rangeset
/// rxbexecute (regx.c:702). Always wraps (end<-) exactly as the C.
pub fn bexecute(self: *Regx, src: Source, startp: usize) ExecError!?Rangeset
/// Static message for warnings, e.g. "unmatched `('" (regerror strings).
pub fn describe(e: anyerror) []const u8
```

Internals (directed, not frozen): `Inst = struct { op: Op, next: u16 }` with `Op =
union(enum) { rune: u21, any, bol, eol, end, class: struct{ idx: u16, negate: bool },
lbra: i8, rbra: i8, alt: u16, nop }` — u16 **indices** into the program slice, no
self-referential pointers; classes as owned slices keeping sam's triple encoding or a
`ClassItem = union(enum){ single: u21, range: [2]u21 }` list; thread lists
`[2][nlist+1]` stored in the struct (not stack); bexecute's `-p` trick may use `isize`
internally — public API stays usize. No channels/threads: `regerror` => error return.

**File split (~400 cap, 843 C lines):** `Regx.zig` (~150: types, state, init/deinit,
method re-exports a la Text.zig:100-107) + `regx_compile.zig` (~350: lex, stacks,
evaluntil, bldcclass, optimize) + `regx_exec.zig` (~350: addinst, classmatch,
execute/bexecute, newmatch/bnewmatch).

### 2.2 `src/core/edit/addr.zig` — namespace module (evaluation only; types live in
ast.zig per R-P10-1; signatures per R-P10-3)

```zig
pub const Error = error{ OutOfMemory, BadRegexp, NoMatch, ListOverflow,
    AddressOutOfRange, AddressesOutOfOrder, Unsupported };

pub fn mkAddr(t: *Text) ast.Address                              // ecmd.c:54-60
/// cmdaddress (ecmd.c:1064-1146). sign in {-1,0,1}, callers pass 0.
/// `;` writes a1 into a.t.q0/q1 mid-eval (ecmd.c:1118-1119) — documented side effect.
pub fn eval(rx: *Regx, ap: *const ast.Addr, a: ast.Address, sign: i8) Error!ast.Address
/// nextmatch (ecmd.c:1034-1058): compile, wrap-search via rx, empty-match advance.
pub fn nextMatch(rx: *Regx, t: *Text, re: []const u21, p: usize, sign: i8) Error!File.Range
pub fn charAddr(l: usize, a: ast.Address, sign: i8) Error!ast.Address // ecmd.c:1250-1262
pub fn lineAddr(l: usize, a: ast.Address, sign: i8) Error!ast.Address // ecmd.c:1264-1325
pub fn describe(e: anyerror) []const u8   // editerror strings for cmd.zig's boundary
```

~280 lines. `CompileError` inside `nextMatch` collapses to `error.BadRegexp` ("bad
regexp in command address"). No default-address logic here — cmdexec's defaddr
synthesis (ecmd.c:86-108) is O21's, expressed by building `.dot`/`.all` nodes.

## 3. Named tests (Rangeset[0] shown as (q0,q1))

Regx over `Source.runes` unless noted. r = compile+execute(start 0, eof=len) unless
noted.

1. `regx: literal` — `hello` on "say hello" => (4,9).
2. `regx: leftmost wins` — `a*` on "baaa" => empty (0,0).
3. `regx: longest at same start` — `aa|a` on "xaa" => (1,3) (newmatch regx.c:697-699).
4. `regx: plus` — `ba+` on "abaaac" => (1,5).
5. `regx: quest` — `ab?c` on "ac" => (0,2); on "abc" => (0,3).
6. `regx: class range` — `[a-c]+` on "zabcz" => (1,4).
7. `regx: negated class excludes newline` — `[^a]` on "\nb" => (1,2) (regx.c:477-478).
8. `regx: class escaped dash` — `[\-x]` on "a-b" => (1,2) (QUOTED, regx.c:462, 502).
9. `regx: dot excludes newline` — `a.c` on "a\nc", eof=3 => null.
10. `regx: bol` — `^ab` on "zz\nab" => (3,5); on "ab" => (0,2).
11. `regx: eol before newline only` — `b$` on "ab\ncb" => (1,2); `b$` on "ab" (no
    trailing \n) => **null** (regx.c:662-664 — pins the c==0 non-match).
12. `regx: match ending at eof` — `ab` on "ab", eof=2 => (0,2) (the wrapped-case-0
    extra click, regx.c:588-592).
13. `regx: groups` — `(a+)(b+)` on "xaabb" => r[0]=(1,5), r[1]=(1,3), r[2]=(3,5);
    nested `((a)b)` on "ab" => r[1]=(0,2), r[2]=(0,1).
14. `regx: unmatched group is zero` — `(a)|b` on "b" => r[0]=(0,1), r[1]=(0,0).
15. `regx: escaped metachar` — `a\*` on "xa*" => (1,3); `\n` matches "\n" at (0,1).
16. `regx: compile errors` — `a(` => UnmatchedLeftParen; `)` => UnmatchedRightParen;
    `*` => MissingOperand; `[a-]`/`[` => MalformedClass.
17. `regx: recompile cache` — compile twice, execute still correct.
18. `regx: wrap when eof null` — buffer "abcab": `ab` start 4, eof null => (0,2);
    one-lap: `zz` start 2, eof null => null (terminates).
19. `regx: no wrap when eof given` — `ab` start 4, eof 5 => null.
20. `regx: bexecute basic` — buffer "abcab": `ab` start 5 => (3,5); start 3 => (0,2);
    ranges returned q0<=q1 (bnewmatch reversal regx.c:838-842).
21. `regx: bexecute wraps to end` — `ab` start 1 => (3,5) (regx.c:731-736).
22. `regx: bexecute bol/eol` — `^a` on "b\na" start 3 => (2,3); `b$` on "ab\ncb"
    start 2 => (1,2).
23. `regx: list overflow` — `a?`x128 then `a`x128 on "a"x128 => error.ListOverflow.

Address tests over file "abc\ndef\nghi\n" (nc=12; line1=(0,4), line2=(4,8),
line3=(8,12)); AST built by hand; dot via `t.q0/q1`.

24. `addr: absolute line` — `3` => (8,12); `1` on "ab" (no \n) => (0,2); `2` on
    "ab\n" => (3,3).
25. `addr: zero and dollar` — `0` => (0,0); `$` => (12,12).
26. `addr: char` — `#5` => (5,5); `#13` => error.AddressOutOfRange.
27. `addr: dot` — dot (5,6) => (5,6).
28. `addr: fwd regexp` — dot (0,0), `/de/` => (4,6).
29. `addr: back regexp` — dot (8,8), `?de?` => (4,6).
30. `addr: regexp wraps` — dot (4,8), `/abc/` => (0,3) (wrap inside execute, eof=null).
31. `addr: regexp plus lines` — `/abc/+2` => (8,12).
32. `addr: bare plus` — dot (0,4), `+` => (4,8); dot (0,0), `+` => (0,4) (q1==0
    special case ecmd.c:1283-1285).
33. `addr: bare minus` — dot (8,12), `-` => (4,8).
34. `addr: plus zero / minus zero` — dot (5,6): `+0` => (6,8); `-0` => (4,5)
    (ecmd.c:1275-1281, 1302-1304).
35. `addr: comma vs semi dot update` — dot (8,12): `1,+` => (0,12) (right `+`
    evaluated from ORIGINAL dot); `1;+` => (0,8) (right evaluated from a1=(0,4) =>
    (4,8)); after `;`, t.q0/q1 == (0,4) (ecmd.c:1115-1122).
36. `addr: bare comma` — `,` => (0,12); `0;$` => (0,12).
37. `addr: out of order` — `3,1` => error.AddressesOutOfOrder.
38. `addr: empty match advances` — dot (2,2), `/x*/` => (3,3) (ecmd.c:1042-1047);
    backward: dot (3,3), `?x*?` => (2,2).
39. `addr: line out of range` — `9` => error.AddressOutOfRange.
40. `addr: char arithmetic` — `#3+#2` => (5,5); `$-#2` => (10,10).
41. `addr: mark and filematch unsupported` — `'` => error.Unsupported ("can't handle
    '", ecmd.c:1086); `"re"` => error.Unsupported.

## 4. Seams (as resolved by the master)

- ast.zig (O21) owns Addr/Address/Diag/Error; Rangeset lives in Regx.zig; addr.zig
  imports ast+Regx only — acyclic. One compiled program at a time is safe: looper
  PRE-collects ranges before children recompile (ecmd.c:864-891).
- x/g/s loops pass `eof=q1` — no wrap; filematch-style checks use `Source{.runes}`.
- ListOverflow: consumers warn + treat as no-match (regx.c:622-627).

## 5. Wave split (master 10a-A1 / 10b-B1)

- 10a-A1 (opus): Regx.zig + regx_compile.zig + regx_exec.zig, tests 1-23; `ed.regx`.
- 10b-B1 (sonnet): addr.zig, tests 24-41 — mechanical against the frozen Regx API,
  every expected Range hand-derived above.
