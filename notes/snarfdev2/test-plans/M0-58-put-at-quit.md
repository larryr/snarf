# #58 — leaks at quit + unfinished-Put recovery file (PR #68)

Validated by SnarfDev2 on 2026-10-31 at PR head `4608a8d`. Review: https://github.com/larryr/snarf/pull/68#issuecomment-6548052698.
Extra tests are in PR #71. Follow-up issue: #70 (a new-file Put cut off at exit is silent).

## Spec under test (Larry, decisions README 2026-10-31)
- Partial bytes go to `<dir>/.<base>.snarf-partial`, then `.1`, `.2`, … The file is made with an exclusive create and mode 0600, and the original is never touched.
- The fallback is `$TMPDIR/snarf-partial-<pid>-<base>` with the same numbering. A relative or empty `$TMPDIR` means `/tmp`.
- stderr line 1: `snarf: Put of /abs not finished at exit; file left unchanged`. Line 2 is either `snarf: partial contents saved in /abs/.x.snarf-partial` or `snarf: could not save partial contents (<Error>)`.
- A zero-byte Put prints line 1 only and writes no file. The in-place variant prints `… written in place and may be incomplete` and writes no file.
- Nothing is printed when no Put was running, or when the Put had already failed.
- Paths are bare and absolute, so B3 works on them.

## Headless (zig build test)
| Area | Tests |
|---|---|
| content, 0600, original untouched | recovery_test "exact partial bytes" |
| numbering / no overwrite | recovery_test "taken name"; #71 dangling symlink, symlink to file, 1000 taken → fallback |
| fallback | recovery_test "read-only directory"; #71 relative/empty TMPDIR, trailing `/` |
| total failure | recovery_test "nowhere takes it" |
| zero bytes | recovery_test "zero bytes" |
| silent cases | HostTree tests (no Put); #71 already-failed Put |
| in-place | #71 in-place variant |
| B3 paths | main_native_test `expectB3Paths` |
| new-file Put | #71 FLAG `create_put_notice_fixed` (#70) |

Mutations M1–M14 (numbering, exclusive, fallback, TMPDIR, mode, zero-byte, path printing, silent cases, failure line, in-place line) all go red with #71. Without #71, M6 (relative TMPDIR), M7 (`//`), M12 (already-failed) and M14 (in-place line) stay green.

## X11 (Linux, devdraw, xdotool)
1. Make a 1.14 MB file (20000 lines). Open it, type a character, B2 `Put`, and as soon as `.<base>.snarf-put.0` appears, `xdotool windowkill`.
   - Expect the two lines on stderr, a 0600 prefix file beside the original, the original byte-identical, and no temp left behind.
   - Run it again: the recovery file gets `.1`.
2. The same, but `chmod 555` the directory once the temp appears. Expect the `$TMPDIR/snarf-partial-<pid>-<base>` line.
   - Known: the temp `.<base>.snarf-put.0` stays in the read-only directory.
3. With the directory read-only from the start, expect the in-place line and no recovery file.
4. B3 each printed path in a tag. It should open the partial contents.
5. Count `leaked` lines on stderr at close, in both Debug and ReleaseSafe. Main gives 69–74; #68 gives 0.

Timing notes:
- The Debug load of a 1.14 MB file takes about 6s.
- The Put sends about one 8138-byte write per tick, so a 1 MB file leaves a kill window of several seconds.
