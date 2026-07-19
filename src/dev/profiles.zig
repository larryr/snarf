//! devinput profiles — button constants, keyboard.h rune constants, and the
//! chord-synthesis state machine that turns raw shim events into logical
//! `/dev/mouse` button transitions and kbd delivery decisions (S-04 §2).
//!
//! Pure `std` — no `ninep`, no `shim` (S-07 §6, R-P6-6). This file, its types,
//! and its `Machine` compile and test natively with zero dependency on the 9P
//! framework, so the whole chord/modifier algebra is proven before `input.zig`
//! (wave 6b) wires it to a served tree.
//!
//! Citations: mouse buttons B1=1/B2=2/B3=4, wheel 8/16 — S-04 §1
//! (docs/spec/04-input-devices.md). native profile — S-04 §2.1. modifier
//! profile + the 2-1 release-swap divergence — S-04 §2.2, ADR-0004. kbd
//! specials — S-04 §3. Kernel rune constants — `larryr/plan9@ed1a9c2`,
//! `sys/include/keyboard.h` (the "4e tree", our device authority per R-P6-7;
//! plan9port's `Kdown=0x80` is a noted p9p divergence, NOT followed here).
//!
//! ## RawEvent placement ruling
//!
//! The devinput side contract (`agents/contracts/phase6-input-devinput.md`,
//! "src/dev/input.zig — DevInput") sketches `RawEvent`/`Mod`/`Mods` inside
//! `input.zig`, but `Machine.step` (this file, wave 6a) already takes a
//! `RawEvent` — and `profiles.zig` must stay pure-std and natively testable on
//! its own, one wave ahead of `input.zig` existing at all. Resolution: these
//! three types (plus the `MouseRec`-shaped `LogicalMouse`) live HERE, in the
//! pure-std home, fully defined and tested against the normative table below.
//! `input.zig` (B1, wave 6b) re-exports or type-aliases them
//! (`pub const RawEvent = profiles.RawEvent;` etc.) rather than redefining —
//! its own `MouseRec` is byte-for-byte the same shape as `LogicalMouse` and
//! should alias it directly (`pub const MouseRec = profiles.LogicalMouse;`) to
//! avoid a silent divergence between the two.
const std = @import("std");

// ===========================================================================
// Profiles (R-P6-6). Native + modifier ship now; touch/chordbar are TODO
// machines — the enum and RawEvent shapes exist from day one so the ctl verb
// surface and ABI don't have to change again when they land.
// ===========================================================================

pub const Profile = enum { native, modifier, touch, chordbar };

// ===========================================================================
// Button bits (S-04 §1, devmouse.c-equivalent semantics; 9/port/devmouse.c
// buttons: B1=1, B2=2, B3=4, wheel up=8, wheel down=16, one event per notch).
// ===========================================================================

pub const B1: u32 = 1;
pub const B2: u32 = 2;
pub const B3: u32 = 4;
pub const WHEEL_UP: u32 = 8;
pub const WHEEL_DOWN: u32 = 16;

/// DOM `PointerEvent.button` (0/1/2) → logical bit, native profile (S-04 §2.1:
/// "real simultaneous buttons = chords, no synthesis needed"). Buttons past
/// index 2 (browser extra buttons) are ignored, per the side contract.
pub const native_button_map = [_]u32{ B1, B2, B3 };

// ===========================================================================
// keyboard.h rune constants — `sys/include/keyboard.h` (larryr/plan9@ed1a9c2,
// lines 22-46). Cited per constant; `u21` matches Zig's rune width. Only the
// constants Phase 6 or the devinput side contract actually name are ported —
// Kalt/Kshift/Kctl/Keof are omitted (unused; add with a citation if needed).
// ===========================================================================

