//! `devdraw_files` — the C/ObjC source lists for the bundled `devdraw` peer
//! (ADR-0006, phase 18 contract §3c). BUILD-TIME ONLY: imported by
//! `build/devdraw.zig`, imports only `std`, part of no S-07 module graph.
//!
//! Transcribed from the mkfiles of `larryr/plan9port@337c6ac` and cross-checked
//! against the archives a real plan9port install builds on macOS (`install.log`
//! `9ar` lines). Every name is a real file in the fetched tree, which is never
//! modified (R-P18-3). This is a table, not prose: several names per line.
//! Each list is compiled whole into a static archive and the linker pulls the
//! members it needs, exactly as `9l` does (R-P18-2).
//!
//! Deliberately NOT built: `lib9/fmt/{errfmt,dorfmt,fmtlock,test,test2,test3}.c`,
//! `lib9/{debugmalloc,fork,lock,priv,udp,test,testfltfmt,testfmt,testfork,
//! testprint}.c` (`lib9/mkfile:9`), and `devdraw/{nowsys,drawclient,macargv,
//! x11-*}` (not part of the macOS binary, `mkwsysrules.sh:26-31,58`).
const std = @import("std");

/// `devdraw/mkfile:8-13` + `mkwsysrules.sh:58` (Darwin ⇒ `WSYSTYPE=mac` ⇒
/// `mac-draw.o mac-screen.o`). `mac-screen.m` is the one ObjC file and is
/// compiled with `-fobjc-arc` (`devdraw/mkfile:42-43`), so `devdraw_c` and
/// `devdraw_objc` are separate slices; `devdraw` is both, for counting.
pub const devdraw_c = [_][]const u8{ "devdraw.c", "latin1.c", "mouseswap.c", "srv.c", "winsize.c", "mac-draw.c" };
pub const devdraw_objc = [_][]const u8{"mac-screen.m"};
pub const devdraw = devdraw_c ++ devdraw_objc;

/// The host tool that generates `latin1.h` (`devdraw/mkfile:36-37`).
pub const mklatinkbd = "mklatinkbd.c";

/// `libmemdraw/mkfile:5-30`.
pub const libmemdraw = [_][]const u8{
    "alloc.c",  "alloc-stub.c", "arc.c",       "cload.c",     "cload-stub.c",     "cmap.c",
    "cread.c",  "draw.c",       "draw-stub.c", "ellipse.c",   "fillpoly.c",       "hwdraw.c",
    "iprint.c", "line.c",       "load.c",      "load-stub.c", "openmemsubfont.c", "poly.c",
    "read.c",   "string.c",     "subfont.c",   "unload.c",    "unload-stub.c",    "write.c",
};

/// `libmemlayer/mkfile:5-17`.
pub const libmemlayer = [_][]const u8{
    "draw.c", "lalloc.c",  "layerop.c",     "ldelete.c",  "lhide.c",   "line.c",
    "load.c", "lorigin.c", "lsetrefresh.c", "ltofront.c", "ltorear.c", "unload.c",
};

/// `libdraw/mkfile:5-63`. `drawclient.c` and `event.c` include `<mux.h>`/
/// `<bio.h>`; they compile against the headers and are never pulled.
pub const libdraw = [_][]const u8{
    "alloc.c",        "allocimagemix.c", "arith.c",       "bezier.c",      "border.c",        "buildfont.c",
    "bytesperline.c", "chan.c",          "cloadimage.c",  "computil.c",    "creadimage.c",    "cursor.c",
    "debug.c",        "draw.c",          "drawclient.c",  "drawfcall.c",   "drawrepl.c",      "egetrect.c",
    "ellipse.c",      "emenuhit.c",      "event.c",       "font.c",        "freesubfont.c",   "getrect.c",
    "getsubfont.c",   "icossin.c",       "icossin2.c",    "init.c",        "iprint.c",        "keyboard.c",
    "line.c",         "loadimage.c",     "menuhit.c",     "mkfont.c",      "mouse.c",         "openfont.c",
    "poly.c",         "readimage.c",     "readsubfont.c", "rectclip.c",    "replclipr.c",     "rgb.c",
    "scroll.c",       "snarf.c",         "string.c",      "stringbg.c",    "stringsubfont.c", "stringwidth.c",
    "subfont.c",      "subfontcache.c",  "subfontname.c", "unloadimage.c", "window.c",        "writeimage.c",
    "writesubfont.c", "wsys.c",          "unix.c",
};

