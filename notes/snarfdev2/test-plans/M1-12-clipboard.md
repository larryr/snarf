# Test plan: #12 System clipboard on native

**Issue:** #12 · **Requirements:** R-EDIT-14, R-9P-07 (native path = devdraw Trdsnarf/Twrsnarf; browser keeps Clipboard API; PM to fix R-9P-07 wording — PM Q2), devdraw `Trdsnarf`/`Twrsnarf` (`src/host/devdraw/wsys.zig`), ADR-0005 amendment

Harness: scripted devdraw peer (existing `src/host` codec tests pattern) that answers `Trdsnarf` and records `Twrsnarf`.

| ID | Type | Scenario | Expected | Traces |
|---|---|---|---|---|
| CB-01 | unit | Encode/decode `Trdsnarf`/`Rrdsnarf`/`Twrsnarf` round trip | byte-exact vs devdraw wire format | R-9P-07 |
| CB-02 | integration | Read `/dev/snarf` on native | issues `Trdsnarf`; returns peer's text | R-EDIT-14, R-9P-07 |
| CB-03 | integration | Write `/dev/snarf` | issues `Twrsnarf` with exact bytes | R-9P-07 |
| CB-04 | integration | Snarf / Cut in editor | pasteboard (peer) receives selection | R-EDIT-14 |
| CB-05 | integration | Peer pasteboard changed externally, then Paste / B1-B3 chord | editor inserts external text (no stale internal cache) | R-EDIT-14 |
| CB-06 | integration | UTF-8: é, 日本語, emoji (4-byte), combining marks | round trip byte-exact | #12 |
| CB-07 | boundary | Empty clipboard; large (1 MB) payload across multiple 9P reads (offset semantics) | empty read = 0 bytes; large intact | R-9P-07 |
| CB-08 | negative | devdraw error / non-text pasteboard | 9P error, not silent truncation | R-9P-07 |
| CB-09 | regression | Browser build keeps internal/previous behaviour, still compiles & smoke passes | green | R-OV-09 |
| CB-10 | manual | checklist 22: snarf → TextEdit Cmd-V, and reverse; non-ASCII | pass | #12 |
