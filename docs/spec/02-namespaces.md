# S-02 — Namespace Specification (mounts & file formats)

Satisfies: R-9P-03, R-9P-05..12, R-9P-14, R-9P-15, R-EDIT-14..17.

All file formats are line-oriented UTF-8 text unless stated (R-9P-14). The assembled tree:

![namespaces](diagrams/namespaces.puml)

Diagram source: [diagrams/namespaces.puml](diagrams/namespaces.puml)

## 1. Mount table

The namespace is a per-instance ordered table `path prefix → ordered list of
(server, root fid)`. Longest-prefix match on path COMPONENT boundaries wins
(`/mnt/host` never matches `/mnt/hostx`). Built at boot (S-00 §4); the file `/dev/ns`
(read-only) lists the table in `ns(1)` style for debugging.

### 1.1 Unions (`bind -a` / `bind -b`) — R-9P-03, OQ-9P-1 resolved YES

Each mount point carries an ORDERED list of targets, the flattened form of the kernel's
`Mhead` + `Mount` chain (`9/port/chan.c:646-760 cmount`). `bind` takes a flag mirroring
`MREPL`/`MBEFORE`/`MAFTER` (`sys/include/libc.h:538-540`):

| Flag | `ns(1)` | Effect |
|------|---------|--------|
| `replace` | `mount`/`bind` | drops whatever chain was there (chan.c:739-742) |
| `before` | `bind -b` | new target goes FIRST in the union |
| `after` | `bind -a` | new target goes LAST in the union |

- **Walk** (chan.c:965-1050, esp. :1020-1043): try the first target; on failure try the
  remaining members *in order*; the first success wins. All fail ⇒ the walk fails at that
  component.
- **Read** (`9/port/sysfile.c:323-367 unionread`): a directory read CONCATENATES the
  members' stat streams in bind order, one cursor per open directory. A member that
  errors is skipped ("Error causes component of union to be skipped", sysfile.c:340).
  There is **no de-duplication** — Plan 9 does none, so a name in two members is listed
  twice. Offset 0 rewinds (`unionrewind`); any other offset must equal the bytes already
  returned (read(5), `Edirseek`).
- **Unmount**: `unmount(prefix)` drops the whole mount point; `unbindTarget(prefix, …)`
  drops one member and removes the entry when its last member goes.

`/dev/ns` prints the head of each union as `mount <prefix>` and every stacked member as
`bind -a <prefix>` / `bind -b <prefix>` (the shape of `/proc/n/ns`, devproc.c:954-966;
we have no server names to print, so the line carries the mount point only).

### 1.2 Synthetic mount-point directories — R-9P-16

