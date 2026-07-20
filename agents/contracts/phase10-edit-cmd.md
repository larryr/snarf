# Phase 10 side contract (O21) — Edit command language (parse / exec / elog)

Pinned C: `larryr/plan9port@337c6ac`; cites `acme/<file>:<line>`. Master
supersessions: `Address = { r, t: *Text }` (R-P10-1); addr signatures per R-P10-3;
Elog on Ctx (R-P10-6); Edit builtin row per R-P10-8.

## 1. C ground truth

### 1.1 Grammar table (edit.c:18-54) — v1-relevant rows, exactly

```
/* cmdc  text regexp addr defcmd defaddr count token  fn     */
  '\n',  0,   0,     0,   0,     aDot,   0,    0,     nl_cmd,   // edit.c:20
  'a',   1,   0,     0,   0,     aDot,   0,    0,     a_cmd,    // :21
  'c',   1,   0,     0,   0,     aDot,   0,    0,     c_cmd,    // :23
  'd',   0,   0,     0,   0,     aDot,   0,    0,     d_cmd,    // :24
  'g',   0,   1,     0,   'p',   aDot,   0,    0,     g_cmd,    // :27
  'i',   1,   0,     0,   0,     aDot,   0,    0,     i_cmd,    // :28
  'm',   0,   0,     1,   0,     aDot,   0,    0,     m_cmd,    // :29
  'p',   0,   0,     0,   0,     aDot,   0,    0,     p_cmd,    // :30
  's',   0,   1,     0,   0,     aDot,   1,    0,     s_cmd,    // :32
  't',   0,   0,     1,   0,     aDot,   0,    0,     m_cmd,    // :33
  'u',   0,   0,     0,   0,     aNo,    2,    0,     u_cmd,    // :34
  'v',   0,   1,     0,   'p',   aDot,   0,    0,     g_cmd,    // :35
  'x',   0,   1,     0,   'p',   aDot,   0,    0,     x_cmd,    // :37
  'y',   0,   1,     0,   'p',   aDot,   0,    0,     x_cmd,    // :38
  '=',   0,   0,     0,   0,     aDot,   0,    linex, eq_cmd,   // :39
```
Deferred rows: `b e f r w` (:22,:25,:26,:31,:36), `B D X Y < | >` (:40-46). `k n q !`
are **absent from acme itself** (edit.c:47-52). No `M` in acme. Column meanings:
edit.h:48-58 (`text`=collecttext arg, `regexp`, `addr`=simpleaddr arg for m/t,
`defcmd`=command substituted when the loop body is bare (`'p'` for x/y/g/v),
`defaddr` in {aNo,aDot,aAll} (edit.h:74-78), `count`=numeric prefix (`s2///`; u's `2`
means sign allowed, edit.c:227), `token`=rest-of-line collection set).

### 1.2 parsecmd recursion (edit.c:470-563)

- `cmd.addr = compoundaddr()` first (edit.c:481); `,`/`;` right-recursive
  (edit.c:670-686), `simpleaddr` chains `+`/`-` terms with an implicit `+` inserted
  between e.g. `/x/2` (edit.c:633-664). Address atoms: `#n`, digits->`'l'`,
  `/ ? "`->regexp, `. $ + - '` (edit.c:610-632).
- `defaddr==aNo && cmd.addr` -> "command takes no address" (edit.c:496-497).
- regexp arg: `x`/`X` followed by space/tab/newline => `re==0` (default `.*\n` ->
  linelooper) (edit.c:501-504); otherwise `okdelim` (alnum/backslash rejected,
  edit.c:362-367), `getregexp`; `s` additionally collects rhs via `getrhs` and an
  optional trailing `g` flag (edit.c:510-519).
- `defcmd`: bare newline after x/y/g/v => synthesize child `p`; else recurse
  `parsecmd(nest)` (edit.c:524-530).
- `{`: loop of `parsecmd(nest+1)` chained via `next`; `}` at nest 0 errors
  (edit.c:539-555).
- Sleazy `cd` two-char case: `cmdc = 'c'|0x100` (edit.c:487-490) -> no table entry ->
  "unknown command" in cmdexec (ecmd.c:123-124). Keep the detection so `Edit cd /x`
  doesn't parse as `c` with text `d /x`.
