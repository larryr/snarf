# Phase 15 — ADR-0005 native-host SPIKE: the core in a real window through `devdraw`

Branch `phase15` (worktree `../snarf-wt/phase15`), based on `main` after 14b.
Contract: [`agents/contracts/phase15-native-spike.md`](../contracts/phase15-native-spike.md).
Decision under test: [ADR-0005](../../docs/spec/adr/0005-two-hosts-one-core.md) (two hosts,
one core), R-OV-09.

## The finding first: R-P15-2 PASSED — zero adapter-forced changes

```
$ git diff main --stat -- src/core src/draw src/ninep
 src/core/Load.zig     |  12 ++-
 src/core/core.zig     |   1 +
 src/core/expand.zig   |  15 ++--
 src/core/look.zig     |  24 ++++--
 src/core/openfile.zig |  11 +--
 src/core/warp.zig     | 202 +++++++++++++++++++++++++++++++++++++++++++
 6 files changed, 243 insertions(+), 22 deletions(-)

$ git diff main -- src/draw src/ninep        # (empty)
```

`src/draw` and `src/ninep` are **byte-identical to `main`**. Every changed line in
`src/core` is the warp feature ADR-0005 itself ordered (R-P15-3 / the R-EDIT-25
amendment) — plumbing `e->jump` from `look.c:735/741` to the two surviving `moveto`
sites, plus the new `core/warp.zig` and its `core.zig` re-export. **Nothing in the core
had to change to make `devdraw` work.** The boundary claim of R-OV-03 now has a second,
independent implementation.

`core`, `draw` and `ninep` are the SAME `b.addModule` objects the wasm executable links
(`build.zig`): no `-D` fork, no host switch, no conditional compilation inside them.

## Files

| File | Pre-test lines | What |
|---|---|---|
| `src/host/host.zig` | 32 | module root: `wsys`, `Conn`, `dev_draw`, `dev_input` |
| `src/host/devdraw/wsys.zig` | 394 | the `drawfcall` codec: all 17 message pairs, BE framing, `len[4]` strings |
| `src/host/devdraw/Conn.zig` | 527 | one `devdraw` connection: spawn, `poll(2)`, tag mux, the two long polls, `Script` double |
| `src/host/devdraw/dev_draw.zig` | 303 | 9P `Ops` for `/dev/draw` — `data` → `Twrdraw`, `ctl` → the 144-byte line |
| `src/host/devdraw/dev_input.zig` | 267 | 9P `Ops` for `/dev/{mouse,kbd,cursor,snarf,label}` — **mouse WRITE → `Tmoveto`** |
| `src/main_native.zig` | 241 (was 11) | the native host loop |
| `src/core/warp.zig` | 104 | the warp request: `/dev/mouse` write, all failures swallowed |
| `build.zig` | +30 | `host` module + test root; `zig build native` → `snarf-native` |

(File totals including tests: wsys 492, Conn 717, dev_draw 410, dev_input 354, warp 202,
main_native 241, host 32. `Conn.zig` at 527 pre-test lines is over the ~400-line soft cap;
its seam is `spawn`+transport vs. the tag mux. Flagged for the debt pass rather than split
mid-spike.)

Contract §3 items and where they live:

* §3a `src/host/devdraw/` — as above; `wsys.zig` is the codec, `Conn.zig` the connection
  (file-as-struct split so neither file exceeds the cap; `wsys.Conn` re-exports it, which
  is the name the contract and the test writer use).
* §3b the warp — `src/core/warp.zig` (request) + `src/host/devdraw/dev_input.zig`
  (honour) + `src/dev/input.zig` (refuse). `/dev/cursor` IS in scope after all: it was
  ~10 lines (`Tcursor`, which devdraw scales itself, `srv.c:258-266`).
* §3c acceptance — 4, 5 and 6 below; 1–3 are Larry's manual pass.
* §3d docs — ADR-0005 status + a "Spike results" section, R-02 v6 (R-EDIT-25 amended),
  S-04 §1 (the warp table), S-07 §6 (`host/*`).

## What `Trddraw` returns after `Tinit` — verified

**Nothing by itself.** plan9port's `devdraw` has no file system: `Trddraw` returns
whatever the last draw READ-VERB queued into `client->readdata` (`devdraw.c:617-637`),
and after a bare `Tinit` that is empty, i.e. `Rerror "no draw data"`.

The connection line is produced by two verbs, exactly as libdraw's `getimage0` does
(`init.c:129-152`):

