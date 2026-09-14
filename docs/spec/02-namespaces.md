# S-02 — Namespace Specification (mounts & file formats)

Satisfies: R-9P-03, R-9P-05..12, R-9P-14, R-9P-15, R-EDIT-14..17.

All file formats are line-oriented UTF-8 text unless stated (R-9P-14). The assembled tree:

![namespaces](diagrams/namespaces.puml)

Diagram source: [diagrams/namespaces.puml](diagrams/namespaces.puml)

## 1. Mount table

The namespace is a per-instance ordered table `path prefix → ordered list of
(server, root fid)`. Longest-prefix match on path COMPONENT boundaries wins
(`/mnt/host` never matches `/mnt/hostx`). Built at boot (S-00 §4); the read-only file
`/mnt/snarf-self/ns` lists the table in `ns(1)` style for debugging (§1.3 records why it
is not `/dev/ns`).

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

The `ns` file prints the head of each union as `mount <prefix>` and every stacked member as
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
| `/dev/snarf` | both | clipboard (§3): browser = async Clipboard API; native = `devdraw` `Trdsnarf`/`Twrsnarf` (ADR-0005 §2) |
| `/dev/storage`, `/dev/notify`, `/dev/location`, `/dev/title`, `/dev/log` | browser | browser feature files (§3) |
| `/mnt/snarf-self/ns` | both | the mount table itself, `ns(1)` style, read-only — see the note below |
| `/mnt/host` | both | the host file system (§4): browser = File System Access grants; native = a real 9P file server (ADR-0005 §2) |
| `/mnt/opfs` | browser | Origin Private File System (§4) |
| `/mnt/snarf-self` | both | Snarf's own served tree (§6) |
| `/n/origin` | both | the origin server's 9P export (§5); transport-agnostic (WebSocket in the browser, any 9P transport natively) |
| `/bin` | both | command union; the origin's `bin/` is bound in with `-a` (§5) |

"Host" is where the mount can exist at all: **browser** (needs the page), **native**
(needs the host OS), **both**. The native host is ADR-0005's target; the editor core
cannot tell the difference, which is the point of R-OV-03.

**Where the table lives (ruling R-P13a-4).** Plan 9 puts this listing at `/dev/ns`,
which devcons synthesizes. Snarf has no `/dev` server of its own — `/dev` is the input
device and `/dev/draw` the draw device, and neither has any business knowing the mount
table — so the file lives at **`/mnt/snarf-self/ns`**, in the tree that is already the
editor's own interface (§6). It renders one line per union member, exactly as
`Namespace.list` does.

**As built (phase 14b).** The rows above are the intended table; the ones the browser
actually mounts at boot today are:

| Prefix | Mounted by | Notes |
|--------|-----------|-------|
| `/dev` | `ns_boot.mountDevices` | the input device — root directory `mouse kbd ctl` (S-04) |
| `/dev/draw` | `ns_boot.mountDevices` | the draw device; a *separate server*, so `/dev`'s listing gains a synthesized `draw` child (§1.2) |
| `/mnt/snarf-self` | `ns_boot.SelfTree.start` | served in-process from boot (§6) |
| `/mnt/opfs` | `ns_boot.OpfsTree.start` | the OPFS device, mounted UNCONDITIONALLY (§4); every op parks, so jobs only |
| `/n/origin`, `/bin` | `origin/OriginMount` | only if the origin attaches (§5) |

`/` and `/mnt` are mounted by nobody: they are synthesized from those prefixes (§1.2).
So a listing of `/` reads `dev/ mnt/` with the origin down and `bin/ dev/ mnt/ n/` with
it up, and a listing of `/mnt` reads `opfs/ snarf-self/`. Not yet mounted: `/dev/snarf`,
`/dev/dom`, the browser feature files and `/mnt/host`. (`/mnt/snarf-self/ns` itself is
SERVED as of phase 13b; `/mnt/opfs` as of phase 14b.)

