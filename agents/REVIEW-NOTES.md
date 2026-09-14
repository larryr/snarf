# Review notes for Larry — one entry per phase, newest first

Purpose: a short digest to read after each phase. What changed for you as a user, what to
try, decisions I made on your behalf, and open questions. Details live in
`agents/reports/phaseN-*.md`; state lives in `agents/HANDOFF.md`. Standing instruction
(2026-09-14): "continue to execute on each planned phase in turn; keep notes after each phase
for me to review; when all planned phases are complete recommend next phases."

Planned queue: **13b directory windows → 14 OPFS (`/mnt/opfs`) → ADR-0005 native-host spike**
(`devdraw` adapter, the core drawing in a real window with warping). Then recommendations.

---

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