/// Beginning of the private Unicode space used for function keys (keyboard.h:23).
pub const KF: u21 = 0xF000;
/// `Spec` — second private-space base, used only by `Kdown`/`Kview` (keyboard.h:24).
pub const Spec: u21 = 0xF800;
/// keyboard.h:26 — `Khome = KF|0x0D`.
pub const Khome: u21 = KF | 0x0D;
/// keyboard.h:27 — `Kup = KF|0x0E`.
pub const Kup: u21 = KF | 0x0E;
/// keyboard.h:28 — `Kpgup = KF|0x0F`.
pub const Kpgup: u21 = KF | 0x0F;
/// keyboard.h:29 — `Kprint = KF|0x10` (not named by the side contract; ported
/// for completeness alongside its neighbors).
pub const Kprint: u21 = KF | 0x10;
/// keyboard.h:30 — `Kleft = KF|0x11`.
pub const Kleft: u21 = KF | 0x11;
/// keyboard.h:31 — `Kright = KF|0x12`.
pub const Kright: u21 = KF | 0x12;
/// keyboard.h:32 — `Kdown = Spec|0x00` = 0xF800 (R-P6-7: our 4e-tree device
/// authority; plan9port's `Kdown=0x80` is a p9p divergence, NOT used here).
pub const Kdown: u21 = Spec | 0x00;
/// keyboard.h:34 — `Kpgdown = KF|0x13`.
pub const Kpgdown: u21 = KF | 0x13;
/// keyboard.h:35 — `Kins = KF|0x14`.
pub const Kins: u21 = KF | 0x14;
/// keyboard.h:36 — `Kend = KF|0x18`.
pub const Kend: u21 = KF | 0x18;
/// keyboard.h:42 — `Kbs = 0x08` (backspace).
pub const Kbs: u21 = 0x08;
/// keyboard.h:43 — `Kdel = 0x7f`.
pub const Kdel: u21 = 0x7F;
/// keyboard.h:44 — `Kesc = 0x1b`.
pub const Kesc: u21 = 0x1B;

/// `KF|1 .. KF|0xC` is F1..F12 (keyboard.h:25 comment). `n` must be in `1..=0xC`.
pub fn kfun(n: u5) u21 {
    std.debug.assert(n >= 1 and n <= 0xC);
    return KF | @as(u21, n);
}

// ===========================================================================
// Raw input events (from the devinput side contract's `input.zig` sketch;
// homed here per the placement ruling above).
// ===========================================================================

pub const Mod = enum(u8) { alt, meta, ctrl, shift };

pub const Mods = packed struct(u8) {
    alt: bool = false,
    meta: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    _pad: u4 = 0,

    fn has(self: Mods, m: Mod) bool {
        return switch (m) {
            .alt => self.alt,
            .meta => self.meta,
            .ctrl => self.ctrl,
            .shift => self.shift,
        };
    }

    fn set(self: *Mods, m: Mod, v: bool) void {
        switch (m) {
            .alt => self.alt = v,
            .meta => self.meta = v,
            .ctrl => self.ctrl = v,
            .shift => self.shift = v,
        }
    }
};

pub const RawEvent = union(enum) {
    pointer: struct { kind: enum(u8) { down, up, move }, x: i32, y: i32, button: u8, msec: u32 },
    wheel: struct { notches: i32, x: i32, y: i32, msec: u32 },
    key: struct { rune: u21, mods: Mods, msec: u32 },
    mod: struct { kind: enum(u8) { down, up }, which: Mod, msec: u32 },
};

// ===========================================================================
// Logical mouse record — MouseRec-shaped (x/y/buttons/msec); see the placement
// ruling above for why `input.zig`'s `MouseRec` should alias this rather than
// redefine it.
// ===========================================================================

pub const LogicalMouse = struct { x: i32, y: i32, buttons: u32, msec: u32 };

/// Which mapped mod (alt or "meta_or_ctrl") a physical Alt/Meta/Ctrl press
/// arms. Only two virtual slots exist (S-04 §2.2): Alt always arms one slot;
/// Meta and Ctrl share the other (the shim picks which one it ever sends,
/// per-platform or via the ctl `map` verb — devinput's concern, not ours).
/// Shift is never mapped: it is always a no-op modifier here (S-04 §3).
pub const ModMap = struct {
    alt: u32 = B2,
    meta_or_ctrl: u32 = B3,

    fn bitFor(self: ModMap, m: Mod) ?u32 {
        return switch (m) {
            .alt => self.alt,
            .meta, .ctrl => self.meta_or_ctrl,
            .shift => null,
        };
    }
};

