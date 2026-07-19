//! mount.zig — ordered mount table / `Namespace` (S-02 §1).
//!
//! A `Namespace` is a per-instance ordered table `path prefix → (client, root
//! fid)`. `resolve` does longest-prefix match on path COMPONENT boundaries
//! (never a bare string prefix: `/mnt/host` must not match `/mnt/hostx`).
//! v1 has `mount` (rejects an exact-duplicate prefix) and `bind`
//! (replace-or-insert) — "no unions" per S-02 §1 / contract R7, OQ-9P-1.
//! `list` renders the table `ns(1)`-style, one `mount <prefix>` line per
//! entry in insertion order, for `/dev/ns` (S-02 §1) later.
//!
//! Imports: std + client.zig only (S-07 §6).
const std = @import("std");
const Client = @import("client.zig").Client;

/// One 9P endpoint a mount point resolves to: the client driving it and the
/// fid already attached to its root.
pub const Target = struct {
    client: *Client,
    root_fid: u32,
};

/// One entry in the ordered mount table. `prefix` is an owned, canonical
/// copy (see `canonicalize`): always absolute, no trailing '/' except the
/// root "/", no empty/"."/".." component.
///
/// Extension point: v1 carries a single `Target`. A future union mount
/// (stacking several targets at one prefix, R7/OQ-9P-1) would widen this to
/// a list of `Target`s tried in bind order — `Resolved` would not need to
/// change shape, since it hands back the winning `*const Entry` and the
/// remainder; whatever walks a union would iterate `entry`'s targets itself.
pub const Entry = struct {
    prefix: []u8,
    target: Target,
};

/// The result of a successful `resolve`: the winning table entry and the
/// path remainder to walk from its root (leading '/' stripped; "" on an
/// exact match).
pub const Resolved = struct {
    entry: *const Entry,
    remainder: []const u8,
};

pub const Error = error{
    /// No mounted prefix is a component-wise ancestor of the path.
    NotMounted,
    /// `mount` (not `bind`) named a prefix that is already mounted exactly.
    MountExists,
    /// The path/prefix is not absolute, or has an empty/"."/".." component.
    BadPath,
    OutOfMemory,
};

