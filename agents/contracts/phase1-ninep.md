# Phase 1 contract — ninep (9P2000 core)

Approved build spec for `src/ninep/`. Produced by outline agents O1 (msg/qid) and O2
(transport/errors/chan/server/client/mount), reconciled by the orchestrator. Build agents
implement these signatures and the named tests **as written**; deviations require
orchestrator sign-off, never silent edits. Specs: S-01 (9P), S-02 §1 (mount table),
S-07 §3/§4/§6 (idioms, budgets, import rules). ninep imports **std only** (S-07 §6);
ninep-internal file imports are fine.

C references (cite in doc comments as `file:line`):
- `~/proj/plan9/sys/include/fcall.h` (type codes 90–121, GBIT/PBIT LE 64–74, QIDSZ/NOTAG/NOFID/IOHDRSZ/MAXWELEM 6,76–88)
- `~/proj/plan9/sys/src/libc/9sys/convM2S.c`, `convS2M.c` (wire field order)
- `~/proj/plan9/sys/include/libc.h` (Qid 607–612, QT bits 570–576, open modes 545–549)
- `~/proj/plan9port/include/9p.h` (Srv 180–207, Fid 39–54, walk1/clone 203–204)
- `~/proj/plan9port/src/lib9p/srv.c` (dispatch 699–747, sversion 166–178, sauth 187–198,
  sattach 211–234, sflush 244–253, swalk 304–334, rwalk partial 338–358, sclunk 554)
- `~/proj/plan9/sys/man/5/flush`

## Reconciliation deltas (orchestrator rulings — override anything contrary below)

- **R1** The message type is named `Message` (not `Msg`).
- **R2** New file `src/ninep/stat.zig` (§4) — stat(5) codec; sub-wave 1a.
- **R3** `transport.zig` + `errors.zig` are built in **sub-wave 1a** (verbatim from §5/§6)
  so 1b agents compile against them.
- **R4** `Body.rstat = struct { stat: []const u8 }` stays opaque on the wire. The server
  framework encodes `Ops.stat`'s returned `stat.Stat` via stat.zig; `Client.stat` decodes
  the blob back to `stat.Stat` (strings borrow the client rbuf).
- **R5** `Ops` has **no** create/remove/wstat fields in v1 (msg has no such arms). The
  server answers those type codes via the `error.Unsupported` decode path: recover the
  tag from raw frame bytes `frame[5..7]` (LE; header is fixed `size[4] type[1] tag[2]`),
  then Rerror: tauth → "authentication not required"; tcreate/tremove/twstat →
  "permission denied"; unknown codes / Terror / malformed → "bad message" (tag
  recoverable iff `frame.len >= 7`, else drop the frame).
- **R6** Only sub-wave 1a touches `ninep.zig` (adds re-exports for its own files).
  1b agents must NOT edit `ninep.zig`, `build.zig`, or any file outside their assignment;
  the orchestrator adds 1b re-exports at merge and writes the acceptance test in Wave C.
- **R7** O2's OQ-1..OQ-9 resolved as recommended (accept transport/errors/stat files;
  adopt lib9p error strings; dir reads pass through to ops.read, fixtures return 0;
  bind = replace-in-place v1; boot owns root fids; WouldBlock + pump, SAB later; second
  Tversion rejected "bad message"; zero-copy views deferred). Spec amendments (S-07 §4
  file list, S-01 §5 strings) happen at phase end with user sign-off.

## Sub-wave assignments

- **1a (opus, serial)**: `qid.zig` (fix Type layout), `msg.zig`, `stat.zig`,
  `transport.zig`, `errors.zig`, `ninep.zig` re-exports. Test plans §T-qid/§T-msg/§T-stat.
- **1b (concurrent worktrees off integration@1a)**: B1 opus `server.zig` (§7, tests
  §T-server); B2 opus `client.zig` (§8, §T-client); B3 sonnet `chan.zig` (§6, §T-chan);
  B4 sonnet `mount.zig` (§9, §T-mount).
