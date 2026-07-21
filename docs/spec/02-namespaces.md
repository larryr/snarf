# S-02 — Namespace Specification (mounts & file formats)

Satisfies: R-9P-03, R-9P-05..12, R-9P-14, R-9P-15, R-EDIT-14..17.

All file formats are line-oriented UTF-8 text unless stated (R-9P-14). The assembled tree:

![namespaces](diagrams/namespaces.puml)

Diagram source: [diagrams/namespaces.puml](diagrams/namespaces.puml)

## 1. Mount table

The namespace is a per-instance ordered table `path prefix → (server, root fid)`. Longest-
prefix match wins. v1 has `mount` and `bind` (no unions, OQ-9P-1). Built at boot (S-00 §4);
the file `/dev/ns` (read-only) lists the table in `ns(1)` style for debugging.

## 2. `/dev/dom` — the hosting page (R-9P-05)

Element ↔ directory. Children appear as numbered directories `0/ 1/ …` in document order
plus stable alias names `tag.N` (e.g. `div.3`); `qid.path` is derived from an internal
per-element id so fids survive sibling reordering; `qid.vers` bumps on any mutation.

Per-element files:

| File | Read | Write |
|------|------|-------|
| `tag` | element tag name | — |
| `attrs` | `name<TAB>value` per line | replace all attributes (same format) |
| `attr/<name>` | value | set attribute (create with `Twrite`; attrs dir is synthetic-on-demand) |
| `text` | `textContent` | set `textContent` |
| `html` | `innerHTML` | set `innerHTML` (sanitization is the page's problem — same-page power, R-9P-15) |
| `style` | computed style, `prop: value` lines | set inline style properties |
| `ctl` | last command status | commands below |

`ctl` verbs (one per write): `create <tag>` (append new child; the new element's index is
returned by the next `ctl` read), `insert <tag> <index>`, `remove` (this element),
`listen <event>` / `unlisten <event>` (subscribe this element's events into `/dev/dom/events`),
`focus`, `scrollintoview`, `click`.

`/dev/dom/events` (blocking read): one event per line —
`<elem-path> <event-type> <detail-json-or-empty>`; e.g.
`root/1/0 click {"x":102,"y":33,"buttons":1}`. Reads block until an event arrives (R-9P-13).

`/dev/dom/query`: write a CSS selector, read back matching element paths (one per line) —
the escape hatch that keeps tree-walking cheap.

## 3. Browser feature files (R-9P-07, R-9P-08)

| File | Semantics |
|------|-----------|
| `/dev/snarf` | Read: entire clipboard as text (async Clipboard API; permission error → `Rerror "permission denied"`). Write (OTRUNC): replace clipboard on clunk (writes buffered until `Tclunk`, matching Plan 9's snarf semantics and the Clipboard API's single-shot writes). |
| `/dev/storage/` | Writable tree persisted to IndexedDB. Ordinary create/read/write/remove; survives reloads. Quota errors → `Rerror "quota exceeded"`. Intended for `Dump` files (R-EDIT-16), settings, etc. |
| `/dev/notify` | Write `title` on first line, body on the rest → Notification (permission requested on first use). |
| `/dev/location` | Read: current URL + one `key value` line per component. Write: URL → navigate (top-level navigation prompts a confirm since it destroys the session). |
| `/dev/title` | Read/write document title. |
| `/dev/log` | Append-only (`QTAPPEND`); each write becomes one `console.log` line. |
| `/dev/input/ctl` | Read: active input profile + capabilities. Write: `profile native|modifier|touch|chordbar`, `map <modifier> <button>` (S-04). |

## 4. `/mnt/host` and `/mnt/opfs` — host storage (R-9P-09)

- `/mnt/host`: appears **empty-with-a-ctl** until granted. Write `open` to
  `/mnt/host/ctl` → shim calls `showDirectoryPicker()` (must be within a user gesture —
  Snarf arranges that the write is issued from the input-event path; otherwise
  `Rerror "no user gesture"`). The granted directory is grafted at `/mnt/host/<dirname>`.
  Multiple grants coexist. Full CRUD via FS Access handles; `Twstat` rename supported via
  `move()` where available.
- Permission revocation mid-session ⇒ subsequent ops return `Rerror "permission denied"`.
- Browsers without the API (R-9P-09 fallback): `/mnt/host/ctl` accepts `import` (file picker
  → read-only snapshot files) and `export <path>` (download). 
- `/mnt/opfs`: the Origin-Private File System, always available, fully writable, no prompts.

## 5. `/mnt/origin` — origin 9P export (R-9P-10)

Mounted at boot when the WebSocket endpoint (S-01 §3.2) connects; otherwise absent. The
server controls the exported tree entirely — typical exports: project source, `bin/`
services (R-EDIT-18: an origin "command" is a file `bin/<name>/ctl` that Snarf writes
`exec <args>` to and streams `bin/<name>/output` from). Reference server implementations
(Go `9fans.net/go`, plan9port `u9fs` behind a WS bridge) will be listed in the repo README
when code lands; the docs only fix the wire contract.

## 6. `/mnt/snarf-self` — Snarf's own interface (R-9P-12, R-EDIT-17)

Mirror of ACME's served tree so existing ACME tooling concepts port directly:

```
index                    one line per window: id name dirty ...
new/                     walking in creates a window
<id>/addr  <id>/body  <id>/data  <id>/tag  <id>/event  <id>/ctl  <id>/xdata
```

Formats and `ctl`/`event` verbs follow acme(4) exactly except: `event` strings use the
same syntax but only mouse/keyboard origins that exist here. Served in-process; also
reachable by the origin server over the same WebSocket (server-initiated attach is a v2
item — v1 exposes it to other tabs via `BroadcastChannel` transport experiment, OQ-OV-2).

**Deferred extension — `kbd hold` (specified here, not implemented in v1).** acme(4)'s
event interface is asymmetric: with an `event` file open, B2/B3 actions are
*deliver-first* (the client may act on the message or write it back for the editor to
apply), but keyboard actions are *report-only* — typed runes self-insert and are then
reported as `K I` deltas. That asymmetry is the one thing preventing modal layers (vim
motions, OQ-EDIT-4) from being pure namespace clients. Snarf completes the symmetry:

- writing `kbd hold` to a window's `ctl` switches that window's keyboard to
  deliver-first: `K` events are delivered to the event-file reader **without mutating
  the buffer**; the client either handles the rune itself (a motion/operator, typically
  ending in `addr` writes + `dot=addr`, per R-EDIT-19) or writes the event back to apply
  it as the ordinary self-insertion (passthrough — i.e. insert mode);
- `kbd release` written to `ctl`, clunking the `event` fid, or window deletion restores
  normal typing — a wedged or dead client MUST never leave a window untypeable;
- holds are per-window and do not affect the tag unless separately requested
  (`kbd hold tag`).

Rationale, motion→address mapping, and the dot-transformer principle: R-EDIT-19 and
OQ-EDIT-4 in [R-02](../requirements/02-editor-functional.md).

## 7. Input & graphics devices

`/dev/draw`, `/dev/mouse`, `/dev/cursor`, `/dev/kbd`, `/dev/cons` are specified in
[03-draw-device.md](03-draw-device.md) and [04-input-devices.md](04-input-devices.md).
