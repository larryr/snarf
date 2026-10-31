# Native first run: hands-on checklist for Larry

*SnarfProdd (PM) working note, 2026-10-11. Use it once the `zig build native` milestone (ADR-0006, runnable `snarf-native`) lands. It takes about 15–20 minutes.*

*Setup assumed: your Mac, a Magic Trackpad with **three-finger drag on**, plan9port installed and `$PLAN9` set.*

*The steps are grounded in the repo at `b92d825`:*
- *`src/main_native.zig`*
- *`src/host/devdraw/Conn.zig`*
- *`src/core/exec/builtins.zig`*
- *`agents/HANDOFF.md`*
- *`agents/reports/phase15-native-spike.md` and `agents/reports/phase17-put-get-dump-load.md`*
- *[ADR-0006](../../../docs/spec/adr/0006-devdraw-fetch-dependency.md)*

*How to read it: **⚠ expected to fail today** means the repo doesn't support it on native yet. Please still try it and note what happens. A clean, honest error counts as a pass.*

**Input profile: P2 from the [input mapping guide](../input/input-mapping-guide.md).**

| Button | How |
|---|---|
| B1 | click or sweep |
| B2 | **Option**-click or sweep |
| B3 | **2-finger click**, or Command-click or sweep |

**Chords: hold the click (B1 sweep), then press a modifier.**

| Chord | How |
|---|---|
| Cut | B1 sweep held, then **Option** |
| Paste | B1 sweep held, then **Command** |
| Snarf | B1 sweep held, then **Option** then **Command** |
| 2-1 | Option-click held on the command, then **Control** |

## Why some steps can't work yet
Native snarf's namespace today is only `/dev`, `/dev/draw` and `/mnt/snarf-self` (`src/main_native.zig` header). The **native file server is not built** (roadmap M1, NEXT-PHASES Tier 2 #4). So these show `NotMounted` on native:
- opening real files;
- `Put`, `Get` and `Putall`;
- `Dump` and `Load` (phase 17: `$home` = `$HOME`, "unmounted until Tier 2").

The system clipboard isn't wired either: the `Trdsnarf`/`Twrsnarf` messages are encoded in `wsys.zig` but not connected to `/dev/snarf`. **Test editing in scratch windows (`New`).**

## Checklist