> Revision log: 2026-09-14 (phase 14b) — `/mnt/opfs` is BUILT and is the FOURTH
> in-process 9P stack (§4 for the tree as built). It changes no existing listing:
> `/` still reads `dev/ mnt/` with the origin down, because `opfs/` sits under `mnt/`.
>
> Revision log: 2026-09-14 (phase 13b) — `/mnt/snarf-self/ns` is BUILT (§6): the served
> root's dirtab grew an `ns` row rendering `Namespace.list`, which was possible only in
> a wave allowed to move served listings. A window's `ctl` line now reports the real
> `isdir` column (wind.c:695) instead of a hard-coded 0, because directory windows exist.
>
> Revision log: 2026-09-14 (phase 13a) — §1.3 gained the as-built table: the boot
> namespace is no longer empty (`/dev`, `/dev/draw`, `/mnt/snarf-self` mounted at boot,
> `ns_boot.zig`). `/dev/ns` became **`/mnt/snarf-self/ns`** (ruling R-P13a-4: Snarf has
> no `/dev` server of its own), specified but not yet implemented. §6's R-P10-E
> (on-demand serving of the editor's tree) is retired.

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
| `/dev/snarf` | both | Read: entire clipboard as text (browser: async Clipboard API; native: `devdraw` `Trdsnarf`; permission error → `Rerror "permission denied"`). Write (OTRUNC): replace clipboard on clunk (writes buffered until `Tclunk`, matching Plan 9's snarf semantics and the Clipboard API's single-shot writes). |
| `/dev/storage/` | browser | Writable tree persisted to IndexedDB. Ordinary create/read/write/remove; survives reloads. Quota errors → `Rerror "quota exceeded"`. Intended for `Dump` files (R-EDIT-16), settings, etc. |
| `/dev/notify` | browser | Write `title` on first line, body on the rest → Notification (permission requested on first use). |
| `/dev/location` | browser | Read: current URL + one `key value` line per component. Write: URL → navigate (top-level navigation prompts a confirm since it destroys the session). |
| `/dev/title` | browser | Read/write document title. |
| `/dev/log` | browser | Append-only (`QTAPPEND`); each write becomes one `console.log` line. |
| `/dev/input/ctl` | both | Read: active input profile + capabilities. Write: `profile native|modifier|touch|chordbar`, `map <modifier> <button>` (S-04). |

## 4. `/mnt/host` and `/mnt/opfs` — host storage (R-9P-09) — Host: `/mnt/host` **both**, `/mnt/opfs` **browser**

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

> Revision log: 2026-09-14 (phase 14b) — **`/mnt/opfs` AS BUILT** (`src/dev/opfs.zig`,
> contract `agents/contracts/phase14b-opfs.md`). Mounted UNCONDITIONALLY at boot, so
> `/mnt/` lists `opfs/` from the first frame; a browser with no
> `navigator.storage.getDirectory` answers every request `Rerror "i/o error"` and logs
> `/mnt/opfs: unavailable` once (ruling R-P14b-2 — a mount that errors is simpler to
> report than a mount point that is silently absent). The mount is LAZY: boot issues no
> browser call at all.
>
> - **Files and directories only**, read/write, OTRUNC, create (files and dirs, DMDIR
>   honoured), remove (empty directories only — 9P has no recursive remove, and the shim
>   never passes `{recursive}` to `removeEntry`). Names: UTF-8, no `/`, never `.`/`..`;
>   a partial multi-element walk gives a short Rwalk, as everywhere else.
> - **No rename** (R-P14b-4): `FileSystemHandle.move()` is Chromium-only, so `Twstat`
>   supports **length only** (a truncate) and every other change — name, mode, times,
>   owner — is refused `"wstat prohibited"`. An all-"don't touch" wstat is the
>   conventional no-op and succeeds. Rename is create + copy + remove, by the client.
> - **qid caveat**: OPFS exposes no inode, so `qid.path` is the FNV-1a 64 hash of the
>   file's absolute path and `qid.vers` is `File.lastModified` truncated to seconds.
>   Qids are therefore stable per NAME, not per identity — remove a file and create
>   another with the same name and the qid is unchanged. Modes are fixed at `0644` /
>   `0755|DMDIR` (OPFS stores none); `uid`/`gid`/`muid` are `opfs`; directories report
>   length 0 and mtime 0. A `create` perm is masked per `5/open` and travels to the shim,
>   but nothing stores it.
> - **Directory reads** are offset-addressed stat streams (`read(5)`), built ONCE per
>   open fid from a single `list` call. Entries in a listing carry length 0 and mtime 0 —
>   the `list` reply has only the name and the kind, and a stat per entry would turn one
>   round trip into N; walk to the entry and stat it for the real numbers.
> - **Every operation may park.** Each one that needs the browser sends one op record and
>   returns 14a's `park.WouldBlock`; the completion is cached by ticket and the framework
>   re-dispatches the whole T-frame (S-06 §4 for the record format). Consequence, the
>   same one `/dev` carries and stronger: reach `/mnt/opfs` through `ninep.nsjob`'s
>   asynchronous jobs ONLY — a synchronous `Client` RPC would pump for a reply that
>   cannot come until a later frame.
> - **Error mapping**: `not found` → `"file does not exist"`, `exists` →
>   `"file already exists"`, `not a directory` → `"not a directory"`, `is a directory` →
>   `"file is a directory"` (the kernel's `Eisdir`), `permission` →
>   `"permission denied"`, `quota` → `"no space on device"`, `not empty` →
>   `"directory not empty"`, `io` → `"i/o error"`.
> - **Deferred**: sync access handles (`createSyncAccessHandle` is worker-only — they
>   arrive free with the Worker+SAB move); rename via `move()` where available;
>   exporting `/mnt/opfs` over 9P to other machines (needs `Tauth`, OQ-9P-3); `/mnt/host`
>   and `/dev/storage`, which remain unbuilt.

## 5. `/n/origin` — origin 9P export (R-9P-10) — Host: **both** (WebSocket transport is the browser's)

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

**Served from boot (phase 13a).** Wave 10a served this tree only on demand ("runtime
mounting waits for the first in-editor client", R-P10-E). That is RETIRED: the entry
point stands up the server, client and mount at boot and polls the server on every tick,
so the first client is the editor itself.

**`ns` and the `ctl` `isdir` column (phase 13b).** The served root now carries `ns`
(§1.3), a read-only file rendering `Namespace.list` in `ns(1)` style — 13a specified it
and deliberately did not build it, because a row in the served root's dirtab is also a
row in its listing; directory windows were the wave allowed to move those expectations.
Its qid `FILE` value is appended after the existing ones so no path renumbers. In the
same wave a window's `ctl` line stopped hard-coding its fourth column: it reports
`w->isdir` (wind.c:695), which is 1 for a directory window and 0 otherwise.

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
