---
id: t-aud22
title: **[t-aud22]** Test-harness parallelism flakiness — FIXED (3/3 targeted). (1) `ScarfMonTests`: assertions filter by the call's sample name instead of total count — ScarfMon's backend is process-global, so concurrent suites' samples leaked into the test's ring. (2) `RemoteSQLiteBackendTests.openWithDefaultTildeHomeExpands`: now `.enabled(if: !exists(~/.hermes))` — it manipulates the REAL `~/.hermes` (move/symlink `state.db`), which races a live install + risked the user's real DB (the original Code=516); skips safely on dev machines, runs on clean CI. (3) `ModelPresetServiceDiskTests` now passes (the tilde test's `~/.hermes` contention was the cross-suite racer). Full ScarfCore run: **609/610**, tilde skipped. The 1 remaining (`M0dViewModelsTests.richChatViewModelInitsEmpty`) is a SEPARATE pre-existing DETERMINISTIC env-coupling bug → split to t-aud25.
status: archived
---

## Description



## Plan



## Artifacts



