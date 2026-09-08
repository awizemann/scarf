---
id: t-09bd3af5
title: GW follow-ups: skill-load spinner, iOS SkillEditorSheet dismiss-on-failure, manifest-repair notice
status: done
added: 2026-09-07
priority: low
---

## Description

Residuals from the GW-F wave close-out (2026-09-04, commits 4aabf5c2..10c3475f): (1) SkillsView/SkillDetailView render no "reading…" affordance while isLoadingContent (Edit is correctly disabled); (2) iOS SkillEditorSheet dismisses on Save regardless of outcome (pre-existing); (3) GW-F6's manifest.json wrong-shape repair is silent-but-logged — consider surfacing "manifest was reshaped"; (4) narrowed-not-closed L1: non-ENOENT read failure + failed stat over one SSH channel still reports absent (documented in place).

## Plan



## Artifacts



