# Phase 6 ninep side contract (O11) — wait queue + client tickets

Read with the master (R-P6-1..5). C evidence: plan9port src/lib9p/srv.c (sflush :245,
rflush :257, respond :751, deferred or->flush[] FIFO :862, tag-reuse race doc :812-826);
flush(5). Zig 0.16; cite srv.c/flush(5) in doc comments.

## A1 — src/ninep/server.zig extensions

```zig
/// Ops.read may additionally return WouldBlockRead: "no data now, park me".
/// NOT part of errors.OpError — it can never become an Rerror string.
pub const ReadError = errors.OpError || error{WouldBlockRead};
// Ops.read changes: read: *const fn (...) ReadError!usize
// (errors.zig UNTOUCHED — errorString stays total over OpError.)

const Parked = struct { tag: u16, fid: u32, offset: u64, count: u32 }; // fid NUMBER, not *Fid
// New Server fields:
parked: std.ArrayListUnmanaged(Parked) = .empty,   // FIFO, park order
pbuf: []u8,   // completion scratch, max_msize, allocated in init, freed in deinit (D6)

/// Device/adapter signal: data may now exist on the file(s) whose qid.path == path.
/// Re-runs each matching parked read IN PARK ORDER (looking up the fid to get its
/// qid): success => Rread + unpark; WouldBlockRead => stays parked; other error =>
/// Rerror + unpark. Returns replies sent. SAFE to call from inside Ops callbacks and
/// from tick-level code: reads fill pbuf (NEVER rbuf — it may hold an in-flight
/// Twrite's data); replies encode into wbuf via reply() as usual.
pub fn completeReads(self: *Server, path: u64) Error!usize
pub fn parkedCount(self: *const Server) usize
```

Dispatch changes:
- handleRead's ops.read call: `catch |e| switch (e) { error.WouldBlockRead => return
  self.park(tag, fid, offset, clamped), else => |oe| return self.replyError(tag, oe) }`.
  park() appends {tag,fid,offset,count}; sends NO reply.
- handleFlush: search parked for oldtag. Found => remove; reply Rerror "interrupted"
  (error.Interrupted exists) on oldtag FIRST; then Rflush on the flush's tag. Not
  found => plain Rflush (existing behavior + test retained). ops.flush notify stays.
- handleClunk: before removing the fid, sweep parked entries with that fid => Rerror
  "interrupted" each, remove, then op-notify + Rclunk as today.
- handleVersion: also clear `parked` SILENTLY (no replies; session reset).
- Hardening: an incoming T-message whose tag is currently parked => Rerror "bad
  message" on the new frame; parked entry untouched.

Named tests (TestTransport + a BlockingFixture whose read drains an injectable
per-file queue else WouldBlockRead):
1. "server: park and complete round trip"
2. "server: flush interrupts parked read" (exactly two frames IN ORDER: Rerror
   "interrupted" tag T, then Rflush; parkedCount 0; later completeReads sends nothing)
3. "server: flush of completed tag is plain Rflush"
4. (existing flush-idle test retained)
5. "server: clunk with parked reads interrupts then Rclunk"
6. "server: multiple parked tags on one file complete in park order" (one fid two
   tags + a two-fid variant)
7. "server: partial completion leaves remainder parked"
8. "server: version reset silently discards parked"
9. "server: duplicate tag while parked rejected"
10. "server: completeReads from inside Ops.write does not corrupt the write"
    (ctl-write triggers completion; the Twrite's rbuf-aliased data validated after —
    pins pbuf/D6)

## A2 — src/ninep/client.zig extensions

Core change: rpc's "reply.tag != t.tag => ProtocolError" becomes DISPATCH — a reply
matching a pending ticket is routed to its slot (data copied out of rbuf immediately);
only truly unknown tags are ProtocolError.

```zig
pub const ReadTicket = struct { tag: u16 };   // opaque
const PendingRead = struct {
    buf: []u8,                                 // caller-owned destination
    state: union(enum) { waiting, done: usize, failed: Error },
};
pending: std.AutoHashMapUnmanaged(u16, PendingRead) = .empty,  // new field

/// Send Tread(fid, offset, min(buf.len, msize-IOHDRSZ)) WITHOUT waiting. buf must
/// outlive the ticket; the reply (whenever it arrives, during ANY pump/rpc/checkRead)
/// is copied into it.
pub fn beginRead(self: *Client, fid: u32, offset: u64, buf: []u8) Error!ReadTicket
/// Non-blocking: drain ready frames (dispatching by tag), then report. null =>
/// pending. A flushed ticket completes with error.Interrupted. Non-null consumes.
pub fn checkRead(self: *Client, t: ReadTicket) Error!?usize
/// Abandon: sends Tflush(oldtag=t.tag) synchronously via rpc (flushes never park).
/// Rerror "interrupted" for the old tag arrives BEFORE Rflush and is dispatched to
/// the slot; if data raced ahead, the data reply is dispatched and discarded. Consumes.
pub fn cancelRead(self: *Client, t: ReadTicket) Error!void
```
Doc rule (add to Pump docs + rpc): rpc-based read() on files that may park is a
programming error (spins forever); use tickets. deinit frees the pending map.

Named tests (ScriptedTransport):
11. "client: beginRead pending then completes"
12. "client: out-of-order reply dispatched during rpc" (pending ticket A; scripted
    replies [Rread(A), Rstat] during a sync stat => both succeed — THE crux)
13. "client: cancelRead consumes interrupted-then-Rflush"
14. "client: cancelRead races completion" (replies [Rread(A), Rflush] => clean, data
    discarded)
15. "client: flushed ticket surfaces error.Interrupted via checkRead"

## S-00 §2 amendment (orchestrator, Wave C — O11's wording, apply verbatim-ish)

R-9P-13 ships as async mode with tickets on the main thread; "SAB mode" REDEFINED:
the Worker move relocates the module and adds ONE blocking point (Atomics.wait on the
inbound event ring at the top of the editor loop); per-file Atomics.wait inside a
device read is ruled out permanently (single thread must select over mouse+kbd) —
this corrects §2's original sentence. Ticket machinery identical in both modes.
Also: S-01 §4 gets a "implemented (phase 6)" note; the phase-5 S-00 note is superseded.
