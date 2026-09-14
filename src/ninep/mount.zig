//! mount.zig — ordered mount table / `Namespace` with UNION mounts (S-02 §1).
//!
//! A `Namespace` is a per-instance ordered table `path prefix → ordered list of
//! (client, root fid)`. `resolve` does longest-prefix match on path COMPONENT
//! boundaries (never a bare string prefix: `/mnt/host` must not match
//! `/mnt/hostx`).
//!
//! ## Unions (phase 12d, OQ-9P-1 resolved YES)
//!
//! This is the kernel's `Mhead`/`Mount` chain, flattened: one `Entry` per mount
//! point (`Mhead`), an ordered `targets` list (the `Mount` chain) underneath
//! (`9/port/chan.c:646-760 cmount`). `bind`'s flag mirrors `MREPL`/`MBEFORE`/
//! `MAFTER` (`sys/include/libc.h:538-540`): REPL discards the existing chain
//! (`chan.c:739-742`), BEFORE prepends and AFTER appends (`chan.c:744-753`).
//! `MCREATE`/`MCACHE` are out of scope (no create, no cache yet).
//!
//! Walking and reading THROUGH a union lives in `nsdir.zig`; this file only
//! keeps the table. `resolve` hands back the whole `Entry`, so its shape is
//! unchanged from v1 (ruling R-P12d-1).
//!
//! `list` renders the table `ns(1)`-style for `/mnt/snarf-self/ns` (S-02 §1.3 —
//! Snarf has no `/dev` server of its own, ruling R-P13a-4).
//!
//! Imports: std + client.zig + nspath.zig only (S-07 §6).
const std = @import("std");
const Client = @import("client.zig").Client;
const nspath = @import("nspath.zig");

/// Which end of the union a `bind` lands on. [libc.h:538-540 MREPL/MBEFORE/MAFTER]
pub const BindFlag = enum {
    /// MREPL: the new target replaces the whole chain (chan.c:739-742).
    replace,
    /// MBEFORE: "mount goes before others in union directory" — index 0.
    before,
    /// MAFTER: "mount goes after others in union directory" — appended.
    after,
};

/// One 9P endpoint a mount point resolves to: the client driving it, the fid
/// already attached to its root, and the flag it was bound with (the kernel's
/// `Mount.mflag`, which `/proc/n/ns` prints back — devproc.c:623-638).
pub const Target = struct {
    client: *Client,
    root_fid: u32,
    flag: BindFlag = .replace,
};

/// One entry in the ordered mount table: a mount POINT and the union of
/// targets stacked at it, in bind order (the kernel's `Mhead` + its `Mount`
/// chain). `prefix` is an owned, canonical copy (see `nspath.canonicalize`):
/// always absolute, no trailing '/' except the root "/", no empty/"."/".."
/// component. `targets` is never empty — an entry that loses its last target
/// is removed from the table.
pub const Entry = struct {
    prefix: []u8,
    targets: std.ArrayList(Target) = .empty,

    /// The head of the union: the target a walk tries first and the one an
    /// exact-match resolve uses (`mh->mount->to`, chan.c:1030). Callers that
    /// want the whole union walk it through `nsdir`, not here (R-P12d-1).
    pub fn first(self: *const Entry) Target {
        return self.targets.items[0];
    }
};

/// The result of a successful `resolve`: the winning table entry and the
/// path remainder to walk from its root (leading '/' stripped; "" on an
/// exact match).
pub const Resolved = struct {
    entry: *const Entry,
    remainder: []const u8,
};

pub const Error = error{
    /// No mounted prefix is a component-wise ancestor of the path, or
    /// `unmount`/`unbindTarget` named something that is not in the table.
    NotMounted,
    /// `mount` (not `bind`) named a prefix that is already mounted exactly.
    MountExists,
    /// The path/prefix is not absolute, or has an empty/"."/".." component.
    BadPath,
    OutOfMemory,
};

