---
id: t-3eed315b
title: Fix env-dependent ScarfCore test failures (ProjectDoctor, RealPyYAML)
status: todo
added: 2026-11-06
---

## Description

Surfaced 2026-11-06 once ScarfCore compiled again (fix 6282987f — main had a shadowing compile error, so these suites weren't running). Baseline at 0f3c2bc0 and again on feat/hermes-v0230-parity at 8005c52c: `swift test` = 79 issues, identical failing suites, all pre-existing and independent of the v0.23 parity work.
- ProjectDoctorServiceTests (20), ProjectDoctorTrustTests, ProjectMCPToolTests (:913 healthy), ProjectMCPStdioSmokeTests, ProjectsD2LifecycleTests, BlindB03ProjectsTests: ProjectDoctor scans the REAL ~/Projects (e.g. finds orphan dir awizemann-hackernews-digest) instead of a test-isolated root — inject the root.
- HermesP32YAMLUnificationTests (49): RealPyYAML round-trips depend on host python/PyYAML (pyYAMLAvailable false on this Mac) — make them skip when unavailable.
- Flaky crash: 1 of 4 full runs on 8005c52c aborted with signal 6 in swiftpm-testing-helper (stack showed TaskLocal.withValue); not reproduced in 3 further runs; crash log not captured. Rerun the suite a few times with full output to identify the test.
Done = full ScarfCore `swift test` green on a dev Mac with real ~/Projects present, and no intermittent abort.

## Plan



## Artifacts



