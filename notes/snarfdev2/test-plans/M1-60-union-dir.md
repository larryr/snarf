# Test plan: #60 Union directory listing (host at `/`)

**Issue:** #60 · **Requirements:** PM interim ruling 2026-10-31 (decisions README row: host at `/`, every name listed once, snarf's entries first, nothing hidden), R-9P-03 (union read, no dedup), R-9P-16 (synthetic dirs DMDIR|0555, stable qid), R-EDIT-03 (dir windows + B3), R-EDIT-15 (Get/Put through the namespace), ADR-0005 §2 (native namespace), #28 symlink policy, R-OV-09 (browser frozen), #11 Q1 (`/` vs `/n/local`, pending Larry) · **Status:** draft. Tests are in PR #75 behind `union_dir_landed = false`.

Reference behaviour: plan9port acme and Plan 9 `sysfile.c`/`dirread`. Baseline: main `9a49627`.

## Parameter: `HOST_MTPT`
This plan and the tests set the host mount point in exactly one place: `const host_mtpt = "/";` in `src/accept_union_dir.zig`.
- **`/` (interim ruling):** the host tree is shadowed by snarf's mounts (`/dev`, `/mnt`, …), so all UD cases apply.
- **`/n/local`:** nothing is shadowed. UD-01..09 and UD-12..16 skip as N/A. UD-10, UD-11 and UD-17 still run as guards. With this setting the build gave 891 passed, 24 skipped.

The native namespace on main is `/dev/draw`, `/dev` (input), `/mnt/snarf-self`, the host at `HOST_MTPT` (main_native.zig:296) and the `/mnt/host` alias (main_native.zig:297). Paths resolve by longest prefix.

## Behaviour today (9a49627)
- **`/` listing:** the stream is `dev mnt` (synthetic), then every host entry including the host's own `dev`/`mnt`. The names appear twice.
- **`/dev`:** an exact mount. The host's `/dev` entries can't be listed or walked.
- **`/mnt`:** resolves to the `/` mount with remainder `mnt`. The listing is synthetic `host snarf-self`, then the host's `/mnt` entries. Walks to host-only `/mnt/x` already work; only dedup is missing.
- **HostFs:** hides anything that isn't a regular file or a directory (char/block devices, fifos, sockets). `statFile` follows symlinks, so a dangling link is invisible.
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
| UD-02 | guard+flag | `/` stream order | guard: `dev mnt` lead. Flag: host entries follow with shadowed names removed (`etc` at index 2) | ruling ("snarf first"), Q6 |
| UD-03 | flag | Which record is kept for `dev` in `/` | snarf's synthetic stat: DMDIR\|0555, `syntheticQidPath` (high bit) | R-9P-16, **Q3** |
| UD-04 | flag | B3 `/` → dir window | `dev/ mnt/ etc/` once each, in dircmp order | R-EDIT-03, Q6 |
| UD-05 | flag | Read `/dev` raw | `draw mouse kbd` then `hostonly.txt shm`; each once; `kbd` not doubled | ruling, Q1 |
| UD-06 | flag | B3 `/dev` window | union listed once each | R-EDIT-03 |
| UD-07 | flag | B3 on `/dev/hostonly.txt`, walk `/dev/shm/deep.txt` | host bytes opened; the walk falls through to the host when snarf has no such name | R-EDIT-03/15, ruling ("never hidden") |
| UD-08 | guard | Name in both (`/dev/kbd`) | the walk goes to snarf's device (first member wins). The host copy is reachable at `/mnt/host/dev/kbd` | Plan 9 bind -b semantics, **Q8** |
| UD-09 | guard+flag | `/mnt` | guard: `host snarf-self usb` listed, `/mnt/usb/readme` walks. Flag: `host` once | ruling, Q8 |
| UD-10 | guard | `/mnt/host/dev` | the plain host tree: `kbd` once, no `draw`/`mouse` | ADR-0005 §2 |
| UD-11 | guard | Host with no `/mnt` | `/mnt` synthetic: DMDIR\|0555, stable qid across two stats, 2 DMDIR\|0555 children | R-9P-16 |
| UD-12 | flag | Record and stat of host-only `/dev/hostonly.txt` (0640) | host mode, length, qid tagged 1<<40 | R-9P-16 (contrast), hostfs |
| UD-13 | flag | Edit `/dev/hostonly.txt`, Put | host disk updated, window clean | R-EDIT-15, **Q5** |
| UD-14 | guard+flag | Symlinks under `/dev` (`link.txt → ../target.txt`, dir link `shmlink`), dangling link | flag: listed and followed (local = trusted). Guard: dangling link invisible | #28 policy |
| UD-15 | guard+flag | 3000 host entries in `/dev` + `kbd` collision; 200-byte vs 64 KiB reads | guard: both read sizes agree, < 10 s. Flag: every name once, `kbd` once (dedup holds across read chunks / offsets) | R-9P-03 offsets, ruling |
| UD-16 | flag (skip as root) | `dev/secret` 0000 file; host `dev` itself 0000 | the secret file is listed once and B3 on it gives an honest error in `+Errors`. Guard: unreadable host `/dev` drops out of the union, so snarf's entries still list (sysfile.c:340 skips the failing member) | R-EDIT-03, checklist "honest errors" |
| UD-17 | guard | Browser-shaped ns (no host at `/`) | `/` = the 4 synthetic dirs. A `/bin` member union still lists `rc` twice (R-9P-03 unchanged outside the host-shadowing case) | R-9P-03, R-OV-09, **Q1** |