/// Ordered table of path-prefix → 9P-target bindings (S-02 §1). Prefixes are
/// unique: `mount` rejects an exact duplicate and `bind` stacks onto (or
/// replaces) the existing entry, so `resolve` can never tie.
pub const Namespace = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Namespace {
        return .{ .allocator = allocator };
    }

    /// Frees the owned prefix strings, the target lists, and the table itself.
    /// Clunks NOTHING: boot owns the root fids (and the `Client`s they belong
    /// to) and tears them down independently of the namespace (contract R7).
    pub fn deinit(self: *Namespace) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.prefix);
            e.targets.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Mount `client`/`root_fid` at `prefix` as the sole target. An exact
    /// duplicate prefix is rejected with `error.MountExists`; stacking a union
    /// there is `bind`'s job (`.before`/`.after`), exactly as `mount(2)`'s
    /// MREPL/MBEFORE/MAFTER flags decide in Plan 9.
    pub fn mount(self: *Namespace, prefix: []const u8, client: *Client, root_fid: u32) Error!void {
        const canon = try nspath.canonicalize(self.allocator, prefix);
        errdefer self.allocator.free(canon);
        if (self.findExact(canon) != null) return error.MountExists;
        try self.addEntry(canon, .{ .client = client, .root_fid = root_fid, .flag = .replace });
    }

    /// Bind `client`/`root_fid` at `prefix` with union order `flag`
    /// (`cmount`, chan.c:646-760):
    ///   * `.replace` (MREPL) drops whatever chain was there (chan.c:739-742);
    ///   * `.before` (MBEFORE) inserts at the head of the union;
    ///   * `.after` (MAFTER) appends at the tail.
    /// On a prefix that is not mounted yet, all three simply create the entry.
    ///
    /// Unlike the kernel we do not require the mount point to exist first
    /// (chan.c:662 errors when binding BEFORE/AFTER onto a non-directory):
    /// Snarf has no root filesystem to hold the mount points, so the table
    /// itself synthesizes them (R-9P-16, see `nsdir`).
    pub fn bind(
        self: *Namespace,
        prefix: []const u8,
        client: *Client,
        root_fid: u32,
        flag: BindFlag,
    ) Error!void {
        const canon = try nspath.canonicalize(self.allocator, prefix);
        const target = Target{ .client = client, .root_fid = root_fid, .flag = flag };
        if (self.findExact(canon)) |entry| {
            self.allocator.free(canon); // reuse the already-owned prefix
            switch (flag) {
                .replace => {
                    entry.targets.clearRetainingCapacity();
                    try entry.targets.append(self.allocator, target);
                },
                .before => try entry.targets.insert(self.allocator, 0, target),
                .after => try entry.targets.append(self.allocator, target),
            }
            return;
        }
        errdefer self.allocator.free(canon);
        try self.addEntry(canon, target);
    }

    /// Drop the whole mount point — every union member at `prefix`
    /// (`cunmount(mnt, nil)`, chan.c:762-820). `error.NotMounted` if nothing is
    /// mounted exactly there. Clunks nothing (see `deinit`).
    pub fn unmount(self: *Namespace, prefix: []const u8) Error!void {
        const canon = try nspath.canonicalize(self.allocator, prefix);
        defer self.allocator.free(canon);
        for (self.entries.items, 0..) |*e, i| {
            if (!std.mem.eql(u8, e.prefix, canon)) continue;
            self.allocator.free(e.prefix);
            e.targets.deinit(self.allocator);
            _ = self.entries.orderedRemove(i);
            return;
        }
        return error.NotMounted;
    }

    /// Drop ONE union member from `prefix` — the kernel's
    /// `cunmount(mnt, mounted)` (chan.c:762-820), which unlinks the single
    /// `Mount` whose channel matches. Matching is by (client, root fid). The
    /// surviving members keep their order; an entry that loses its last member
    /// is removed outright. `error.NotMounted` if the prefix is absent or holds
    /// no such member.
    pub fn unbindTarget(self: *Namespace, prefix: []const u8, client: *Client, root_fid: u32) Error!void {
        const canon = try nspath.canonicalize(self.allocator, prefix);
        defer self.allocator.free(canon);
        for (self.entries.items, 0..) |*e, i| {
            if (!std.mem.eql(u8, e.prefix, canon)) continue;
            for (e.targets.items, 0..) |t, ti| {
                if (t.client != client or t.root_fid != root_fid) continue;
                _ = e.targets.orderedRemove(ti);
                if (e.targets.items.len == 0) {
                    self.allocator.free(e.prefix);
                    e.targets.deinit(self.allocator);
                    _ = self.entries.orderedRemove(i);
                }
                return;
            }
            return error.NotMounted; // prefix is there, this member is not
        }
        return error.NotMounted;
    }

    /// Longest-prefix match of `path` against the table, on path COMPONENT
    /// boundaries: `/mnt/host` matches `/mnt/host` (remainder "") and
    /// `/mnt/host/x` (remainder "x"), but never `/mnt/hostx`. A root entry
    /// "/" matches every absolute path. `path` must be absolute (else
    /// `error.BadPath`); it is used verbatim otherwise (no "."/".."
    /// canonicalization — that policing applies to mounted prefixes only).
    ///
    /// The winning entry may hold a union: `entry.targets` is that union in
    /// bind order, and `nsdir.walk` is what tries them (R-P12d-1).
    pub fn resolve(self: *const Namespace, path: []const u8) error{ NotMounted, BadPath }!Resolved {
        if (path.len == 0 or path[0] != '/') return error.BadPath;
        var best: ?*const Entry = null;
        var best_remainder: []const u8 = "";
        for (self.entries.items) |*e| {
            const rem = nspath.matchPrefix(e.prefix, path) orelse continue;
            if (best == null or e.prefix.len > best.?.prefix.len) {
                best = e;
                best_remainder = rem;
            }
        }
        const entry = best orelse return error.NotMounted;
        return .{ .entry = entry, .remainder = best_remainder };
    }

    /// Render the table `ns(1)`-style, insertion order, for `/mnt/snarf-self/ns`
    /// (S-02 §1). One line per union member, mirroring `/proc/n/ns`
    /// (devproc.c:954-966 `mount [flags] ...` / `bind [flags] ...`):
    /// the head of each union prints as `mount <prefix>`, every stacked
    /// member as `bind -b <prefix>` or `bind -a <prefix>` per its own flag
    /// (`int2flag`, devproc.c:623-638). We have no server names to print —
    /// a `Client` is not a path — so the line carries the mount point only;
    /// `ns(1)`'s "an rc script that could recreate the name space" is not a
    /// claim we can make yet.
    pub fn list(self: *const Namespace, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.entries.items) |e| {
            for (e.targets.items, 0..) |t, i| {
                if (i == 0) {
                    try w.print("mount {s}\n", .{e.prefix});
                } else {
                    try w.print("bind -{c} {s}\n", .{ flagChar(t.flag), e.prefix });
                }
            }
        }
    }

    /// Append a fresh entry owning `canon` with one target.
    fn addEntry(self: *Namespace, canon: []u8, target: Target) Error!void {
        var entry = Entry{ .prefix = canon };
        errdefer entry.targets.deinit(self.allocator);
        try entry.targets.append(self.allocator, target);
        try self.entries.append(self.allocator, entry);
    }

    /// The entry whose canonical prefix equals `canon` exactly, if any.
    fn findExact(self: *Namespace, canon: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.prefix, canon)) return e;
        }
        return null;
    }
};