- **Wave C (orchestrator)**: merges, re-exports, acceptance test §10.

---

## §1 `qid.zig` — file-as-struct `Qid` (~80 lines)

Keep field names `path`, `vers`, `qtype`. **Fix the stub's Type layout** (QTTMP is 0x04,
bit 2 — libc.h:575; the stub wrongly put `tmp` at bit 0).

```zig
pub const wire_size: usize = 13;                    // [fcall.h:80 QIDSZ]
pub const Type = packed struct(u8) {                // [libc.h:570-576]
    _pad: u2 = 0,          // bits 0-1 unused in 9P2000
    tmp: bool = false,     // 0x04 QTTMP
    auth: bool = false,    // 0x08 QTAUTH
    mount: bool = false,   // 0x10 QTMOUNT
    excl: bool = false,    // 0x20 QTEXCL
    append: bool = false,  // 0x40 QTAPPEND
    dir: bool = false,     // 0x80 QTDIR
};
path: u64,
vers: u32 = 0,
qtype: Type = .{},
pub fn encode(self: Qid, buf: *[wire_size]u8) void; // type[1] vers[4le] path[8le]
pub fn decode(buf: *const [wire_size]u8) Qid;
```

Infallible fixed-size encode/decode; caller (msg.zig) does bounds checks. Wire order is
**type byte first** (convM2S.c gqid), NOT the C struct declaration order. Keep the
existing `test "qid dir bit"`.

## §2 `msg.zig` — codec, namespace module (~400 lines + tests)

Imports `std` + `qid.zig`. Constants:

```zig
pub const version9p = "9P2000";
pub const MAXWELEM = 16;                 // [fcall.h:6]
pub const NOTAG: u16 = 0xFFFF;           // [fcall.h:86]
pub const NOFID: u32 = 0xFFFF_FFFF;      // [fcall.h:87]
pub const IOHDRSZ = 24;                  // [fcall.h:88]
pub const header_size: usize = 7;        // size[4] type[1] tag[2]
pub const min_msize: u32 = 8192;         // S-01 §1
pub const default_msize: u32 = 65536;
pub const OREAD: u8 = 0; pub const OWRITE: u8 = 1; pub const ORDWR: u8 = 2;
pub const OEXEC: u8 = 3; pub const OTRUNC: u8 = 0x10;   // [libc.h:545-549]
```

`Kind = enum(u8)` with ALL 9P2000 codes tversion=100 … rwstat=127, **exhaustive** (no
`_`); unknown bytes rejected in decode before `@enumFromInt`. terror=106 is illegal on
the wire.

```zig
pub const DecodeError = error{ BadMessage, Unsupported };
pub const EncodeError = error{ ShortBuffer, BadMessage };

pub const Message = struct { tag: u16, body: Body };

pub const Body = union(enum) {   // inferred tag, NOT union(Kind)
    tversion: Version, rversion: Version,
    tattach: struct { fid: u32, afid: u32, uname: []const u8, aname: []const u8 },
    rattach: struct { qid: Qid },
    rerror: struct { ename: []const u8 },
    tflush: struct { oldtag: u16 }, rflush: void,
    twalk: Twalk, rwalk: Rwalk,
    topen: struct { fid: u32, mode: u8 },
    ropen: struct { qid: Qid, iounit: u32 },
    tread: struct { fid: u32, offset: u64, count: u32 },
    rread: struct { data: []const u8 },              // count derived from data.len
    twrite: struct { fid: u32, offset: u64, data: []const u8 },
    rwrite: struct { count: u32 },
    tclunk: struct { fid: u32 }, rclunk: void,
    tstat: struct { fid: u32 },
    rstat: struct { stat: []const u8 },              // opaque blob (R4)

    pub const Version = struct { msize: u32, version: []const u8 };
    pub const Twalk = struct {
        fid: u32, newfid: u32, nwname: u16, wname: [MAXWELEM][]const u8,
        pub fn names(self: *const Twalk) []const []const u8;
    };
    pub const Rwalk = struct {
        nwqid: u16, wqid: [MAXWELEM]Qid,
        pub fn qids(self: *const Rwalk) []const Qid;
    };
    pub fn kind(self: Body) Kind;                    // exhaustive switch
};

pub fn decode(buf: []const u8) DecodeError!Message;
pub fn encodedSize(m: *const Message) usize;
pub fn encode(m: *const Message, buf: []u8) EncodeError!usize;
```

