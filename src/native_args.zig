//! The native host's command line: acme's `ARGBEGIN … ARGEND` split
//! (acme.c:71-124) and its file-argument boot (acme.c:241-266) — open a window
//! for each file or directory named, a missing one as an empty window under
//! that name (SnarfProdd ruling, 2026-11-02; acme's `readfile`, acme.c:285).
//! Split out of `main_native.zig` (S-07 P-2). Ported from
//! larryr/plan9port@337c6ac; cite as `acme.c:NN`.
//!
//! Flags are the arguments before the first that is not one, as `ARGBEGIN`
//! takes them: an argument starting with `-` (but not `-` alone) is a flag;
//! `--` ends the flags and is dropped; everything from the first non-flag on
//! is a file, even one that starts with `-`.
const std = @import("std");

/// `--help` / `--version` (#77): print and exit 0 before devdraw is
/// started, so they work with no display. Only the flag arguments count; the
/// first one present wins.
pub const Info = enum { help, version };

pub fn infoFlag(flags: []const []const u8) ?Info {
    for (flags) |f| {
        if (std.mem.eql(u8, f, "--help") or std.mem.eql(u8, f, "-h")) return .help;
        if (std.mem.eql(u8, f, "--version")) return .version;
    }
    return null;
}

/// The `--help` text (stdout). acme's own usage line is acme.c:118-121.
pub const usage =
    \\usage: snarf [-colors=NAME] [file ...]
    \\
    \\Snarf, a port of Plan 9 acme. Opens a window for each file or directory
    \\named (a missing file gets an empty window with that name).
    \\
    \\  -colors=NAME  color scheme: acme, monadnock, sunapee or whiteface
    \\  --help, -h    print this and exit
    \\  --version     print the version and exit
    \\  --            end of flags; every later argument is a file
    \\
    \\Display: snarf runs a plan9port devdraw — $DEVDRAW, else the devdraw
    \\beside this executable, else $PLAN9/bin/devdraw, else devdraw on $PATH.
    \\
;

/// `#define WPERCOL 8` (acme.c:240): file arguments per column.
pub const wpercol = 8;

pub const Split = struct {
    flags: []const []const u8,
    files: []const []const u8,
};

/// `args` WITHOUT argv[0].
pub fn split(args: []const []const u8) Split {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) return .{ .flags = args[0..i], .files = args[i + 1 ..] };
        if (a.len < 2 or a[0] != '-') break;
    }
    return .{ .flags = args[0..i], .files = args[i..] };
}

/// acme.c:241-249: 2 columns, or one per `WPERCOL` files, at least 2.
pub fn ncolFor(nfiles: usize) usize {
    return @max(2, (nfiles + wpercol - 1) / wpercol);
}

/// acme.c:261-266: file `i` goes to column `i/WPERCOL`, except a `…/guide`
/// file, or one past the columns that exist, which goes to the last column.
pub fn columnFor(i: usize, name: []const u8, ncol: usize) usize {
    const guide = if (std.mem.lastIndexOfScalar(u8, name, '/')) |k| std.mem.eql(u8, name[k..], "/guide") else false;
    if (guide or i / wpercol >= ncol) return ncol - 1;
    return i / wpercol;
}

/// acme.c:293-294 (`readfile`): an unrooted name is `wdir/name` — the
/// process's working directory, `cwd`, on this host. `openfile.readFile`
/// cleans the result (`cleanrname`). Caller frees.
pub fn absolute(a: std.mem.Allocator, cwd: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    if (name.len != 0 and name[0] == '/') return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ cwd, name });
}

// ===========================================================================
const testing = std.testing;

test "native_args: flags stop at the first non-flag, -- ends them, - alone is a file (ARGBEGIN)" {
    const S = struct {
        fn files(args: []const []const u8) []const []const u8 {
            return split(args).files;
        }
    };
    try testing.expectEqual(@as(usize, 0), S.files(&.{}).len);
    try testing.expectEqual(@as(usize, 0), S.files(&.{"-colors=acme"}).len);
    const s1 = split(&.{ "-colors=acme", "a.c", "-x", "b" });
    try testing.expectEqual(@as(usize, 1), s1.flags.len);
    try testing.expectEqualStrings("a.c", s1.files[0]);
    try testing.expectEqualStrings("-x", s1.files[1]); // a file once files began
    try testing.expectEqual(@as(usize, 3), s1.files.len);
    const s2 = split(&.{ "-colors=acme", "--", "-odd", "x" });
    try testing.expectEqual(@as(usize, 1), s2.flags.len);
    try testing.expectEqualStrings("-odd", s2.files[0]);
    try testing.expectEqual(@as(usize, 2), s2.files.len);
    const s3 = split(&.{ "-", "y" });
    try testing.expectEqual(@as(usize, 0), s3.flags.len);
    try testing.expectEqualStrings("-", s3.files[0]);
}

test "native_args: ncol and placement follow acme.c:241-266 (WPERCOL 8, guide to the last column)" {
    try testing.expectEqual(@as(usize, 2), ncolFor(0));
    try testing.expectEqual(@as(usize, 2), ncolFor(1));
    try testing.expectEqual(@as(usize, 2), ncolFor(16));
    try testing.expectEqual(@as(usize, 3), ncolFor(17));
    try testing.expectEqual(@as(usize, 0), columnFor(0, "/a", 2));
    try testing.expectEqual(@as(usize, 0), columnFor(7, "/a", 2));
    try testing.expectEqual(@as(usize, 1), columnFor(8, "/a", 2));
    try testing.expectEqual(@as(usize, 1), columnFor(0, "/x/guide", 2));
    try testing.expectEqual(@as(usize, 0), columnFor(0, "/x/guides", 2));
    try testing.expectEqual(@as(usize, 1), columnFor(16, "/a", 2)); // past the columns: the last
    try testing.expectEqual(@as(usize, 2), columnFor(16, "/a", 3));
}

test "native_args: relative names root at the working directory (acme.c:293-294)" {
    const a = testing.allocator;
    const r1 = try absolute(a, "/home/u/src", "x/y.c");
    defer a.free(r1);
    try testing.expectEqualStrings("/home/u/src/x/y.c", r1);
    const r2 = try absolute(a, "/home/u", "/etc/hosts");
    defer a.free(r2);
    try testing.expectEqualStrings("/etc/hosts", r2);
}

test "native_args: --help/-h and --version are found among the flags only (#77)" {
    try testing.expectEqual(@as(?Info, .help), infoFlag(split(&.{"--help"}).flags));
    try testing.expectEqual(@as(?Info, .help), infoFlag(split(&.{ "-colors=acme", "-h" }).flags));
    try testing.expectEqual(@as(?Info, .version), infoFlag(split(&.{"--version"}).flags));
    try testing.expectEqual(@as(?Info, .version), infoFlag(split(&.{ "--version", "--help" }).flags));
    try testing.expectEqual(@as(?Info, null), infoFlag(split(&.{ "a.c", "--help" }).flags)); // a file named --help
    try testing.expectEqual(@as(?Info, null), infoFlag(split(&.{ "--", "--version" }).flags));
    try testing.expectEqual(@as(?Info, null), infoFlag(split(&.{"-colors=acme"}).flags));
}
