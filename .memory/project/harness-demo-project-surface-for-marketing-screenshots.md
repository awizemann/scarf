---
title: Harness demo project surface for marketing screenshots
type: note
permalink: scarf/project/harness-demo-project-surface-for-marketing-screenshots
source_paths: [documents/demo-shoot/p1-recon-brief.md, documents/demo-shoot/p5-capture-guide.md]
source_paths_inferred: false
source_sha: 951ac39575c173950a1b989b29d5d689b19616ae
created: 2026-08-13
updated: 2026-08-13
---

## Observations
- [fact] ~/Developer/harness is the demo project for Scarf marketing screenshots (built 2026-08-13, four commits on harness main starting e78bd83, not pushed): .scarf/dashboard.json (real metrics: v0.7.0, 303 @Test / 58 suites, 8 releases), .scarf/miniapps/run-user-test/ (v1 bridge: prompt/events/store), .scarf/manifest.json pinning kanbanTenant scarf:harness.
- [fact] Live ~/.hermes seeded additively (Alan-approved): harness registered with uuid CCA5399F-831D-439A-97AC-88EBF20FC063 and Scarf with CDD496D4-EF55-404F-82F8-88883E85402E in scarf/projects.json; 6 kanban cards under tenant scarf:harness; 2 cron jobs prefixed [proj:CCA5399F-…] both PAUSED (nightly user-test suite, weekly issue triage). Backups of pre-seed projects.json/jobs.json were taken in the session scratchpad (ephemeral).
- [gotcha] Hermes v0.20.0 kanban CLI: `kanban create --initial-status` is silently ignored (use `claim` to reach running); `kanban block <id> <reason>` rejects its reason argument — upstream bug worth filing; no CLI path to `review` status.
- [fact] Capture guide for the shoot lives at documents/demo-shoot/p5-capture-guide.md (shot list, dimensions, session script); recon brief at documents/demo-shoot/p1-recon-brief.md. docs/DASHBOARD_SCHEMA.md is stale — 5 live widget types undocumented (markdown_file, log_tail, cron_status, status_grid, sparkline on stat).
- [todo] After the shoot: decide whether the seeded kanban/cron demo data stays or gets cleaned up; file the Hermes kanban CLI bug; update DASHBOARD_SCHEMA.md.

## Relations
- relates_to [[README and docs marketing structure convention]]
- relates_to [[Project Templates (.scarftemplate)]]