- `getregexp` (edit.c:565-599): `\`+delim -> delim; `\\` kept as two chars; non-empty
  pattern **replaces `lastpat`**; empty pattern reuses `lastpat`, error "no regular
  expression defined" if never set. `lastpat` persists ACROSS Edit invocations
  (edit.c:181).
- `getrhs` (edit.c:391-411): stops at delim or `\n`; `\n`(char n) -> newline;
  `\`+delim -> delim; for `s` all other backslashes are PRESERVED (`\1`,`\&` reach
  s_cmd raw, edit.c:405).
- `collecttext` (edit.c:428-457) two forms: newline => lines until a line that is
  exactly `.\n` (terminator stripped, edit.c:445-447); inline => `a/text/` with
  okdelim + getrhs('a' mode) + atnl.
- editcmd envelope (edit.c:151-194): appends `\n` if missing (edit.c:168-169);
  RBUFSIZE "string too long" guard (edit.c:157-160) — dropped in port (no fixed
  buffers), flagged.

### 1.3 cmdexec + address defaults (ecmd.c:62-129)

- No-window guard ecmd.c:75-78 (v1: `ct.w` always set).
- Default-address synthesis ecmd.c:86-97: missing addr + defaddr!=aNo => `'.'` (or
  `'*'`=whole file for aAll); **skipped for `'\n'`** (nl_cmd computes its own).
- The address is evaluated ONCE into the edit-global `Address addr` (ecmd.c:20,
  :98-107) before dispatch; loop commands copy `addr.r` at entry because nested
  cmdexec clobbers it (ecmd.c:859 `r = addr.r`).
- `{`: dot evaluated once; each subcommand runs with `t->q0/q1` reset to that dot
  (ecmd.c:110-121), guarded "dot extends past end of buffer during { command".

### 1.4 Dot rules per command (hand-verified)

| cmd | dot in (defaddr) | dot out |
|---|---|---|
| a | `.` | pre-apply q0=q1=addr.q1 (ecmd.c:795-797); apply's insert-at-caret rule extends q1 (elog.c:317-318) => dot = inserted text |
| i | `.` | same at addr.q0 (ecmd.c:388-391) |
| c | `.` | q0/q1 = addr (ecmd.c:217-218); apply => dot = new text |
| d | `.` | q0=q1=addr.q0 (ecmd.c:228-230) |
| m/t | `.` (+simpleaddr dest) | NOT set explicitly (ecmd.c:427-438) — final dot = old dot coordinate-adjusted by the log |
| p | `.` | dot = addressed range (ecmd.c:823-824) |
| = | `.` | unchanged (eq_cmd never touches q0/q1, ecmd.c:742-766) |
| s | `.` | q0/q1 = addr pre-apply (ecmd.c:524-525) => whole modified range |
| g/v | `.` | q0/q1 = addr, then child runs (ecmd.c:379-382) |
| x/y | `.` | per-iteration q0/q1 = match/gap (loopcmd ecmd.c:841-850); final = last iteration's, adjusted |
| u | aNo | undo() sets it |
| \n | special | extend dot to line boundaries; if already exact, advance one line; textshow (ecmd.c:769-788) |

### 1.5 Elog transaction model (elog.c)

- Why buffered (elog.c:19-27): (1) addresses refer to the OLD file; (2) `,x m$`-style
  movement is untrackable live; (3) merge optimization => Replace record besides
  Insert/Delete.
- Record types dat.h:497-502 (`Empty/Null/Delete/Insert/Replace`); pending head
  merges: Insert merges when same q0 and under Maxstring (elog.c:174-177); Delete
  merges when contiguous (elog.c:205-207); Replace merges across gaps < Minstring=16
  by reading the gap text from the file (elog.c:137-149). Out-of-order q0 => one
  "warning: changes out of sequence" then flush-and-proceed (elog.c:131-135,
  :168-172, :199-203).
- **Apply order is DESCENDING**: records appended in ascending-q0 command order;
  `elogapply` reads the log from the END backwards (elog.c:257-259) so applying a
  high-address change never invalidates the still-unapplied lower addresses of the
  frozen coordinate space.
- Apply calls `filemark(f)` ONCE on first modification (elog.c:271-273, :293-295,
  :304-306) — combined with `seq++` in exec.c:1141 that is exactly one undo step per
  Edit per file. Inserts/deletes go through `textinsert/textdelete(..., TRUE)` so
  frame + q0/q1 coordinates update (elog.c:275-318); insert at collapsed caret
  q0==q1==b.q0 extends q1 (select-the-insertion convention, elog.c:284-285,
  :317-318). Addresses constrained via `textconstrain` = min-clamp (text.c:517-521).
  `elogterm` per file resets state + `warned` (elog.c:84-94); `editerror` truncates
  ALL edit logs before reporting (edit.c:145-146).

### 1.6 s-command (ecmd.c:447-534)

- Collect phase over the FROZEN buffer: matches from addr.q0, `--n>0 continue` skips
  to the n-th (ecmd.c:475-476); with `g`, the n-th AND every later match is kept
  (break-after-first only when `!cp->flag`, ecmd.c:516-517). Empty-match advance: an
  empty match at the previous match end is skipped with `p1++`; otherwise `p1 = q1+1`
  (ecmd.c:466-473).
- Rhs expansion per match (ecmd.c:487-511): `\1`-`\9` => subexpression j text read
  from the file; `&` => whole match; `\&`/`\x` => literal char; sam.1:344-379
  confirms. Replace recorded per match via `elogreplace`.
- "no substitution" error ONLY at nest==0 (ecmd.c:522-523) — inside x/g loops a miss
  is silent.

### 1.7 Loops and guards

- `looper` (x/y, ecmd.c:852-894): compile, then PRE-COLLECT all ranges over the
  unmodified buffer into `rp[]`, then `loopcmd` runs the child per range — this
  two-phase shape is what makes the elog model correct. x: range = match; y: range =
  gap `[op, match.q0)` plus the final tail (ecmd.c:867-885). Empty-match advance
  ecmd.c:873-878. `nest++` around the run.
- `linelooper` (bare `x`, ecmd.c:896-935): per-line ranges via `lineaddr`, clipped to
  the addressed range.
- `g_cmd` (ecmd.c:370-385): one `rxexecute` over the range, XOR `cmdc=='v'`; on pass,
  dot=range, run child once.

### 1.8 v1 scope evaluation

- **Include**: addresses, `a c i d s m t`, `x y g v` (+ bare-x linelooper), `=` (all
  three modes `=`, `=#`, `=+`, ecmd.c:694-766), `p` (pdisplay -> warning,
  ecmd.c:800-825), `\n` goto/extend (ecmd.c:769-788), `{ }` (edit.c:539-555 +
  ecmd.c:110-121), **`u`** (ecmd.c:536-553 — File.undo/redo + R-P9-10's show rule;
  count with sign, `u-1`=redo).