Rules the implementer must not get wrong:
1. Little-endian everywhere (GBIT/PBIT).
2. `size[4]` includes its own 4 bytes; min legal message 7 bytes.
3. Strings: `len[2]` + len UTF-8 bytes, no NUL. Decode never mutates; returns sub-slices.
4. Qid 13 bytes `type/vers/path`.
5. Twalk: reject nwname > 16 at decode AND encode; nwname=0 legal (clone).
6. Rwalk: nwqid ≤ 16; nwqid < nwname is protocol-legal partial (msg does not police).
7. Rread `count[4] data[count]`; Twrite `fid[4] offset[8] count[4] data[count]`; check
   count against remaining buffer before slicing.
8. Rstat: `nstat[2]` + opaque bytes (blob has its own internal leading size[2]).
9. `decode` requires `buf.len ==` size field exactly; trailing bytes ⇒ BadMessage.
10. Tags verbatim, NOTAG convention not enforced here.
11. Valid-but-unimplemented codes (tauth/rauth, tcreate/rcreate, tremove/rremove,
    twstat/rwstat) ⇒ `error.Unsupported`; terror ⇒ BadMessage.
12. Zero-copy decode: all slices alias `buf`; document lifetime.
13. encode: string len > 0xFFFF, data.len > maxInt(u32), nwname/nwqid > 16 ⇒ BadMessage;
    buf too small ⇒ ShortBuffer.

Private suggested: ~40-line cursor with get/put 8/16/32/64/bytes/string/qid helpers.
If the file overruns ~460 lines total, extract the cursor to `src/ninep/wire.zig`
(ninep-internal) rather than splitting the message switch.

## §3 Test plan — qid & msg (§T-qid, §T-msg)

qid: `"qid type bits match Plan 9"` (dir→0x80 … tmp→0x04, `Type{}`→0x00);
`"qid wire layout"` (path=0x0102030405060708, vers=0xAABBCCDD, dir+append ⇒
`[0]==0xC0`, vers LE, path LE); `"qid round-trip"` (that value, path=0, max values);
keep `"qid dir bit"`.

msg (names as given):
- **RT-1 "round-trip every mandatory message"** — table-driven over all 19 bodies with
  the exact values from the O1 contract (tversion NOTAG/65536/"9P2000"; tattach
  uname="glenda" aname=""; rerror "file does not exist"; twalk ["dev","mouse"];
  topen mode 0x12; tread offset=0xFFFF_FFFF_0000_0001; rread "hello\x00world";
  twrite data {0,1,2,255}; rstat 49 arbitrary bytes; etc.). Assert encode() ==
  encodedSize() and deep-equal after decode.
- **RT-2 "zero-copy decode aliases input"** — rread.data.ptr and twalk wname[0].ptr lie
  within the input buffer range.
- **ERR-1 "decode: truncated at every offset"** — encoded tattach, every prefix len
  0..n-1 ⇒ BadMessage.
- **ERR-2 "decode: size field mismatch"** — size+1 (short buffer) and one trailing
  garbage byte ⇒ BadMessage.
- **ERR-3 "decode: oversize string length"** — version strlen field 0xFFFF with 6 bytes
  following ⇒ BadMessage; rread count 0xFFFF_FFFF ⇒ BadMessage.
- **WALK-1 "walk: zero names"** — twalk nwname=0 and rwalk nwqid=0 round-trip.
- **WALK-2 "walk: MAXWELEM ok, 17 rejected"** — 16 names round-trip; hand-crafted wire
  nwname=17 ⇒ decode BadMessage; nwname=17 value ⇒ encode BadMessage; same for rwalk.