Plan 9's root device `#/` supplies the top-level directories that mounts hang from:
`rootreset` (`9/port/devroot.c:96-107`) statically adds `bin dev env fd mnt net net.alt
proc root srv`, each `DMDIR|0555`, and `bind(2)` then requires the mount point to exist.
(`/n` is NOT in that list — on a real Plan 9 it comes from the root file server's tree.)

Snarf has no root filesystem, so the mount table plays that role generically: **any
directory that exists only as a PREFIX of a mounted entry is synthesized** — `/`, `/n`
(because `/n/origin` is mounted), `/mnt`, … A walk to such a path yields a synthetic
directory handle; a directory read of it yields one `DMDIR|0555` stat record per child
prefix (next component only, each name once), *followed* by the union members' own
listings when something is also mounted exactly there. Synthetic qids are FNV-1a-64 of
the canonical path with the high bit set, so repeated listings are stable and cannot be
confused with a server's own qid paths. Synthetic directories are read-only; nothing can
be created in them (a `bind`/`mount` is what puts something there).

### 1.3 The boot namespace

| Prefix | Host | What |
|--------|------|------|
| `/dev/draw`, `/dev/mouse`, `/dev/kbd`, `/dev/cons`, `/dev/cursor` | both | in-module device servers (S-03, S-04) |
| `/dev/dom` | browser | the hosting page (§2) — **browser-only, low priority** |
| `/dev/snarf`, `/dev/storage`, `/dev/notify`, `/dev/location`, `/dev/title`, `/dev/log` | browser | browser feature files (§3) |
| `/dev/ns` | both | this table, `ns(1)` style, read-only |
| `/mnt/host` | browser | File System Access grants (§4) |
| `/mnt/opfs` | browser | Origin Private File System (§4) |
| `/mnt/snarf-self` | both | Snarf's own served tree (§6) |
| `/n/origin` | browser | the origin server's 9P export (§5) |
| `/bin` | both | command union; the origin's `bin/` is bound in with `-a` (§5) |

"Host" is where the mount can exist at all: **browser** (needs the page), **native**
(needs the host OS), **both**. The native host is ADR-0005's target; the editor core
cannot tell the difference, which is the point of R-OV-03.

## 2. `/dev/dom` — the hosting page (R-9P-05) — Host: **browser**

> Kept in the design, browser-host only, LOW priority (user decision 2026-09-14): no wave
> until someone needs to script the page from inside Snarf.

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

## 3. Browser feature files (R-9P-07, R-9P-08) — Host: **browser** unless noted

| File | Host | Semantics |
|------|------|-----------|
| `/dev/snarf` | browser | Read: entire clipboard as text (async Clipboard API; permission error → `Rerror "permission denied"`). Write (OTRUNC): replace clipboard on clunk (writes buffered until `Tclunk`, matching Plan 9's snarf semantics and the Clipboard API's single-shot writes). |
| `/dev/storage/` | browser | Writable tree persisted to IndexedDB. Ordinary create/read/write/remove; survives reloads. Quota errors → `Rerror "quota exceeded"`. Intended for `Dump` files (R-EDIT-16), settings, etc. |
| `/dev/notify` | browser | Write `title` on first line, body on the rest → Notification (permission requested on first use). |
| `/dev/location` | browser | Read: current URL + one `key value` line per component. Write: URL → navigate (top-level navigation prompts a confirm since it destroys the session). |
| `/dev/title` | browser | Read/write document title. |
| `/dev/log` | browser | Append-only (`QTAPPEND`); each write becomes one `console.log` line. |
| `/dev/input/ctl` | both | Read: active input profile + capabilities. Write: `profile native|modifier|touch|chordbar`, `map <modifier> <button>` (S-04). |

## 4. `/mnt/host` and `/mnt/opfs` — host storage (R-9P-09) — Host: **browser**

(The native host reaches the file system through a native 9P file server instead; ADR-0005.)

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

## 5. `/n/origin` — origin 9P export (R-9P-10) — Host: **browser**

Mounted at boot when the WebSocket endpoint (S-01 §3.2) connects; otherwise absent.
`/n` is Plan 9's directory for network-mounted services (`ns(1)`, `srv(4)`: `/n/<service>`)
and exists only because this mount hangs from it (§1.2). The
server controls the exported tree entirely — typical exports: project source, `bin/`
services (R-EDIT-18: an origin "command" is a file `bin/<name>/ctl` that Snarf writes
`exec <args>` to and streams `bin/<name>/output` from). On a successful attach the export's
`bin` directory — when it has one — is additionally bound into `/bin` with `-a` (MAFTER),
so command lookup is acme's "the window's directory, then the path" over a `/bin` that is a
union, exactly as on Plan 9 (R-EDIT-20, `acme/exec.c run()`). An export with no `bin`
mounts normally and contributes nothing to `/bin`. Both rows go away together when the
connection dies. Reference server implementations
(Go `9fans.net/go`, plan9port `u9fs` behind a WS bridge) will be listed in the repo README
when code lands; the docs only fix the wire contract.

> Revision log: 2026-09-02 (phase 11) — Snarf's own origin server shipped
> (`tools/origin/`, `zig build serve`). v1 export tree: `version` (server identity),
> `bin/{echo,date}/{ctl,output}` (**built-ins only — no host process is ever spawned**;
> arbitrary exec over a WebSocket would be remote code execution, so real host commands
> await an allow-list design + ADR), and `fs/` — one host directory (`-Dexport`),
> plain files and directories only, read/write with OTRUNC, **no create/remove yet**
> (the server framework has no create/remove ops, ruling R5 of phase 1). Directory
> reads are offset-addressed stat streams (read(5)). Per-connection state: outputs and
> fid nodes die with the WebSocket. The browser side (mount at boot,
> R-9P-10 absence tolerance, `Reconnect`) shipped in phase 12.
>
> Revision log: 2026-09-14 (phase 12d) — the mount point moved out of `/mnt` to **`/n/origin`**
> (user decision), §1 rewritten for union mounts (OQ-9P-1 resolved YES) and the synthetic
> mount-point directories (new R-9P-16), the origin's `bin/` is now bound into `/bin` with
> `-a`, and every device/mount row carries a **Host** column (browser · native · both,
> ADR-0005).

## 6. `/mnt/snarf-self` — Snarf's own interface (R-9P-12, R-EDIT-17) — Host: **both**

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

## 7. Input & graphics devices — Host: **both**

`/dev/draw`, `/dev/mouse`, `/dev/cursor`, `/dev/kbd`, `/dev/cons` are specified in
[03-draw-device.md](03-draw-device.md) and [04-input-devices.md](04-input-devices.md).