pub const StepResult = struct {
    events: [2]?LogicalMouse = .{ null, null },
    kbd_deliver: bool = true,
};

// ===========================================================================
// Machine — the chord-synthesis state machine (S-04 §2, normative 11-row
// table below, verbatim from the devinput side contract). Allocation-free.
//
// Internal state is NOT an explicit Idle/Armed/Sweep tag; it is reconstructed
// from four fields, which is sufficient because the table's states are
// exactly `(pointer_down, latched-bits)`:
//   - `pointer_down`: is Sweep active right now?
//   - `latched`: which mapped modifiers (alt/meta/ctrl) are currently
//     counted into `buttons` — the live "Armed(m)" or in-sweep chord set.
//   - `physical`: every modifier key currently held DOWN at the OS/DOM level,
//     tracked independently of `latched`. Row 8 says a pointer-up drops back
//     to Idle but "mods still held physically re-Arm" — i.e. `latched` is
//     cleared on pointer-up while `physical` is not, so the very next
//     pointer-down (still logically "Idle") consults `physical` and re-derives
//     Sweep(bit(m)) exactly as if it had come through Armed(m) again.
//   - `buttons`: the last emitted logical bitmask (also the base a wheel
//     pulse or a chord recomputation starts from).
// `last_x`/`last_y` remember the most recent pointer position: `RawEvent.mod`
// carries no coordinates (the kernel's mouse record always needs one — a
// button-only transition re-emits the last known position, matching how a
// real mouse's queued transitions carry position too).
// ===========================================================================