- **ERR-4 "decode: unknown and unsupported codes"** — type 99,128 ⇒ BadMessage; 106 ⇒
  BadMessage; 102,114,122,126 ⇒ Unsupported.
- **UTF-1 "rerror: UTF-8 ename"** — "fichier inexistant — файл" byte-exact round-trip.
- **TAG-1 "tags: NOTAG and boundaries"** — NOTAG, 0, 0xFFFE round-trip verbatim.
- **ENC-1 "encode: ShortBuffer"** — encodedSize-1, 0-byte, 6-byte buffers ⇒ ShortBuffer.

## §4 `stat.zig` — stat(5) codec (new, ~100 lines) (§T-stat)

File-as-struct `Stat`. Wire (all LE, strings s = len[2]+bytes):
`size[2] type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8] name[s] uid[s] gid[s] muid[s]`
where `size` counts the bytes AFTER itself. STATFIXLEN = 49 with all-empty strings
[fcall.h:82-84].

```zig
pub const DMDIR: u32 = 0x8000_0000;
ktype: u16 = 0, kdev: u32 = 0,        // "for kernel use"
qid: Qid, mode: u32, atime: u32 = 0, mtime: u32 = 0, length: u64,
name: []const u8, uid: []const u8 = "snarf", gid: []const u8 = "snarf",
muid: []const u8 = "snarf",
pub fn encodedSize(self: *const Stat) usize;
pub fn encode(self: *const Stat, buf: []u8) error{ShortBuffer,BadMessage}!usize;
pub fn decode(buf: []const u8) error{BadMessage}!Stat;   // zero-copy strings
```

Tests §T-stat: `"stat round-trip"` (dir and file variants, incl. non-default uid);
`"stat size field"` (empty-string encode == 49 bytes, size field == 47);
`"stat truncated"` (every prefix ⇒ BadMessage); `"stat mode dir bit"` (DMDIR ↔
qid.qtype.dir consistency is caller policy, codec passes verbatim).

## §5 `transport.zig` — keystone interface (~50 lines, verbatim)

Implement exactly as specified by O2 (§1 of its report): `pub const Error = error{
WouldBlock, Closed, FrameTooBig, BadFrame };` and `pub const Transport = struct { ctx:
*anyopaque, vtable: *const VTable, ... }` with `writeMsg(frame []const u8) Error!void`,
`readMsg(buf []u8) Error![]u8`, `close() void` and the five semantic guarantees
(intact/ordered/exactly-once; writeMsg validates len>=7 and prefix==len ⇒ BadFrame;
too-small readMsg buf ⇒ FrameTooBig without consuming; close idempotent, peer drains
then Closed; zero-copy deferred). Doc comments cite S-01 §3.1/§3.2.

## §6 `chan.zig` — SPSC ring + Pipe (~200 lines) (§T-chan)

Implement O2's §3 exactly: `Ring` over caller-supplied `[]u8` (monotonic wrapping
head/tail, capacity < 2^31, works for non-power-of-2), `init/readable/writable/push/pop/
peek/close`; `Pipe` allocator-backed, `init(allocator, capacity) !*Pipe` (heap for stable
ctx pointers), `deinit`, `clientEnd()/serverEnd() Transport`. Frame-atomic writeMsg
(whole frame or WouldBlock); readMsg peeks 4-byte size, validates 7..capacity ⇒ BadFrame,
buf too small ⇒ FrameTooBig (frame stays queued), pops whole frame; close closes tx ring
only. Tests §T-chan (10 named cases from O2's plan: round trip, wrap-around, full/empty,
peek, loopback intact ×2 directions, empty WouldBlock, full WouldBlock atomic,
FrameTooBig both sides, BadFrame both cases, close semantics).

## §7 `server.zig` — lib9p-shaped Srv (~350 lines) (§T-server)

Implement O2's §4 exactly, with rulings R4/R5 applied:

