# Phase 12d contract — union directories, the synthetic root, and `/n/origin`

Status: **binding once fable signs §3.** Branch `phase12d` (worktree `../snarf-wt/phase12d`),
based on `main@037ff8f`. Requirements: R-9P-03 (mount + bind; unions were "may be deferred",
OQ-9P-1), R-9P-10 (origin mount point), R-EDIT-20 (directory context → command lookup
"window dir, then the path"). User decisions 2026-09-14 (HANDOFF "Namespace decisions"):
(1) origin mount `/mnt/origin` → **`/n/origin`**; (3) **unions YES, this wave, before
directory windows**, origin `bin/` unioned into `/bin`; (5) S-02 gets a per-device host
column. Also lifts the phase-12 GAP "Namespace lacks `unmount(prefix)`".

Pipeline: fable spec → **opus** codes §3 → **sonnet** writes §4 → **sonnet** runs the gate →
**fable** reviews → loop.

## 1. Ground truth (kernel `larryr/plan9@ed1a9c2`, cite `9/port/file.c:NN`)

| Item | Where | What |
|---|---|---|
| bind flags | `sys/include/libc.h:538-542`, `sys/man/2/bind` | `MREPL` replace; `MBEFORE` new target goes first in the union; `MAFTER` goes last; `MCREATE` marks which union member takes creates (out of scope: no create yet). Binding with BEFORE/AFTER onto a non-directory is an error (`chan.c:662`). |
| union assembly | `9/port/chan.c:646-760 cmount` | a mount point has an `Mhead` with an ordered `Mount` list; REPL discards the list; BEFORE/AFTER insert at head/tail (`:723-750`). |
| walk through a union | `9/port/chan.c:965-1050 walk`, esp. `:1020-1043` | after `domount`, try the mount-point's first target; on failure "try a union mount, if any" — iterate the remaining `Mount`s **in order**, first success wins; all fail ⇒ the walk fails at that component (`nerror`). |
| reading a union directory | `9/port/sysfile.c:323-367 unionread`, `:368-380 unionrewind` | concatenate the directory streams of the union's members in order; per-chan cursor `uri` (member index) + `umc` (open clone of that member); "Error causes component of union to be skipped"; `unionrewind` on offset 0. No de-duplication of names. |
| the root device | `9/port/devroot.c` (`rootinit`, `addroot`, the static `/`, `/dev`, `/mnt`, `/n`, `/proc`, … entries) | Plan 9's `#/` device synthesizes the top-level directories that mounts hang from; `bind` requires the mount point to *exist*. Snarf has no root filesystem, so the mount table itself must play `devroot` for the directories that only exist as prefixes of mounts (`/`, `/n`, `/mnt`, `/dev` if nothing is mounted exactly there). |
| `ns(1)` output | `sys/man/1/ns` | one line per operation: `mount [-abc] servename old`, `bind [-abc] new old`. Our `/dev/ns` mirrors the shape (`bind -a /n/origin/bin /bin`). |
| acme command lookup | `acme/exec.c` `run()` and paper §User interface | "the file to be executed is searched for first in that directory" then `$path`; on Plan 9 `/bin` is the union of every bound bin. This wave makes `/bin` such a union; the editor-side lookup arrives with external commands (not this wave). |

## 2. Merged reality (`main@037ff8f`)

- `src/ninep/mount.zig` (318 lines): `Namespace{entries: ArrayList(Entry)}`, `Entry{prefix,
  target: Target{client, root_fid}}`, `mount` (rejects exact duplicate), `bind` (replace in
  place), `resolve(path) → Resolved{entry, remainder}` (longest component-wise prefix),
  `list(w)` (`mount <prefix>` lines), `canonicalize`. The `Entry` doc names this exact
  extension ("would widen this to a list of Targets tried in bind order").
- No `unmount`; `OriginMount.unbind` reaches into `entries` (GAP comment at
  `OriginMount.zig:340-354`). `OriginMount.mount_point = "/mnt/origin"` (`:55`), `bind` at
  `:262`, prefix compare at `:349`.
- Callers of `resolve`: `src/accept.zig:879-905` (served-tree scene), `ninep.zig:170-173`
  smoke, `OriginMount` tests. The editor does not yet walk the namespace (async ticket gap).
