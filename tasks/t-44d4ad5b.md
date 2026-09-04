---
id: t-44d4ad5b
title: Projects AX: accessibility batch for projects surfaces
status: todo
added: 2026-09-03
---

## Description

From the P7 accessibility audit (documents/reports/2026-09-03-projects-full-surface-audit.md; app has a real a11y baseline — fix regressions first). (1) Announce registry damage + repair completion via AccessibilityNotification (RegistryDamageBanner, ProjectDoctorSheet:222-245) and manage focus after Repair All. (2) Doctor finding severity into the combined label/value (ProjectDoctorSheet:163-200 — copy the StatusGridCellView pattern). (3) Charts: axis names + per-mark labels/chartDescriptor; pie needs value labels (ChartWidgetView). (4) Sparkline accessibility value + trend summary; group StatWidgetView (children:.combine). (5) Kanban statusDot: shape/text channel + VO value (KanbanSummaryWidgetView:87-98). (6) Label sidebar icon buttons (add/archived/remove/clear-filter — ProjectsSidebar:240-262,85-93). (7) Table widget header semantics (.isHeader / row grouping). (8) @ScaledMetric for widget fixed sizes; lift 9pt hard fonts. (9) Log tail grouping + full-content access; mini-app WebView container label + inspector focus management; inline sheet validation announcements. Include the contrast pass note (warning.opacity(0.14) backgrounds, accentActive-on-accentTint).

## Plan



## Artifacts



