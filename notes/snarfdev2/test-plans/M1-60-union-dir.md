# Test plan: #60 Union directory listing (host at `/`)

**Issue:** #60 · **Requirements:** PM interim ruling 2026-10-31 (decisions README row: host at `/`, every name listed once, snarf's entries first, nothing hidden), R-9P-03 (union read, no dedup), R-9P-16 (synthetic dirs DMDIR|0555, stable qid), R-EDIT-03 (dir windows + B3), R-EDIT-15 (Get/Put through the namespace), ADR-0005 §2 (native namespace), #28 symlink policy, R-OV-09 (browser frozen), #11 Q1 (`/` vs `/n/local`, pending Larry), **PM rulings on #60 (SnarfProdd, 2026-11-02, decisions README; R1–R9 below)**, follow-up #76 (device I/O) · **Status:** rulings applied. Tests are in PR #75 behind `union_dir_landed = false`.

Reference behaviour: plan9port acme and Plan 9 `sysfile.c`/`dirread`. Baseline: main `9a49627`.

## Parameter: `HOST_MTPT`
This plan and the tests set the host mount point in exactly one place: `const host_mtpt = "/";` in `src/accept_union_dir.zig`.
- **`/` (interim ruling):** the host tree is shadowed by snarf's mounts (`/dev`, `/mnt`, …), so all UD cases apply.
- **`/n/local`:** nothing is shadowed, `/mnt/host` stays, and `/dev` and `/mnt` are snarf-only (R7). The shadowing cases UD-01..09, UD-12..16, UD-18, UD-24 and UD-25 skip as N/A. UD-10, UD-11 and UD-17 still run as guards, and UD-19..23 run against `/mnt/host`. With this setting the build gave 891 passed, 32 skipped (PR #75 @ 22e0b06).

The native namespace on main is `/dev/draw`, `/dev` (input), `/mnt/snarf-self`, the host at `HOST_MTPT` (main_native.zig:296) and the `/mnt/host` alias (main_native.zig:297). Paths resolve by longest prefix.

## Behaviour today (9a49627)
- **`/` listing:** the stream is `dev mnt` (synthetic), then every host entry including the host's own `dev`/`mnt`. The names appear twice.
- **`/dev`:** an exact mount. The host's `/dev` entries can't be listed or walked.
- **`/mnt`:** resolves to the `/` mount with remainder `mnt`. The listing is synthetic `host snarf-self`, then the host's `/mnt` entries. Walks to host-only `/mnt/x` already work; only dedup is missing.
- **HostFs:** hides anything that isn't a regular file or a directory (char/block devices, fifos, sockets). R2 changes this: they are listed and stat-able, and open fails with "not supported" (UD-19..23). `statFile` follows symlinks, so a dangling link is invisible.
- **dirwin:** sorts by `dircmp` (text.c:121-133, dirwin.zig:61), so the window never shows the "snarf first" order. Only the raw 9P stream does.

## Harness
The Rig (from accept_hostfs) serves a per-test tmp dir with the real HostTree, mounted at `HOST_MTPT` and at `/mnt/host`. Also mounted:
- MemTree `/dev/draw` (`new`)
- MemTree `/dev` (`mouse`, `kbd`)
- the boot tree and SelfTree

`seedStd` creates these host files:
- `etc/hosts`
- `dev/hostonly.txt`
- `dev/kbd`: collides with snarf's kbd. `mouse` is not used for the collision because the #45 warp writes `m x y` into the snarf mouse file.
- `dev/shm/deep.txt`
- `mnt/usb/readme`
- `mnt/host/shadowed`

Listings are taken with `nsdir.DirReader` (raw records), and windows with B3/`openWin`. Landed-flag pattern:
- flag false and the check fails → skip
- flag false and the check passes → `UnexpectedPassFlipFlag`
- flag true → hard assert

Guards assert the current behaviour unconditionally.

| ID | Type | Scenario | Expected | Traces |
|---|---|---|---|---|
| UD-01 | flag | Read `/` raw | every name exactly once (`dev`, `mnt` not doubled) | ruling 2026-10-31, Q1 |
| UD-02 | guard+flag | `/` stream order | guard: `dev mnt` lead. Flag: host entries follow with shadowed names removed (`etc` at index 2) | ruling ("snarf first"), R6 |
| UD-03 | flag | Which record is kept for `dev` in `/` | snarf's synthetic stat: DMDIR\|0555, `syntheticQidPath` (high bit) | R-9P-16, **R3** |
| UD-04 | flag | B3 `/` → dir window | `dev/ mnt/ etc/` once each, in dircmp order | R-EDIT-03, R6 |
| UD-05 | flag | Read `/dev` raw | `draw mouse kbd` then `hostonly.txt shm`; each once; `kbd` not doubled | ruling, R1 |
| UD-06 | flag | B3 `/dev` window | union listed once each | R-EDIT-03 |
| UD-07 | flag | B3 on `/dev/hostonly.txt`, walk `/dev/shm/deep.txt` | host bytes opened; the walk falls through to the host when snarf has no such name | R-EDIT-03/15, ruling ("never hidden") |
| UD-08 | guard | Name in both (`/dev/kbd`) | the walk goes to snarf's device (first member wins). The host copy is reachable at `/mnt/host/dev/kbd` | Plan 9 bind -b semantics, **R8** |
| UD-09 | guard+flag | `/mnt` | guard: `host snarf-self usb` listed, `/mnt/usb/readme` walks. Flag: `host` once | ruling, R8 |
| UD-10 | guard | `/mnt/host/dev` | the plain host tree: `kbd` once, no `draw`/`mouse` | ADR-0005 §2 |
| UD-11 | guard | Host with no `/mnt` | `/mnt` synthetic: DMDIR\|0555, stable qid across two stats, 2 DMDIR\|0555 children | R-9P-16 |
| UD-12 | flag | Record and stat of host-only `/dev/hostonly.txt` (0640) | host mode, length, qid tagged 1<<40 | R-9P-16 (contrast), hostfs |
| UD-13 | flag | Edit `/dev/hostonly.txt`, Put | host disk updated, window clean | R-EDIT-15 (existing file; new files: UD-24) |
| UD-14 | guard+flag | Symlinks under `/dev` (`link.txt → ../target.txt`, dir link `shmlink`), dangling link | flag: listed and followed (local = trusted). Guard: dangling link invisible | #28 policy |
| UD-15 | guard+flag | 3000 host entries in `/dev` + `kbd` collision; 200-byte vs 64 KiB reads | guard: both read sizes agree, < 10 s. Flag: every name once, `kbd` once (dedup holds across read chunks / offsets) | R-9P-03 offsets, ruling |
| UD-16 | flag (skip as root) | `dev/secret` 0000 file; host `dev` itself 0000 | the secret file is listed once and B3 on it gives an honest error in `+Errors`. Guard: unreadable host `/dev` drops out of the union, so snarf's entries still list (sysfile.c:340 skips the failing member) | R-EDIT-03, checklist "honest errors" |
| UD-17 | guard | Browser-shaped ns (no host at `/`) | `/` = the 4 synthetic dirs. A `/bin` member union still lists `rc` twice (R-9P-03 unchanged outside the host-shadowing case) | R-9P-03, R-OV-09, **R1** |
| UD-18 | guard | Host at `/`, two members bound at `/bin` (a union outside `/`, `dev/`, `mnt/`) | `rc` listed twice: dedup is limited to `/`, `dev/` and `mnt/` | **R1**, R-9P-03 |
| UD-19 | flag | Host fifo `dev/pipe` and unix socket `dev/sock` (made in the tmp dir, no root) | each listed once in `/mnt/host/dev` and in the `/dev` union; not DMDIR; regular entries still listed (guard) | **R2** |
| UD-20 | flag | Walk + Tstat of the fifo and the socket, via `/mnt/host/dev/…` and `/dev/…` | stat succeeds, name matches, not DMDIR | **R2** |
| UD-21 | flag | Raw 9P open (OREAD) of the socket and the fifo; B3 on `/dev/sock` | Topen fails and the Rerror says "not supported"; B3 puts a "not supported" message in `+Errors`. The test holds the fifo open O_RDWR\|O_NONBLOCK so a blocking server open can't hang the suite | **R2**, #76 |
| UD-22 | flag (root only, else skip) | `mknod dev/null c 1 3` in the tmp dir | listed once, stats, open fails "not supported" | **R2** |
| UD-23 | flag | Host root = the REAL `/dev` (read-only; no root needed) | `null` listed once, stats, open fails "not supported" | **R2** |
| UD-24 | flag | Rename the `/dev/hostonly.txt` window to `/dev/new.txt`, Put | host `dev/new.txt` = buffer, window clean; source untouched (guard) | **R5** (Plan 9 MCREATE), R-EDIT-15 |
| UD-25 | guard | Host has `dev/draw/hostdraw.txt` | `/dev/draw` lists only snarf's `new`; `/dev/draw/hostdraw.txt` is NotFound; reachable at `/mnt/host/dev/draw/hostdraw.txt`. Nested union is **out of scope** | **R4** |

### Manual / X11 (native, real host)
| ID | Scenario | Expected |
|---|---|---|
| UD-M1 | Linux: B3 `/`, `/dev`, `/mnt` in snarf-native | each name once. Real `/dev` entries (dirs/links only today, Q2) are listed and openable; `/dev/draw` still works |
| UD-M2 | macOS (Larry's Mac): same as M1 | same; `/dev` lists the host's entries according to Q2 |
| UD-M3 | Large real dir: B3 `/proc` or `/usr/lib` | the window opens < 2 s and no names are duplicated |
| UD-M4 | `Get` in the `/dev` window after creating a host file | the new entry appears once |

## WASM
- **No host at `/`:** `/` is synthetic (`dev mnt n bin`) and `/mnt/opfs` is mounted. `/mnt/host` (File System Access) isn't built. The shadowing cases are **N/A** in the browser.
- **UD-17** pins the browser shape headlessly. The browser is frozen (R-OV-09), so the only requirement is that it builds and passes `make smoke` (40/0). Under R1, dedup never touches R-9P-03 member unions such as `/bin` (UD-17). R2 (UD-19..23) and #76 are N/A in the browser because it has no host special files.

## PM rulings (SnarfProdd, 2026-11-02; replaces Q1–Q9)
Source: `notes/snarfprod/decisions/README.md`, row 2026-11-02 (#60, PR #75).
1. **R1, dedup scope:** dedup applies only at `/` and its shadowed dirs `dev/` and `mnt/`. Every other union keeps R-9P-03 and lists duplicates. Tests: UD-17 (browser shape), UD-18 (host at `/`, `/bin` union).
2. **R2, device nodes, fifos and sockets:** they are listed and can be stat'ed. Opening one fails with a clear "not supported" error. Device I/O is a later feature, tracked in **#76**. Tests: UD-19..23.
3. **R3, collision record:** the listing shows snarf's record (UD-03).
4. **R4, nested mounts:** there is no nested union; `/dev/draw` stays snarf-only. This is **out of scope** and pinned by guard UD-25.
5. **R5, create in a shadowed dir:** a new file goes to the host, as with Plan 9 MCREATE (UD-24).
6. **R6, order:** "snarf entries first" applies to the raw 9P stream only (UD-02). Folder windows keep ACME's dircmp order (UD-04, UD-06).
7. **R7, `/n/local`:** confirmed as assumed. `/mnt/host` stays; `/dev` and `/mnt` become snarf-only, so the union cases are N/A (see `HOST_MTPT`).
8. **R8, shadowed collisions:** confirmed as assumed. Host `/dev/kbd`, `/dev/mouse` and `/mnt/host` are reachable only via `/mnt/host/...` (UD-08, UD-09).
9. **R9, spec text:** the S-02 §1.3 revision-log line will be corrected. SnarfDev1 is doing it (the decisions row says "in the #60 commit"). This plan doesn't test it.