- `/mnt/origin` literals: `src/main_wasm.zig`, `src/core/exec/{builtins,cmd_origin}.zig`,
  `src/origin/{origin,OriginMount}.zig`, `tools/smoke_wasm.mjs`, `tools/origin/accept.zig`,
  docs (`spec/00,01,02,05`, `requirements/01,02,03`, `README.md`, diagrams
  `architecture.puml`, `mermaid/architecture.md`), `agents/contracts/phase12-origin-mount.md`
  (leave contracts as history — add one amendment line only).
- `ninep/stat.zig`: `Stat`, `DMDIR`, `encode/decode`, `STATFIXLEN` — enough to synthesize
  directory entries. `Client`: `walk(fid, names) FidInfo`, `open`, `read(fid, offset, buf)`,
  `clunk`, `stat`, `allocFid/freeFid`.

## 3. CONTRACT

### 3a. Union table — `src/ninep/mount.zig` (stay ≤ ~400 non-test lines; move `canonicalize`
+ `matchPrefix` to `src/ninep/nspath.zig` if needed)

```zig
pub const BindFlag = enum { replace, before, after }; // MREPL / MBEFORE / MAFTER (libc.h:538-540)
pub const Entry = struct { prefix: []u8, targets: std.ArrayListUnmanaged(Target) }; // ordered union (chan.c Mhead/Mount)
pub fn mount(self, prefix, client, root_fid) Error!void        // unchanged semantics: new entry, exact duplicate ⇒ error.Duplicate
pub fn bind(self, prefix, client, root_fid, flag: BindFlag) Error!void
pub fn unmount(self, prefix: []const u8) Error!void             // drop the whole entry (error.NotMounted if absent)
pub fn unbindTarget(self, prefix, client: *Client, root_fid: u32) Error!void // drop ONE union member; empty entry ⇒ removed
pub fn resolve(self, path) error{NotMounted,BadPath}!Resolved    // unchanged shape; `entry.targets` is the union in order
pub fn list(self, w) …                                           // ns(1) shape: `mount <prefix>` for the first target, `bind -b|-a <prefix>` per extra member (we have no server names — print the prefix only, cite ns(1))
```
- `bind(.replace)` on an existing prefix = today's behavior (targets ← [new]); on a new
  prefix = mount. `.before` inserts at index 0, `.after` appends (chan.c:723-750); on a
  new prefix both create the entry.
- Update the three call sites of the old `bind`: `OriginMount.zig:262` → `.replace`;
  `OriginMount.unbind` → `self.ns.unmount(mount_point)` (delete the GAP block).
- Keep every existing `mount.zig` test passing unchanged except the `list` format test,
  which may gain lines.

### 3b. Walking and reading through the namespace — NEW `src/ninep/nsdir.zig`

```zig
/// chan.c:965-1050 `walk` over a union: resolve `path`, then try each target in order
/// (`Client.walk(newfid, root_fid, components)`); first success wins. A path that is only a
/// PREFIX of mounted entries (`/`, `/n`, `/mnt`) is a synthetic root-device directory
/// (devroot.c) and yields `.dir`. All targets fail ⇒ error.NotFound; nothing matches ⇒ error.NotMounted.
pub const Handle = union(enum) { fid: struct { client: *Client, fid: u32 }, dir: SyntheticDir };
pub fn walk(ns: *const Namespace, path: []const u8) Error!Handle
pub fn close(ns, h: Handle) void   // clunk the fid; no-op for .dir

/// sysfile.c:323-380 `unionread`/`unionrewind`: one cursor per open directory.
pub const DirReader = struct {
    pub fn open(allocator, ns: *const Namespace, path: []const u8) Error!DirReader
    /// Fill `buf` with whole 9P stat records (never split one), in this order:
    ///   (1) synthetic entries — one DMDIR stat per child prefix of `path` in the table
    ///       (devroot.c role: `/n/origin` appears under `/n`; `/mnt/snarf-self` under `/mnt`),
    ///       name = the next component, qid.type = QTDIR, mode = DMDIR|0555, mtime 0;
    ///   (2) then each union member's directory stream in bind order, opened OREAD lazily,
    ///       read until it returns 0, then the next member; a member that errors is skipped
    ///       (sysfile.c:340 comment). No de-duplication (Plan 9 does none).
    /// `offset == 0` rewinds (unionrewind); any other offset must equal the bytes returned so
    /// far, else error.BadOffset (9P directory-read rule, read(5)).
    pub fn read(self, offset: u64, buf: []u8) Error!usize
    pub fn close(self) void
};
```
- Synthetic entries only for prefixes that are NOT themselves exactly mounted: if `/dev`
  is mounted, `readDir("/dev")` is the device's own listing (plus any deeper child
  prefixes such as `/dev/draw` if separately mounted — still synthesized since the
  device does not know about them). Pin this rule in a test.