/// Ordered table of path-prefix → 9P-target bindings (S-02 §1). Ties in
/// `resolve` cannot occur: `mount` rejects an exact-duplicate prefix and
/// `bind` replaces in place, so canonical prefixes stay unique.
pub const Namespace = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Namespace {
        return .{ .allocator = allocator };
    }

    /// Frees the owned prefix strings and the table itself. Clunks NOTHING:
    /// boot owns the root fids (and the `Client`s they belong to) and tears
    /// them down independently of the namespace (contract R7).
    pub fn deinit(self: *Namespace) void {
        for (self.entries.items) |e| self.allocator.free(e.prefix);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Mount `client`/`root_fid` at `prefix`. An exact-duplicate prefix is
    /// rejected with `error.MountExists` — Plan 9's `bind(2)` can stack a
    /// union there; v1 cannot (see `bind` and the `Entry` extension-point
    /// comment).
    pub fn mount(self: *Namespace, prefix: []const u8, client: *Client, root_fid: u32) Error!void {
        const canon = try canonicalize(self.allocator, prefix);
        errdefer self.allocator.free(canon);
        if (self.findExact(canon) != null) return error.MountExists;
        try self.entries.append(self.allocator, .{
            .prefix = canon,
            .target = .{ .client = client, .root_fid = root_fid },
        });
    }

    /// Bind `client`/`root_fid` at `prefix`, replacing whatever was mounted
    /// there (insert if nothing was). Divergence from Plan 9 `bind(2)`
    /// (R7/OQ-9P-1): real `bind` can layer a union (MREPL/MBEFORE/MAFTER) of
    /// several targets at one prefix; v1 always replaces in place — one
    /// `Target` per `Entry`. Union bind semantics are future work.
    pub fn bind(self: *Namespace, prefix: []const u8, client: *Client, root_fid: u32) Error!void {
        const canon = try canonicalize(self.allocator, prefix);
        if (self.findExact(canon)) |entry| {
            self.allocator.free(canon); // reuse the already-owned prefix
            entry.target = .{ .client = client, .root_fid = root_fid };
            return;
        }
        errdefer self.allocator.free(canon);
        try self.entries.append(self.allocator, .{
            .prefix = canon,
            .target = .{ .client = client, .root_fid = root_fid },
        });
    }

    /// Longest-prefix match of `path` against the table, on path COMPONENT
    /// boundaries: `/mnt/host` matches `/mnt/host` (remainder "") and
    /// `/mnt/host/x` (remainder "x"), but never `/mnt/hostx`. A root entry
    /// "/" matches every absolute path. `path` must be absolute (else
    /// `error.BadPath`); it is used verbatim otherwise (no "."/".."
    /// canonicalization — that policing applies to mounted prefixes only).
    pub fn resolve(self: *const Namespace, path: []const u8) error{ NotMounted, BadPath }!Resolved {
        if (path.len == 0 or path[0] != '/') return error.BadPath;
        var best: ?*const Entry = null;
        var best_remainder: []const u8 = "";
        for (self.entries.items) |*e| {
            const rem = matchPrefix(e.prefix, path) orelse continue;
            if (best == null or e.prefix.len > best.?.prefix.len) {
                best = e;
                best_remainder = rem;
            }
        }
        const entry = best orelse return error.NotMounted;
        return .{ .entry = entry, .remainder = best_remainder };
    }

    /// Render the table `ns(1)`-style: one `mount <prefix>\n` line per entry,
    /// insertion order (S-02 §1, for `/dev/ns`).
    pub fn list(self: *const Namespace, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.entries.items) |e| {
            try w.print("mount {s}\n", .{e.prefix});
        }
    }

    /// The entry whose canonical prefix equals `canon` exactly, if any.
    fn findExact(self: *Namespace, canon: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.prefix, canon)) return e;
        }
        return null;
    }
};

/// Does `path` fall under mounted `prefix` at a component boundary? Returns
/// the remainder (leading '/' stripped, "" on exact match) or null. Both
/// arguments are assumed absolute; `prefix` is assumed canonical (no
/// trailing '/' unless it IS "/").
fn matchPrefix(prefix: []const u8, path: []const u8) ?[]const u8 {
    if (prefix.len == 1) return path[1..]; // root "/": matches everything
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len == prefix.len) return path[prefix.len..]; // exact match, ""
    if (path[prefix.len] != '/') return null; // e.g. prefix "/dev", path "/devx"
    return path[prefix.len + 1 ..];
}

/// Canonicalize a mount-table prefix into a freshly owned copy: must be
/// absolute; a single trailing '/' is stripped (except when the whole
/// prefix collapses to root "/"); any empty (e.g. "//"), "." or ".."
/// component is `error.BadPath`.
fn canonicalize(allocator: std.mem.Allocator, prefix: []const u8) Error![]u8 {
    if (prefix.len == 0 or prefix[0] != '/') return error.BadPath;
    if (std.mem.eql(u8, prefix, "/")) return allocator.dupe(u8, "/");

    var end = prefix.len;
    while (end > 1 and prefix[end - 1] == '/') end -= 1;
    const trimmed = prefix[0..end];
    if (trimmed.len == 1) return allocator.dupe(u8, "/"); // e.g. "//"

    var it = std.mem.splitScalar(u8, trimmed[1..], '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return error.BadPath;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return error.BadPath;
    }
    return allocator.dupe(u8, trimmed);
}

// ==========================================================================
// Tests (§T-mount)
// ==========================================================================
const testing = std.testing;

