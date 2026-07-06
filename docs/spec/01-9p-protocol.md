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
| `Tflush`/`Rflush` | MUST be honored; critical for cancelling blocked reads (`/dev/mouse`) |
| `Rerror` | error strings, Plan 9 style; no errno numbers |

### 2.2 Conditional

| Message | Required for |
|---------|--------------|
| `Tcreate`/`Rcreate`, `Tremove`/`Rremove` | writable trees: `/mnt/host`, `/mnt/opfs`, `/dev/storage`, `/mnt/origin` (server permitting), `/dev/dom` (element creation via directories is done with `ctl` instead — devdom returns `Rerror "create prohibited"` and documents the `ctl` verbs) |
| `Twstat`/`Rwstat` | rename/truncate on writable trees; others return `Rerror` |
| `Tauth`/`Rauth` | optional everywhere; `/mnt/origin` MAY implement it (OQ-9P-3), in-browser servers return `Rerror "authentication not required"` |

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

### 3.3 Flow control & tags

Clients may pipeline; tag space is 16-bit; `NOTAG` only for `Tversion`. Servers answer in
any order. `Tflush` handling follows the man page strictly (respond to flushed request
first or not at all, then `Rflush`).

## 4. Blocking reads & cancellation (R-9P-13)

Files like `/dev/mouse`, `/dev/kbd`, `/dev/dom/events`, and window `event` files block until
data exists. Servers implement this by parking the request (tag) in a wait queue; the SAB
or async machinery (S-00 §2) wakes them. A client dropping interest MUST `Tflush`. The
sequence diagram below shows the common walk/open/read flow against `/mnt/host`:

![9p-session](diagrams/9p-session.puml)

Diagram source: [diagrams/9p-session.puml](diagrams/9p-session.puml)

## 5. Errors (canonical strings)

`"file does not exist"`, `"permission denied"`, `"fid in use"`, `"i/o error"`,
`"bad message"`, `"file is a directory"`, `"connection closed"`, `"interrupted"` (flush),
`"no user gesture"` (devhost: FS Access needs user activation), `"quota exceeded"`
(devstorage). Servers should prefer these before inventing new strings.

## 6. Zig mapping (informative)

`src/ninep/` provides: `Msg` tagged union with `encode`/`decode` (bounds-checked, no
allocation for fixed parts), `Client` (fid/tag tables), `Server` framework (`Srv` vtable:
`attach/walk/open/read/write/clunk/stat/...` — deliberately shaped like Plan 9's `lib9p`),
and `Mount` table. All std-only (R-CON-01).
