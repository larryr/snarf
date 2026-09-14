//! `host` — the NATIVE host's device layer (ADR-0005, phase 15).
//!
//! The browser host's devices live in `src/dev` (a canvas backend, a browser
//! input device); the native host's live here. Both are *below* the R-OV-03
//! boundary: `core`, `draw` and `ninep` never import either (S-07 §6). The
//! editor sees the same namespace on both hosts — `/dev/draw`, `/dev/mouse`,
//! `/dev/kbd` — and nothing above the device layer can tell which host it is
//! running on except by whether a warp actually moves the pointer.
//!
//! `devdraw/` is the one host implemented so far: plan9port's own display
//! server, driven over its `drawfcall` pipe protocol as a peer PROCESS (never
//! linked — ADR-0002 holds, ADR-0005 §3).
//!
//!     wsys.zig      the drawfcall codec (pure)
//!     Conn.zig      one connection: spawn, reader thread, tag mux, long polls
//!     dev_draw.zig  9P `Ops` for /dev/draw  — forwards to Twrdraw/Trddraw
//!     dev_input.zig 9P `Ops` for /dev/{mouse,kbd,cursor,snarf,label}
//!
//! Imports: `ninep` (the server framework) + `dev` (the `/dev/mouse` record
//! formatter, shared verbatim with the browser device so the two hosts cannot
//! drift). Never `core`, never `draw`.
pub const wsys = @import("devdraw/wsys.zig");
pub const Conn = wsys.Conn;
pub const dev_draw = @import("devdraw/dev_draw.zig");
pub const dev_input = @import("devdraw/dev_input.zig");

test {
    _ = wsys;
    _ = Conn;
    _ = dev_draw;
    _ = dev_input;
}
