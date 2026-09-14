//! The snarf buffer's single-Text ops — `cut` and `paste`'s inner core
//! (exec.c:947-1073), the bodies both the mouse chords (`textselect.zig`) and the
//! Cut/Snarf/Paste builtins (`exec/cmd_edit.zig`) delegate to. Namespace module
//! (S-07 P-1, lowercase); the buffer itself stays the `Editor.snarf` field, the
//! way `errors.zig` works on `Editor.warnings`. Carved out of `Editor.zig` in
//! phase 12e, which keeps `ed.cut`/`ed.snarfInsert` as one-line forwarders.
//!
//! Ported from larryr/plan9port@337c6ac; cite as `exec.c:NN`.
//!
//! Imports: `std` + sibling core files only (S-07 §6 — never dev/shim).
const std = @import("std");
const Editor = @import("Editor.zig");
const Text = @import("text/Text.zig");
const Buffer = @import("Buffer.zig");

/// snarf capture read chunk (exec.c uses RBUFSIZE; any bound works — see `cut`).
const snarf_chunk_runes: usize = 2000;

/// `cut` (exec.c:947-1016), single-Text subset (no window/tag plumbing, no
/// cross-window lock). Snarf and/or delete the current selection `[q0,q1)`.
///   * `dosnarf` — copy the selection into `ed.snarf` (replacing its contents).
///   * `docut`   — delete the selection and collapse the caret to `q0`.
/// A null selection (q0==q1) returns with the snarf buffer UNTOUCHED
/// (exec.c:984-988). The CALLER bumps `ed.seq` + `File.mark` first, exactly as
/// `execute`/`texttype` do in the C — `cut` never marks. /dev/snarf sync
/// (`acmeputsnarf`, exec.c:1003) is deferred (R-P7-5).
pub fn cut(ed: *Editor, t: *Text, dosnarf: bool, docut: bool) !void {
    const q0 = t.q0;
    const q1 = t.q1;
    if (q0 == q1) return; // exec.c:984-988 no selection: snarf left as-is
    if (dosnarf) {
        ed.snarf.clearRetainingCapacity(); // exec.c:992 bufdelete(&snarfbuf,...)
        // chunked read of [q0,q1) into the snarf buffer (exec.c:993-1002).
        var scratch: [snarf_chunk_runes * Buffer.max_bytes_per_rune]u8 = undefined;
        var p = q0;
        while (p < q1) {
            const n = @min(q1 - p, snarf_chunk_runes);
            const bytes = t.file.buffer.read(p, n, &scratch);
            try ed.snarf.appendSlice(ed.allocator, bytes);
            p += n;
        }
        // exec.c:1003 acmeputsnarf — /dev/snarf + clipboard sync DEFERRED (R-P7-5).
    }
    if (docut) {
        try t.deleteRange(q0, q1, true); // exec.c:1006 textdelete
        try t.setSelect(q0, q0); // exec.c:1007 textsetselect
        try t.scrDraw(); // exec.c:1009 textscrdraw (LIVE; no-op when w==null). winsettag deferred.
    }
}

/// `paste` (exec.c:1018-1073), single-Text subset (no `tobody`, no cross-window
/// lock, no /dev/snarf fetch). Replace the current selection with the snarf
/// buffer at the caret. `selectall` selects the inserted text (the chord path,
/// text.c:1087); otherwise the caret lands after it. The CALLER marks first.
pub fn snarfInsert(ed: *Editor, t: *Text, selectall: bool) !void {
    // exec.c:1037-1039 acmegetsnarf + empty guard (dev fetch DEFERRED, R-P7-5).
    if (ed.snarf.items.len == 0) return;
    try ed.cut(t, false, true); // exec.c:1046 cut(t,t,nil,FALSE,TRUE) — no snarf
    const q0 = t.q0;
    const n = std.unicode.utf8CountCodepoints(ed.snarf.items) catch unreachable;
    try t.insertAt(q0, ed.snarf.items, true); // exec.c:1051-1061 textinsert
    if (selectall) {
        try t.setSelect(q0, q0 + n); // exec.c:1063-1064
    } else {
        try t.setSelect(q0 + n, q0 + n); // exec.c:1065-1066
    }
    try t.scrDraw(); // exec.c:1068 textscrdraw (LIVE; no-op when w==null). winsettag deferred.
}
