---
id: t-c9895ecb
title: Test the security-audit exit-0-with-advisories label end to end
status: todo
added: 2026-09-10
priority: low
---

## Description

P21 fixed `HealthViewModel.runAudit()`'s `.clean` arm to label the exit-0-with-advisories case distinctly (`scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift:775-800`), driven by the new `HermesSecurityAuditReport.parse` (`scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift`, end of file).

The PARSER is pinned by `HermesCLIVerdictP21Tests.exitZeroWithHighSeverityAdvisoriesIsNotAnEmptyReport` etc., but the VIEW-MODEL branch that consumes it has no test: `HealthViewModel` calls `fileService.runHermesCLI(...)` directly and has no injectable CLI seam (unlike `PluginsViewModel`, which took `HermesCLIRunner` in P11). So reverting the `if report.findingCount > 0` branch in `runAudit()` would leave every test green.

Work: give `HealthViewModel` the same optional `cliRunner: HermesCLIRunner` init parameter `PluginsViewModel` has (`scarf/scarf/Core/Models/HermesCLIRunner.swift`) and add a Mac-target test that feeds a verbatim `_render_human` report with HIGH/MODERATE findings at exit 0 and asserts `auditMessage` names the findings rather than reading as clean. Several other Health actions (`debug share`, `sessions optimize`) would become testable by the same seam.

## Plan



## Artifacts