/// `ns(1)`/`int2flag` letter for a stacked member (devproc.c:630-633). A
/// `.replace` member can only ever be the head of a chain, which prints as
/// `mount`, so it never reaches this function; 'a' is the harmless fallback.
fn flagChar(flag: BindFlag) u8 {
    return switch (flag) {
        .before => 'b',
        .after => 'a',
        .replace => 'a',
    };
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

    try ns.bind("/dev", &c9, 9, .replace);
    try testing.expectEqual(@as(usize, 1), ns.entries.items.len);

    const r = try ns.resolve("/dev/x");
    try testing.expectEqual(&c9, r.entry.first().client);
    try testing.expectEqual(@as(u32, 9), r.entry.first().root_fid);
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

test "mount: bind(.after) then bind(.before) orders [before, first, after] (T1)" {
    var c1: Client = undefined; // the original mount
    var c2: Client = undefined; // .after
    var c3: Client = undefined; // .before
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/bin", &c1, 1);
    try ns.bind("/bin", &c2, 2, .after);
    try ns.bind("/bin", &c3, 3, .before);

    const r = try ns.resolve("/bin");
    try testing.expectEqual(@as(usize, 3), r.entry.targets.items.len);
    try testing.expectEqual(&c3, r.entry.targets.items[0].client);
    try testing.expectEqual(&c1, r.entry.targets.items[1].client);
    try testing.expectEqual(&c2, r.entry.targets.items[2].client);
}

test "mount: bind(.replace) on a union collapses it to one target (T2)" {
    var c1: Client = undefined;
    var c2: Client = undefined;
    var c3: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/bin", &c1, 1);
    try ns.bind("/bin", &c2, 2, .after);
    try testing.expectEqual(@as(usize, 2), (try ns.resolve("/bin")).entry.targets.items.len);

    try ns.bind("/bin", &c3, 9, .replace);
    const r = try ns.resolve("/bin");
    try testing.expectEqual(@as(usize, 1), r.entry.targets.items.len);
    try testing.expectEqual(&c3, r.entry.first().client);
    try testing.expectEqual(@as(u32, 9), r.entry.first().root_fid);
}

test "mount: unmount removes the whole entry (T3)" {
    var c1: Client = undefined;
    var c2: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/n/origin", &c1, 1);
    try ns.bind("/n/origin", &c2, 2, .after);
    try testing.expectEqual(@as(usize, 1), ns.entries.items.len);

    try ns.unmount("/n/origin");
    try testing.expectError(error.NotMounted, ns.resolve("/n/origin"));
    try testing.expectEqual(@as(usize, 0), ns.entries.items.len);

    try testing.expectError(error.NotMounted, ns.unmount("/n/origin"));
}

test "mount: unbindTarget removes one member, and the last one removes the entry (T4)" {
    var c1: Client = undefined;
    var c2: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/bin", &c1, 1);
    try ns.bind("/bin", &c2, 2, .after);

    try ns.unbindTarget("/bin", &c1, 1);
    const r = try ns.resolve("/bin");
    try testing.expectEqual(@as(usize, 1), r.entry.targets.items.len);
    try testing.expectEqual(&c2, r.entry.first().client);

    try ns.unbindTarget("/bin", &c2, 2);
    try testing.expectError(error.NotMounted, ns.resolve("/bin"));

    // Absent prefix, and absent member of a present prefix, both NotMounted.
    try testing.expectError(error.NotMounted, ns.unbindTarget("/bin", &c1, 1));
    try ns.mount("/dev", &c1, 5);
    try testing.expectError(error.NotMounted, ns.unbindTarget("/dev", &c2, 99));
}

test "mount: list renders a union in table order (T5)" {
    var c1: Client = undefined;
    var c2: Client = undefined;
    var c3: Client = undefined;
    var ns = Namespace.init(testing.allocator);
    defer ns.deinit();

    try ns.mount("/n/origin", &c1, 1);
    try ns.bind("/bin", &c2, 2, .after);
    try ns.bind("/bin", &c3, 3, .before);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ns.list(&w);

    try testing.expectEqualStrings(
        "mount /n/origin\nmount /bin\nbind -a /bin\n",
        w.buffered(),
    );
}