- **Defer**: `b B D e r f w` — namespace/disk/menu (ecmd.c:154-368, 556-570); `X Y` —
  cross-file loops (ecmd.c:937-1032); `< | >` — impossible pre-namespace (runpipe
  ecmd.c:591-654); `"` file-match parses but eval errors Unsupported; `'` mark —
  errors "can't handle '" exactly as acme (ecmd.c:1085-1087); `k n q !` — absent
  from acme. Deferred letters NOT in the v1 cmdtab => "unknown command %c"
  (v1-honest divergence, flagged).

## 2. Contract — files and frozen signatures

New directory `src/core/edit/`. Arena-allocated AST replaces the C's
cmdlist/addrlist/stringlist bookkeeping (edit.c:70-72, 346-359).

### 2.1 `src/core/edit/ast.zig` (~170) — THE one home for edit.h types

```zig
pub const Error = error{ Edit, OutOfMemory } || Text.Error; // editerror => error.Edit + Diag
pub const Diag = struct {
    buf: [256]u8, msg: []const u8 = "",
    pub fn set(d: *Diag, comptime fmt: []const u8, args: anytype) error{Edit}; // returns error.Edit
};
pub const String = std.ArrayList(u21);        // edit.h:9-14
pub const Range = File.Range;
pub const Address = struct { r: Range, t: *Text };            // R-P10-1 (t, not f)
pub const Addr = struct {                                     // edit.h:16-25
    kind: Kind, next: ?*Addr = null,
    pub const Kind = union(enum) {
        char: usize, line: usize,             // '#n' / 'n'
        re: []const u21, back_re: []const u21,// '/' '?'
        dot, end, mark, plus, minus, all,     // . $ ' + - '*'(synth)
        comma: ?*Addr, semi: ?*Addr,          // left side; null => line 0
        file: []const u21,                    // '"' — parses; eval defers (v1)
    };
};
pub const Cmd = struct {                                      // edit.h:33-46
    addr: ?*Addr = null, re: ?[]const u21 = null,
    arg: union(enum) { none, cmd: *Cmd, text: []const u21, mtaddr: *Addr } = .none,
    next: ?*Cmd = null,                       // {} chain
    num: i32 = 1, flag_g: bool = false, cmdc: u16,  // 'c'|0x100 = cd
};
pub const Defaddr = enum { none, dot, all };                  // edit.h:74-78
```

