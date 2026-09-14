# S-01 — 9P Protocol Specification

Satisfies: R-9P-01, R-9P-02, R-9P-04, R-9P-13, R-OV-03.

## 1. Version

Snarf speaks **9P2000** as defined by the Plan 9 manual (intro(5)). Extensions from
9P2000.u / 9P2000.L are **not** used; numeric uid fields are unused (`uname` strings only),
which suits a single-user browser instance.

`msize` is negotiated at `Tversion`; Snarf proposes **65536** and accepts any value ≥ 8192.
For the in-memory transport, `msize` bounds message framing but large reads/writes may be
chunked by the client as usual.

## 2. Message subset

### 2.1 Mandatory (all servers)

| Message | Notes |
|---------|-------|
| `Tversion`/`Rversion` | exactly once per connection |
| `Tattach`/`Rattach` | `afid = NOFID`; `aname` selects sub-export where a server has several |
| `Twalk`/`Rwalk` | up to 16 names per walk (MAXWELEM) |
| `Topen`/`Ropen` | modes: OREAD, OWRITE, ORDWR, OTRUNC; OEXEC treated as OREAD |
| `Tread`/`Rread`, `Twrite`/`Rwrite` | offset semantics per file type (see S-02 per-file notes; directories: standard stat-record stream) |
| `Tclunk`/`Rclunk` | |
| `Tstat`/`Rstat` | |
| `Tcreate`/`Rcreate` | directory fid, unopened; `perm` masked against the parent by the server; the fid then names the NEW file, opened with `mode` (`5/open`) |
| `Tremove`/`Rremove` | "a clunk with the side effect of removing the file": the fid is clunked even when the remove fails (`5/remove`) |
| `Twstat`/`Rwstat` | "don't touch" = `~0` / empty strings; type, dev, qid, muid and the DMDIR bit may never be changed (`5/stat`) |
| `Tflush`/`Rflush` | MUST be honored; critical for cancelling blocked reads (`/dev/mouse`) |
| `Rerror` | error strings, Plan 9 style; no errno numbers |

The framework decodes and dispatches all of the above. create/remove/wstat are
*mandatory for the framework, optional per server*: a server that leaves the `create`,
`remove` or `wstat` slot unbound answers lib9p's refusal strings — `"create prohibited"`,
`"remove prohibited"`, `"wstat prohibited"` (`lib9p/srv.c:18,20,24`) — so a read-only
tree needs no code at all. Which trees bind them: `/mnt/host`, `/mnt/opfs`,
`/dev/storage`, `/n/origin` (server permitting); `/dev/dom` deliberately does NOT
(element creation is a `ctl` verb, so it keeps answering `"create prohibited"`).

### 2.2 Conditional

| Message | Required for |
|---------|--------------|
| `Tauth`/`Rauth` | the ONLY pair Snarf does not implement. Optional everywhere; `/n/origin` MAY implement it (OQ-9P-3), in-browser servers return `Rerror "authentication not required"` |

### 2.3 Qids

Standard 13-byte qids. `qid.type` bits used: `QTDIR`, `QTFILE`, `QTAPPEND` (e.g. `/dev/log`).
Synthetic files use `qid.vers` as a change counter (devdom bumps it on mutation).

## 3. Transports (R-9P-02)

### 3.1 In-memory channel (worker-local)

Client and servers share the address space, so the "wire" is a pair of SPSC ring buffers of
framed 9P messages (`size[4] type[1] tag[2] ...`, standard framing). Zero-copy fast path:
`Rread` data for large payloads may be passed as a (pointer, len) view valid until the
client acks — an internal optimization; the *logical* protocol remains byte-exact 9P so any
server can be lifted out of process unchanged (R-9P-04).

### 3.2 WebSocket (origin)

- Endpoint: `wss://<origin>/9p` by default; overridable via `<meta name="snarf-9p" content="...">`
  in the hosting page or `?9p=` query parameter (same-origin or CORS/WSS-permitted only, R-9P-15).
- **Binary** WebSocket messages; each WebSocket message contains exactly **one** 9P message
  (the 4-byte size prefix is still present and must match the payload length). No batching
  in v1.
- Connection loss ⇒ all fids on that mount become stale; the mount point reports
  `Rerror "connection closed"`; a `Reconnect` command in Snarf's UI re-attaches.
