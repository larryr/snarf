//! ns_boot — assembling the BOOT NAMESPACE (S-02 §1.3, contract §3d).
//!
//! Through phase 12 `App.ns` was empty at boot: the draw device, the input
//! device and the served `/mnt/snarf-self` tree all existed, but each was
//! reached through its own captured `ninep.Client`, never by path, and the
//! served tree was not even served ("runtime mounting waits for the first
//! in-editor client", R-P10-E). That is the one thing standing between the
//! editor and the paper's namespace: a window cannot list `/` if `/` has
//! nothing under it. This file mounts the three of them.
//!
//! Split out of `main_wasm.zig` for the same reason as `screen.zig`,
//! `input_pump.zig` and `origin_glue.zig` (S-07's ~400-line cap, R-P12c-5): it
//! takes BORROWED pointers into the entry point's heap boot context rather than
//! the `App` struct itself, so it holds no state of its own.
//!
//! What the table holds once `init` returns (13b's boot window lists it):
//!
//!     /dev            → the input device ("input" root: mouse kbd ctl)
//!     /dev/draw       → the draw device (devdraw's root IS the draw directory)
//!     /mnt/snarf-self → the served editor tree (core/served/fsys.zig)
//!
//! `/` and `/mnt` are not mounted by anyone; they are SYNTHESIZED from the
//! prefixes above (devroot.c's role, R-9P-16, `ninep.nsdir`). `/n/origin` and
//! `/bin` join later and only if the origin attaches (`origin_glue`), so a
//! `ListDirJob("/")` reads `dev/ mnt/` with the origin down and
//! `bin/ dev/ mnt/ n/` with it up.
//!
//! Imports: `core` + `ninep` (this is boot glue, not core — it sees the
//! entry point's device stacks).
const std = @import("std");
const core = @import("core");
const ninep = @import("ninep");

/// The in-process `/mnt/snarf-self` server and its client — the third 9P stack
/// in the module, assembled exactly like the draw and input ones (the "devdraw
/// pattern"). Lives in the entry point's heap `App` because the server captures
/// `&fsys`, the client captures the pipe, and the client's pump captures
/// `&srv`: nothing here may move once `start` has run.
///
/// This RETIRES R-P10-E (wave 10a's "runtime mounting waits for the first
/// in-editor client"): the tree is served from boot, so the first client is the
/// editor itself.
pub const SelfTree = struct {
    fsys: core.served.fsys.Fsys = undefined,
    pipe: *ninep.chan.Pipe = undefined,
    srv: ninep.server.Server = undefined,
    cl: ninep.Client = undefined,
    root_fid: u32 = 0,

    /// Serve the tree bound to `ed` and mount it at `/mnt/snarf-self`
    /// (R-9P-12, R-EDIT-17). `ed` must already be initialised — `Fsys` resolves
    /// every window id through `ed.row` on each call, so it only needs the
    /// pointer, not a populated tree.
    pub fn start(
        self: *SelfTree,
        a: std.mem.Allocator,
        ed: *core.Editor,
        ns: *ninep.mount.Namespace,
    ) !void {
        self.fsys = core.served.fsys.Fsys.init(ed);
        self.pipe = try ninep.chan.Pipe.init(a, 16384);
        self.srv = try ninep.server.Server.init(
            a,
            self.pipe.serverEnd(),
            &core.served.fsys.Fsys.ops,
            &self.fsys,
            8192,
        );
        self.cl = try ninep.Client.init(a, self.pipe.clientEnd(), 8192);
        self.cl.pump = .{ .ctx = &self.srv, .run = pumpServer };
        _ = try self.cl.version(8192);
        const root = try self.cl.attach("larry", "");
        self.root_fid = root.fid;
        try ns.mount(mount_point, &self.cl, root.fid);
    }

    /// Drive the served tree one poll, from the entry point's `tick` — the same
    /// treatment the draw server gets. Every `Fsys` file answers synchronously
    /// (no parked reads), so one poll per frame drains whatever a client asked.
    pub fn poll(self: *SelfTree) !void {
        _ = try self.srv.poll();
    }
};

/// Where the served tree mounts. Settled with the user 2026-09-14: it stays
/// `/mnt/snarf-self` — Snarf makes no `/mnt/acme` compatibility claim.
pub const mount_point = "/mnt/snarf-self";

/// Mount the two device stacks (S-02 §1.3). `/dev/draw` is mounted SEPARATELY
/// from `/dev` rather than under it because they are two different servers:
/// the union machinery then synthesizes a `draw` child into `/dev`'s listing
/// (R-9P-16 — exactly phase 12d's T13 shape).
pub fn mountDevices(
    ns: *ninep.mount.Namespace,
    draw_cl: *ninep.Client,
    draw_root: u32,
    input_cl: *ninep.Client,
    input_root: u32,
) !void {
    try ns.mount("/dev/draw", draw_cl, draw_root);
    try ns.mount("/dev", input_cl, input_root);
}

/// Drive an in-process 9P server one poll at a time; wired as a client's pump
/// so its blocking setup RPCs (version/attach) advance the server.
fn pumpServer(ctx: *anyopaque) anyerror!void {
    const s: *ninep.server.Server = @ptrCast(@alignCast(ctx));
    _ = try s.poll();
}
