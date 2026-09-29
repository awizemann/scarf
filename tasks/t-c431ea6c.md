---
id: t-c431ea6c
title: Flaky/failing Mac UI tests: Kanban, Cron, SectionSweep, ModelPreset
status: todo
added: 2026-09-29
---

## Description

Root cause (2026-09-29): all four failures (SectionSweep.testEverySectionRenders, ConfigJourney.testModelPresetCreateAndDeleteWritesPresetStore, CronKanban Kanban card + Cron job) come from macOS window tiling squeezing Scarf to ~1492x890 instead of the pinned 1800x1300 (seen in the run's screen recording). Harness fix in commit 334b1bd2 (branch merge/p1-146): launchAndSurface fails up front with the real cause under 1500x1200; revealSidebarRow scrolls the new sidebar.nav ScrollView and requires the row inside its frame; ConfigJourney.openSection reveals before clicking. Compiled, NOT run. Verify during 3.5.0 release testing with tiling off for Scarf.

## Plan



## Artifacts



