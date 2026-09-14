# Review notes for Larry — one entry per phase, newest first

Purpose: a short digest to read after each phase. What changed for you as a user, what to
try, decisions I made on your behalf, and open questions. Details live in
`agents/reports/phaseN-*.md`; state lives in `agents/HANDOFF.md`. Standing instruction
(2026-09-14): "continue to execute on each planned phase in turn; keep notes after each phase
for me to review; when all planned phases are complete recommend next phases."

Planned queue: **13b directory windows → 14 OPFS (`/mnt/opfs`) → ADR-0005 native-host spike**
(`devdraw` adapter, the core drawing in a real window with warping). Then recommendations.

---

## Phase 15 — ADR-0005 native-host SPIKE (merged `efeb3fe`, 2026-09-14)

**For you — try it:** `zig build run-native` (uses `~/proj/plan9port/bin/devdraw`; set
`PLAN9=~/proj/plan9port` or `DEVDRAW=…/devdraw` if it is not found). A real `snarf` window:
two columns, `/` on the right. Type; B3 `mnt/`; select a word and B2 `Look` — **the pointer
warps onto the hit**, the paper's behavior, for the first time. Resize the window; it reflows.

**The finding:** the editor core needed ZERO adapter-forced changes. `src/draw` and
`src/ninep` are byte-identical to before; the only core change is the warp feature the ADR
ordered. "Two hosts, one core" is proven, not asserted.

**What changed:** `src/host/devdraw/` — a `drawfcall` codec, a `Conn` that spawns `devdraw`
over a pipe and keeps one mouse and one keyboard long-poll outstanding, and two 9P devices
(`/dev/draw` forwarding the core's draw bytes as `Twrdraw`; `/dev/mouse`,`/dev/kbd`,
`/dev/cursor`,`/dev/snarf`,`/dev/label`); `main_native.zig` wires them exactly like the
browser host. **Warp is now a core feature**: acme's `moveto` points are written to
`/dev/mouse` (Plan 9 `mouse(3)`) from the search-hit and open-window sites; the browser
device refuses the write and nothing happens; the native device does `Tmoveto`.

**Decisions made for you:** no warp when the `:addr` was invalid (acme's rule; reviewer
caught it). `permission denied` as the browser's refusal string (no new error member).
Single-threaded `poll(2)` loop rather than a reader thread (Zig 0.16 has no mutex/condvar).

**Found along the way:** browser **ArrowDown does nothing** — the core's `Kdown` constant
took plan9port's value while the browser device uses Plan 9 4e's; native works by accident.
First item of the debt pass. Also devdraw's own `Rrdmouse` clobbers the timestamp's middle
byte (reproduced on the wire; we timestamp locally).

## Phase 14b — `/mnt/opfs` (merged `851d0dc`, 2026-09-14) — ABI v6

**For you — try it:** reload; B3 `mnt/` then `opfs/`: an empty directory window on the
browser's private file system (`/mnt/opfs/`). It stays empty until `Put` exists (next wave
candidates). To inspect it from devtools: `for await (const e of (await
navigator.storage.getDirectory()).entries()) console.log(e)`. To seed a file for browsing:
`const d = await navigator.storage.getDirectory(); const f = await
d.getFileHandle("hello.txt",{create:true}); const w = await f.createWritable(); await
w.write("hi from opfs\n"); await w.close();` then B2 `Get` in the `/mnt/opfs/` tag and B3
`hello.txt`.

**What changed:** every 9P op on this tree parks while the browser answers (14a's framework);
completions travel over a new `fsOp` import + `fsStage`/`fsPush` exports (ABI v6, so the page
and module must match — a stale tab shows an ABI mismatch until reloaded). Walk/open/read/
write/create/remove/stat/wstat(length) all work over the wire; the smoke test drives the
real module from `mnt/` into `opfs/`, opens a file, and `Get`s a new one.

**Decisions made for you:** `/mnt/opfs` is mounted unconditionally; a browser without OPFS
gets `i/o error` on first use plus one console line (simpler than a conditional mount). No
rename (Chromium-only `move()`); `wstat` supports length only. `is a directory` uses the
kernel's `file is a directory`.

**Debt for the pass:** a parked walk that is flushed leaks one slot (framework should clunk a
discarded tentative fid); six `stat` round trips per file open (a per-path cache); one OPFS
writable per 8 KiB chunk (quadratic large writes — matters for `Put`); `main_wasm.zig` 458 and
`opfs.zig` 440 pre-test lines; `bad offset` string. wasm ≈ 2.19 MB ReleaseSafe.

## Phase 14a — 9P server framework: parking for every op, create/remove/wstat (merged `afff8ac`, 2026-09-14)

**For you:** nothing visible; this is the server half of OPFS. Reload is safe.

**What changed:** any 9P operation a device serves can now say "ask me again later" and the
server parks the raw request and retries it in order (the phase-6 read-only parking,
generalized; bound 64). Tcreate/Tremove/Twstat are decoded and handled with lib9p's
"prohibited" defaults, so every existing tree is byte-identical. `server.zig` went from 780
to 450 lines by moving parking, fid-lifecycle handlers, and the test harness out.

**Decisions made for you:** Tflush keeps the phase-6 `interrupted` + `Rflush` pair. Three
existing test bodies were edited because the contract made their old expectations
impossible (codes now implemented; a struct the design abolished) — names kept, reviewed.

**Debt:** `client.zig` 637 and `msg.zig` 476 pre-test lines (both pre-existing).

## Phase 13b — directory windows (merged `fd1abe0`, 2026-09-14)

**For you — try it:** `make run`. Boot is now acme's: two columns, the right one a directory
window on `/` listing `dev/  mnt/` (tag `/ Del Snarf Get | Look`). B3 on `mnt/` opens
`/mnt/` (`snarf-self/`), B3 on `snarf-self/` opens the served tree, B3 on `index` opens it as
a file window. After the origin attaches, B2 `Get` in the `/` tag re-lists and shows `bin/ n/`;
B3 into `n/origin/fs/` browses the repo. `file:12` and `file:/re/` select the address after
opening; a word that is not a file falls back to the literal search.

**What changed:** acme's `textload` directory arm, `dircmp`, `textcolumnate` (narrower
TABDIR tabs), `openfile`, `expandfile`, `Get` for directories, `isdir` in the tag/ctl,
`/mnt/snarf-self/ns`. R-EDIT-03 satisfied. FROZEN-ACCEPT-13B freezes the new boot.