- `walk` of a path under a synthetic dir with no matching entry ⇒ `error.NotMounted`.

### 3c. `/n/origin` rename + `/bin` union at boot — `src/origin/OriginMount.zig`, `src/main_wasm.zig`

- `mount_point = "/n/origin"`; every literal listed in §2 becomes `/n/origin` (code, smoke
  script, README, specs, requirements, diagrams). Contracts from earlier phases are
  history: add ONE amendment line at the end of `agents/contracts/phase12-origin-mount.md`
  pointing here; do not rewrite them.
- On a successful attach, `OriginMount` additionally walks `bin` on the origin root
  (`Client.walk(newfid, root_fid, &.{"bin"})`) and binds it: `ns.bind("/bin", c, binfid,
  .after)`. If the export has no `bin` the bind is skipped silently (an origin need not
  export commands). On `lose`/`fail`: `ns.unbindTarget("/bin", c, binfid)` then
  `ns.unmount("/n/origin")` — both must be gone (T11).
- Messages: `/n/origin: not mounted (...)`, `/n/origin: disconnected (...)`, console
  `/n/origin: mounted`; `Reconnect` text likewise.

### 3d. `/dev/ns` (S-02 §1) — optional, only if trivially reachable

If the served tree (`src/core/served/`) can expose a read-only `ns` file with one line
per `Namespace.list` row for free, do it; otherwise leave a cited seam. Not gated.

### 3e. Docs (the wave owns these)

- `docs/spec/02-namespaces.md`: §1 rewritten — union semantics (`bind -a/-b`, walk order,
  `unionread` concatenation, no dedup), the synthetic root-device rule (`/`, `/n`, `/mnt`
  exist because mounts hang from them, devroot.c), `/dev/ns` line format; §5 retitled
  `/n/origin`, boot bind of `bin/` into `/bin`; **a `Host` column (browser · native · both)
  added to every device/mount table row** (ADR-0005; user decision 5: `/dev/dom` browser
  only, low priority). Revision-log entry.
- `docs/requirements/03-namespace-and-9p.md`: R-9P-03 — unions are now REQUIRED (bind
  before/after, union reads); R-9P-10 — mount at `/n/origin`; OQ-9P-1 RESOLVED (2026-09-14,
  user); add R-9P-16: "Directories that exist only as prefixes of mounted entries SHALL be
  synthesized by the namespace (Plan 9 `#/` role) so directory listings and walks work at
  every level." Status → Draft v3 with a revision-log entry naming the user decision.
- `docs/requirements/01-overview.md` §2 vision text and R-OV-04: `/n/origin`.
- Diagrams: text-only label changes in `architecture.puml` and `mermaid/architecture.md`;
  run `plantuml -checkonly` if available, otherwise say so.
- `README.md` quick start: `/n/origin`.

### 3f. Rulings

- **R-P12d-1** `resolve`'s shape is unchanged; unions live in `Entry.targets`. No caller
  outside `ninep` iterates targets — they use `nsdir.walk`/`DirReader`.
- **R-P12d-2** No de-duplication in union reads (sysfile.c). The first member wins a walk.
- **R-P12d-3** Synthetic directories are read-only, qid path derived deterministically from
  the prefix (e.g. FNV-1a of the canonical prefix, high bit set) so repeated listings are
  stable; document the scheme.
