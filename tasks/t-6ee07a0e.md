---
id: t-6ee07a0e
title: Real project move flow (re-home a hand-moved project)
status: todo
added: 2026-09-04
---

## Description

Deferred from D2 (t-a2c169f0), audit "no real move flow (hand-move bricks Upgrade, doctor silent)".

D2 delivered the MINIMUM the brief asked for: the doctor is no longer silent. `ProjectDoctorFinding.Kind.recordPathDivergence` (high, report-only) fires when `<root>/.scarf/project.json` declares a `rootPath` other than the folder it was found in, and its detail distinguishes the two causes — the declared path still exists (a COPY) versus it is gone (a MOVE) — and says plainly that updates and template actions will target the old path until it is resolved.

What is still missing is the repair. It was deliberately not built: every writer underneath addresses a project by `record.rootPath`, so a wrong guess rewrites a project the user never touched. The two cases need different answers and both need user intent:
- MOVE (old path gone): rewrite `record.rootPath` to the folder the record was found in, re-point the registry row, and re-tag the project's `[proj:<uuid>]` cron jobs' `workdir`.
- COPY (old path present): the copy is a NEW project and needs a fresh identity — deriving one detaches it from the original's cron jobs and grants, which is the correct outcome but must be said out loud.

Suggested scope: a "This project moved" sheet reachable from the doctor finding, offering the two named outcomes; cron `workdir` re-pointing verified against the tagged Hermes argparse (charter C5) before shipping; tests for both branches plus the case where BOTH paths hold a record.

## Plan



## Artifacts



