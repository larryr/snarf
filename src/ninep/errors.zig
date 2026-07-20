//! 9P operation errors and their wire strings.
//!
//! Servers report failures as Rerror with a human-readable `ename` string
//! (S-01 §5). We adopt the lib9p / plan9port error text conventions so a Snarf
//! server is indistinguishable on the wire from a native 9P server, and so a
//! client can map a received Rerror back to a typed error (R7).
//!
//! `errorFromString` does an exact match; anything unrecognized becomes
//! `.Other` (the raw text is preserved separately by the client, see
//! `client.zig` last_rerror_buf). `.Other` shares the generic "i/o error"
//! string on the way out, so it is NOT round-trip-stable by design.
const std = @import("std");

/// Typed 9P operation error set. [ref: 9p.h, srv.c error strings]
pub const OpError = error{
    FileDoesNotExist,
    PermissionDenied,
    FidInUse,
    IoError,
    BadMessage,
    FileIsDirectory,
    ConnectionClosed,
    Interrupted,
    NoUserGesture,
    QuotaExceeded,
    UnknownFid,
    WalkNoDir,
    FidOpen,
    AuthNotRequired,
    // Draw-device errors (S-03 §2; phase-2 addition, ruling OQ-1 in
    // agents/contracts/phase2-draw.md). [ref: 9/port/devdraw.c:174-178]
    BadDraw,
    ShortDraw,
    NoDrawImage,
    // Phase-3 font/pixel-upload errors (ruling R-P3-4 in
    // agents/contracts/phase3-font.md). [ref: 9/port/devdraw.c:182-184, 2098]
    NotFont,
    BadIndex,
    WriteOutside,
    BadWriteImage,
    // Served-tree (acme fsys) errors (S-07 §4; ruling R-P10-B in
    // agents/contracts/phase10-served.md). [ref: acme/xfid.c:20-21]
    DeletedWindow,
    BadCtl,
    Other,
};

/// The canonical wire string for an OpError. `.Other` maps to the generic
/// "i/o error" (same as `.IoError`).
pub fn errorString(e: OpError) []const u8 {
    return switch (e) {
        error.FileDoesNotExist => "file does not exist",
        error.PermissionDenied => "permission denied",
        error.FidInUse => "fid in use",
        error.IoError => "i/o error",
        error.BadMessage => "bad message",
        error.FileIsDirectory => "file is a directory",
        error.ConnectionClosed => "connection closed",
        error.Interrupted => "interrupted",
        error.NoUserGesture => "no user gesture",
        error.QuotaExceeded => "quota exceeded",
        error.UnknownFid => "unknown fid",
        error.WalkNoDir => "walk in non-directory",
        error.FidOpen => "cannot clone open fid",
        error.AuthNotRequired => "authentication not required",
        error.BadDraw => "bad draw message",
        error.ShortDraw => "short draw message",
        error.NoDrawImage => "unknown id for draw image",
        error.NotFont => "image not a font",
        error.BadIndex => "character index out of range",
        error.WriteOutside => "writeimage outside image",
        error.BadWriteImage => "bad writeimage call",
        error.DeletedWindow => "deleted window",
        error.BadCtl => "ill-formed control message",
        error.Other => "i/o error",
    };
}

/// Map a received Rerror string back to a typed OpError. Exact match only;
/// anything unrecognized (including "i/o error", which is claimed by
/// `.IoError`) that does not match a named string becomes `.Other`.
pub fn errorFromString(s: []const u8) OpError {
    const eq = std.mem.eql;
    if (eq(u8, s, "file does not exist")) return error.FileDoesNotExist;
    if (eq(u8, s, "permission denied")) return error.PermissionDenied;
    if (eq(u8, s, "fid in use")) return error.FidInUse;
    if (eq(u8, s, "i/o error")) return error.IoError;
    if (eq(u8, s, "bad message")) return error.BadMessage;
    if (eq(u8, s, "file is a directory")) return error.FileIsDirectory;
    if (eq(u8, s, "connection closed")) return error.ConnectionClosed;
    if (eq(u8, s, "interrupted")) return error.Interrupted;
    if (eq(u8, s, "no user gesture")) return error.NoUserGesture;
    if (eq(u8, s, "quota exceeded")) return error.QuotaExceeded;
    if (eq(u8, s, "unknown fid")) return error.UnknownFid;
    if (eq(u8, s, "walk in non-directory")) return error.WalkNoDir;
    if (eq(u8, s, "cannot clone open fid")) return error.FidOpen;
    if (eq(u8, s, "authentication not required")) return error.AuthNotRequired;
    if (eq(u8, s, "bad draw message")) return error.BadDraw;
    if (eq(u8, s, "short draw message")) return error.ShortDraw;
    if (eq(u8, s, "unknown id for draw image")) return error.NoDrawImage;
    if (eq(u8, s, "image not a font")) return error.NotFont;
    if (eq(u8, s, "character index out of range")) return error.BadIndex;
    if (eq(u8, s, "writeimage outside image")) return error.WriteOutside;
    if (eq(u8, s, "bad writeimage call")) return error.BadWriteImage;
    if (eq(u8, s, "deleted window")) return error.DeletedWindow;
    if (eq(u8, s, "ill-formed control message")) return error.BadCtl;
    return error.Other;
}

test "errors: round-trip every member" {
    // Every named member (all but .Other) is round-trip-stable through its
    // canonical string.
    const named = [_]OpError{
        error.FileDoesNotExist,
        error.PermissionDenied,
        error.FidInUse,
        error.IoError,
        error.BadMessage,
        error.FileIsDirectory,
        error.ConnectionClosed,
        error.Interrupted,
        error.NoUserGesture,
        error.QuotaExceeded,
        error.UnknownFid,
        error.WalkNoDir,
        error.FidOpen,
        error.AuthNotRequired,
        error.BadDraw,
        error.ShortDraw,
        error.NoDrawImage,
        error.NotFont,
        error.BadIndex,
        error.WriteOutside,
        error.BadWriteImage,
        error.DeletedWindow,
        error.BadCtl,
    };
    for (named) |e| {
        try std.testing.expectEqual(e, errorFromString(errorString(e)));
    }
    // .Other aliases the generic string, so it decodes back to .IoError.
    try std.testing.expectEqual(OpError.IoError, errorFromString(errorString(error.Other)));
}

test "errors: unknown string maps to Other" {
    try std.testing.expectEqual(OpError.Other, errorFromString("totally bespoke server message"));
    try std.testing.expectEqual(OpError.Other, errorFromString(""));
}

test "errors: Other string is i/o error" {
    try std.testing.expectEqualStrings("i/o error", errorString(error.Other));
}
