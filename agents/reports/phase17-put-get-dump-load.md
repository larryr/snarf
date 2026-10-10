# Phase 17 report — `Put`, `Get` for files, `Putall`, name-change `Undo`, `Dump`/`Load`

**Merged to main:** (this commit's `--no-ff` merge) · **Tests:** 743/743, run twice, no leaks ·
`zig build` / `zig build native` OK · `zig fmt` clean · **two goldens moved, both sanctioned,
pixel-level evidence below (FROZEN-ACCEPT-8, FROZEN-ACCEPT-12B/T22)** · **Contract:**
`agents/contracts/phase17-put-get-dump-load.md` · **Pipeline:** Fable spec → Opus build →
Sonnet tests+gate → Fable review (APPROVE WITH NITS, one fix applied below) → this merge.
Satisfies **R-EDIT-15** (Put/Get/Putall) and **R-EDIT-16** (Dump/Load; closes the `$home`
decision — v7).

## What this unblocks

Snarf can now edit its own repository through `/n/origin/fs/`: load a file, edit it, `Put` it
back (or `Putall` every dirty named window), and the window's live tag tracks dirty/clean via
`putseq` exactly as acme's wind.c does. `Dump`/`Load` round-trip the whole row's layout through
`$home/acme.dump` (`/mnt/opfs/acme.dump` on the browser host; real `$HOME`, unmounted until
Tier 2's native file server, on the native host — the dump honestly warns `NotMounted` there
rather than silently no-op'ing).

## Built (NEW)

`src/ninep/nswrite.zig` (`WriteFileJob`: create-on-`NotFound`/truncate-existing/`must_exist`,
chunked `Twrite`s, fire-and-forget `deinit`) · `src/core/Put.zig` (async `putfile`: sha1
stale-check, acme's exact `exec.c` warning texts, `putseq` tail) · `src/core/exec/cmd_put.zig`
(`getName`/`put`/`putall`) · `src/core/getaddr.zig` + `src/core/loadaddr.zig` (pure move, kept
`Load.zig` under cap) · `src/core/exec/cmd_dump.zig`, `src/core/Session.zig`,
`src/core/RowDump.zig`, `src/core/RowLoad.zig`, `src/core/dumpfmt.zig` · test-only
`src/core/MemTree.zig` (writable in-memory 9P tree + fault injection: `fail_create`,
`short_once`, `qtype_append`).

## Changed

`File.zig` (rename-undo record, `unread`, `disk` identity) · `Window.zig` (`putseq`,
`isscratch`, tag `put` flag) · `wintag.zig` (`commit`, `setName`, `setTagCommit`, `clearTag`,
the live ` Put` word) · `cmd_edit.zig` (`dirty = seq != putseq`) · `cmd_get.zig`, `Load.zig` ·
`Gesture.zig`/`typing.zig` tag-commit hooks · `builtins.zig` (14 → 18 entries) · served
`xfid.zig` ctl `get`/`put` · `openfile`/`place`/`dirwin` rename through `wintag.setName` ·
`Editor.zig` (+8 lines) · `wasm_boot.zig`/`main_native.zig` (`$home`) · origin `tree.zig`/
`hostfs.zig` (`create`, files only, exclusive, logged) · docs S-05 §2/§4/§8, S-02 §4/§6,
R-02 v7.

## Deviations from the contract (all reviewed)

1. **`setTagCommit`** added — a hand-edited tag name has no `ed` to bump `seq`, so a separate
   entry point was needed for the sweep/Put-completion/Undo call sites.
2. **`wintag.commit` clears the tag's `mod` when the name is already in sync** (`wintag.zig:270-
   278`) — restores acme's `wind.c:565` invariant (cleared after every `winsettag1`, which runs
   per-keystroke in acme) so an Undo-restored name isn't misread as a fresh rename. Verified in
   review: can't suppress a *real* rename, since a real rename is by definition a name
   mismatch, and the clear only fires on match.
3. **`Putall` now commits each window's tag before checking `mod`** (fixed post-review, see
   below) — the stand-in for acme's per-keystroke `wincommit` (wind.c:401-408), which Snarf
   doesn't have (R-P17-7).
4. **`WriteFileJob.Options.refuse_append`** — the job only sees the qid; Put supplies the
   pre-write length for the append-only (`QTAPPEND`) check, matching acme's own ordering hazard
   (it also truncates before `dirfstat`-ing for the flag).
5. **`@alignCast`/`@fieldParentPtr`** in `place.zig` for Column/Row tag access — `File.Disk`
   carries a `u64`, raising `File`'s (and its embedding structs') alignment to 8 on wasm32;
   verified necessary and safe (Columns/Rows are heap-created at natural alignment).
6. **A failed file `Get` keeps the old body** (acme empties it first) — matches the existing
   13b directory-arm choice; `textreset` still zeroes `seq` on success so undo history drops as
   in acme.

### Review fix applied (finding 1, was a real gap)

The build stage had dropped `Putall`'s tag-commit entirely, citing `exec.c:1190`
(`wincommit(w, &w->body)` touches only the body cache, never the tag — accurate citation). But
acme never *needs* a tag-commit at that point because it already committed on the triggering
keystroke; Snarf has no such per-keystroke site, so an uncommitted tag rename would have
survived a `Putall` and been applied only afterward, under the stale name. Fixed: one
`try wintag.commit(ed, w);` call added in `cmd_put.putall`, before the `mod` check (`commit` is
a no-op in the common case where the tag already matches).

## Golden re-freeze (R-P17-9), pixel-level evidence

| Scene | Old hash | New hash |
|---|---|---|
| FROZEN-ACCEPT-8 (boot chrome) | `0x9816211a7aca91d7` | `0xfd8b232d77d1f0bd` |
| FROZEN-ACCEPT-12B / T22 (+Errors) | `0xa4af36d064fbd9c9` | `0x86a3f4679b1b8d21` |

Both scenes' w1 tag gained the `Put` word (`…Undo | Look` → `…Undo Put | Look`). Spot-check
(suppress `putShown`, re-render, diff pixel-for-pixel against the real render): **exactly 212
pixels differ in both scenes, confined to rows [40,57) — entirely inside the tag row** (tag
band is y=[40,58)). Nothing else moved; every other FROZEN-ACCEPT scene (2, 3, 6a, 6b, 7, 9,
10, 13B) is untouched, confirmed by diff on `src/accept.zig` showing only these two hash/
comment edits plus one unrelated fix below.

**Incidental real bug caught**: `src/accept.zig`'s `tgbuf: [128]u8` was one `Buffer.read`
precondition away from a crash — w1's tag grew from 30 to 34 runes, and `Buffer.read` requires
`dest.len >= 4 * nrunes = 136 > 128`. Raised to 256 (this file's existing convention for a
longer tag, not an arbitrary number).

## Tests

22 named tests (T1-T22) per contract §4; 20 new named tests landed (some folded into existing
files rather than new ones), bringing the suite from 723 → 743. One explicit gap:

- **T7** (Put byte-for-byte on invalid UTF-8): not exercised directly — `Load.sanitize` already
  replaces invalid UTF-8 with U+FFFD at load time, so no invalid bytes reach the buffer via the
  normal path, and forcing one in would require bypassing `File.insert`'s rune-counting (which
  panics on invalid UTF-8 by design). Judged not worth a bespoke bypass fixture; the general
  round-trip is covered via exact-string comparisons elsewhere.

## Debt (carried to the next structure/debt pass — none blocks this merge)

- **T21 not completed** (wasm smoke: a real B2-click on the "Put" word). The obstacle is
  geometry, not principle: at `/mnt/opfs/notes.txt`'s tag length, "Put" lands at rune ~35,
  x≈811 — off the 800px test display. **Fix recipe (from review): seed a short window name**
  (e.g. `/mnt/opfs/n`, putting "Put" at rune 27, x≈743) **and compute `putX` from the known tag
  string** the same way the existing 13b probe does (`smoke_wasm.mjs:736-737`,
  `x = 496 + rune*9`), not by hand-deriving from name length in the abstract. This is the only
  end-to-end check of R-P17-2's fsOp ordering against the real OPFS device (`opfs.js`'s
  per-path writable) — the Zig suite only exercises `MemTree`. Recommended as a short, focused
  follow-up, not urgent.
- **Over-cap files** (~400-line soft cap): `xfid.zig` 424 pretest lines (contract
  pre-authorized a small overage this wave) and `Window.zig` 405 pretest lines (newly crossed
  this phase, +15 lines for `putseq`/`isscratch`/`clean()`). Neither needs splitting *because
  of* this phase (file-as-struct, no clean seam); the next wave that touches `Window.zig`
  (Zerox/Sort, Tier 1 item 3) should carry the split.
- **`Load.finishTail` doesn't set the new tag `.put` field** — defaults false, so a `Get` on a
  previously-`Put` window causes one extra (idempotent) tag recompose next sweep pass. Low
  priority; a shared `wintag.tagStateOf(w)` helper would prevent this class of drift if anyone
  touches tag-state construction again.
- Already known, still open: no per-keystroke tag-commit site (timer-less/pointer-leave-less,
  now also no-`wintype`-equivalent — all three are the same underlying gap); OPFS has no
  rename, so Dump/Load can't preserve a mid-session rename across a reload; `nopen[QWevent]`
  skip in `Putall` is n/a until `/dev/event`-shaped serving exists.

## Decisions recorded, not stopped on (contract §6, confirmed no objection)

1. `$home` = `/mnt/opfs` (browser), real `$HOME` (native, unmounted until Tier 2 — honest
   `NotMounted` warning, not silent no-op). Dump file uses acme's exact `rowdump1` format;
   supersedes S-05 §8's older "versioned text format" wording (revision-log entry, no ID
   change).
2. The origin server's `fs/` export gained `create` (files only, exclusive, logged) — widens
   its write surface from "rewrite existing" to "create new under the export." Flagged, not
   silent; separate from the Tier 1 item 2 host-command allow-list question.
