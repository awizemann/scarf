# UI Gate Summary (release 3.8.0)

- Mode: unit tests on this Mac, UI tests in the scarf-ui Tart VM
- Git commit: 6f5fb9b1 (clean tree when the gate started)

## UI Gate Summary

- Date: 2026-11-01 21:17:09 UTC
- Git commit: 6f5fb9b1
- Hermes version: not used (--unit-only)
- Fixture build: none (--unit-only)
- DerivedData: /var/folders/1_/gpwt9pm55k915zn8blxdsj200000gn/T//scarf-ui-gate.1j36LL/DerivedData

| Plan | Result | Tests | Wall time | Result bundle |
| --- | --- | --- | --- | --- |
| Full (scarfTests only) | PASS | XCTest: 6 executed / 0 failed; Test run with 2189 tests in 301 suites passed | 481s | `/var/folders/1_/gpwt9pm55k915zn8blxdsj200000gn/T//scarf-ui-gate.1j36LL/Full.xcresult` |

Result: PASS

## UI Gate (Tart VM) Summary

- Date: 2026-11-01 21:54:08 UTC
- Git commit: 6f5fb9b1
- VM: scarf-ui
- Scope: UI tests only (-only-testing:scarfUITests)
- Hermes: v0.22.5 (Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7, Python 3.14)

| Plan | Result | Tests (first run) | Wall time |
| --- | --- | --- | --- |
| Full | PASS | 34 executed / 17 passed / 0 failed / 17 skipped | 644s |
| Live | PASS | 17 executed / 16 passed / 0 failed / 1 skipped | 1414s |

Guest disk:

- Full: boot volume 8.8 GB free before, 8.7 GB after; macOS low-disk purges: 0, runner terminations by the purge: 0 (Full.guest-purge.log)
- Live: boot volume 8.7 GB free before, 8.7 GB after; macOS low-disk purges: 0, runner terminations by the purge: 0 (Live.guest-purge.log)

Result: PASS

Overall: PASS