### Manual / X11 (native, real host)
| ID | Scenario | Expected |
|---|---|---|
| UD-M1 | Linux: B3 `/`, `/dev`, `/mnt` in snarf-native | each name once. Real `/dev` entries (dirs/links only today, Q2) are listed and openable; `/dev/draw` still works |
| UD-M2 | macOS (Larry's Mac): same as M1 | same; `/dev` lists the host's entries according to Q2 |
| UD-M3 | Large real dir: B3 `/proc` or `/usr/lib` | the window opens < 2 s and no names are duplicated |
| UD-M4 | `Get` in the `/dev` window after creating a host file | the new entry appears once |

## WASM
- **No host at `/`:** `/` is synthetic (`dev mnt n bin`) and `/mnt/opfs` is mounted. `/mnt/host` (File System Access) isn't built. The shadowing cases are **N/A** in the browser.
- **UD-17** pins the browser shape headlessly. The browser is frozen (R-OV-09), so the only requirement is that it builds and passes `make smoke` (40/0). Dedup must not change R-9P-03 member unions such as `/bin` unless the answer to Q1 extends dedup to every union.

## Questions for SnarfProdd (not guessed; the tests encode the assumption marked)
1. **Scope of dedup.** R-9P-03 / S-02 §1.1 say union reads do not dedup (Plan 9). The ruling says every name appears once. Should dedup apply only where snarf's mounts shadow the host tree (host at `/`), or to every union (`/bin`, origin)? *Assumed: host-shadowing only (UD-17).*
2. **Device files.** HostFs hides char/block devices, fifos and sockets, so host `/dev/null` (the ruling's own example) can't be listed or opened. Should hostfs expose device nodes, at least under `/dev`? If so, what should open, read and stat do with them? Today a Linux `/dev` would list only directories and symlinks.
3. **Which record is kept on a collision.** For `dev` in `/`, is it snarf's synthetic stat (DMDIR|0555, empty uid) or the host's real stat? Plan 9 `dirread` of the parent shows the underlying entry, while a stat of the mount point gives the mounted one. *Assumed: snarf's (UD-03).*
4. **Nested mounts.** Does the union extend to nested mount points, e.g. `/dev/draw` = the draw device ∪ host `/dev/draw`? Should host entries under a snarf-served subtree be reachable? Not tested.
5. **Create in a shadowed dir.** Where does a Put of a new `/dev/new.txt` go? `nswrite` uses the first member whose parent walk succeeds (snarf's device, which refuses). Plan 9 uses the MCREATE member. *Expected: the host.* UD-13 covers only existing files; create gets a test after the ruling.
6. **Order.** "Snarf's entries first" can be seen only in the raw 9P stream, because dirwin sorts (dircmp). Confirm that the requirement is on the stream order and that the window keeps ACME's sorted order. *Assumed (UD-02 vs UD-04).*
7. **`/n/local`.** If Larry picks `/n/local` (#11 Q1), does the `/mnt/host` alias stay, and do `/dev` and `/mnt` become pure snarf dirs with no union? *Assumed: yes; the shadowing cases become N/A.*
8. **Shadowed collisions.** The host's own `/dev/kbd`, `/dev/mouse` and `/mnt/host` are listed once, but snarf's entry wins, so the host copy is reachable only through `/mnt/host/...`. Does that satisfy "nothing hidden"? *Assumed: yes (UD-08).*
9. **Spec text.** The S-02 §1.3 revision log says `dev/` and `mnt/` "are not in that listing". That contradicts both the current code and the ruling, and needs a spec fix.
