# Phase 6 devinput side contract (O12, with R-P6-2/3 applied) — input.zig + profiles.zig + shim capture

Read with the master. Ground truth (cite in headers): mouse record devmouse.c:306-309
("m%11d %11d %11d %11lud ", buf[1+4*12+1]; 49 bytes; count clamp :311-312); blocking
:272-273; buttons B1=1 B2=2 B3=4, wheel 8/16; 'r' resize marker RESERVED (phase 6
emits 'm' only); kernel queues transitions only, moves read live (:598-604) — we keep
transitions-never-dropped but DIVERGE from the qfull-discard (S-04 §5/R-IN-02);
writes to mouse/kbd => error.PermissionDenied (S-04 §1 overrides kernel warp);
kbd = plain UTF-8 rune stream, whole runes only per read (S-04 §3, G-I8); specials
per 4e keyboard.h:22-46 (Kup 0xF00E, Kdown 0xF800 [R-P6-7], Kleft 0xF011, Kright
0xF012, Khome 0xF00D, Kend 0xF018, Kpgup 0xF00F, Kpgdown 0xF013, Kins 0xF014,
Kdel 0x7F, Kesc 0x1B, Kbs 0x08, KF 0xF000+n); {d:>11} +-sign trap (format {d} then
pad — reuse the putIntField idiom from dev/draw.zig:522-542, duplicate locally).

## Served tree (single-server, pre-namespace — dev/draw.zig precedent)

root "input" dir 0555 / mouse 0444 / kbd 0444 / ctl 0666. Node enum + qidFor/nodeOf
per draw.zig's idiom; comptime dirtab (P-7) drives walk1/stat. mouse+kbd are
exclusive-single-reader (second concurrent open => PermissionDenied; clunk frees).
ctl read (offset-0 idempotent): "profile <name>\nmap alt 2\nmap meta 3\n
uncapturable ...\n". ctl write verbs: "profile native|modifier" (touch/chordbar =>
BadMessage until built); "map <alt|meta|ctrl> <2|3>". Bad verb => BadMessage
(R-P6-11). Profile switch mid-gesture: queued until Machine returns to Idle.

## Mouse record (normative)

49 bytes: 'm' + x[11]+sp + y[11]+sp + buttons[11]+sp + msec[11]+sp, decimal
right-justified space-padded. Golden (x=102,y=33,b=1,msec=123456):
"m        102          33           1      123456 ". One record per Tread; count<49
=> first count bytes; empty => return error.WouldBlockRead (R-P6-2).

## src/dev/input.zig — DevInput

```zig
pub const RawEvent = union(enum) {
    pointer: struct { kind: enum(u8) { down, up, move }, x: i32, y: i32, button: u8, msec: u32 },
    wheel:   struct { notches: i32, x: i32, y: i32, msec: u32 },
    key:     struct { rune: u21, mods: Mods, msec: u32 },
    mod:     struct { kind: enum(u8) { down, up }, which: Mod, msec: u32 },
};
pub const Mod = enum(u8) { alt, meta, ctrl, shift };
pub const Mods = packed struct(u8) { alt: bool, meta: bool, ctrl: bool, shift: bool, _pad: u4 = 0 };

pub const MouseRec = struct { x: i32, y: i32, buttons: u32, msec: u32 };
pub const mouse_rec_len: usize = 49;
pub fn formatMouseRec(rec: MouseRec, out: *[mouse_rec_len]u8) void;

pub const DevInput = struct {
    allocator, profile: profiles.Profile = .native, machine: profiles.Machine,
    mouse_q: MouseQueue, kbd_q: std.ArrayListUnmanaged(u8) = .empty,
    mouse_open: bool = false, kbd_open: bool = false,
    pending_profile: ?profiles.Profile = null,
    // NO parked fields, NO Server pointer (R-P6-2/3).
    pub const ops: ninep.server.Ops = .{ ... }; // read returns ReadError!usize
    pub fn init(allocator) DevInput;  pub fn deinit(*Self) void;
    pub fn push(self: *DevInput, ev: RawEvent) void;   // THE single intake
    pub fn pushPointer/pushWheel/pushKey/pushMod(...) void;  // scalar wrappers
    /// qid paths the adapter passes to srv.completeReads after a push batch:
    pub fn mousePath() u64;  pub fn kbdPath() u64;
};
```
push => machine.step => logical events => queues. MouseQueue: ArrayList-as-deque;
push coalesces a move onto a tail move WITH THE SAME BUTTONS (overwrite tail);
transitions always append, never dropped; wheel notch => TWO transitions (b|8 or
b|16, then b) per notch, |n| pairs. read(mouse): pop one record, format 49 bytes;
empty => WouldBlockRead. read(kbd): return as many WHOLE pending UTF-8 runes as fit
count, FIFO; never split a rune; empty => WouldBlockRead.