pub const Machine = struct {
    profile: Profile = .native,
    mod_map: ModMap = .{},
    pointer_down: bool = false,
    latched: Mods = .{},
    physical: Mods = .{},
    buttons: u32 = 0,
    last_x: i32 = 0,
    last_y: i32 = 0,

    const mapped_mods = [_]Mod{ .alt, .meta, .ctrl };

    pub fn init(profile: Profile) Machine {
        return .{ .profile = profile };
    }

    pub fn step(self: *Machine, ev: RawEvent) StepResult {
        return switch (self.profile) {
            .native => self.stepNative(ev),
            .modifier => self.stepModifier(ev),
            // touch/chordbar: TODO machines (R-P6-6). Safe no-op passthrough
            // until built: nothing synthesized, every key delivered.
            .touch, .chordbar => .{},
        };
    }

    fn recordAt(self: *Machine, x: i32, y: i32, msec: u32) LogicalMouse {
        self.last_x = x;
        self.last_y = y;
        return .{ .x = x, .y = y, .buttons = self.buttons, .msec = msec };
    }

    fn recordHere(self: *const Machine, msec: u32) LogicalMouse {
        return .{ .x = self.last_x, .y = self.last_y, .buttons = self.buttons, .msec = msec };
    }

    /// Row 10 ("any + wheel(n)"): one notch's worth of pulse — bit set then
    /// cleared. A `RawEvent.wheel` is taken to represent exactly one notch
    /// (`notches`'s sign gives direction); a caller carrying a multi-notch
    /// scroll delta is expected to call `step` once per notch (documented for
    /// `input.zig`, wave 6b, whose `push` owns the `|n| pairs` fan-out into
    /// the mouse queue — `StepResult.events` only has two slots).
    fn wheelStep(self: *Machine, w: anytype) StepResult {
        self.last_x = w.x;
        self.last_y = w.y;
        const bit: u32 = if (w.notches >= 0) WHEEL_UP else WHEEL_DOWN;
        return .{ .events = .{
            .{ .x = w.x, .y = w.y, .buttons = self.buttons | bit, .msec = w.msec },
            .{ .x = w.x, .y = w.y, .buttons = self.buttons, .msec = w.msec },
        } };
    }

    // -- native profile: 1:1 physical bits, no modifier synthesis -----------

    fn stepNative(self: *Machine, ev: RawEvent) StepResult {
        switch (ev) {
            .pointer => |p| {
                if (p.button < native_button_map.len) {
                    const bit = native_button_map[p.button];
                    switch (p.kind) {
                        .down => self.buttons |= bit,
                        .up => self.buttons &= ~bit,
                        .move => {},
                    }
                }
                return .{ .events = .{ self.recordAt(p.x, p.y, p.msec), null } };
            },
            .wheel => |w| return self.wheelStep(w),
            .key => return .{}, // all keys delivered (S-04 §2.1)
            .mod => return .{}, // native ignores modifiers for synthesis
        }
    }

    // -- modifier profile: normative 11-row table ----------------------------

    fn stepModifier(self: *Machine, ev: RawEvent) StepResult {
        return switch (ev) {
            .pointer => |p| self.modPointer(p),
            .wheel => |w| self.wheelStep(w),
            .mod => |m| self.modMod(m),
            .key => |k| self.modKey(k),
        };
    }

    fn latchedBits(self: *const Machine) u32 {
        var b: u32 = 0;
        for (mapped_mods) |m| {
            if (self.latched.has(m)) {
                if (self.mod_map.bitFor(m)) |bit| b |= bit;
            }
        }
        return b;
    }

    fn modPointer(self: *Machine, p: anytype) StepResult {
        switch (p.kind) {
            .down => {
                if (!self.pointer_down) {
                    var bits = self.latchedBits();
                    if (bits == 0) {
                        // Row 3 vs row 4: nothing latched from an explicit
                        // Armed transition — fall back to physically-held
                        // mapped mods (the row-8 re-Arm case).
                        for (mapped_mods) |m| {
                            if (self.physical.has(m)) self.latched.set(m, true);
                        }
                        bits = self.latchedBits();
                    }
                    self.pointer_down = true;
                    self.buttons = if (bits == 0) B1 else bits; // rows 3/4
                }
                return .{ .events = .{ self.recordAt(p.x, p.y, p.msec), null } };
            },
            .up => {
                // Row 8: Idle, emit 0; latched clears, physical does not.
                self.pointer_down = false;
                self.buttons = 0;
                self.latched = .{};
                return .{ .events = .{ self.recordAt(p.x, p.y, p.msec), null } };
            },
            .move => return .{ .events = .{ self.recordAt(p.x, p.y, p.msec), null } }, // row 9
        }
    }

    fn modMod(self: *Machine, m: anytype) StepResult {
        const mapped = self.mod_map.bitFor(m.which);
        self.physical.set(m.which, m.kind == .down);
        if (mapped == null) return .{}; // shift/unmapped: no-op, kbd_deliver=true
        const bit = mapped.?;

        if (!self.pointer_down) {
            // Rows 1/2: Armed bookkeeping only, no logical button yet.
            if (m.kind == .down) {
                self.latched.set(m.which, true);
                return .{ .kbd_deliver = false }; // row 1: consume
            }
            self.latched.set(m.which, false); // row 2: nothing
            return .{};
        }

        // Rows 5-7: mid-sweep modifier chord.
        if (m.kind == .down) {
            self.latched.set(m.which, true);
            self.buttons |= bit; // row 5
        } else {
            self.latched.set(m.which, false);
            const remaining = self.buttons & ~bit;
            self.buttons = if (remaining != 0) remaining else B1; // row 6 / row 7 (release-swap)
        }
        return .{ .events = .{ self.recordHere(m.msec), null } };
    }

    fn modKey(self: *Machine, k: anytype) StepResult {
        // Row 11: a latched mod "captured" for the sweep suppresses a key
        // event carrying that same mod, but only while Sweep is active —
        // Armed-but-not-yet-swept (or plain Idle) always delivers.
        if (self.pointer_down) {
            for (mapped_mods) |m| {
                if (self.latched.has(m) and k.mods.has(m)) return .{ .kbd_deliver = false };
            }
        }
        return .{};
    }
};

// ===========================================================================
// Tests — the 8 named "profiles:"/"modifier:" tests from the devinput side
// contract. Each asserts the full emitted-events sequence and kbd_deliver
// verdicts, table-driven where the sequence is uniform.
// ===========================================================================

const testing = std.testing;