- `Fid { fid: u32, qid: Qid, omode: ?u8 = null, ctx: ?*anyopaque = null, uname: []u8 }`.
- `Ops` vtable: `attach`, `walk1`, `clone` (?), `open`, `read`, `write`, `clunk` (?),
  `stat` (returns `stat.Stat` — R4), `flush` (?). NO create/remove/wstat (R5). All fns
  take `(ctx: *anyopaque, srv: *Server, fid: *Fid, ...)` and return
  `errors.OpError!...`. `*Fid` valid only during the call; persist via fid.ctx.
- `Server { allocator, tport: Transport, ops: *const Ops, ctx, fids:
  AutoHashMapUnmanaged(u32, Fid), msize: u32 = 0, max_msize, rbuf, wbuf }`;
  `init/deinit`, `step() Error!Progress {idle,handled}`, `poll() Error!usize`,
  `lookupFid`.
- Dispatch rules (each cites its srv.c anchor): pre-version ⇒ "bad message"; Tversion
  clamps msize to [8192, max_msize], non-"9P2000" prefix ⇒ Rversion "unknown", msize<8192
  ⇒ "bad message", clears fid table; second Tversion ⇒ "bad message"; Tattach dup fid ⇒
  "fid in use", afid != NOFID ⇒ "authentication not required"; Twalk: unknown fid,
  open fid ("cannot clone open fid"), non-dir with names ("walk in non-directory"),
  newfid dup ("fid in use"), walk1 loop ≤16, first-name failure ⇒ Rerror, later-name
  failure ⇒ partial Rwalk with gathered qids and tentative newfid removed, 0-name clone;
  Topen: OEXEC→OREAD, dir+write/OTRUNC ⇒ "file is a directory", sets omode, Ropen
  iounit=0; Tread/Twrite: open + direction checks ⇒ "permission denied", clamp count to
  msize-IOHDRSZ; Tclunk: op notify then remove unconditionally; Tflush ⇒ always Rflush
  (v1 synchronous, nothing pending; wait-queue slots in at the Tread arm later);
  Tstat ⇒ encode returned Stat via stat.zig into wbuf, reply Rstat; decode
  error.Unsupported ⇒ R5 tag-recovery replies; BadMessage ⇒ "bad message" if
  frame.len>=7 else drop. All strings via `errors.errorString`.

Tests §T-server: the 17 named cases from O2's plan (pre-version reject, msize clamp ×4,
second-version reject, attach root, dup fid, walk existing/missing/partial/unknown-fid/
non-dir, open-read-write-clunk happy path, wrong-direction read, clunk-frees-fid-reuse,
unknown-fid read, flush idle ⇒ Rflush, tauth/tcreate/tremove/twstat defaults, stat
name+length). Use a private in-file TestTransport (ArrayList frame queues) + raw
msg.encode frames + a private TestTree fixture — NO dependency on chan.zig or client.zig.

## §8 `client.zig` — synchronous client (~300 lines) (§T-client)

