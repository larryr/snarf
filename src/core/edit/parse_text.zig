//! Argument-collection helpers for the Edit parser (edit.c:391-457, 565-599) —
//! the `getregexp`/`getrhs`/`collecttext`/`collecttoken` seam split out of
//! `parse.zig` to keep each file under the ~400-line cap (S-07). These are free
//! functions over a `*parse.Parser`: they use its pub lexing primitives (getch,
//! nextc, ungetch, skipbl, okdelim, atnl) and its `arena`/`ed`/`diag` fields, so
//! the split is purely mechanical — no behavior lives here that isn't a faithful
//! port of the cited C.
//!
//! Ported from larryr/plan9port@337c6ac; cite as `edit.c:NN`.
const std = @import("std");
const ast = @import("ast.zig");
const parse = @import("parse.zig");
const Parser = parse.Parser;
const is = parse.is;

/// `getregexp` (edit.c:565-599): collect the pattern up to `delim`/`\n`.
/// `\`+delim yields the literal delimiter; `\\` keeps BOTH backslashes; a non-empty
/// pattern REPLACES the persistent `edit_lastpat`; an empty pattern REUSES it (error
/// "no regular expression defined" if never set). The result is an arena copy of
/// `edit_lastpat` (the C's newstring+runemove). Never compiles the regexp.
pub fn getregexp(p: *Parser, delim: u21) ast.Error![]const u21 {
    var buf: std.ArrayList(u21) = .empty;
    var last: ?u21 = null; // the rune that ended the scan
    while (true) {
        var c = p.getch();
        if (is(c, '\\')) {
            const nx = p.nextc();
            if (is(nx, delim)) {
                c = p.getch(); // \+delim -> literal delim
            } else if (is(nx, '\\')) {
                try buf.append(p.arena, '\\'); // keep the first backslash
                c = p.getch(); // ...and fall through to add the second
            }
            // else: a lone backslash — added as-is below
        } else if (c == null or c.? == delim or c.? == '\n') {
            last = c;
            break;
        }
        try buf.append(p.arena, c.?);
    }
    // C: if(c!=delim && c) ungetch();  — put a terminating '\n' back for atnl.
    // A delimiter is consumed; EOF is unreachable (editcmd appends '\n').
    if (last != null and last.? != delim) p.ungetch();
    if (buf.items.len > 0) {
        p.ed.edit_lastpat.clearRetainingCapacity(); // patset; replace lastpat
        try p.ed.edit_lastpat.appendSlice(p.ed.allocator, buf.items);
    }
    if (p.ed.edit_lastpat.items.len == 0)
        return p.diag.set("no regular expression defined", .{});
    return try p.arena.dupe(u21, p.ed.edit_lastpat.items);
}

/// `getrhs` (edit.c:391-411): collect a replacement into `buf` up to `delim`/`\n`.
/// `\n`(letter) -> newline; `\`+delim -> delim; a backslash before a newline is kept
/// literal. For `cmd=='s'` EVERY other backslash is PRESERVED (so `\1`, `\&` reach
/// s_cmd raw); for the `a`/`i`/`c` inline form only `\\` collapses.
pub fn getrhs(p: *Parser, buf: *std.ArrayList(u21), delim: u21, cmd: u21) ast.Error!void {
    while (true) {
        const c0 = p.getch();
        if (c0 == null) return; // EOF: nothing to put back
        var c = c0.?;
        if (c == delim or c == '\n') {
            p.ungetch(); // let the caller read the delimiter/newline
            return;
        }
        if (c == '\\') {
            const c2 = p.getch();
            if (c2 == null) return p.diag.set("bad right hand side", .{});
            var cc = c2.?;
            if (cc == '\n') {
                p.ungetch();
                cc = '\\';
            } else if (cc == 'n') {
                cc = '\n';
            } else if (cc != delim and (cmd == 's' or cc != '\\')) {
                try buf.append(p.arena, '\\'); // s keeps its own backslashes
            }
            c = cc;
        }
        try buf.append(p.arena, c);
    }
}

/// `collecttext` (edit.c:428-457) — the `a`/`c`/`i` argument, two forms. Newline
/// right after the command ⇒ BLOCK form: lines until one that is exactly `.\n` (that
/// terminator is stripped, trailing newlines of the kept lines remain). Otherwise
/// INLINE form: `a/text/` via okdelim + getrhs + trailing delimiter + atnl.
pub fn collecttext(p: *Parser) ast.Error![]const u21 {
    var buf: std.ArrayList(u21) = .empty;
    if (is(p.skipbl(), '\n')) {
        _ = p.getch(); // consume the newline
        while (true) {
            const begline = buf.items.len;
            while (true) {
                const c = p.getch();
                if (c == null) return buf.items; // EOF: goto Return (no strip)
                if (c.? == '\n') break;
                try buf.append(p.arena, c.?);
            }
            try buf.append(p.arena, '\n');
            if (buf.items[begline] == '.' and begline + 1 < buf.items.len and
                buf.items[begline + 1] == '\n') break; // the ".\n" terminator line
        }
        buf.items.len -= 2; // strip the ".\n"
        return buf.items;
    }
    const delim = p.getch() orelse return p.diag.set("newline expected (saw {u})", .{@as(u21, 0)});
    try p.okdelim(delim);
    try getrhs(p, &buf, delim, 'a');
    if (is(p.nextc(), delim)) _ = p.getch();
    try p.atnl();
    return buf.items;
}

/// `collecttoken` (edit.c:413-426): significant leading blanks, then everything up
/// to a rune in `end`. Used only by `=` (end = "\n").
pub fn collecttoken(p: *Parser, end: []const u21) ast.Error![]const u21 {
    var buf: std.ArrayList(u21) = .empty;
    while (p.nextc()) |c| {
        if (c != ' ' and c != '\t') break;
        try buf.append(p.arena, p.getch().?);
    }
    while (true) {
        const c = p.getch();
        if (c == null) {
            try p.atnl(); // c<=0 -> c!='\n' -> atnl (errors at true EOF)
            break;
        }
        if (inSet(end, c.?)) {
            if (c.? != '\n') try p.atnl();
            break;
        }
        try buf.append(p.arena, c.?);
    }
    return buf.items;
}

/// `utfrune(end, c) != 0` membership (edit.c:423).
fn inSet(end: []const u21, c: u21) bool {
    for (end) |e| {
        if (e == c) return true;
    }
    return false;
}
