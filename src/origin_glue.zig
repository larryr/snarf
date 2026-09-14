//! The root's origin-mount adapter: the `/n/origin` half of `main_wasm.zig`.
//! Namespace module (S-07 P-1), a sibling of `screen.zig` and `input_pump.zig`
//! and, like them, it works through BORROWED POINTERS and never sees the `App`
//! context — no new global (R-P12e-5). Carved out verbatim in phase 12e so
//! `main_wasm.zig` stays inside the ~400-line cap.
//!
//! It owns three things: the inbound-frame staging buffer behind the `wsStage`
//! ABI call (R-P12-2), the record hand-off behind `wsPush`, and the per-tick
//! `poll` that turns an `OriginMount.Event` into exactly one user-visible line
//! (R-P12-5/6/7). The `export fn`s themselves stay in `main_wasm.zig`: they are
//! one-line trampolines over these bodies, because only the root may hold the
//! `app` pointer and only the root may declare the `consoleLog` import (R-P5-6),
//! which arrives here as `Devices.log`.
const std = @import("std");
const core = @import("core");
const origin = @import("origin");
const shim = @import("shim");

const OriginMount = origin.OriginMount;

/// The borrowed view of the origin stack this glue works through (the
/// `input_pump.Devices` pattern). Every field points into the heap `App`, which
/// never moves.
pub const Devices = struct {
    /// The allocator the staging buffer is grown from.
    allocator: std.mem.Allocator,
    mount: *OriginMount,
    /// The `App.ws_stage` slice, written in place when it has to grow.
    stage: *[]u8,
    /// Where a `failed`/`lost` line lands (`+Errors`, phase 12b).
    editor: *core.Editor,
    /// The root's `consoleLog` import — declared in `main_wasm.zig` only, so the
    /// native shim test root never references the symbol (R-P5-6). `callconv(.c)`
    /// because that is what an `extern "env"` function is.
    log: *const fn (ptr: [*]const u8, len: usize) callconv(.c) void,
};

/// The staging ceiling: a frame this large is not a 9P message we ever
/// negotiated (OriginMount proposes 8192), so refusing it early keeps a hostile
/// or confused peer from sizing our heap.
pub const stage_cap: u32 = 1 << 20;

/// Reserve `len` bytes of module memory for one inbound WebSocket frame and
/// hand the shim its address (R-P12-2). The shim writes the frame there through
/// the exported memory and immediately calls `wsPush`; nothing else touches the
/// buffer in between (JS is single-threaded and `wsPush` does not re-enter JS).
/// Returns 0 — "cannot stage", the shim drops the frame — on a frame larger than
/// any 9P message we would accept, or on allocation failure. (The pre-`init`
/// arm of that contract is the trampoline's `app orelse return 0`.)
pub fn stage(d: Devices, len: u32) u32 {
    if (len > stage_cap) return 0;
    // The shim stages EVERY record, including the empty payload of `open`, and
    // reads 0 as "cannot stage". So always hand back a real allocation: the
    // pointer of an empty slice is not guaranteed to be non-zero.
    const want = @max(len, 1);
    if (d.stage.len < want) {
        if (d.stage.len > 0) d.allocator.free(d.stage.*);
        d.stage.* = d.allocator.alloc(u8, want) catch {
            d.stage.* = &.{};
            return 0;
        };
    }
    return @intFromPtr(d.stage.ptr);
}

/// Deliver one inbound WebSocket record to the connection it belongs to
/// (R-P12-2). `kind` mirrors `shim.abi.WsKind`; `ptr[0..len]` is the staged
/// payload (empty for `open`). This ONLY queues — the module drains on `tick`,
/// so there is no JS→WASM re-entrancy. An unknown kind or a record for a
/// connection this session has walked away from is dropped.
pub fn push(d: Devices, id: u32, kind: u32, ptr: [*]const u8, len: u32) void {
    const k: shim.abi.WsKind = switch (kind) {
        1...4 => @enumFromInt(kind), // range-checked (no std.meta.intToEnum in 0.16)
        else => return,
    };
    d.mount.push(id, k, ptr[0..len]);
}

/// `Editor.OriginHook.redial` (R-P12-7): tear down whatever connection exists
/// and start a fresh dial. Returns immediately — `tick` reports the outcome.
pub fn redial(d: Devices) void {
    d.mount.dial();
}

/// Advance the origin connection and turn a state change into EXACTLY one line
/// (R-P12-5/6/7). A successful mount is expected behavior, not an error, so it
/// goes to the browser console only (user decision 2026-09-14 — it used to open a
/// `+Errors` window on every boot once warnings became visible in phase 12b);
/// failure and loss remain `+Errors` warnings. `now_ms` is the animation-frame
/// clock: freestanding wasm has no `std.Io` and no OS, so this is the module's
/// only source of time and the 10 s dial budget is counted in these ticks. A
/// failure here never touches the editor — an absent `/n/origin` is a supported
/// state, not an error.
pub fn poll(d: Devices, now_ms: u32) void {
    switch (d.mount.poll(now_ms)) {
        .none => {},
        .mounted => {
            const msg = "/n/origin: mounted";
            d.log(msg.ptr, msg.len);
        },
        .failed => |why| d.editor.warning("/n/origin: not mounted ({s})\n", .{why}),
        .lost => |why| d.editor.warning("/n/origin: disconnected ({s})\n", .{why}),
    }
}