fn mkPointer(kind: anytype, x: i32, y: i32, button: u8, msec: u32) RawEvent {
    return .{ .pointer = .{ .kind = kind, .x = x, .y = y, .button = button, .msec = msec } };
}

fn mkMod(kind: anytype, which: Mod, msec: u32) RawEvent {
    return .{ .mod = .{ .kind = kind, .which = which, .msec = msec } };
}

fn expectRec(want_buttons: u32, got: ?LogicalMouse) !void {
    try testing.expect(got != null);
    try testing.expectEqual(want_buttons, got.?.buttons);
}

test "profiles: native button map" {
    try testing.expectEqualSlices(u32, &.{ B1, B2, B3 }, &native_button_map);

    var m = Machine.init(.native);

    // Real simultaneous buttons are chords — no synthesis (S-04 §2.1).
    var r = m.step(mkPointer(.down, 0, 0, 0, 100));
    try expectRec(B1, r.events[0]);
    try testing.expectEqual(@as(?LogicalMouse, null), r.events[1]);

    r = m.step(mkPointer(.down, 1, 2, 2, 101)); // button 2 → B3, chords with B1
    try expectRec(B1 | B3, r.events[0]);
    try testing.expectEqual(@as(i32, 1), r.events[0].?.x);
    try testing.expectEqual(@as(i32, 2), r.events[0].?.y);

    r = m.step(mkPointer(.move, 5, 6, 0, 102));
    try expectRec(B1 | B3, r.events[0]);

    r = m.step(mkPointer(.up, 0, 0, 0, 103));
    try expectRec(B3, r.events[0]);

    r = m.step(mkPointer(.up, 0, 0, 2, 104));
    try expectRec(0, r.events[0]);

    // Keys always deliver; modifiers are inert in native.
    var mm = Machine.init(.native);
    const kr = mm.step(.{ .mod = .{ .kind = .down, .which = .alt, .msec = 0 } });
    try testing.expect(kr.kbd_deliver);
    try testing.expectEqual(@as(?LogicalMouse, null), kr.events[0]);

    // Wheel row 10 applies to native too.
    var mw = Machine.init(.native);
    const wr = mw.step(.{ .wheel = .{ .notches = 1, .x = 3, .y = 4, .msec = 5 } });
    try expectRec(WHEEL_UP, wr.events[0]);
    try expectRec(0, wr.events[1]);
}

test "modifier: plain click and sweep" {
    // Rows 3, 9, 8: no modifier involved at all.
    var m = Machine.init(.modifier);

    var r = m.step(mkPointer(.down, 10, 20, 0, 1));
    try expectRec(B1, r.events[0]);

    r = m.step(mkPointer(.move, 11, 21, 0, 2));
    try expectRec(B1, r.events[0]);
    try testing.expectEqual(@as(i32, 11), r.events[0].?.x);

    r = m.step(mkPointer(.up, 11, 21, 0, 3));
    try expectRec(0, r.events[0]);
}

test "modifier: armed click emulates B2/B3" {
    // Row 1 then row 4, for both the alt slot (B2) and the meta_or_ctrl slot (B3).
    var alt_m = Machine.init(.modifier);
    var ar = alt_m.step(mkMod(.down, .alt, 1));
    try testing.expect(!ar.kbd_deliver);
    try testing.expectEqual(@as(?LogicalMouse, null), ar.events[0]);
    ar = alt_m.step(mkPointer(.down, 0, 0, 0, 2));
    try expectRec(B2, ar.events[0]);

    var meta_m = Machine.init(.modifier);
    _ = meta_m.step(mkMod(.down, .meta, 1));
    const mr = meta_m.step(mkPointer(.down, 0, 0, 0, 2));
    try expectRec(B3, mr.events[0]);
}

