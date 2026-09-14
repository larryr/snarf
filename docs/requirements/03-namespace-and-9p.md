# R-03 — Namespace & 9P Requirements

Status: **Draft v3**

Everything outside the editor core's memory is a file served over 9P. This document states
which namespaces must exist and what they must let a client do. Protocol details:
[../spec/01-9p-protocol.md](../spec/01-9p-protocol.md); per-mount file trees:
[../spec/02-namespaces.md](../spec/02-namespaces.md).

## 1. Protocol

| ID | Requirement |
|----|-------------|
| R-9P-01 | The file protocol SHALL be **9P2000** (baseline, not 9P2000.u/.L). A defined subset of messages is mandatory (spec 01); unknown/unsupported requests get proper `Rerror` responses. |
| R-9P-02 | 9P SHALL run over at least two transports: (a) an **in-memory channel** between the editor core and in-browser device servers (zero-copy where possible), and (b) **WebSocket** framing to the origin server. |
| R-9P-03 | The namespace SHALL support **mount** and **bind** so the visible tree is assembled per instance, **including union directories**: `bind` SHALL take a Plan 9 order flag (replace / before / after, `MREPL`/`MBEFORE`/`MAFTER`), a walk SHALL try the union's members in bind order and take the first success, and a directory read SHALL concatenate the members' listings in bind order with no de-duplication. (OQ-9P-1 resolved YES, 2026-09-14.) |
| R-9P-04 | All servers SHALL be usable by external 9P clients in principle: no server may depend on being called by the editor core specifically (clean layering; enables R-EDIT-17). |

## 2. Mandatory mounts

| ID | Mount | Requirement |
|----|-------|-------------|
| R-9P-05 | `/dev/dom` | The **DOM of the hosting page** exposed as a file tree: elements as directories; attributes, computed style, text content, and inner HTML as files; a `ctl` file per element for mutations (create/append/remove/listen); an `events` file streaming DOM events as text. Reading and writing the DOM through the namespace MUST be sufficient to script the page without any JavaScript. |
| R-9P-06 | `/dev/draw` | The graphics device (requirements in [04-graphics.md](04-graphics.md)). |
| R-9P-07 | `/dev/snarf` | Read = current clipboard contents; write = replace clipboard. Backed by the async Clipboard API; permission failures surface as 9P errors, not silent truncation. |
| R-9P-08 | `/dev/browser` features | At minimum: `/dev/storage` (localStorage/IndexedDB-backed persistent files), `/dev/notify` (write to post a notification), `/dev/location` (read/navigate URL), `/dev/title` (read/write tab title), `/dev/log` (write to console). Each is small, plain-text, Plan 9-flavored. |
| R-9P-09 | `/mnt/host` | The **host file system** via the HTML5 **File System Access API**: the user picks a directory (`showDirectoryPicker`), which appears as a writable subtree. Permission prompts and denials MUST map to well-defined 9P errors; no host access ever occurs without an explicit user gesture. Fallback when the API is unavailable (Firefox/Safari): read-only import + explicit download-to-save, and OPFS as an always-available private area (`/mnt/opfs`). |
| R-9P-10 | `/n/origin` | If the **origin server** exports a 9P service (WebSocket endpoint, default `wss://<origin>/9p`), it SHALL be mounted at `/n/origin` (Plan 9's directory for network-mounted services, `ns(1)`), giving Snarf real remote files with full 9P semantics. Its `bin/` directory, when it has one, SHALL additionally be bound into `/bin` with `-a` (MAFTER) so command lookup sees a union. Absence of the endpoint MUST degrade gracefully (mount simply absent), and losing the connection MUST remove both bindings. |
| R-9P-11 | `/dev/mouse`, `/dev/kbd`, `/dev/cons` | Input devices per [05-input.md](05-input.md). |
| R-9P-12 | `/mnt/snarf-self` | Snarf's own editor state (R-EDIT-17), same file API shape as ACME's. |

## 3. Cross-cutting

| ID | Requirement |
|----|-------------|
| R-9P-13 | Blocking reads (e.g. `/dev/mouse`, `event` files) MUST work without blocking the browser main thread — the concurrency model (spec 00/01) has to make long-poll-style reads natural in WASM. |
| R-9P-14 | Every namespace file SHALL be documented with its read/write format in spec 02; formats are line-oriented text unless there is a strong reason otherwise (Plan 9 style). |
| R-9P-15 | Security: the namespace boundary is the security boundary. `/dev/dom` is same-page only; `/mnt/host` only ever contains user-granted handles; `/n/origin` is same-origin (or CORS/WSS-permitted) only. No server may proxy to arbitrary third-party URLs in v1 (see OQ-9P-2). |
| R-9P-16 | Directories that exist only as prefixes of mounted entries (`/`, `/n`, `/mnt`, …) SHALL be **synthesized by the namespace** — the role Plan 9's root device `#/` plays (`9/port/devroot.c`) — so that walks and directory listings work at every level of the tree without a root file system. Synthesized directories are read-only, report `DMDIR|0555`, and carry a stable qid derived from their path. |

## 4. Open questions

- ~~OQ-9P-1~~: Union directories (Plan 9 `bind -a`) in v1, or plain mount table only?
  **RESOLVED 2026-09-14 (user): YES, unions, in their own wave before directory windows.**
  Folded into R-9P-03 + R-9P-16 and built in phase 12d; the first user is the origin's
  `bin/` unioned into `/bin`.
- OQ-9P-2: A `/dev/fetch` (write URL+headers, read response) would be extremely useful but
  is an SSRF-shaped feature; gated behind explicit origin opt-in? *Deferred, not in v1.*
- OQ-9P-3: 9P auth (`Tauth`) is unnecessary in-browser (same-origin is the auth) — but
  should `/n/origin` support it for servers that want tokens? *v1: `Tauth` optional,
  token may ride the WebSocket URL/cookies instead.*

## 5. Revision log

- **v1** — initial mount list.
- **v3** (2026-09-14, phase 12d) — **OQ-9P-1 resolved YES by the user**: R-9P-03 now
  REQUIRES union directories (bind order flags, first-success walk, concatenated reads);
  new **R-9P-16** makes the namespace synthesize the mount-point directories that only
  exist as prefixes (Plan 9 `#/`'s role); **R-9P-10 moved the origin mount out of `/mnt`
  to `/n/origin`** (user decision, Plan 9 network-mount idiom) and added the `bin/` → `/bin`
  union bind.
- **v2** — added OPFS fallback to R-9P-09 after surveying File System Access API browser
  support; added R-9P-13 (non-blocking reads) after the /dev/draw + event-loop design;
  split browser features into named small files (R-9P-08).