- Keepalive: WebSocket ping/pong at 30 s, owned by the shim.

> Revision log: 2026-09-02 (phase 11) — server side implemented
> (`tools/origin/ws_transport.zig` as a `ninep.transport.Transport`): binary frames only
> (a text frame is a `BadFrame` and drops the connection), size prefix checked against
> the payload, pings answered inside the transport so they never reach 9P, **no
> fragmentation** (a non-FIN frame is rejected — one message per frame, as specified).
> Blocking transport, thread per connection; the client half for native use is
> `ws_client.zig`. The shim's WebSocket import and `/n/origin` mount are not yet wired.

### 3.3 Flow control & tags

Clients may pipeline; tag space is 16-bit; `NOTAG` only for `Tversion`. Servers answer in
any order. `Tflush` handling follows the man page strictly (respond to flushed request
first or not at all, then `Rflush`).

## 4. Blocking reads & cancellation (R-9P-13)

Files like `/dev/mouse`, `/dev/kbd`, `/dev/dom/events`, and window `event` files block until
data exists. Servers implement this by parking the request (tag) in a wait queue; the SAB
or async machinery (S-00 §2) wakes them. A client dropping interest MUST `Tflush`. The
sequence diagram below shows the common walk/open/read flow against `/mnt/host`:

**ANY operation may park, not just reads.** A device that has to ask the browser cannot
answer a walk, an open, a create or a stat synchronously either, so the framework signal
is uniform: an `Ops` callback returns `error.WouldBlock` and the server files the WHOLE
T-frame on the FIFO, unanswered. A retry re-decodes that frame and re-dispatches it
through the ordinary handler — there is no partially-applied operation to resume, which
is why a blocked handler must leave no observable trace (the rule `read` always obeyed).
`attach`, `clunk` and `flush` may NOT park, and their vtable signatures make that a
compile-time fact rather than a runtime check. A `Tflush` of a parked tag answers the
old tag `Rerror "interrupted"` and then `Rflush`; a `Tclunk` sweeps everything parked on
that fid the same way; a `Tversion` discards the queue silently.

The queue is BOUNDED (64 entries) and the overflowing request is refused with
`Rerror "too many parked requests"`. Plan 9 has no such limit — a kernel mount point
simply blocks the calling process — but Snarf's servers share one wasm heap with the
editor and have no way to apply back-pressure to a misbehaving client, so the bound is
the server's memory budget.

![9p-session](diagrams/9p-session.puml)

Diagram source: [diagrams/9p-session.puml](diagrams/9p-session.puml)

### 4.1 Tickets and jobs — the client side of "never block" (R-9P-13)

The server side above is only half the rule. The editor runs on the browser's main
thread, so **no 9P operation it issues may block** — not just reads of parkable files.
Two situations make a synchronous RPC impossible: a file that parks server-side (the
reply never comes), and a transport with no pump at all (`/n/origin`'s frames arrive on
a later tick, through `wsPush`). One mechanism covers every T-message:

- **`begin(client, T-message, buf) → Ticket`** — send now, do not wait. A slot keyed by
  the freshly allocated tag records the caller's borrowed `buf`. `begin` may pump, but
  only for the SEND.
- **`check(client, ticket) → ?Reply`** — **never pumps and never blocks.** It drains
  whatever frames the transport has *right now* (a `WouldBlock` ends the drain), routes
  each by tag into its slot, then reports this ticket: `null` = still pending, a decoded
  reply = done (and the ticket is consumed), an `Rerror` = the mapped error
  (`"interrupted"` for a flushed ticket).
- **`cancel(client, ticket)`** — `Tflush` the ticket and consume it either way, handling
  both server orderings (flushed-reply-then-`Rflush`, or the data racing ahead).
  Asynchronous like everything else here: it sends the `Tflush` and returns, never
  waiting for the `Rflush`.

Invariant: a live tag is always in the pending table, so a synchronous op still in
flight routes a foreign reply into its ticket rather than failing — an out-of-order
`Rread` for a standing `/dev/mouse` ticket is absorbed while a `Tstat` is outstanding.