- **R-P12d-4** No editor behavior changes: command lookup through `/bin` is the external-
  commands wave's job; this wave only guarantees `nsdir.walk(ns, "/bin/date/ctl")` resolves
  to the origin's fid once mounted.
- **R-P12d-5** `core` still imports nothing from `dev`/`shim`/`origin`; `ninep` imports only
  `std` and itself; every file ≤ ~400 non-test lines; `zig fmt` clean; no golden moves.
- **R-P12d-6** `mount`'s duplicate-rejection and all existing `mount.zig` tests stay
  green; `bind` gains a flag parameter (3 call sites).

## 4. Named tests (sonnet)

| # | Where | Test |
|---|---|---|
| T1 | `mount.zig` | `bind(.after)` then `bind(.before)` on one prefix ⇒ `targets` order is [before, first, after]. |
| T2 | `mount.zig` | `bind(.replace)` on a union collapses it to the one new target (chan.c:739-741). |
| T3 | `mount.zig` | `unmount` removes the entry (later `resolve` ⇒ NotMounted); `unmount` of an absent prefix ⇒ NotMounted. |
| T4 | `mount.zig` | `unbindTarget` removes one member and keeps the rest; removing the last member removes the entry. |
| T5 | `mount.zig` | `list` prints `mount /n/origin` and `bind -a /bin`-style lines in table order (pin exact text). |
| T6 | `nsdir.zig` | Two fake servers (reuse the `ninep.zig`/`accept.zig` in-memory pipe pattern) unioned at `/bin`, file `date/ctl` only in the SECOND ⇒ `walk("/bin/date/ctl")` returns a fid on the second client (chan.c:1030-1037). |
| T7 | `nsdir.zig` | File in BOTH members ⇒ the first member's fid wins. |
| T8 | `nsdir.zig` | Missing in all ⇒ `error.NotFound`; unmounted path ⇒ `error.NotMounted`. |
| T9 | `nsdir.zig` | Mounts at `/dev`, `/n/origin`, `/mnt/snarf-self`: `DirReader("/")` yields exactly `dev n mnt` as DMDIR stats; `DirReader("/n")` yields `origin`; `walk("/n")` ⇒ `.dir`. |
| T10 | `nsdir.zig` | Union read concatenates member listings in bind order, no dedup (same name in both appears twice). |
| T11 | `nsdir.zig` | A member whose directory open/read errors is skipped; the other member's entries still arrive (sysfile.c:340). |
| T12 | `nsdir.zig` | Offset continuation: reading with a 64-byte buffer repeatedly yields byte-identical concatenation to one large read; offset 0 rewinds; a wrong offset ⇒ `error.BadOffset`. |
| T13 | `nsdir.zig` | Exactly-mounted dir with a deeper separate mount: `/dev` mounted and `/dev/draw` mounted ⇒ `DirReader("/dev")` = device listing + synthesized `draw`. |
| T14 | `OriginMount.zig` | On attach: `/n/origin` mounted AND `/bin` has one `.after` member pointing at the origin's `bin` fid; on disconnect both are gone; an export without `bin` mounts without error and leaves `/bin` untouched. |
| T15 | `accept.zig` | Served-tree scene unchanged at `/mnt/snarf-self` (regression); add `walk(ns, "/mnt/snarf-self/index")` via `nsdir` returning a readable fid whose content equals the old `resolve`-then-walk path. |
| T16 | `tools/smoke_wasm.mjs` | Console log text now `/n/origin: mounted`; no `/mnt/origin` string remains in `src/`, `web/`, `tools/`, `docs/`, `README.md` (`grep -rn '/mnt/origin' … | grep -v agents/contracts` empty — a shell check in the gate, cited in the report). |

## 5. Gate (fable)

1. `zig build test` to a file, `$?==0`, 0 failures, twice; `zig fmt --check`; `zig build`;
   `node tools/smoke_wasm.mjs`; boundary grep empty; no FROZEN literal changed.
2. `grep -rn '/mnt/origin' src web tools docs README.md` empty.
3. Report `agents/reports/phase12d-unions.md`; HANDOFF: phase-12 GAP `unmount` closed,
   OQ-9P-1 resolved, `/n/origin` live, directory windows are next.