/// `libthread/mkfile:4-15`. No assembly on Darwin (the `.S`/`.s` rules at
/// `libthread/mkfile:36-43` are OpenBSD/sparc64 only).
pub const libthread = [_][]const u8{
    "bg.c",   "channel.c", "daemonize.c", "exec.c",   "ioproc.c",
    "iorw.c", "pthread.c", "ref.c",       "thread.c", "wait.c",
};

/// `libbio/mkfile:5-23`. Linked into `mklatinkbd` only, never into devdraw.
pub const libbio = [_][]const u8{
    "bbuffered.c", "bfildes.c", "bflush.c", "bgetc.c",   "bgetrune.c", "bgetd.c",
    "binit.c",     "boffset.c", "bprint.c", "bputc.c",   "bputrune.c", "brdline.c",
    "brdstr.c",    "bread.c",   "bseek.c",  "bvprint.c", "bwrite.c",
};

/// `lib9/mkfile:69-161` `LIB9OFILES`, plus `fmtlock2.c` and `frexp.c`, which
/// the mkfile lists under `FMTOFILES` but which live at the top level.
/// `get9root.c` is NOT here: it needs `-DPLAN9_TARGET` (`lib9/mkfile:178-179`)
/// and is compiled in a call of its own (`lib9_get9root`).
pub const lib9 = [_][]const u8{
    "_exits.c",     "_p9dialparse.c", "_p9dir.c",       "announce.c",  "argv0.c",      "atexit.c",
    "atoi.c",       "atol.c",         "atoll.c",        "atnotify.c",  "await.c",      "cistrcmp.c",
    "cistrncmp.c",  "cistrstr.c",     "cleanname.c",    "convD2M.c",   "convM2D.c",    "convM2S.c",
    "convS2M.c",    "crypt.c",        "ctime.c",        "dial.c",      "dirfstat.c",   "dirfwstat.c",
    "dirmodefmt.c", "dirstat.c",      "dirwstat.c",     "dup.c",       "encodefmt.c",  "errstr.c",
    "exec.c",       "execl.c",        "exitcode.c",     "fcallfmt.c",  "frand.c",      "getcallerpc.c",
    "getenv.c",     "getfields.c",    "getnetconn.c",   "getns.c",     "getuser.c",    "getwd.c",
    "jmp.c",        "lrand.c",        "lnrand.c",       "main.c",      "malloc.c",     "malloctag.c",
    "mallocz.c",    "nan.c",          "needsrcquote.c", "needstack.c", "netcrypt.c",   "netmkaddr.c",
    "notify.c",     "nrand.c",        "nulldir.c",      "open.c",      "opentemp.c",   "pin.c",
    "pipe.c",       "post9p.c",       "postnote.c",     "qlock.c",     "quote.c",      "rand.c",
    "read9pmsg.c",  "readcons.c",     "readn.c",        "rfork.c",     "searchpath.c", "sendfd.c",
    "sleep.c",      "strdup.c",       "strecpy.c",      "sysfatal.c",  "syslog.c",     "sysname.c",
    "time.c",       "tm2sec.c",       "tokenize.c",     "truerand.c",  "u16.c",        "u32.c",
    "u64.c",        "unsharp.c",      "wait.c",         "waitpid.c",   "write.c",      "zoneinfo.c",
    "fmtlock2.c",   "frexp.c",
};