```
Twrdraw "JI"            J = install the screen image as id 0   (devdraw.c:918)
                        I = queue that image's info            (devdraw.c:930)
Trddraw 144          →  "          1           0    x8r8g8b8           0 …"
```

144 bytes = 12 fields of `%11d ` (`devdraw.c:945-947`) — the same shape and the same
length `draw.Display.parseConnInfo` already parsed, so the client needed no change. A
RE-read (the resize path) must free image 0 first (`f` id 0, little-endian per
`BGLONG`, `draw.h:528`) or `J` fails `Eimageexists` (`devdraw.c:920`). All of this is
`dev_draw.refreshLine()`; nothing above `/dev/draw` sees it.

## Did `zig build run-native` open a window? — YES, and it drew the boot scene

Run on larry's Mac with `PLAN9=~/proj/plan9port` and `DEVDRAWTRACE=1` (devdraw's own
message trace, `srv.c:60-62`):

```
<- tag=3  Tinit label='snarf' winsize='1024x768'      -> Rinit
<- tag=4  Tlabel label='snarf'                        -> Rlabel
<- tag=5  Twrdraw 2 "JI"                              -> Rwrdraw 2
<- tag=6  Trddraw 144                                 -> Rrddraw 144
          "  1  0  x8r8g8b8  0  0  0  1024  740  0  0  1024  740"
<- tag=7..9   Twrdraw 51 ×3      the white/black solids + the font image
<- tag=10     Twrdraw 3909       the subfont pixels
<- tag=12     Twrdraw 7119       the font glyph table
<- tag=13..33 Twrdraw ×20        the acme palette, the two columns, the tags
<- tag=1  Trdmouse                 ← the standing mouse poll, armed
<- tag=2  Trdkbd4                  ← the standing kbd poll, armed
<- tag=35 Twrdraw 1923             ← the `/` directory window's listing, one
                                     frame later (the async Load completing)
```

`ps` confirms the child: `/Users/larry/proj/plan9port/bin/devdraw snarf (devdraw)`. The
process stayed alive and idle past 4 s with no error output, and was killed.

The window's client area is **1024×740** (devdraw trimmed the requested 768 for the
title bar) and the whole boot scene — two columns, the row tag, the `/` directory window
with `dev/ mnt/` — was drawn into it.

**Screenshot NOT obtained, and it is an environment limit, not a defect:**
`screencapture` from this session returns only the desktop. Verified against the
baseline — plan9port's OWN `acme`, run the same way, is equally invisible to
`screencapture` here — so it is the terminal's screen-recording permission, not
`snarf-native`. The `DEVDRAWTRACE` transcript above is the oracle.

## Deviations, with cites

1. **No reader thread** (contract §3a asked for one). Zig 0.16 removed
   `std.Thread.Mutex`/`Condition`; the replacements `std.Io.Mutex`/`Io.Condition` need
   an `Io` at every lock and have no timed wait. `Conn` is single-threaded over
   `poll(2)`, which is libdraw's own `canreadfd` (`drawclient.c:470-490`) used as the
   loop's wait rather than as a peek. The whole device stack stays on one thread, which
   is what the 9P servers above it require.
2. **`drawfcall` strings are `len[4] bytes`, not `len[2]`** as the contract §1 table
   said: `_stringsize` is `4+strlen(s)` and `PUTSTRING` uses `PUT` (4 bytes), not `PUT2`
   (`drawfcall.c:9-37`).
3. **`Tinit` carries `winsize[s] label[s]` only** — no `font[s]`. The header comment
   block in `drawfcall.h` advertises a third string that `sizeW2M`/`convW2M` never encode
   (`drawfcall.c:80-84`, `:177-181`).
4. **A bug in the reference codec, reproduced bug-for-bug.** `Rrdmouse` writes `msec` at
   offset 18 and then stamps `resized` at offset **19**, inside `msec`'s own four bytes
   (`drawfcall.c:132-137` / `:237-242`); the byte at 22 that `sizeW2M` reserves is never
   written. Encoder and decoder agree, so the wire is self-consistent, but bits 16..23
   of every timestamp are destroyed. `Conn` therefore timestamps mouse records from the
   local monotonic clock and ignores `Rrdmouse.msec` — which matters, because `msec`
   drives double-click and chord timing in `core/Gesture.zig`.
5. **`devdraw` must be spawned with `NOLIBTHREADDAEMONIZE=1`** or libthread daemonizes
   and the pipe goes nowhere (`drawclient.c:110-123`, `libthread/thread.c:729`).
