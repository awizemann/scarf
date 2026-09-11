---
id: t-63ffcac4
title: Accept "forever"/"once" in the cron Repeat field
status: todo
added: 2026-09-10
priority: low
---

## Description

Found during P18. `cron edit --repeat` / `cron create --repeat` are `type=int` in argparse (`hermes_cli/subcommands/cron.py:38,97` at v2026.9.7), so a user typing `forever` or `once` into the Cron editor's Repeat field makes argparse exit 2 and fails the WHOLE edit with "invalid int value".

Hermes's own `normalize_repeat_value` (`cron/jobs.py:591-617`) accepts those words — but only on the tool/API path, never through the CLI's argparse. Scarf's read side already ports the whole vocabulary (`HermesCronJob.normalizeRepeatValue`), so the write side is the asymmetric half.

Fix: in `CronViewModel.repeatEditArguments` / the create path (`scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift`), map the forever-family (`forever`/`infinite`/`inf`/`none`) to `0` and the once-family (`once`/`one`/`1x`) to `1` before emitting, mirroring `normalize_repeat_value`; leave anything else alone so Hermes's error still surfaces rather than Scarf inventing a value. Ungated (the fold is v0.4.0, below the v0.6.0 floor). Add cases to `scarf/scarfTests/CronP18ClearGestureTests.swift`.

Deliberately out of scope for P18, which fixed only the empty-field gesture.

## Plan



## Artifacts



