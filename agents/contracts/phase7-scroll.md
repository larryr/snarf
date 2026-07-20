# Phase 7a side contract (O14) — scroll

ONE opus agent. Files: src/core/text/Text.zig (+field +4 fns), src/core/text/typing.zig
(8 new arms + 2 upgrades + iq1 sites), src/core/Editor.zig (wheel arm). Frame and
select.zig UNTOUCHED (verified). C: plan9port acme text.c/acme.c/dat.h + libdraw
scroll.c. Cite per fn.

## Text.zig

- Field `iq1: usize = 0` ("insertion q1", dat.h): insertAt slides it (q0 < iq1 =>
  iq1 += n, text.c:393-394); deleteRange (q0 < iq1 => iq1 -= min(n, iq1-q0),
  :488-489). ALSO: the q0 < org arms of insertAt/deleteRange (:399-400, :494-495) are
  now LIVE — update their "(dead: org fixed)" comments; test 8 covers.
- `pub fn backNL(self, p, n) usize` (textbacknl :1590-1609): n==0 => BOL of p (if not
  already after '\n'); each line capped 128 chars; runeAt = buffer.runeAt.
- `pub fn setOrigin(self, org, exact: bool) Error!void` (textsetorigin :1611-1648):
  (1) inexact + org>0 + runeAt(org-1)!='\n' => scan forward <=256 for '\n', org past
  it (:1618-1628); (2) a = org - self.org in [0, fr.nchars) => fr.delete(0, a),
  fixup=true (:1630-1634); (3) negative a, -a < fr.nchars => read (self.org - org)
  runes at org into heap scratch (4x rule), fr.insert(bytes, 0) (:1635-1641);
  (4) else fr.delete(0, fr.nchars) (:1642-1643). Always: self.org = org; fill();
  FLAG(windows) scrdraw (:1645); setSelect(q0, q1); if fixup and fr.p1 > fr.p0 =>
  fr.drawSel(fr.ptOfChar(fr.p1-1), fr.p1-1, fr.p1, true) (:1647-1648).
- `pub fn show(self, q0, q1, doselect: bool) Error!void` (textshow :1101-1147,
  single-Text): doselect => setSelect; visibility test (:1119-1132) with nc =
  buffer.len(): visible => no-op (FLAG scrdraw :1134); else nl = fr.maxlines/4
  (:1139); q = backNL(q0, nl); if !(q0 > org and q < org) setOrigin(q, true)
  (:1141-1143); while (q0 > org + fr.nchars) setOrigin(org+1, false) (:1144-1145).
- `pub fn bsWidth(self, c: u21) usize` (textbswidth :535-560 IN FULL: ^H=1; ^U 0x15
  to line start eating at most one '\n'; ^W 0x17 alnum word). isalnum v1: r < 0x80
  and std.ascii.isAlphanumeric (flag divergence note).

## typing.zig

Consts: Khome=KF|0x0D, Kup=KF|0x0E, Kpgup=KF|0x0F, Kpgdown=KF|0x13, Kend=KF|0x18,
pub Kscrolloneup=KF|0x20, pub Kscrollonedown=KF|0x21 (dat.h:562-563);
mouse_scroll_lines=1 (libdraw scroll.c default).
New arms (return; typecommit == ed.in_typing_run=false ONLY where the C commits):
Kdown n=maxlines/3 (:694-698); Kscrollonedown n=1 clamped (:699-705); Kpgdown
n=2*maxlines/3 (:706-707) — all => q0 = org + fr.charOfPt(r.min.x, r.min.y + n*h);
setOrigin(q0, true) (:708-711, NO caret move). Kup/Kscrolloneup/Kpgup mirror =>
setOrigin(backNL(org, n), true) (:712-727). Khome (:728-735): commit; org > iq1 ?
setOrigin(backNL(iq1,1), true) : show(0,0,false). Kend (:736-747): commit; iq1 >
org+fr.nchars ? (clamp iq1<=len, :739-742) setOrigin(backNL(iq1,1),true) :
show(len,len,false). ^A 0x01 (:748-755): commit; nnb = (q0>0 and runeAt(q0-1)!='\n')
? bsWidth(0x15) : 0; show(q0-nnb, q0-nnb, true). ^E 0x05 (:756-762): commit; scan to
'\n'/EOF; show(q, q, true).
Upgrades: Kleft/Kright setSelect -> show(..., true) (:686-687, :691-692);
autoscroll-on-type: try t.show(t.q0, t.q0, true) right after the type-over-selection
block (:826); iq1 = t.q0 at end of Kbs arm (:888) and after ordinary insertion (:940).
Remove the now-live keys from the DEFERRED header.

## Editor.zig

Idle-arm wheel (replaces the FLAG comment): buttons & (8|16) => typeRune(ed,
Kscrolloneup/Kscrollonedown per bit 8/16), needs_flush, return (acme.c:618-628).
Does NOT clear in_typing_run. Sweeping arm unchanged.

## Named tests (17 from the O14 report — implement exactly)

Text: "text: backNL counts lines" · "text: setOrigin forward scroll deletes from the
top" · "text: setOrigin backward scroll inserts at the top" · "text: setOrigin large
jump clears and refills" · "text: setOrigin inexact hunts forward to a newline" ·
"text: setOrigin re-projects the selection (fixup)" · "text: show places an
off-screen caret a quarter from the top" (incl. tsd no-op + long-line walk) ·
"text: insert/delete before org slide org".
typing: "typing: Kdown and Kup scroll a third of the frame" (q0/q1 UNCHANGED
asserted) · "typing: wheel key runes scroll one line" · "typing: Kpgdown and Kpgup
scroll two thirds" · "typing: Khome and Kend jump to the ends" (both branches) ·
"typing: ctrl-a and ctrl-e move to line boundaries" · "typing: typing at an
off-screen caret autoscrolls" · "typing: arrows scroll the caret visible".
Editor: "editor: wheel scrolls one line without breaking the typing run" ·
"editor: acceptance 60-line scroll scene" (60 lines/25-line rect: wheel x3 => org ==
runeOfLine(3), first box "line03"; Kend => org+fr.nchars == len; type 'X' => lands,
org unchanged).