6. **No exclusive-open on the native `/dev/mouse`.** The browser device refuses a second
   `mouse` open; the native one must not, because the warp needs a write fid while the
   host loop holds the standing read fid. Plan 9's own `/dev/mouse` is one read-write
   file acme does both through (`mouse.c:9-12` writes the very fd `readmouse` reads).
7. **`Rerror "permission denied"`, not a bespoke "warp unsupported" string,** for the
   browser's refusal (contract §3b suggested the latter). A new string means a new
   member in `ninep/errors.zig` — and R-P15-2 forbids touching `ninep`. "permission
   denied" is also the kernel's own text for a device that will not take a write.
8. **No `ctl` file on the native input device.** There is no profile machinery on this
   host (devdraw delivers real three-button records; its Cocoa layer already maps
   Option→B2 and Cmd→B3), so there is nothing for `profile <name>` to select.

## The warp, precisely (R-P15-3)

The two `moveto` sites acme still has that Snarf reaches, each re-read in
`~/proj/plan9port/src/cmd/acme/`:

| C | Snarf |
|---|---|
| `look.c:219` — a search hit, `if(search(...) && e.jump)` | `core/look.zig literal` → `warp.toSelection(ed, ct)` |
| `look.c:897` — after `openfile`, `if(e->jump)` | `core/Load.zig addressAndShow` → `warp.toSelection(ed, t)` |

