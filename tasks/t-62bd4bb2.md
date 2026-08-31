---
id: t-62bd4bb2
title: Fix pre-existing SettingsWriteReadParityTests interpolated-shape failure
status: done
added: 2026-08-28
---

## Description

SettingsWriteReadParityTests.unresolvedInterpolatedShapesFailLoudly() fails reproducibly (also in isolation). Cause: setSetting("auxiliary.\(task).max_concurrency", …) at SettingsViewModel.swift:497/499 (added in b9b07ab, 2026-08-20, Hermes v0.20.4 config keys) was never added to the test's knownInterpolatedTemplates set. Fix: add the template plus its expansion to the set. Not related to the a11y change set; found during its test run 2026-08-28.

## Plan



## Artifacts

Fixed in c1b5209: added auxiliary.\(task).max_concurrency to knownInterpolatedTemplates AND to the expandedAuxKeys() expansion (all 9 aux tasks), so everyWrittenSettingKeyIsReadableThroughScarfCore now round-trips those keys through HermesConfig(yaml:) — verified all pass and fabricatedUnreadKeyIsDetected still trips, so the gate remains functional, not silenced.

