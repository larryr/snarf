//! The root's OPFS adapter: the `/mnt/opfs` half of `main_wasm.zig`, and a
//! straight mirror of `origin_glue.zig` (S-07 P-1 namespace module). Like its
//! siblings `screen.zig`, `input_pump.zig` and `origin_glue.zig` it works
//! through BORROWED POINTERS and never sees the `App` context — no new global
//! (R-P12e-5).
//!
//! It owns two things: the completion staging buffer behind the `fsStage` ABI
//! call, and the hand-off behind `fsPush` (ABI v6, R-P14b-6). The `export fn`s
//! themselves stay in `main_wasm.zig` as one-line trampolines, because only the
//! root may hold the `app` pointer.
//!
//! THE ONE INTERESTING LINE is in `push`: after handing the answer to the
//! device it calls `Server.retryParked()`. Caching a completion produces no
//! reply by itself — the request is sitting in the framework's park queue as a
//! raw T-frame, and the retry is what re-dispatches it (14a). Doing it here,
//! inside `fsPush`, rather than on the next `tick`, is what makes a chain of
//! dependent round trips (a multi-component walk, an open with OTRUNC) advance
//! one step per browser answer instead of one step per animation frame.
//! Re-entrancy is not a hazard: the retry may issue NEW `fsOp` calls back into
//! JS, and the shim's contract (§3a) is that `fsOp` only queues.
const std = @import("std");
const dev = @import("dev");
const ninep = @import("ninep");
const shim = @import("shim");

const DevOpfs = dev.opfs.DevOpfs;

/// The borrowed view of the OPFS stack this glue works through. Every field
/// points into the heap `App`, which never moves.
pub const Devices = struct {
    /// The allocator the staging buffer is grown from.
    allocator: std.mem.Allocator,
    dev: *DevOpfs,
    /// The in-process server whose parked requests a completion unblocks.
    srv: *ninep.server.Server,
    /// The `App.fs_stage` slice, written in place when it has to grow.
    stage: *[]u8,
};

/// The staging ceiling. A completion payload is a directory listing, a read of
/// at most one 9P message, or 17 bytes of stat; a megabyte is far past any of
/// them and keeps a confused shim from sizing our heap.
pub const stage_cap: u32 = 1 << 20;

/// Reserve `len` bytes of module memory for one completion payload and hand
/// the shim its address. The shim writes the payload there through the exported
/// memory and immediately calls `fsPush`; nothing else touches the buffer in
/// between (JS is single-threaded and `fsPush` re-enters JS only through
/// `fsOp`, which does not stage). Returns 0 — "cannot stage", the shim drops
/// the completion — on an implausible length or on allocation failure.
pub fn stage(d: Devices, len: u32) u32 {
    if (len > stage_cap) return 0;
    // The shim stages EVERY completion, including the empty payload of a
    // `remove`, and reads 0 as "cannot stage". So always hand back a real
    // allocation: the pointer of an empty slice is not guaranteed non-zero.
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

/// Deliver one `fsOp` completion and let the framework answer whatever it
/// unblocked. `status` mirrors `shim.abi.FsStatus`; an unrecognised value is
/// treated as `io` rather than dropped, so a shim bug surfaces as an Rerror the
/// user can see instead of an operation parked forever.
pub fn push(d: Devices, ticket: u32, status: u32, ptr: [*]const u8, len: u32) ninep.server.Error!void {
    const st: shim.abi.FsStatus = switch (status) {
        0...8 => @enumFromInt(status), // range-checked (no std.meta.intToEnum in 0.16)
        else => .io,
    };
    d.dev.complete(ticket, st, ptr[0..len]);
    _ = try d.srv.retryParked();
}

// NO TESTS HERE, deliberately: like `origin_glue.zig`, `screen.zig` and
// `input_pump.zig`, this file belongs to the `main_wasm` ROOT module, which
// `build.zig` never builds as a test root (a test root for it would need the
// wasm entry point's exports). The staging pair is exercised end to end against
// the real module by `tools/smoke_wasm.mjs`, exactly as `wsStage`/`wsPush` are.