Both use `addpt(frptofchar(&fr, fr.p0), Pt(4, font->height-4))`, which is
`warp.toSelection`. `e->jump` itself is now plumbed from `look.c:735` (`= TRUE`) and
`look.c:741-742` (a bare click inside a TAG's selection sets it FALSE) — a tweak phase 9
could correctly drop as unobservable and that is now observable.

NOT restored (layout/scroll gestures, out of scope on both hosts): `cols.c:154`,
`cols.c:232`, `scrl.c:127`, `util.c:397`, `wind.c:132`, `wind.c:214`, `wind.c:221`,
`wind.c:294`.

## Public API for the test writer

**`host.wsys`** (`src/host/devdraw/wsys.zig`) — pure, allocation-free:

```zig
pub const Kind = enum(u8) { rerror = 1, trdmouse = 2, ... rrdkbd4 = 33 };
pub const Msg  = union(Kind) { ... };          // slice payloads borrow the frame
pub const Point / Rect / Mouse / Cursor / Cursor2
pub const Error = error{ ShortMessage, ShortBuffer, BadMessage };
pub const max_msg: usize = 4 << 20;            // MAXWMSG
pub const header_len: usize = 6;               // size[4] tag[1] type[1]

pub fn sizeOf(m: Msg) usize;
pub fn encode(m: Msg, tag: u8, buf: []u8) Error!usize;
pub fn frameLen(buf: []const u8) Error!usize;  // the framer's "how long is this?"
pub fn decode(frame: []const u8) Error!Msg;    // one COMPLETE frame
pub fn tagOf(frame: []const u8) u8;
```

Round-trip note for T1: `.rrdmouse` does **not** round-trip `msec` — byte 1 of `msec`
is `resized` (deviation 4). Assert `msec` with that byte replaced, as
`wsys.zig`'s own test does.

**`host.Conn`** (`src/host/devdraw/Conn.zig`) — file-as-struct:

```zig
pub const mouse_tag: u8 = 1;      // the standing Trdmouse
pub const kbd_tag:   u8 = 2;      // the standing Trdkbd4
                                  // rpc tags rotate 3..255
pub const Error = error{ Closed, DrawError, Timeout, Protocol, WriteFailed } || Allocator.Error;
pub const Sink = struct { ctx: *anyopaque, writeAll: *const fn (*anyopaque, []const u8) anyerror!void };
pub const MouseEvent = struct { x: i32, y: i32, buttons: u32, msec: u32, resized: bool };

pub fn init(gpa) Conn;
pub fn deinit(*Conn) void;
pub fn spawn(*Conn, io: std.Io, env: *const std.process.Environ.Map, SpawnOptions) !void;
pub fn devdrawPath(gpa, env) ![]u8;            // $DEVDRAW, else $PLAN9/bin/devdraw, else PATH
pub fn send(*Conn, tag: u8, Msg) Error!void;
pub fn rpc(*Conn, Msg) Error!Reply;            // Reply{ .msg, .frame }; call .deinit()
pub fn armMouse(*Conn) Error!void;
pub fn armKbd(*Conn) Error!void;
pub fn poll(*Conn, timeout_ms: i32) Error!bool;   // -1 blocks, 0 peeks
pub fn nextMouse(*Conn) ?MouseEvent;
pub fn nextRune(*Conn) ?u32;
pub fn isClosed(*Conn) bool;
pub fn lastError(*const Conn) []const u8;
// convenience: wrDraw, rdDraw, moveTo, label, cursor, rdSnarf, wrSnarf
```

**The scripted double** (no child process, no thread — this is how T2/T4/T6/T7 run):

```zig
var script: Conn.Script = .{ .gpa = testing.allocator };
defer script.deinit();
var c = Conn.init(testing.allocator);
defer c.deinit();
c.useSink(script.sink());
script.conn = &c;                 // enables auto-replies

try script.expect(.{ .rwrdraw = 2 });   // queue a reply; the tag is stamped for you
_ = try c.wrDraw("JI");
try testing.expectEqualStrings("JI", script.frame(0).?.msg.twrdraw);
try testing.expectEqual(@as(usize, 1), script.count());
```

`script.expect(m)` queues a reply template that the NEXT outbound frame is answered
with (`replymsg`'s tag discipline, `srv.c:326-336`). With no template queued, nothing is
answered — then hand-feed instead: `c.feedMsg(msg, tag)` or `c.feed(raw_bytes)` (which
accepts a frame split across calls). `c.closed = true` simulates the peer exiting.

CAUTION: `Conn.rpc` skips a tag whose slot still holds an unclaimed reply, so
pre-feeding two replies for two *successive* rpcs does not work — use `script.expect`.

**`host.dev_draw.DevDraw9`**:

```zig
pub const conn_line_len: usize = 144;
pub const refresh_rec_len: usize = 16;
pub const Rect = struct { x0, y0, x1, y1: i32 };
pub fn init(conn: *Conn) DevDraw9;
pub fn refreshLine(*DevDraw9) !void;          // f? + J + I + Trddraw
pub fn noteResize(*DevDraw9, Rect) void;      // the next `refresh` read reports it
pub fn screenRect(*const DevDraw9) Rect;
pub const ops: ninep.server.Ops = ...;        // `read`/`write` are NOT optional fields
```

Tree: `new`, `<N>`/`ctl`, `<N>`/`data`, `<N>`/`refresh` where `N` is field 0 of the line
(devdraw hard-wires `clientid = 1`, `devdraw.c:29`). Opening `new` morphs the fid to
`ctl`; a `ctl` read at offset 0 re-reads the line from the peer.

**`host.dev_input.DevInput9`**:

```zig
pub const mouse_rec_len = dev.input.mouse_rec_len;   // 49, the SHARED formatter
pub const cursor_rec_len: usize = 72;
pub const Warp = struct { x: i32, y: i32 };
pub fn parseWarp(data: []const u8) ?Warp;            // 'm' then two ints (devmouse.c:461-468)
pub fn init(gpa, conn: *Conn) DevInput9;
pub fn deinit(*DevInput9) void;
pub fn mousePath() u64;  pub fn kbdPath() u64;       // for Server.completeReads
pub fn pushMouse(*DevInput9, Conn.MouseEvent) !void;
pub fn pushRune(*DevInput9, u32) !void;
pub const ops: ninep.server.Ops = ...;
```

Tree: `mouse` (0666 — the warp), `kbd` (0444), `cursor`, `snarf`, `label`. Reads of
`mouse`/`kbd` return `error.WouldBlockRead` when the queue is empty.

**The warp write path** — `src/core/warp.zig`:

```zig
pub const mouse_path = "/dev/mouse";
pub const rec_len: usize = 49;
pub fn format(x: i32, y: i32, out: *[rec_len]u8) void;   // "m<x:11> <y:11> <0> <0> "
pub fn to(ed: *Editor, pt: draw.proto.Point) void;        // best effort, swallows all
pub fn toSelection(ed: *Editor, t: *Text) void;           // look.c:219 / :897 point
pub const MouseSink = struct { ... };                     // the capture server, see below
```

The exact record for x=100, y=200 is
`"m        100         200           0           0 "` (49 bytes).

**Browser refusal string**: `Rerror "permission denied"` (`ninep.errors.PermissionDenied`
→ `errorString`), from `dev/input.zig writeOp` for both `mouse` and `kbd`.

**How a headless test captures a `/dev/mouse` write from a `Look` hit** — the seam is
already in the tree as `core.warp.MouseSink` (a 9P `Ops` whose `mouse` file records the
last write). Mount it at `/dev` and drive the editor:

```zig
var sink: core.warp.MouseSink = .{};
const pipe = try ninep.chan.Pipe.init(a, 16384);
var srv = try ninep.server.Server.init(a, pipe.serverEnd(), &core.warp.MouseSink.ops, &sink, 8192);
var cl  = try ninep.Client.init(a, pipe.clientEnd(), 8192);
cl.pump = .{ .ctx = &srv, .run = pumpServer };
_ = try cl.version(8192);
const root = try cl.attach("larry", "");
var ns = ninep.mount.Namespace.init(a);
try ns.mount("/dev", &cl, root.fid);
ed.ns = &ns;
// ... drive a B3 look that hits ...
try testing.expectEqual(@as(usize, 1), sink.writes);
try testing.expectEqualStrings("m        100         200           0           0 ", &sink.last);
```

Two traps for T9: (a) the hit must be a LITERAL search hit, so the B3'd text must not
look like a file name, or `expand.startLook` parks a `StatJob` instead and the warp
happens a frame or two later through `Load.addressAndShow`; (b) `warp.toSelection` reads
`t.fr.ptOfChar(t.fr.p0)`, so the Text must be windowed and laid out — a bare headless
`Text` with an empty frame warps to its origin, not to the match.

## Gate

| Check | Result |
|---|---|
| `zig build test --summary all` | **690/690 pass**, exit 0 (was 665 on `main`; +25) |
| `zig fmt --check src build.zig` | clean |
| `zig build` (wasm) | exit 0, `snarf.wasm` 2 248 616 B (2195.9 KiB) |
| `node tools/smoke_wasm.mjs` | **40 pass, 0 fail, 0 pending**; blit count 34 |
| ABI version | **6**, unchanged |
| FROZEN goldens | `git diff main -- src/accept.zig` EMPTY; every `FROZEN-ACCEPT-*` assertion passes untouched |
| `zig build native` | exit 0, `zig-out/bin/snarf-native` |
| `zig build run-native` | window opens, boot scene drawn, alive and idle past 4 s (transcript above) |
| Boundary (R-P15-2) | `src/draw` + `src/ninep` byte-identical; `src/core` = the warp only |

## Debt created

* `src/host/devdraw/Conn.zig` is 527 pre-test lines (over the ~400 soft cap).
* `snarf-native` never tears the stack down on exit beyond `Conn.deinit` (which kills
  `devdraw`) — the 9P pipes/servers/clients leak at process exit, as `main_wasm` does.
* No CI story for a host that needs a window (ADR-0005 "two hosts to keep green").
* `/dev/snarf` is served natively but nothing in `core` reads it yet (`core/snarf.zig` is
  still an in-memory buffer); `/dev/cursor` is served but never written.
* `dev_input.pushRune` drops runes above `0x10FFFF`. Harmless in practice: every
  plan9port key rune is inside Unicode (`KF = 0xF000` private use, `Kdel = 0x7f`,
  `Kesc = 0x1b`, `Kdown = 0x80` — `include/keyboard.h:19-39`), so arrows, Del, Esc and
  the function keys all reach `core` untouched on this host.

## One latent BUG the spike surfaced (pre-existing, browser-only)

There are **two incompatible `Kdown` conventions in the tree**:

* `src/core/text/typing.zig:43` — `Kdown = 0x80`, plan9port's `include/keyboard.h:27`;
* `src/dev/profiles.zig:67,81` + `web/shim.js:52` — `Kdown = 0xF800`, the 4e tree's
  `sys/include/keyboard.h` (ruling **R-P6-7**, "our device authority").

`typing.zig` only ever tests `0x80`, so a browser **ArrowDown falls through to the
default no-op arm and scrolls nothing** (`0xF800 >= KF`, so it is not insertable
either — it is silently swallowed). The native host is unaffected: `devdraw` sends
plan9port's `0x80` and the scroll works. The spike found this precisely because the two
hosts speak different keyboard dialects to the same core, which R-P6-7 licensed without
noticing that `core` had already taken the other side. Not fixed here — it is a browser
bug in `shim.js`/`profiles.zig` or a missing alias in `typing.zig`, either way outside
R-P15-2's blast radius. **Recommend: fix in the debt pass, with a test that drives
ArrowDown through the browser stack.**