## src/dev/profiles.zig (pure std)

Profile enum {native, modifier, touch, chordbar} (last two: TODO machines);
B1/B2/B3/WHEEL_UP/WHEEL_DOWN; the keyboard.h rune constants (cited);
native_button_map [_]u32{B1,B2,B3} (DOM button 0/1/2; others ignored);
ModMap { alt: u32 = B2, meta_or_ctrl: u32 = B3 };
Machine { profile, mod_map, pointer_down, latched, physical, buttons,
  pub fn step(self, ev: RawEvent) StepResult };
StepResult { events: [2]?LogicalMouse, kbd_deliver: bool }
(LogicalMouse = MouseRec-shaped; define locally or share — implementer's call,
document).

Modifier machine — normative table (state=(pointer_down,buttons); bit(m)=mapped bit;
unmapped mods incl. shift: no-op, kbd_deliver=true):
1 Idle + mod_down(m) => Armed(latch m), emit nothing, consume key
2 Armed + mod_up(m) => Idle, nothing
3 Idle + pointer_down => Sweep(1), emit 1
4 Armed(m) + pointer_down => Sweep(bit(m)), emit bit(m)
5 Sweep(b) + mod_down(m) => Sweep(b|bit(m)), emit b|bit(m)   [mid-sweep chord]
6 Sweep(b) + mod_up(m), b&~bit(m)!=0 => Sweep(b&~bit(m)), emit it
7 Sweep(b) + mod_up(m), b&~bit(m)==0 => Sweep(1), emit 1     [release-swap 2->1]
8 Sweep(b) + pointer_up => Idle, emit 0 (mods still held physically re-Arm)
9 Sweep(b) + move => same, move record (coalescible)
10 any + wheel(n) => |n| pairs of (b|8 or b|16, b)
11 Sweep w/ latched m + key(mods.m set) => consume (kbd_deliver=false); idle => deliver
Native machine: 1:1 physical bits via native_button_map; wheel row 10; all keys
delivered. Row-7 flagged (F7 master): pinned to S-04 §2.2 until a spec amendment.

## Shim surface (6c builder consumes this; A3/B1 do NOT touch shim/web)

abi.zig: version 3; `pub const EventKind = enum(u8) { pointer_down=1, pointer_up=2,
pointer_move=3, wheel=4, key=5, mod_down=6, mod_up=7 };` NO new env imports.
main_wasm: `export fn pushEvent(kind: u32, a: i32, b: i32, c: u32, t: u32) void`
(pointer: a=x b=y c=button; wheel: a=notches; key: a=rune c=mods; mod: c=Mod id) =>
decode => app.devinput.push => then adapter calls completeReads per R-P6-3.
shim.js: ABI_VERSION=3; pointerdown/up/move + setPointerCapture + preventDefaults
(contextmenu, middle-mousedown, wheel non-passive); keydown/keyup on window with the
KEYRUNE table (mechanical keyboard.h mirror incl. F1..F12, Enter=0x0A, Tab=0x09),
Ctrl-letter folding (rune &= 0x1F for rune >= 0x40 when ctrlKey — R-IN-10), modifier
split (Alt/Meta/Control/Shift => mod_down/up); xy via getBoundingClientRect (DPR=1).

## Named tests

profiles.zig: "profiles: native button map" · "modifier: plain click and sweep" ·
"modifier: armed click emulates B2/B3" · "modifier: latch mid-sweep 1->3->1" ·
"modifier: release-swap 2->1" · "modifier: two modifiers chord and unwind" (Alt down,
ptr down(2), Meta down(6), Alt up(4), Meta up(1), ptr up(0)) · "modifier: bare
modifier tap emits nothing, delivers no rune" · "modifier: key composed with latched
mod suppressed mid-gesture".
input.zig (Pipe+Server harness per dev/draw.zig): "devinput: stat and walk table" ·
"devinput: mouse record byte-exactness (49-byte golden)" · "devinput: R-IN-02
byte-identity — emulated chord == hardware chord" (hardware B2 edges native vs Alt
mid-sweep modifier; concatenated Rread streams expectEqualSlices-identical) ·
"devinput: coalescing — N moves one record, transitions preserved" · "devinput: wheel
notches" · "devinput: kbd UTF-8 stream + specials" ('a','é',Kup => 61 C3 A9 EF 80 8E;
count=4 => 61 C3 A9, remainder next read) · "devinput: mouse write and kbd write
rejected" · "devinput: exclusive readers" · "devinput: ctl read/write — profile
switch, map verb, bad verb" (incl. deferred-switch-mid-gesture) · "devinput: read
blocks until push, completes with the queued record" (park via WouldBlockRead; harness
calls completeReads) · "devinput: Tflush cancels a parked read; next read re-parks".