**Decisions made for you:** `wdir` = `/`. `Get` on FILE windows still warns (Put/Get is its
own wave). The self-mount guard refuses only `/mnt/snarf-self` itself, so files under it open.
**One recorded divergence:** acme decides file-vs-text on a right click synchronously; Snarf
parks the look for one round trip (a frame on in-memory mounts) then opens or searches.

**Open items / debt:** wasm grew +297 KiB at ReleaseSafe (+43 KiB ReleaseSmall — real new
code ×7 by safety checks; debt pass). `Window.zig` 559, `Editor.zig` 414, `expand.zig` 402
pre-test lines are over the cap again. Normal windows keep libframe's 72-px tab where acme
uses 36 (pre-existing; fixing it moves a golden). Retina still soft.

## Phase 13a — asynchronous 9P, real boot namespace (merged `cee0441`, 2026-09-14)

**For you:** nothing visible yet; this is the plumbing directory windows need. Reload is safe.

**What changed:** every 9P operation the editor issues can now be started and polled per
frame without blocking; cancellations are tombstoned so a late reply can never poison another
request. The editor holds the namespace. The boot namespace is real: `/dev`, `/dev/draw`,
`/mnt/snarf-self` (served at runtime for the first time), plus `/n/origin` and `/bin` when the
origin attaches.

**Decisions made for you:** `/mnt/snarf-self/ns` deferred to 13b (would have changed a served
listing mid-wave). Fid numbers are recycled before the Rclunk arrives, which assumes in-order
peers — true for both our servers; noted for the native host.

**Pipeline note:** the review caught a real bug (synchronous cancel/clunk on the origin's
un-pumped connection) before merge; fixed and pinned by regression tests. Wasm +137 KiB
because the served tree is now linked in.

## Phase 12e — structure only (merged `35eccc5`)

**For you:** nothing visible. `Editor.zig` 824 → 383 lines; gesture machine, sweep loop,
snarf helpers, origin handshake, and wasm glue each in their own file. Pure move, verified
line-by-line; 540 test names identical. **Decision you made:** keep ReleaseSafe (1.6 MB)
over ReleaseSmall (194 KiB) while the editor is growing.

## Phase 12d — unions, synthetic root, `/n/origin` (merged `6d13dda`)

**For you:** the origin is now at `/n/origin`; its `bin/` is unioned into `/bin`. Not visible
until directory windows. **Decisions you made:** `/n/origin`; unions now; `/mnt/snarf-self`
stays; `/dev/dom` kept browser-only, low priority; `$home` deferred until unions exist.

## Phase 12c — canvas fills the window (merged `e351203`)

**For you:** reload — the editor fills the browser window and follows resizes. Retina stays
soft (DPR 1) until a 2× font exists; the native host gets it free from `devdraw`.

## Phase 12b — `Look`, `+Errors`, placement (merged `96d7cb5`)

**For you:** first `Del` on a modified window now shows `<name> modified` in a `+Errors`
window (rightmost column); `Look` works; auto-created windows follow acme's placement.
A successful origin mount is logged to the console, not `+Errors` (your decision).

## Docs (merged `f6ef98a`) — paper as markdown, related Bell Labs papers, R-02 v4

`docs/acme/acme.md` + sam/plumb/8½ papers + man pages; only Pike-authored = definitive.
R-02 corrected (B3 opens directory entries; live tags) and extended (R-EDIT-20..25).
ADR-0005 (two hosts, one core; native host = plan9port `devdraw` or compatible) merged
`0884f3e`; plan9port built locally with `devdraw` + `acme` at the pinned SHA.
