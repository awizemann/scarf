---
id: t-f65db83c
title: Analytics P6: ScarfMon Stats backend + diagnostics events
status: done
added: 2026-08-20
---

## Description

Add a StatsScarfMonBackend conforming to ScarfMonBackend (Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMon.swift install(_:)) installed from the macOS app, composed with existing backends — emits perf_measure {category, duration_bucket} ONLY for over-budget/thresholded measures; define per-category thresholds. Add bootstrap_task_failed {task: skills|slash_commands|env_mirror} in the scarfApp.init detached tasks that currently swallow errors into Logger.warning. Backend lives in the macOS app target (ScarfCore gains no Stats dependency). Acceptance: build + unit test proving a slow measure emits exactly one event and a fast one none; fresh-eye audit.

## Plan



## Artifacts