/// `lib9/mkfile:178-179`: the one file compiled with `-DPLAN9_TARGET`.
pub const lib9_get9root = [_][]const u8{"get9root.c"};

/// `lib9/mkfile:10-46` `FMTOFILES` minus `fmtlock2.c`/`frexp.c` (top level);
/// `charstod.c`/`pow10.c` are the mkfile's `NUM`. Built with `-Ifmt`
/// (`lib9/mkfile:172-173`).
pub const lib9_fmt = [_][]const u8{
    "dofmt.c",       "fltfmt.c",     "fmt.c",          "fmtfd.c",        "fmtfdflush.c",   "fmtlocale.c",
    "fmtnull.c",     "fmtprint.c",   "fmtquote.c",     "fmtrune.c",      "fmtstr.c",       "fmtvprint.c",
    "fprint.c",      "nan64.c",      "print.c",        "runefmtstr.c",   "runeseprint.c",  "runesmprint.c",
    "runesnprint.c", "runesprint.c", "runevseprint.c", "runevsmprint.c", "runevsnprint.c", "seprint.c",
    "smprint.c",     "snprint.c",    "sprint.c",       "strtod.c",       "vfprint.c",      "vseprint.c",
    "vsmprint.c",    "vsnprint.c",   "charstod.c",     "pow10.c",
};

/// `lib9/mkfile:47-68` `UTFOFILES` (`lib9/mkfile:175-176`).
pub const lib9_utf = [_][]const u8{
    "rune.c",       "runestrcat.c",  "runestrchr.c",  "runestrcmp.c",  "runestrcpy.c",  "runestrdup.c",
    "runestrlen.c", "runestrecpy.c", "runestrncat.c", "runestrncmp.c", "runestrncpy.c", "runestrrchr.c",
    "runestrstr.c", "runetype.c",    "utfecpy.c",     "utflen.c",      "utfnlen.c",     "utfrrune.c",
    "utfrune.c",    "utfutf.c",
};

test "file counts match the mkfiles (contract §3c)" {
    try std.testing.expectEqual(@as(usize, 93), lib9.len + lib9_get9root.len);
    try std.testing.expectEqual(@as(usize, 34), lib9_fmt.len);
    try std.testing.expectEqual(@as(usize, 20), lib9_utf.len);
    try std.testing.expectEqual(@as(usize, 147), lib9.len + lib9_get9root.len + lib9_fmt.len + lib9_utf.len);
    try std.testing.expectEqual(@as(usize, 57), libdraw.len);
    try std.testing.expectEqual(@as(usize, 24), libmemdraw.len);
    try std.testing.expectEqual(@as(usize, 12), libmemlayer.len);
    try std.testing.expectEqual(@as(usize, 10), libthread.len);
    try std.testing.expectEqual(@as(usize, 17), libbio.len);
    try std.testing.expectEqual(@as(usize, 7), devdraw.len);
}

test "every entry is .c except exactly one .m" {
    const lists = [_][]const []const u8{
        &devdraw,    &lib9,        &lib9_get9root, &lib9_fmt, &lib9_utf,      &libdraw,
        &libmemdraw, &libmemlayer, &libthread,     &libbio,   &.{mklatinkbd},
    };
    var objc: usize = 0;
    for (lists) |list| for (list) |name| {
        if (std.mem.endsWith(u8, name, ".m")) {
            objc += 1;
        } else try std.testing.expect(std.mem.endsWith(u8, name, ".c"));
    };
    try std.testing.expectEqual(@as(usize, 1), objc);
}

test "no duplicate names within a directory" {
    const dirs = [_][]const []const u8{
        &devdraw, &(lib9 ++ lib9_get9root), &lib9_fmt, &lib9_utf, &libdraw, &libmemdraw, &libmemlayer, &libthread, &libbio,
    };
    for (dirs) |list| for (list, 0..) |a, i| for (list[i + 1 ..]) |b|
        try std.testing.expect(!std.mem.eql(u8, a, b));
}
