# Phase 12d report — union directories, the synthetic root, and `/n/origin`

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 573/573 (`zig build test`,
was 557 + 6 smoke + 10 named), run twice · node smoke 26/26 (+1: the `/n/origin: mounted`
console line, never asserted before) · `zig fmt` clean · boundary clean (`ninep` imports
only std + itself) · `plantuml -checkonly` clean · **no golden moved** · **Contract:**
`agents/contracts/phase12d-unions.md` (rulings R-P12d-1..6) · **wasm:** 1643407 B =
1604.9 KiB (+14 KiB). User decisions 2026-09-14: `/n/origin`; unions now, before directory
windows; per-device Host column.

## What works now

- **Union mount table** (`src/ninep/mount.zig`, kernel chan.c:646-760): `bind(prefix, …,
  .replace|.before|.after)` = MREPL/MBEFORE/MAFTER; each mount point holds an ordered
  target list; `unmount(prefix)` and `unbindTarget(prefix, client, fid)` — the phase-12 GAP
  ("Namespace lacks unmount") is closed and `OriginMount.unbind` no longer reaches into
  the table. `list` renders `mount <prefix>` + `bind -a|-b <prefix>` lines (ns(1) shape).
- **Walking and reading through unions** (NEW `src/ninep/nsdir.zig`): `walk(ns, path)` tries
  members in bind order, first success wins (chan.c:1020-1043); `DirReader` concatenates
  member listings in order with a per-open cursor, rewinds at offset 0, rejects other
  wrong offsets (`BadOffset`), skips members that fail (sysfile.c:323-380), never returns a
  silent 0 for a too-small buffer (`ShortBuffer`). No de-duplication across members.
- **The synthetic root** (devroot.c role): directories that exist only as prefixes of
  mounts (`/`, `/n`, `/mnt`, and deeper separately-mounted children of an exact mount)
  are synthesized — `walk` yields `.dir`, `DirReader` lists their children first, DMDIR|0555,
  qid path = FNV-1a-64(path) | 1<<63, de-duplicated (one Dirlist per directory).
  Verified against the kernel: `rootreset` (devroot.c:96-107) does NOT create `/n` — a
  real Plan 9 gets it from the root file server — so the synthesis is generic, not a
  static table.
- **`/n/origin`**: every literal in code, smoke, README, specs, requirements, diagrams
  moved; `grep -rn '/mnt/origin' src web tools docs README.md` is empty (agents/ history
  keeps the old name). On attach `OriginMount` walks the export's `bin` in a new
  `binding` handshake step and binds it `.after` into **`/bin`**; an export without `bin`
  mounts without `/bin`; on loss both bindings go. Verified live: the origin access log
  shows `attach /` then `walk bin`; the module logs `/n/origin: mounted`.
- **Docs**: S-02 §1.1 unions, §1.2 synthetic directories, §1.3 boot namespace table with a
  **Host** column (browser · native · both) on every row; §5 `/n/origin`; R-03 v3 — R-9P-03
  requires unions, R-9P-10 renamed + `/bin` bind, **R-9P-16** (synthesized prefix
  directories), OQ-9P-1 RESOLVED; R-01 vision + R-OV-04; R-02 OQ-EDIT-1; README; diagrams;
  one amendment block in the phase-12 contract.

## Files

New: `src/ninep/nsdir.zig` (≈280 code lines; 674 total with cited rationale + tests),
`src/ninep/nspath.zig` (90 — `canonicalize`, `matchPrefix`, `firstComponent`). Changed:
`src/ninep/mount.zig` (150 code), `src/origin/OriginMount.zig` (419 pre-test — over the
soft cap for the first time; seam = handshake steps vs mount lifecycle, debt), `ninep.zig`,
`accept.zig`, `main_wasm.zig`, `core/exec/{builtins,cmd_origin}.zig`, `origin/origin.zig`,
`tools/origin/accept.zig`, `tools/smoke_wasm.mjs`, docs as above.

## Deviations from the contract (all accepted in review)

1. `Target.flag` recorded (kernel `Mount.mflag`) so `list` can print `-a`/`-b`.
2. Extra `binding` handshake phase before `mounted`: `Client.walk` is synchronous with no
   pump over the WebSocket, so the bin walk is hand-driven and must finish before the
   client starts draining the transport. Keeps R-P12-5 (boot never waits) and the 10 s
   deadline. `Rerror` on the walk ⇒ mounted without `/bin`; transport failure ⇒ not mounted.
3. `walk` falls back to a synthetic `.dir` when all members fail on a prefix path.
4. `DirReader` snapshots the union at `open`; first-success for ancestor-mount paths.
5. Non-directory members skipped via the Rwalk qid; `Rattach`'s qid seeded into the fid
   cache (nit: a `Client.seedQid` would keep that private — debt).
6. Synthetic stats carry empty uid/gid/muid (no user model).
7. Synthetic child names de-duplicated; union members are not (R-P12d-2 reads correctly).
8. `/dev/ns` not reachable (served tree has no namespace handle) — cited seam in
   `main_wasm.zig`; the same missing `Editor`→namespace handle is what directory windows
   need next.
9. Orchestrator after review: Host column corrected — `/dev/snarf`, `/mnt/host`,
   `/n/origin` are **both** hosts per ADR-0005 §2 (browser-specific backing named in the
   What column); `walk` tolerates one trailing `/` to agree with `DirReader.open`.

## Pipeline

fable spec → opus (4 logical commits; suite green; live origin verification) → sonnet
tests (T1-T16; found the never-asserted mount log line and pinned it in smoke) → sonnet
gate (twice) → fable review PASS (two non-code blockers: this report + merge onto moved
main; one doc fix; four nits — two applied, two recorded: T11 read-error arm untested,
`Client.seedQid`).

## Next

Directory windows (user-queued): needs an `Editor` handle to the namespace so `core` can
call `nsdir.DirReader`/`walk` without importing `origin`/`dev`, plus the async client
ticket for walk/open/read/clunk. Then phase 13 (OPFS), then the ADR-0005 native-host spike.
