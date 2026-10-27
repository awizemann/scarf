# UI Gate Summary (release 3.7.1)

- Mode: unit tests on this Mac, UI tests in the scarf-ui Tart VM
- Git commit: 20115cd3 (clean tree when the gate started)

## UI Gate Summary

- Date: 2026-10-27 20:55:06 UTC
- Git commit: 20115cd3
- Hermes version: not used (--unit-only)
- Fixture build: none (--unit-only)
- DerivedData: /var/folders/1_/gpwt9pm55k915zn8blxdsj200000gn/T//scarf-ui-gate.zxHy7e/DerivedData

| Plan | Result | Tests | Wall time | Result bundle |
| --- | --- | --- | --- | --- |
| Full (scarfTests only) | PASS | XCTest: 4 executed / 0 failed; Test run with 1996 tests in 291 suites passed | 451s | `/var/folders/1_/gpwt9pm55k915zn8blxdsj200000gn/T//scarf-ui-gate.zxHy7e/Full.xcresult` |

Result: PASS

## UI Gate (Tart VM) Summary

- Date: 2026-10-27 21:13:38 UTC
- Git commit: 20115cd3
- VM: scarf-ui
- Scope: UI tests only (-only-testing:scarfUITests)
- Hermes: v0.22.5 (Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7, Python 3.14)

| Plan | Result | Tests (first run) | Wall time |
| --- | --- | --- | --- |
| Full | PASS | 26 executed / 17 passed / 0 failed / 9 skipped | 658s |
| Live | PASS | 9 executed / 8 passed / 0 failed / 1 skipped | 298s |

Guest disk:

- Full: boot volume 9.6 GB free before, 9.6 GB after; macOS low-disk purges: 0, runner terminations by the purge: 0 (Full.guest-purge.log)
- Live: boot volume 9.6 GB free before, 9.5 GB after; macOS low-disk purges: 0, runner terminations by the purge: 0 (Live.guest-purge.log)

Result: PASS

Overall: PASS
