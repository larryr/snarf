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
const builtin = @import("builtin");

/// Bumped whenever the import/export surface changes (3→4 this phase, R-P12-2:
/// the `ws` import trio + the `wsStage`/`wsPush` exports). `web/shim.js` carries
/// the mirror of this value; the two must match, and the wasm module re-exports
/// it via `abi_version()` so the shim can check before calling `init()`.
pub const version: u32 = 4;

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

/// The browser-provided imports, referenced ONLY under wasm (see the dispatch
/// wrappers). Kept private so nothing outside this file can reach a raw extern.
const js = struct {
    extern "env" fn blit(ptr: [*]const u8, fb_w: u32, fb_h: u32, x: u32, y: u32, w: u32, h: u32) void;
    extern "env" fn wsOpen(id: u32) void;
    extern "env" fn wsSend(id: u32, ptr: [*]const u8, len: u32) void;
    extern "env" fn wsClose(id: u32) void;
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

test "abi version is present and bumped to 4" {
    try @import("std").testing.expectEqual(@as(u32, 4), version);
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
}
