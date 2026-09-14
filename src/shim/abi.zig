//! The WASM env ABI: extern imports/exports + a version hash that both this
//! file and `web/shim.js` must agree on (S-06 §4). Drift becomes a build error
//! once the JS mirror + generated checksum land (OQ-BLD-2, still deferred).
//!
//! Phase 5 wires the first import: `blit`, the single merged present operation
//! (R-P5-4 — S-06 §4's `blit(imgId,…)+flush(rectsPtr,n)` collapses to one call).
//! R-P5-5/R-P5-7: the extern lives behind an `is_wasm` comptime gate so the
//! native shim test root (build.zig compiles this file for the host) never
//! references the symbol; `test_blit` is the native recording seam that stands
//! in for the browser import under `zig build test`.
//!
//! Phase 12 adds the `ws` trio — `wsOpen`/`wsSend`/`wsClose` (R-P12-2) — behind
//! the same gate, with `test_ws_*` seams. Inbound frames travel the other way,
//! browser → module, via the `wsStage`/`wsPush` exports (`src/main_wasm.zig`)
//! into `WsTransport.pushRecord`, so they need no import here.
//!
//! Phase 14b adds the LAST reserved import, `fsOp` (R-P14b-6): one request
//! record (`FsRecord.zig`) asking the browser's Origin Private File System to
//! do something, tagged with a ticket. Its completions come back the same way
//! the ws ones do — module → `fsStage`/`fsPush` exports — kept as a SEPARATE
//! export pair so the two record streams can never interleave.
const builtin = @import("builtin");

/// Bumped whenever the import/export surface changes (5→6 this phase,
/// R-P14b-6: the `fsOp` import and the `fsStage`/`fsPush` export pair joined
/// the surface, so a v5 shim — which provides no OPFS backend at all — cannot
/// serve `/mnt/opfs`). `web/shim.js` carries the mirror of this value; the two
/// must match, and the wasm module re-exports it via `abi_version()` so the
/// shim can check before calling `init()`.
pub const version: u32 = 6;

/// The kind tag of a raw input event crossing the ABI (R-P6-10). `web/shim.js`
/// mirrors these integers when it calls `pushEvent(kind, a, b, c, t)`; the wasm
/// adapter decodes them back into `dev.input.RawEvent`s. The record layout
/// (kind + four scalars) doubles as the future SAB-ring slot. Kept a MECHANICAL
/// mirror on the JS side — all input POLICY (chords, key transliteration to
/// runes) stays in Zig (ADR-0004). No new env imports: input flows the other way
/// (browser → module) via this export, so `is_wasm`/`js` are untouched.
pub const EventKind = enum(u8) {
    pointer_down = 1,
    pointer_up = 2,
    pointer_move = 3,
    wheel = 4,
    key = 5,
    mod_down = 6,
    mod_up = 7,
    /// The browser window changed size (R-GFX-05, S-03 §5): `a` = width,
    /// `b` = height, both in DEVICE pixels of the canvas backing store (at
    /// devicePixelRatio 1 those are CSS pixels — R-P12c-6 defers DPR > 1), `c`
    /// unused. The shim has already resized the canvas, which CLEARS it, so the
    /// module owes a full repaint on the next flush.
    resize = 8,
};

/// The kind tag of an inbound WebSocket record crossing the ABI (R-P12-2).
/// `web/shim.js` mirrors these integers when it calls `wsPush(id, kind, ptr,
/// len)`; the wasm adapter hands them to `WsTransport.pushRecord`. Payloads:
/// `data` carries exactly one 9P frame (`size[4]` == len, R-P12-3); `close` and
/// `err` carry a short human-readable reason (code + text) for the warning line;
/// `open` carries nothing. Named `err` because `error` is a Zig keyword — the JS
/// mirror spells it `error` (the integers are what must agree).
pub const WsKind = enum(u8) {
    open = 1,
    data = 2,
    close = 3,
    err = 4,
};

/// The `fsOp` request record and its two integer mirrors (`FsRecord.Op`,
/// `FsRecord.Status`). Re-exported here because the record IS part of the ABI
/// surface this file defines; the codec itself lives in its own file so it can
/// carry its own round-trip tests (S-07 P-1, R-P14b-6).
pub const FsRecord = @import("FsRecord.zig");
pub const FsOp = FsRecord.Op;
pub const FsStatus = FsRecord.Status;
/// The op-record format generation, mirrored in JS as `FS_OP_VERSION`.
pub const fs_op_version: u32 = FsRecord.version;