Implement O2's §5 exactly: `Client { allocator, tport, msize=0, max_msize, next_tag=0,
next_fid=0, free_fids, fids: AutoHashMapUnmanaged(u32, Qid), rbuf, wbuf, pump: ?Pump,
last_rerror_buf: [128]u8, last_rerror_len: u8 }`; `Pump { ctx, run }` invoked on every
transport WouldBlock before retrying (else WouldBlock surfaces);
`Error = errors.OpError || transport.Error || error{OutOfMemory, ProtocolError,
MessageTooBig}`. Methods: `init/deinit`, `version(want_msize) !u32` (NOTAG, proposes
min(want,max), stores negotiated, resets tag/fid state, "unknown" ⇒ ProtocolError),
`attach(uname,aname) !FidInfo` (afid=NOFID), `walk(fid, names) !FidInfo` (clone+walk,
chunks by 16, partial Rwalk ⇒ error.FileDoesNotExist + fid recycled), `open(fid,mode)
!Qid`, `read(fid,offset,buf) !usize` (count=min(buf.len, msize-IOHDRSZ), 0=EOF),
`write`, `clunk` (frees fid number even on Rerror), `stat(fid) !stat.Stat` (borrows
rbuf — R4), `flushTag(oldtag)`, `allocFid/freeFid`, `rpc(t: Message) !Message` (tag
match ⇒ else ProtocolError; Rerror ⇒ errorFromString, .Other copies raw string to
last_rerror_buf), `lastErrorString()`. Tag alloc wraps 0..0xFFFE skipping NOTAG.

Tests §T-client: the 9 named cases from O2's plan (version negotiation + "unknown",
attach, walk full, partial ⇒ error + fid recycled, tag wrap skips NOTAG, tag mismatch,
Rerror mapping known + .Other with lastErrorString, read clamps count, fid reuse after
clunk). Use a private scripted transport (canned R-frames) — NO dependency on server.zig
or chan.zig.

## §9 `mount.zig` — ordered mount table (~200 lines) (§T-mount)

Implement O2's §6 exactly: `Target { client: *Client, root_fid: u32 }`; `Entry { prefix:
[]u8 (owned canonical), target }`; `Resolved { entry: *const Entry, remainder: []const
u8 }`; `Error = error{NotMounted, MountExists, BadPath, OutOfMemory}`; `Namespace {
allocator, entries: ArrayList(Entry) }` with `init/deinit` (clunks nothing — boot owns
root fids), `mount` (exact dup ⇒ MountExists), `bind` (replace-or-insert), `resolve`
(longest-prefix on COMPONENT boundaries: "/mnt/host" never matches "/mnt/hostx";
relative path ⇒ BadPath; remainder has leading '/' stripped, "" on exact),
`list(w: *std.Io.Writer)` ("mount <prefix>\n" per entry, insertion order). Prefix
canonicalization: absolute, trailing '/' stripped (except "/"), no empty/"."/".."
components ⇒ BadPath.

Tests §T-mount: the 8 named cases from O2's plan (root fallback, nested longest-prefix
×4 paths, non-prefix trap, exact-match empty remainder, duplicate mount, bind rebinding,
bad/normalized paths, list format). Use `var c: Client = undefined; &c` for pointer
identity — no live transport.

## §10 Acceptance test (Wave C, orchestrator, in `ninep.zig`)

`test "phase-1: client reads a served file over a chan pipe"`: TestTree fixture (root
dir path=1; `index` path=2 "hello, snarf\n" read-only; `notes` path=3 writable
ArrayList-backed; `sub/` path=4 with `leaf` path=5 "leaf\n"); Pipe(16384); Server on
serverEnd (max 8192); Client on clientEnd with pump = srv.poll; then: version 8192 ⇒
8192; attach ⇒ dir root; walk index ⇒ path 2; open OREAD; full read ⇒ "hello, snarf\n";
offset read 7/5 ⇒ "snarf"; EOF at 13 ⇒ 0; clunk ⇒ server fid count 1; walk missing ⇒
FileDoesNotExist; nested walk sub/leaf ⇒ path 5, read "leaf\n"; write path on notes
(ORDWR, write "abc"@0 ⇒ 3, read back "abc"); flushTag(12345) clean; mount "/" + resolve
"/sub/leaf" ⇒ remainder "sub/leaf", walk it, read "leaf\n".

## Hard gates for every build agent

- Zig 0.16 (`zig version` = 0.16.0). `zig build test --summary all` green and
  `zig fmt --check build.zig src/ tools/` clean IN YOUR WORKTREE before returning.
- Only touch your assigned files (R6). No new deps (ADR-0002). No globals; allocators
  explicit; tagged unions; colocated tests; ~400-line soft cap (see §2 overflow rule).
- Cite the pinned C in doc comments (`srv.c:304`, `convM2S.c:122`, …).
- If a contract signature cannot work as written, STOP and report the conflict — do not
  redesign unilaterally, do not weaken a test.
