# M0-47: snarf-origin must not share a busy port (issue #47)

**Owner:** SnarfDev2. **Fix:** SnarfDev1. **Tests:** PR #62, `tools/origin/port_test.zig`.
**Flag:** `origin_port_exclusive_fixed = false`. While it's false, a second bind that succeeds SKIPs; one that fails FAILs with `UnexpectedPassFlipFlag`.
**Cause:** `Origin.listen` (`tools/origin/main.zig:49`) passes `.reuse_address = true`, which sets SO_REUSEADDR and SO_REUSEPORT (std/Io/net.zig:229). Two instances can then share a port, and connections are split between them.

| ID | Type | Case | Expected | Gated |
|---|---|---|---|---|
| OP-01 | unit | Origin A on `127.0.0.1:0`; Origin B on A's port | B's listen returns `error.AddressInUse`; `main` logs `cannot listen on …` and exits non-zero | yes |
| OP-02 | unit (control) | A plain listener (no reuse) holds a port; Origin listens there | `error.AddressInUse` (already true on main) | no |
| OP-03 | unit (control) | Origin binds, `deinit`s, then binds the same port again | Succeeds, so restarts still work | no |
| OP-04 | manual | `zig build serve` twice with the same port | The second run prints `cannot listen` and exits non-zero; smoke origin checks report PENDING, not flaky results | (manual) |

Verified on main (ba5bc12):
- Flag forced to `true`: OP-01 fails ("second listen on busy port … succeeded").
- Flag `false`: 826/843 passed, 17 skipped.
- Probe `.reuse_address = false` with the flag `true`: 827/843 passed.
- Open risk for the fix: dropping `reuse_address` also drops SO_REUSEADDR, so a restart while connections are in TIME_WAIT may hit `AddressInUse`. OP-03 doesn't cover that.