| # | Step | Expected result | ✓ / notes |
|---|---|---|---|
| **Build and start** | | | |
| 1 | From a fresh clone: `zig build native`. Note the wall time and whether it fetched anything | `zig-out/bin/snarf-native` plus a bundled `zig-out/bin/devdraw`. The first run fetches the pinned `larryr/plan9port@337c6ac` (ADR-0006). If there's no bundled devdraw, the milestone hasn't fully landed | [ ] |
| 2 | Run `zig-out/bin/snarf-native` (or `zig build run-native`) **with `$PLAN9` still set**. Read the startup log | A log line names the devdraw it used, and it is the **bundled** one, chosen over `$PLAN9`. ADR-0006's order is `$DEVDRAW` → bundled (next to `snarf-native`) → `$PLAN9` → `$PATH`, and it requires the line. *(Today's `Conn.zig` checks `$DEVDRAW` → `$PLAN9` → `$PATH` with no bundled step. If you see `$PLAN9` picked, the change hasn't landed.)* | [ ] |
| 3 | Run it again from a different directory (`cd /tmp && ~/…/zig-out/bin/snarf-native`) | Still the bundled devdraw: it is resolved relative to the executable, not the cwd | [ ] |
| 4 | Look at the window | A devdraw window titled "snarf". The root tag shows `Newcol Kill Putall Dump Exit`. A directory window for `/` lists `dev/ mnt/` | [ ] |
| **Files** | | | |
| 5 | B3 (2-finger click) on a path to a real file, e.g. type `/Users/larry/.profile` in a tag and look at it | ⚠ **Expected to fail today**: a not-found or `NotMounted` warning in `+Errors`. It should not crash. *(It passes once the native file server lands.)* | [ ] |
| 6 | `Put` / `Get` / `Putall` on a window | ⚠ **Expected to fail today**, with the same honest error. It should not report a false success | [ ] |
| 7 | `Dump`, then quit (close the window; there's no `Exit` builtin yet), relaunch, then `Load` | ⚠ **Expected to fail today**: `Dump` warns `NotMounted` at `$HOME` (phase 17) | [ ] |
| **Directory windows** | | | |
| 8 | In the `/` window, B3 on `dev/`, then on `mnt/`, then on `snarf-self/` inside `mnt/` | Directory windows open listing the entries (phase 13b). Each new window gets the pointer: **warp on open** (`openfile`, `look.c:897`) | [ ] |
| **Editing (in a `New` window)** | | | |
| 9 | B2 (Option-click) on `New` in a column tag. Type a few lines | A scratch window appears, the pointer warps into it, and typing goes where the pointer is (point-to-type) | [ ] |
| 10 | B1 double-click on a word, then on a line end, then inside `( … )` | Selects the word, then the line, then the bracketed text | [ ] |
| **Execute and look** | | | |
| 11 | Type `Look foo` in the tag and Option-click it | A search for `foo` in the body | [ ] |
| 12 | 2-finger click (B3) on a word that appears again lower down | The next match is selected **and the pointer warps to it** (`look.c:219`). Repeat to step through matches | [ ] |
| 13 | Command-click (B3) on the same word | Same as step 12 (the alternative B3) | [ ] |
| **Chords** | | | |
| 14 | Sweep text with a held click, then press **Option** | **Cut** | [ ] |
| 15 | Sweep, keep holding, press **Command** | **Paste** replaces the selection with the snarf buffer | [ ] |
| 16 | Sweep, hold, **Option then Command** | **Snarf** (copy). The text stays and the window stays clean | [ ] |
| 17 | B1-select a word `foo`. Release. Option-click and **hold** on `Look`, then press **Control** | **2-1**: runs `Look foo` | [ ] |
| 18 | 3-finger tap on a word | Unreliable for you with three-finger drag on (an earlier report). Note whether it ever registers as B2. It is not required | [ ] |
| **Edit, undo, warp-back** | | | |
| 19 | Execute `Edit ,s/a/A/g`, then `Edit ,x/A/ c/a/` | Substitutions apply (phase 10 Edit language) | [ ] |
| 20 | `Undo` several times, then `Redo` | Undo walks back through the edits, Redo replays them. Typing runs group into one undo step ⚠ **Known bug #57** in v0.M0-dev.1: the text may not repaint until you resize. Note whether you see it | [ ] |
| 21 | `Del` a window that just popped up (e.g. `+Errors`) | The pointer returns to where it was before the pop-up (ported in #43, exact ACME: any `Del` clears the single saved slot). SnarfDev2 passed this on Linux with v0.M0-dev.1 | [ ] |
| **Clipboard and keys** | | | |
| 22 | Snarf in snarf, then Cmd-V in TextEdit. Then copy in TextEdit and Paste in snarf | ⚠ **Expected to fail today**: the snarf buffer is internal to snarf (native `/dev/snarf` isn't wired, roadmap M1) | [ ] |
| 23 | Try Cmd-X / Cmd-C / Cmd-V / Cmd-Z inside snarf | Unknown: devdraw sends them as Command-key characters, and it isn't verified whether snarf maps them. Just note what happens | [ ] |
| **Display** | | | |
| 24 | Look closely at the text on your Retina display, next to plan9port acme | **Observation only.** Retina is deferred until native is merged and running. Is it crisp or soft? | [ ] |
| 25 | Resize the window and toggle full screen (Cmd-F, or pinch) | The layout reflows. Pinch toggles full screen (devdraw) | [ ] |
| **Wrap-up** | | | |
| 26 | Anything that felt wrong or slow, or crashed (please paste stderr) | — | [ ] |

## Your top 3 blockers to daily use
1.
2.
3.

*These drive the M3 order (next sync, agenda item a).*

## Free notes

## Revision log
- 2026-10-31: Step 21 now expected to pass (#43 merged). Step 20 flags known bug #57. You can run this from the [v0.M0-dev.1 pre-release](https://github.com/larryr/snarf/releases/tag/v0.M0-dev.1) instead of building (first launch: `xattr -d com.apple.quarantine snarf-native devdraw`).
