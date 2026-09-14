---
id: t-aud09
title: **[t-aud09]** Cron decode corruption surfaced — DONE. Added additive `HermesFileService.loadCronJobsOutcome() -> (jobs:, decodeFailed:)` (no ripple to the 9 `loadCronJobs()` callers; `loadCronJobs()` now delegates to it). `CronViewModel` gained `loadDecodeFailed`, set from the outcome; `CronView.emptyJobs` shows a warning triangle + "Its jobs.json couldn't be parsed and may be corrupt." instead of "No cron jobs yet" when decode fails. (Logging part already done in t-aud04.) Verified: macOS BUILD SUCCEEDED, no new warnings.
status: archived
---

## Description



## Plan



## Artifacts