Corollary — **abandoning a request keeps its tag**. The server still owes a reply for a
flushed tag (and for the `Tflush` itself, and for the `Tclunk` a half-finished job owes
on its way out). Freeing the slot would leave those replies homeless, and a homeless
reply is a protocol error charged to whichever *unrelated* ticket happens to drain it
next. So an abandoned slot becomes a **tombstone**: the tag stays booked, the reply that
eventually arrives — in either order, on any later tick — is dropped, and the slot is
released then. Cleanup is consequently all fire-and-forget: nothing on a `cancel` or a
job `deinit` path may issue a synchronous RPC, which on an un-pumped transport would
send its message, fail `WouldBlock` and abandon the tag with nowhere for the reply to
land. A transport that never answers leaks one tombstone per abandoned request until the
session ends (`Tversion` clears the table).
A **read ticket** is the mode of this mechanism that copies the `Rread` *payload* to the
front of the caller's buffer; every other ticket takes the *raw reply frame*, so its
`buf` must be sized for the reply (and a `Tread` issued that way can only ask for
`buf.len − 11` bytes).

**Jobs.** Multi-message operations are state machines over tickets: one message in
flight, one state advanced per `step()`, results in fields, `deinit` cancelling anything
outstanding and clunking anything opened. The four the editor needs are walk a namespace
path (the union walk of S-02 §1.1), stat it, read a whole file, and list a directory
(`unionread`, S-02 §1.2). Nothing in the editor may reach a mounted file any other way.
The synchronous walk/read helpers survive only for pumped in-process transports and for
tests, where a `runSync(job, pump)` loop drives a job to completion — and that loop's
pump must drive **every** server the job can reach, precisely because `check` refuses to
pump on its own.

> Revision log: 2026-07-19 — §4 implemented (phase 6): framework-level parked-read
> FIFO with re-run completion (Server.completeReads), Tflush answering the parked tag
> Rerror "interrupted" BEFORE Rflush, clunk/version sweeps. Devices signal parking
> via error.WouldBlockRead (never a wire string).
>
> 2026-09-14 (phase 14a) — §2 create/remove/wstat moved from Conditional to Mandatory
> (framework-level; `Tauth`/`Rauth` is now the only unimplemented pair) and §4 parking
> generalised from reads to every operation, with the bound added. Implemented in
> `src/ninep/msg_mut.zig` (codec), `src/ninep/park.zig` (queue) and
> `src/ninep/server_mut.zig` (handlers); lifts phase-1 ruling R5.
>
> 2026-09-14 — §4.1 added (phase 13a): R-9P-13 extended from "blocking reads" to every
> 9P operation the editor issues. `src/ninep/tickets.zig` holds the generic ticket (the
> phase-6 read ticket becomes its `.payload` mode, byte-identical — a raw-frame slot
> cannot carry it, since `beginRead` asks for the caller's whole buffer);
> `src/ninep/nsjob.zig` (walk) + `src/ninep/nsio.zig` (stat/read/list) hold the jobs.

## 5. Errors (canonical strings)

`"file does not exist"`, `"permission denied"`, `"fid in use"`, `"i/o error"`,
`"bad message"`, `"file is a directory"`, `"connection closed"`, `"interrupted"` (flush),
`"no user gesture"` (devhost: FS Access needs user activation), `"quota exceeded"`
(devstorage). Servers should prefer these before inventing new strings.

The framework itself also emits, verbatim from lib9p and the Plan 9 kernel:
`"create prohibited"`, `"remove prohibited"`, `"wstat prohibited"`
(`lib9p/srv.c:18,20,24` — an unbound `Ops` slot), `"9P protocol botch"` (create on an
already-open fid), `"create in non-directory"`, `"bad directory in wstat"`,
`"wstat -- attempt to change {type,dev,qid,muid,DMDIR bit}"`, `"file name syntax"`
(`9/port/error.h:15`) and `"too many parked requests"` (§4, Snarf-specific). These are
capability refusals and protocol botches rather than file errors, so they have no typed
counterpart in `errors.OpError` and a client sees them as `error.Other` plus the raw
text.

## 6. Zig mapping (informative)

`src/ninep/` provides: `Msg` tagged union with `encode`/`decode` (bounds-checked, no
allocation for fixed parts), `Client` (fid/tag tables), `Server` framework (`Srv` vtable:
`attach/walk/open/read/write/clunk/stat/...` — deliberately shaped like Plan 9's `lib9p`),
and `Mount` table. All std-only (R-CON-01).