### 2.2 `src/core/edit/parse.zig` (~390) — the parser (edit.c:196-687)

```zig
pub const Parser = struct {
    arena: std.mem.Allocator, ed: *Editor, diag: *ast.Diag,
    s: []const u21, pos: usize = 0,
    pub fn init(arena, ed, diag, runes: []const u21) Parser;
    pub fn parsecmd(p: *Parser, nest: u32) ast.Error!?*ast.Cmd;  // edit.c:470-563
};
// module-private: getch/nextc/ungetch/getnum(signok)/skipbl (edit.c:196-249),
// simpleaddr/compoundaddr (edit.c:601-686), getregexp (edit.c:565-599),
// getrhs (edit.c:391-411), collecttext/collecttoken (edit.c:413-457),
// okdelim/atnl (edit.c:361-378).
```
`ed.edit_lastpat: std.ArrayList(u21) = .empty` new Editor field (deinit'ed); empty =>
"no regular expression defined".

### 2.3 `src/core/edit/Elog.zig` (~260) — the transcript (elog.c)

```zig
const Elog = @This();
pub const Record = union(enum) {              // dat.h:497-502 minus Filename
    insert: struct { q0: usize, nr: usize, text: []u8 },      // owned UTF-8
    delete: struct { q0: usize, nd: usize },
    replace: struct { q0: usize, nd: usize, nr: usize, text: []u8 },
};
allocator: std.mem.Allocator, ed: *Editor,    // ed for the Wsequence warning
log: std.ArrayList(Record) = .empty,
pending: ?Pending = null,                     // the open head being merged
warned: bool = false,                         // elog.c:17, reset by term
pub fn init(a, ed) Elog;  pub fn deinit(*Elog) void;
pub fn insert(e: *Elog, f: *File, q0: usize, text: []const u8, nr: usize) error{OutOfMemory}!void; // elog.c:160-191
pub fn delete(e: *Elog, f: *File, q0: usize, q1: usize) error{OutOfMemory}!void;                   // elog.c:193-213
pub fn replace(e: *Elog, f: *File, q0: usize, q1: usize, text: []const u8, nr: usize) error{OutOfMemory}!void; // elog.c:123-158
pub fn empty(e: *const Elog) bool;
pub fn term(e: *Elog) void;                   // elog.c:84-94 (discard, on editerror)
pub fn apply(e: *Elog, t: *Text) ast.Error!void; // elog.c:216-354
```
`apply`: flush pending; iterate REVERSE; first mutation => `t.file.mark(e.ed.seq)`;
min-clamp (textconstrain); mutate via `t.deleteRange/insertAt(..., tofile=true)`;
collapsed-caret q1-extension per elog.c:284-285/317-318; end-clamp per
elog.c:345-350. Merge thresholds `min_string=16`, `max_string=4096` runes (heuristics
only — the C's hard "replacement string too long" error elog.c:155-156 dropped,
flagged). Placement: on Ctx (R-P10-6).

### 2.4 `src/core/edit/cmd.zig` (~360) — dispatch + simple commands (ecmd.c)

```zig
pub const Ctx = struct {
    ed: *Editor, arena: std.mem.Allocator, diag: ast.Diag = .{},
    elog: Elog,
    addr: ast.Address = undefined,            // ecmd.c:20
    rx: *Regx,                                // ed.regx
    nest: u32 = 0,                            // ecmd.c:17
};
pub const Cmdtab = struct {
    cmdc: u16, text: bool = false, regexp: bool = false, addr: bool = false,
    defcmd: u8 = 0, defaddr: ast.Defaddr, count: u8 = 0, token: ?[]const u8 = null,
    fn_: *const fn (*Ctx, *Text, *ast.Cmd) ast.Error!bool,
};
pub const cmdtab = [_]Cmdtab{ /* §1.1 v1 rows, comptime */ };
pub fn lookup(cmdc: u16) ?*const Cmdtab;      // edit.c:459-468
pub fn cmdexec(x: *Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool; // ecmd.c:62-129
// handlers here: aCmd iCmd cCmd dCmd, mCmd(+t), pCmd(pdisplay->ed.warning),
// eqCmd (Buffer.lineOfRune; ecmd.c:663-766), nlCmd (addr.lineAddr + t.show),
// uCmd (File.undo/redo + t.show per R-P9-10), braces arm.
// Address-eval boundary: addr.eval(...) catch |e| return x.diag.set("{s}", .{addr.describe(e)});
```

### 2.5 `src/core/edit/loop.zig` (~300) — s + the loops

```zig
pub fn sCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool;
pub fn xCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool;  // x/y; re==null => linelooper
pub fn gCmd(x: *cmd.Ctx, t: *Text, cp: *ast.Cmd) ast.Error!bool;  // g/v
// private: looper, linelooper, loopcmd (pre-collect ranges, then run child)
```

### 2.6 `src/core/edit/edit.zig` (~200) — entry point (edit.c:151-194 single-threaded)

```zig
pub fn editcmd(ed: *Editor, ct: *Text, cmd: []const u8) void;
// decode UTF-8 -> arena []u21, append '\n'; Ctx+Parser up;
// loop { parsecmd -> cmdexec } (editthread collapses to this loop);
// on error.Edit: elog.term() + ed.warning("Edit: {s}\n", diag.msg);
// on OOM/Text.Error: same discard + a generic warning;
// success: if (!elog.empty()) elog.apply(body); then setSelect(q0,q1),
// scrDraw, Window.setTag1 (allupdate single-window collapse, edit.c:109-134).
pub fn builtin(ed, et, t, argt, flag1, flag2, arg) Text.Error!void; // exec.c:1128-1146
// chord arg (exec.getArg) wins over inline remainder; ed.seq += 1 (exec.c:1141
// unconditional, before editcmd); editcmd(ed, target-body, str). Never propagates
// error.Edit (already warned).
```
Exectab row per master R-P10-8.

### 2.7 Error model

No longjmp/threadexits: `editerror(fmt,...)` => `return x.diag.set(fmt, args)`
yielding `error.Edit`; OOM and Text.Error propagate in `ast.Error`. All diagnostics
surface as ONE `ed.warning("Edit: {s}\n", ...)`; the elog is discarded first so a
failed Edit applies NOTHING (edit.c:145-146).

## 3. Named tests (hand-derived; `edit:` prefix)

1. `edit: parser builds a/c/i text both forms` — `a/hi/` inline and
   `a\nhi\nthere\n.\n` block; block terminator `.\n` stripped.
2. `edit: getrhs escapes` — `s/a/\n/`=>NL; `s,a,\,x,` delim-escape; `s/a/\1\&/` rhs
   preserves `\1` and `\&` raw for s_cmd.
3. `edit: bad delimiter rejected` — `sxaxbx` => warning "Edit: bad delimiter x",
   buffer untouched.
4. `edit: unknown command` — `Edit z` => "unknown command z"; `Edit cd /tmp` =>
   unknown (the 0x100 case).
5. `edit: right brace without left` — `}` => error; unclosed `{` — pin actual
   behavior.
6. `edit: command takes no address` — `2u` errors (u defaddr=aNo).
7. `edit: bare d uses dot` — "abcdef" dot (2,4) `Edit d` => "abef", dot (2,2).
8. `edit: line address` — "a\nb\nc\n" `Edit 2d` => "a\nc\n", dot (2,2); `Edit 0a/X/`
   inserts at 0.
9. `edit: compound and whole-file` — `Edit ,d` empties; `Edit 1,2p` warns "a\nb\n";
   `Edit 2,1d` => "addresses out of order".
10. `edit: address past EOF` — `Edit 99d` => "address out of range" warning, no
    change; `#999` likewise.
11. `edit: implicit plus` — `Edit /b/2d` on "b\nx\ny\n" deletes "y\n".
12. `edit: empty file boundaries` — empty file: `Edit a/hi/` => "hi"; `Edit 1p`
    warns "".
13. `edit: a/i dot selects insertion` — "ab" dot(0,1) `Edit a/X/` => "aXb", dot
    (1,2); `i/Y/` => dot before.
14. `edit: c sets dot to new text` — `Edit 1c/zzz/` on "a\nb\n" => "zzzb\n"? — pin
    the exact result: line1 (0,2) replaced INCLUDING newline by "zzz", dot (0,3).
15. `edit: m and t` — "a\nb\n": `Edit 1m$` => "b\na\n"; `Edit 1t$` => "a\nb\na\n";
    `Edit 1m1` no-op self-move (ecmd.c:420-421); overlapping m errors "move overlaps
    itself" (ecmd.c:423).
16. `edit: = reports line and does not move dot` — "a\nb\nc\n" `Edit 2=` warns the
    line report (ecmd.c:705-727); `Edit ,=#` warns "#0,#6"-form; dot unchanged.
17. `edit: newline command navigates` — `Edit 3` shows/extends to line 3; pin the
    no-addr extension rule with dot mid-line (ecmd.c:774-785).
18. `edit: s first match only` — "abcabc" `,s/b/X/` => "aXcabc"; top-level
    "no substitution" when no match.
19. `edit: s global flag` — `,s/b/X/g` => "aXcaXc".
20. `edit: s nth and nth-plus-g` — `,s2/b/X/` => "abcaXc"; `,s2/b/X/g` on
    "b b b b" => first kept, rest replaced.
21. `edit: s groups ampersand` — `,s/(a)(b)/\2\1/g` on "abcabc" => "bacbac";
    `,s/b/[&]/g` => "a[b]ca[b]c"; `,s/b/\&/` => "a&cabc".
22. `edit: s empty match advance` — "abc" `,s/x*/-/g` => "-a-b-c-".
23. `edit: x deletes matches` — "abcabc" `,x/b/d` => "acac"; `,y/b/d` => "bb".
24. `edit: x default pattern is lines` — `,x d` empties "a\nb\nc\n" via linelooper.
25. `edit: x m$ reorders via elog` — "abcb" `,x/b/m$` => "acbb".
26. `edit: g and v guards` — "a\nab\nb\n" `,x/.*\n/g/a/d` => "b\n";
    `,x/.*\n/v/a/d` => "a\nab\n".
27. `edit: composed x g s` — `,x/.*\n/ g/ab/ s/b/X/` => only line 2 edited; s-miss
    inside loop silent (nest>0).
28. `edit: braces address once` — "a\nb\n" `Edit 2{a/X/ a/Y/}` => "a\nb\nXY"-form;
    pin record count == 1 (insert coalescing at same q0).
29. `edit: lastpat reuse` — `Edit s/a/x/ s//y/` hits `a` then the NEXT `a`; fresh
    editor `Edit s//x/` => "no regular expression defined"; cross-invocation reuse.
30. `edit: replace gap merge` — two s hits < 16 runes apart end as ONE Replace
    record (elog.c:137-149); adjacent deletes coalesce (elog.c:205-207).
31. `edit: one undo per Edit` — after `,s/b/X/g` (2 subs) one Undo restores exactly;
    `ed.seq` grew by exactly 1.
32. `edit: u command` — `Edit u` == Undo; `Edit u2` two steps; `Edit u-1` redoes.
33. `edit: error discards whole transaction` — first command buffers a replace,
    second errors => warning + buffer UNCHANGED + elog empty.
34. `edit: out-of-sequence warns once and proceeds` — descending addresses => one
    Wsequence warning, both applied, clamped sanely.
35. `edit: builtin row` — exectab has Edit, mark=false (exec.c:106); B2 "Edit ,d"
    via `execute` empties the body; chord argt overrides inline arg.

## 4. Seams (as resolved by the master)

- ast.zig owns the types (R-P10-1); Rangeset with Regx; addr.zig evaluation-only,
  enumerated errors translated at cmd.zig's boundary (R-P10-3).
- Edit exectab row: mark=false, seq++ in builtin, File.mark lazy in apply (R-P10-8).
- Elog.apply mutates ONLY via Text.insertAt/deleteRange(tofile=true); post-apply
  setSelect + scrDraw + setTag1.
- New Editor fields: edit_lastpat (10a-A2), regx (10a-A1) — R-P10-5.
- v1 collapses flagged: editthread/editerrc -> loop+error union; curtext -> the
  passed body Text; allwindows sweeps -> single window; Elog on Ctx; RBUFSIZE caps
  dropped; deferred letters => "unknown command".

## 5. Wave split (master mapping)

- 10a-A2 (opus): ast.zig + parse.zig + ed.edit_lastpat — tests 1-6 + shape pins.
- 10b-B2 (sonnet): Elog.zig — direct-call halves of tests 30/34.
- 10c-C1 (opus): cmd.zig + edit.zig + builtins row — tests 7-17, 32-35.
- 10d-D1 (opus): loop.zig — tests 18-31.
