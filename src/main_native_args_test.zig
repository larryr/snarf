//! Command-line file arguments on the native host (SnarfProdd ruling,
//! 2026-11-02): like acme (acme.c:241-266 + `readfile`, :285-308), a window
//! for each file or directory named, a missing one empty under its name.
//! The names here are already rooted (main does that against the working
//! directory, `native_args.absolute`); the rig serves a scratch directory at `/`.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const mnt = @import("main_native_test.zig");
const Rig = mnt.Rig;

fn find(r: *Rig, name: []const u8) ?struct { col: usize, w: *core.Window } {
    for (r.app.tree.row.col.items, 0..) |c, ci| {
        for (c.w.items) |w| if (std.mem.eql(u8, w.body.file.name.items, name)) return .{ .col = ci, .w = w };
    }
    return null;
}

fn body(w: *core.Window, buf: []u8) []const u8 {
    return w.body.file.buffer.read(0, w.body.file.buffer.len(), buf);
}

fn countWindows(r: *Rig) usize {
    var n: usize = 0;
    for (r.app.tree.row.col.items) |c| {
        for (c.w.items) |w| {
            if (!std.mem.endsWith(u8, w.body.file.name.items, "+Errors")) n += 1;
        }
    }
    return n;
}

test "native file args: a file, a directory and a missing file each get a window (acme.c:261-266)" {
    const r = try Rig.create();
    defer r.destroy();
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "hello\n" });
    try r.tmp.dir.createDir(testing.io, "d", .default_dir);
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "d/inner", .data = "" });
    try r.bootWith(&.{ "/f.txt", "/d", "/sub/../new.txt" });
    try r.settle();

    try testing.expectEqual(@as(usize, 2), r.app.tree.row.col.items.len);
    try testing.expectEqual(@as(usize, 3), countWindows(r)); // no `/` window (+Errors aside)
    var buf: [1024]u8 = undefined;

    const f = find(r, "/f.txt").?;
    try testing.expectEqual(@as(usize, 0), f.col); // files 0..7 → column 0
    try testing.expectEqualStrings("hello\n", body(f.w, &buf));
    try testing.expect(!f.w.dirty and !f.w.body.file.mod); // acme.c:301-302

    const d = find(r, "/d/").?; // a directory window keeps acme's slash
    try testing.expect(d.w.isdir);
    try testing.expect(std.mem.indexOf(u8, body(d.w, &buf), "inner") != null);

    // The missing file: an empty window under its (cleaned) name, and acme's
    // `can't open` line in +Errors (text.c:214-217) — not created on disk.
    const n = find(r, "/new.txt").?;
    try testing.expectEqual(@as(usize, 0), n.w.body.file.buffer.len());
    try testing.expect(!n.w.dirty);
    const errs = find(r, "+Errors").?; // flushed there by the settle ticks
    try testing.expect(std.mem.indexOf(u8, body(errs.w, &buf), "can't open /new.txt") != null);
    try testing.expectError(error.FileNotFound, r.tmp.dir.access(testing.io, "new.txt", .{}));
}

test "native file args: Put in a missing file's window creates it" {
    const r = try Rig.create();
    defer r.destroy();
    try r.bootWith(&.{"/brand-new.txt"});
    try r.settle();
    const n = find(r, "/brand-new.txt").?;
    try r.edit(n.w, "made\n");
    try r.run(&n.w.tag, "Put");
    try r.settle();
    const got = try r.disk("brand-new.txt");
    defer r.a.free(got);
    try testing.expectEqualStrings("made\n", got);
}

test "native file args: 17 files make 3 columns, 8 per column; a guide file goes last (WPERCOL)" {
    const r = try Rig.create();
    defer r.destroy();
    var names: [17][]const u8 = undefined;
    var store: [17][16]u8 = undefined;
    for (0..17) |i| {
        names[i] = if (i == 1) "/x/guide" else try std.fmt.bufPrint(&store[i], "/f{d:0>2}", .{i});
    }
    // All present, so no +Errors window joins a column.
    try r.tmp.dir.createDir(testing.io, "x", .default_dir);
    for (names) |nm| try r.tmp.dir.writeFile(testing.io, .{ .sub_path = nm[1..], .data = "" });
    try r.bootWith(&names);
    try r.settle();
    const cols = r.app.tree.row.col.items;
    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqual(@as(usize, 17), countWindows(r));
    try testing.expectEqual(@as(usize, 0), find(r, "/f00").?.col);
    try testing.expectEqual(@as(usize, 0), find(r, "/f07").?.col);
    try testing.expectEqual(@as(usize, 2), find(r, "/x/guide").?.col);
    try testing.expectEqual(@as(usize, 1), find(r, "/f08").?.col);
    try testing.expectEqual(@as(usize, 1), find(r, "/f15").?.col);
    try testing.expectEqual(@as(usize, 2), find(r, "/f16").?.col);
    try testing.expectEqual(@as(usize, 7), cols[0].w.items.len);
    try testing.expectEqual(@as(usize, 8), cols[1].w.items.len);
    try testing.expectEqual(@as(usize, 2), cols[2].w.items.len);
}

test "native file args: none opens the / directory window in the last column (acme.c:258-259)" {
    const r = try Rig.create();
    defer r.destroy();
    try r.boot();
    try r.settle();
    try testing.expectEqual(@as(usize, 1), countWindows(r));
    try testing.expectEqual(@as(usize, 1), find(r, "/").?.col);
}