test "modifier: latch mid-sweep 1->3->1" {
    // Rows 3, 5, 6: 1 -> 3 -> 1.
    var m = Machine.init(.modifier);
    var seq: std.ArrayList(u32) = .empty;
    defer seq.deinit(testing.allocator);

    var r = m.step(mkPointer(.down, 0, 0, 0, 1)); // row 3
    try seq.append(testing.allocator, r.events[0].?.buttons);
    r = m.step(mkMod(.down, .alt, 2)); // row 5
    try seq.append(testing.allocator, r.events[0].?.buttons);
    r = m.step(mkMod(.up, .alt, 3)); // row 6 (B1 remains)
    try seq.append(testing.allocator, r.events[0].?.buttons);

    try testing.expectEqualSlices(u32, &.{ B1, B1 | B2, B1 }, seq.items);
}

test "modifier: release-swap 2->1" {
    // Rows 1, 4, 7: entering via Armed(alt) so the sweep starts at B2, then
    // releasing the only latched modifier swaps to B1 instead of ending.
    var m = Machine.init(.modifier);
    _ = m.step(mkMod(.down, .alt, 1)); // row 1
    var r = m.step(mkPointer(.down, 0, 0, 0, 2)); // row 4 -> emit 2
    try expectRec(B2, r.events[0]);

    r = m.step(mkMod(.up, .alt, 3)); // row 7 -> emit 1 (release-swap)
    try expectRec(B1, r.events[0]);
    try testing.expect(m.pointer_down); // gesture is NOT over — only pointer-up ends it
}

test "modifier: two modifiers chord and unwind" {
    // Exact sequence from the devinput side contract: Alt down, ptr down(2),
    // Meta down(6), Alt up(4), Meta up(1), ptr up(0).
    var m = Machine.init(.modifier);
    var seq: std.ArrayList(u32) = .empty;
    defer seq.deinit(testing.allocator);

    _ = m.step(mkMod(.down, .alt, 1)); // Armed(alt), no event
    var r = m.step(mkPointer(.down, 0, 0, 0, 2));
    try seq.append(testing.allocator, r.events[0].?.buttons); // 2
    r = m.step(mkMod(.down, .meta, 3));
    try seq.append(testing.allocator, r.events[0].?.buttons); // 6
    r = m.step(mkMod(.up, .alt, 4));
    try seq.append(testing.allocator, r.events[0].?.buttons); // 4
    r = m.step(mkMod(.up, .meta, 5));
    try seq.append(testing.allocator, r.events[0].?.buttons); // 1
    r = m.step(mkPointer(.up, 0, 0, 0, 6));
    try seq.append(testing.allocator, r.events[0].?.buttons); // 0

    try testing.expectEqualSlices(u32, &.{ B2, B2 | B3, B3, B1, 0 }, seq.items);
}

test "modifier: bare modifier tap emits nothing, delivers no rune" {
    var m = Machine.init(.modifier);

    const down = m.step(mkMod(.down, .alt, 1)); // row 1
    try testing.expectEqual(@as(?LogicalMouse, null), down.events[0]);
    try testing.expectEqual(@as(?LogicalMouse, null), down.events[1]);
    try testing.expect(!down.kbd_deliver);

    const up = m.step(mkMod(.up, .alt, 2)); // row 2
    try testing.expectEqual(@as(?LogicalMouse, null), up.events[0]);
    try testing.expect(up.kbd_deliver);
    try testing.expect(!m.pointer_down);
}

test "modifier: key composed with latched mod suppressed mid-gesture" {
    // Row 11: suppressed while Sweep holds the latched modifier; delivered
    // once the gesture ends even though the physical key is still held.
    var m = Machine.init(.modifier);
    _ = m.step(mkMod(.down, .alt, 1)); // Armed(alt)
    _ = m.step(mkPointer(.down, 0, 0, 0, 2)); // Sweep(B2), latched={alt}

    const mid = m.step(.{ .key = .{ .rune = 'x', .mods = .{ .alt = true }, .msec = 3 } });
    try testing.expect(!mid.kbd_deliver);

    _ = m.step(mkPointer(.up, 0, 0, 0, 4)); // row 8: Idle, latched clears

    const after = m.step(.{ .key = .{ .rune = 'x', .mods = .{ .alt = true }, .msec = 5 } });
    try testing.expect(after.kbd_deliver); // idle => deliver
}

test {
    std.testing.refAllDecls(@This());
}