test "mount: root fallback" {
    var c: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/", &c, 0);

    const r1 = try ns.resolve("/x");
    try testing.expectEqualStrings("/", r1.entry.prefix);
    try testing.expectEqualStrings("x", r1.remainder);

    const r2 = try ns.resolve("/");
    try testing.expectEqualStrings("/", r2.entry.prefix);
    try testing.expectEqualStrings("", r2.remainder);
}

test "mount: longest prefix nested" {
    var c_root: Client = undefined;
    var c_dev: Client = undefined;
    var c_draw: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/", &c_root, 0);
    try ns.mount("/dev", &c_dev, 1);
    try ns.mount("/dev/draw", &c_draw, 2);

    const r1 = try ns.resolve("/dev/draw/new");
    try testing.expectEqualStrings("/dev/draw", r1.entry.prefix);
    try testing.expectEqualStrings("new", r1.remainder);

    const r2 = try ns.resolve("/dev/mouse");
    try testing.expectEqualStrings("/dev", r2.entry.prefix);
    try testing.expectEqualStrings("mouse", r2.remainder);

    const r3 = try ns.resolve("/x");
    try testing.expectEqualStrings("/", r3.entry.prefix);
    try testing.expectEqualStrings("x", r3.remainder);

    const r4 = try ns.resolve("/dev/draw");
    try testing.expectEqualStrings("/dev/draw", r4.entry.prefix);
    try testing.expectEqualStrings("", r4.remainder);
}

test "mount: non-prefix trap" {
    var c: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/mnt/host", &c, 0);

    try testing.expectError(error.NotMounted, ns.resolve("/mnt/hostx"));

    const r = try ns.resolve("/mnt/host/x");
    try testing.expectEqualStrings("/mnt/host", r.entry.prefix);
    try testing.expectEqualStrings("x", r.remainder);
}

test "mount: exact match empty remainder" {
    var c: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/mnt/host", &c, 0);

    const r = try ns.resolve("/mnt/host");
    try testing.expectEqualStrings("/mnt/host", r.entry.prefix);
    try testing.expectEqualStrings("", r.remainder);
}

test "mount: duplicate mount" {
    var c1: Client = undefined;
    var c2: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/dev", &c1, 0);
    try testing.expectError(error.MountExists, ns.mount("/dev", &c2, 1));
    try testing.expectEqual(@as(usize, 1), ns.entries.items.len);
}

test "mount: bind rebinding" {
    var c2: Client = undefined;
    var c9: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/dev", &c2, 2);
    try testing.expectEqual(@as(usize, 1), ns.entries.items.len);

    try ns.bind("/dev", &c9, 9);
    try testing.expectEqual(@as(usize, 1), ns.entries.items.len);

    const r = try ns.resolve("/dev/x");
    try testing.expectEqual(&c9, r.entry.target.client);
    try testing.expectEqual(@as(u32, 9), r.entry.target.root_fid);
    try testing.expectEqualStrings("x", r.remainder);
}

test "mount: bad paths" {
    var c: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try testing.expectError(error.BadPath, ns.mount("dev", &c, 0));
    try testing.expectError(error.BadPath, ns.resolve("dev"));

    // A trailing slash normalizes away.
    try ns.mount("/dev/", &c, 0);
    const r = try ns.resolve("/dev/x");
    try testing.expectEqualStrings("/dev", r.entry.prefix);
    try testing.expectEqualStrings("x", r.remainder);

    try testing.expectError(error.BadPath, ns.mount("/a/../b", &c, 0));
}

test "mount: list format" {
    var c1: Client = undefined;
    var c2: Client = undefined;
    var c3: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/", &c1, 0);
    try ns.mount("/dev", &c2, 1);
    try ns.mount("/mnt/host", &c3, 2);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ns.list(&w);

    try testing.expectEqualStrings(
        "mount /\nmount /dev\nmount /mnt/host\n",
        w.buffered(),
    );
}