/// True only for the freestanding wasm build. A comptime const, so the `blit`
/// and `ws*` dispatches below prune the extern branch entirely in native builds
/// — the `env.blit`/`env.ws*` symbols are therefore never referenced when this
/// file is compiled for the host (R-P5-5, R-P12-9a).
pub const is_wasm = builtin.cpu.arch == .wasm32;

/// Present a dirty rectangle of the framebuffer. `ptr` points at RGBA8888
/// row-major pixels covering the full `fb_w × fb_h` display; `(x,y,w,h)` is the
/// half-open damage rect within it (R-P5-7).
pub const BlitFn = *const fn (ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void;

/// Native seam (R-P5-5): tests install a recorder here; `blit` calls it when it
/// is set and no wasm import exists. Null in production native builds ⇒ no-op.
pub var test_blit: ?BlitFn = null;

/// Dial the origin's 9P endpoint as connection `id` (R-P12-2). The URL is NOT a
/// parameter: per R-P12-1 the shim derives it from `location` (same-origin,
/// `/9p`), so the module never sees or chooses an endpoint. S-06 §4's sketch
/// spelled this `wsOpen(urlPtr, len, id)`; the URL argument is DROPPED.
pub const WsOpenFn = *const fn (id: u32) void;
/// Send one 9P frame as one binary WebSocket message (R-P12-3). `ptr[0..len]`
/// is a complete frame; the shim copies it out of wasm memory synchronously.
pub const WsSendFn = *const fn (id: u32, ptr: [*]const u8, len: u32) void;
/// Close connection `id`. Idempotent — a close of an unknown/dead id is a no-op.
pub const WsCloseFn = *const fn (id: u32) void;

/// Native seams (R-P5-5 pattern, R-P12-9a): the `WsTransport` tests install
/// recorders here so the outbound half is exercised with no browser and no
/// socket. Null in production native builds ⇒ no-op.
pub var test_ws_open: ?WsOpenFn = null;
pub var test_ws_send: ?WsSendFn = null;
pub var test_ws_close: ?WsCloseFn = null;

/// Ask the browser to perform ONE filesystem operation against the Origin
/// Private File System (R-P14b-6). `ptr[0..len]` is an encoded `FsRecord`; the
/// shim copies it out of wasm memory synchronously and answers LATER — never
/// re-entrantly — by staging a payload with `fsStage` and calling `fsPush`
/// with this same `ticket`. Tickets are the module's; the shim only echoes
/// them back. There is no cancel: a completion for a ticket the device has
/// forgotten (its fid was clunked) is simply dropped on arrival.
pub const FsOpFn = *const fn (ptr: [*]const u8, len: u32, ticket: u32) void;

/// Native seam (R-P5-5 pattern): `dev/opfs.zig`'s tests and `tools/`-side
/// harnesses install a scripted backend here, so the whole device — parking,
/// completion, error mapping — runs with no browser at all.
pub var test_fs_op: ?FsOpFn = null;

/// The browser-provided imports, referenced ONLY under wasm (see the dispatch
/// wrappers). Kept private so nothing outside this file can reach a raw extern.
const js = struct {
    extern "env" fn blit(ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void;
    extern "env" fn wsOpen(id: u32) void;
    extern "env" fn wsSend(id: u32, ptr: [*]const u8, len: u32) void;
    extern "env" fn wsClose(id: u32) void;
    extern "env" fn fsOp(ptr: [*]const u8, len: u32, ticket: u32) void;
};

/// Blit dispatch (R-P5-5/R-P5-7). Under wasm this calls the `env.blit` import;
/// natively it routes to `test_blit` if installed, else does nothing. Because
/// `is_wasm` is comptime-known, exactly one branch is analyzed per target — the
/// extern is unreachable (and unemitted) in the native shim test root.
pub fn blit(ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void {
    if (is_wasm) {
        js.blit(ptr, fb_w, fb_h, x, y, w, h);
    } else if (test_blit) |f| {
        f(ptr, fb_w, fb_h, x, y, w, h);
    }
}

/// Dial dispatch (R-P12-1/R-P12-2). Same comptime gate as `blit`: exactly one
/// branch is analyzed per target, so `env.wsOpen` is unreachable natively.
pub fn wsOpen(id: u32) void {
    if (is_wasm) {
        js.wsOpen(id);
    } else if (test_ws_open) |f| {
        f(id);
    }
}

/// Frame-send dispatch (R-P12-3). See `wsOpen` for the gating.
pub fn wsSend(id: u32, ptr: [*]const u8, len: u32) void {
    if (is_wasm) {
        js.wsSend(id, ptr, len);
    } else if (test_ws_send) |f| {
        f(id, ptr, len);
    }
}

/// Close dispatch. See `wsOpen` for the gating.
pub fn wsClose(id: u32) void {
    if (is_wasm) {
        js.wsClose(id);
    } else if (test_ws_close) |f| {
        f(id);
    }
}

/// OPFS request dispatch (R-P14b-6). Same comptime gate as `blit`/`wsOpen`, so
/// `env.fsOp` is unreachable — and unemitted — in every native build. With no
/// seam installed natively this is a no-op, which is exactly the "backend
/// absent" state: the ticket never completes, and the device's op stays parked.
pub fn fsOp(ptr: [*]const u8, len: u32, ticket: u32) void {
    if (is_wasm) {
        js.fsOp(ptr, len, ticket);
    } else if (test_fs_op) |f| {
        f(ptr, len, ticket);
    }
}

test "abi version is present and bumped to 6" {
    try @import("std").testing.expectEqual(@as(u32, 6), version);
}

test "abi: fs_op_version and the FsRecord re-exports are the ABI's" {
    const t = @import("std").testing;
    try t.expectEqual(@as(u32, 1), fs_op_version);
    try t.expectEqual(FsRecord.Op.stat, FsOp.stat);
    try t.expectEqual(FsRecord.Status.ok, FsStatus.ok);
}

test "abi: fsOp routes to the native test seam" {
    const t = @import("std").testing;
    const Rec = struct {
        var len: u32 = 0;
        var ticket: u32 = 0;
        fn capture(_: [*]const u8, l: u32, tk: u32) void {
            len = l;
            ticket = tk;
        }
    };
    test_fs_op = Rec.capture;
    defer test_fs_op = null;
    var buf: [64]u8 = undefined;
    const n = try (FsRecord{ .op = .list, .path = "/" }).encode(&buf);
    fsOp(buf[0..n].ptr, @intCast(n), 42);
    try t.expectEqual(@as(u32, @intCast(n)), Rec.len);
    try t.expectEqual(@as(u32, 42), Rec.ticket);
}

test "abi WsKind integer values match the shim mirror" {
    const t = @import("std").testing;
    try t.expectEqual(@as(u8, 1), @intFromEnum(WsKind.open));
    try t.expectEqual(@as(u8, 2), @intFromEnum(WsKind.data));
    try t.expectEqual(@as(u8, 3), @intFromEnum(WsKind.close));
    try t.expectEqual(@as(u8, 4), @intFromEnum(WsKind.err));
}

test "abi EventKind integer values match the shim mirror" {
    const t = @import("std").testing;
    try t.expectEqual(@as(u8, 1), @intFromEnum(EventKind.pointer_down));
    try t.expectEqual(@as(u8, 2), @intFromEnum(EventKind.pointer_up));
    try t.expectEqual(@as(u8, 3), @intFromEnum(EventKind.pointer_move));
    try t.expectEqual(@as(u8, 4), @intFromEnum(EventKind.wheel));
    try t.expectEqual(@as(u8, 5), @intFromEnum(EventKind.key));
    try t.expectEqual(@as(u8, 6), @intFromEnum(EventKind.mod_down));
    try t.expectEqual(@as(u8, 7), @intFromEnum(EventKind.mod_up));
    try t.expectEqual(@as(u8, 8), @intFromEnum(EventKind.resize));
}

test "abi: EventKind.resize is 8 and version is 5 (T9)" {
    // Traceability pin for phase 12c's contract §4 T9 — the facts themselves
    // are already covered above ("abi version is present and bumped to 6",
    // "abi EventKind integer values match the shim mirror"); this test just
    // names them together as the T9 acceptance point. The NAME is frozen at
    // the generation that minted it (12c, ABI 5); the assertion tracks the
    // live `version`, which phase 14b moved to 6.
    const t = @import("std").testing;
    try t.expectEqual(@as(u8, 8), @intFromEnum(EventKind.resize));
    try t.expectEqual(@as(u32, 6), version); // phase 12c froze 5; 14b bumps to 6
}
