# Phase 6 contract — interactive editing (master)

Reconciled from O11 (keystone: execution mode + blocking reads), O12 (devinput), O13
(editing). Side files: phase6-input-{ninep,devinput,editing}.md — build agents read the
master FIRST, then their side file. Hard gates unchanged. Goal: click places the tick,
typing edits, B1 sweep selects — in the browser; all semantics proven natively first.

## Rulings

- **R-P6-1 (execution mode)**: HYBRID — S-00's async mode done properly (server wait
  queue + client tickets), module stays on the MAIN THREAD. O11's decisive finding:
  per-file blocking reads are architecturally wrong under EVERY mode (single thread
  must select over mouse+kbd; Atomics.wait in one device read wedges the module) — the
  S-00 §2 sentence "a blocking Tread becomes Atomics.wait" is CORRECTED, not deferred.
  The Worker move (later) relocates the module and adds ONE blocking point at the top
  of the editor loop; park/complete, tickets, devinput all survive unchanged.
  Orchestrator lands the S-00 amendment (wording in the ninep side file).
- **R-P6-2 (park model — supersedes O12's assumed ticket seam)**: framework-level FIFO
  wait queue with kernel-style RE-RUN completion (O11 D1-D6). Devices never track tags
  or tickets: `Ops.read` returns `error.WouldBlockRead` (a widened ReadError, NOT an
  OpError member — it must never reach the wire) when a file has no data;
  `Server.completeReads(path)` re-runs parked reads for that qid.path. O12's
  parked_mouse/parked_kbd fields are DELETED from the devinput contract.
- **R-P6-3 (who completes)**: the ADAPTER (main_wasm pushEvent/wake path, or the test
  harness) calls `srv.completeReads(mouse_path/kbd_path)` after draining an event batch
  into DevInput. DevInput holds no Server pointer.
- **R-P6-4 (client)**: rpc on blocking files is FORBIDDEN (it spins forever — O11's
  crux). New continuation API: `beginRead(fid, offset, buf) !ReadTicket`,
  `checkRead(t) !?usize`, `cancelRead(t) !void`; rpc's tag-mismatch becomes tag-DISPATCH
  to pending tickets. The editor holds standing tickets on mouse+kbd, re-armed on
  completion.
- **R-P6-5 (Tflush/clunk/version)**: flush of a parked tag ⇒ Rerror "interrupted" on
  the old tag FIRST, then Rflush (flush(5), srv.c deferred-Rflush evidence); clunk
  sweeps the fid's parked entries (interrupt then Rclunk); Tversion clears parked
  silently; duplicate in-flight tag ⇒ "bad message"; completions encode via a separate
  pbuf (the rbuf-aliasing trap, O11 D6).
- **R-P6-6 (profiles scope)**: native + modifier ship now; touch/chordbar deferred
  (enum + RawEvent kinds present from day one). R-05's "all four in v1" stays tracked
  in the phase report.
- **R-P6-7 (Kdown)**: 0xF800 per S-04 §3 and the 4e tree (keyboard.h:32, our device
  authority) — plan9port's 0x80 is a p9p divergence, noted. Phase 6 consumes only
  Kleft/Kright/Kbs/'\n'/printables anyway.
- **R-P6-8 (undo grouping, O13 T-1)**: no typing cache; keystrokes write through File,
  one mark per TYPING RUN (maximal {printable,'\n',Kbs} sequence; ended by nav keys,
  any mouse event, commands). Divergence bounded to backspace-past-run granularity;
  documented; revisit with the served event file.
- **R-P6-9 (frame)**: incremental SelectState regardless of mode (O13 F-1); initTick
  separate+fallible from Frame.init (F-5); tickscale=1 (F-4); selection-cut = plain
  delete until snarf (F-6); no scroll/textshow — org fixed, wheel ignored (F-7);
  single-Text (F-9); NEW scenes use the acme palette (BACK 0xFFFFEAFF, HIGH 0xEEEE9EFF,
  TEXT/HTEXT/BORD black) — frozen phase-2..5 hashes untouched (F-10).
- **R-P6-10 (ABI)**: version 2→3; ONE export `pushEvent(kind,a,b,c,t)` (S-06 §4: input
  has NO env imports; exports are clean); the record layout doubles as the future SAB
  ring slot. Key transliteration (DOM key string → rune) lives in shim.js as a
  MECHANICAL keyboard.h mirror; all policy in Zig (ADR-0004).
- **R-P6-11 (ctl errors)**: reuse error.BadMessage for bad ctl writes (no new OpError
  member).
- **R-P6-12 (editor loop home)**: the routing state machine goes in core/Editor.zig
  (natively testable); main_wasm keeps only the adapter (drain → handle* → frameEnd).

## Waves

- **6a (concurrent, 4 agents, disjoint files):**
  - A1 opus — src/ninep/server.zig: wait queue per the ninep side file (tests 1-10).
  - A2 opus — src/ninep/client.zig: tickets per the ninep side file (tests 11-15).
  - A3 sonnet — src/dev/profiles.zig (+ its dev.zig re-export line): constants, tables,
    the modifier Machine per the devinput side file (tests 1-8).
  - A4 opus — src/draw/frame/*: tick fields+freeBox+initTick (Frame.zig), real tick +
    drawSel prologue + redraw ticked (draw.zig), insert tick activation, delete.zig,
    select.zig per the editing side file (frame tests).
- **6b (after 6a, concurrent):**
  - B1 opus — src/dev/input.zig (+ dev.zig line): tree/queues/formats/park integration
    per the devinput side file with R-P6-2/3 applied (tests 9-19).
  - B2 opus — src/core/text/: Text.zig growth + typing.zig + select.zig per the editing
    side file (typing/select tests).
- **6c (after 6b): C1 opus** — core/Editor.zig loop + main_wasm.zig wiring (second
  in-process Server+Pipe for DevInput, pushEvent export, wake/tick adapter, standing
  tickets per R-P6-4, palette + empty-buffer boot scene) + shim/abi.zig v3 + web/shim.js
  listeners/KEYRUNE + editor tests.
- **Wave C (orchestrator)**: accept.zig phase-6 scene + FROZEN-ACCEPT-6a/6b freezes,
  smoke extension, S-00/S-01/S-04 revision notes, browser check, report, merge.
