//! The ORIGIN-TRANSPORT SEAM (R-P12-7): the one thing `core` knows about the
//! connection its files arrive over. Namespace module (S-07 P-1) carved out of
//! `Editor.zig` verbatim in phase 16a; `Editor.OriginHook` is an alias of the
//! type below, so no call site moved.
//!
//! Imports: `std` only — this file names no editor type at all. That is the
//! point: the hook is an erased `ctx` plus one function pointer, the same
//! inversion as `draw.Backend` and the input device's vtables.

/// The origin-transport seam (R-P12-7), installed on `Editor.origin` by
/// whichever root owns the connection — `src/main_wasm.zig` in the browser, no
/// one in the native harnesses.
///
/// Deliberately ONE verb. The core has no business knowing that the origin is a
/// WebSocket, that it has a connection id, or whether it is currently up: it
/// asks for a re-dial and learns the outcome the same way the user does, from
/// the warning the connection's own poll emits when it resolves.
///
/// `core` may never import `shim` or `dev` (R-OV-03, R-CON-02, S-07 §6), so the
/// origin's WebSocket lives entirely outside it and reaches the editor two ways
/// only: through the 9P namespace (files) and through this hook (the one
/// command that must talk to the transport itself). `src/main_wasm.zig` installs
/// it after boot; every native harness leaves it null, which makes `Reconnect`
/// a single warning line instead of a crash.
pub const OriginHook = struct {
    ctx: *anyopaque,
    /// Close any live origin connection and start a fresh dial. Returns
    /// IMMEDIATELY: the dial is asynchronous (R-P12-5), so success or failure
    /// arrives later as one warning line from the platform's tick, NOT from
    /// this call. Infallible by contract — a re-dial that cannot even start
    /// reports itself through that same warning.
    redial: *const fn (ctx: *anyopaque) void,
};
