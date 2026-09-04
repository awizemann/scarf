---
id: t-44d4ad5b
title: Projects AX: accessibility batch for projects surfaces
status: done
added: 2026-09-03
---

## Description

From the P7 accessibility audit (documents/reports/2026-09-03-projects-full-surface-audit.md; app has a real a11y baseline — fix regressions first). (1) Announce registry damage + repair completion via AccessibilityNotification (RegistryDamageBanner, ProjectDoctorSheet:222-245) and manage focus after Repair All. (2) Doctor finding severity into the combined label/value (ProjectDoctorSheet:163-200 — copy the StatusGridCellView pattern). (3) Charts: axis names + per-mark labels/chartDescriptor; pie needs value labels (ChartWidgetView). (4) Sparkline accessibility value + trend summary; group StatWidgetView (children:.combine). (5) Kanban statusDot: shape/text channel + VO value (KanbanSummaryWidgetView:87-98). (6) Label sidebar icon buttons (add/archived/remove/clear-filter — ProjectsSidebar:240-262,85-93). (7) Table widget header semantics (.isHeader / row grouping). (8) @ScaledMetric for widget fixed sizes; lift 9pt hard fonts. (9) Log tail grouping + full-content access; mini-app WebView container label + inspector focus management; inline sheet validation announcements. Include the contrast pass note (warning.opacity(0.14) backgrounds, accentActive-on-accentTint).

## Plan

Fixed all 12 AX findings in Projects surfaces. HIGH: (1) AccessibilityNotification.Announcement added for registry-damage banner appearance and doctor repair completion (RegistryDamageBanner.swift, ProjectDoctorSheet.swift) — first use of this API anywhere in the app. (2) Doctor finding severity now in .accessibilityValue alongside the existing combined title/detail/path label, matching StatusGridCellView's pattern. (3) ChartWidgetView conforms to AXChartDescriptorRepresentable (per-mark values) plus a plain-text summary value; pie chart now has non-color accessible content. (4) SparklineView gets a spoken trend value; StatWidgetView groups title/value/subtitle/sparkline via .accessibilityElement(children:.combine). (5) Kanban status dot now varies by SF Symbol shape (not just color) and the row carries a spoken status value. MEDIUM: (6) Sidebar add/archive-toggle/remove/clear-filter buttons get .accessibilityLabel. (7) TableWidgetView marks header cells .isHeader and labels each data cell "column: value". (8) @ScaledMetric added to StatusGridWidgetView's cell and Kanban's initials badge, replacing hardcoded 9pt/16-18pt sizes. (9) ProjectDoctorSheet restores @AccessibilityFocusState onto the status line after Repair All, with a guard against double-announcing. LOW: (10) LogTailWidgetView groups lines via .accessibilityElement(children:.contain) with a full-tail container value, keeping untruncated per-line labels. (11) MiniAppHostView's WKWebView gets setAccessibilityLabel (AppKit bridge — SwiftUI's modifier doesn't reach it); MiniAppInspectorSurface gets .isModal + sortPriority for VoiceOver while staying mouse/keyboard-non-modal by design. (12) NewProjectSheet's inline validation error posts an AccessibilityNotification.Announcement on appearance (kept inline rather than converting to .alert, to avoid interrupting the open form).

Build: xcodebuild Debug via private derivedData succeeded (BUILD SUCCEEDED) after fixing two AttributedString-vs-Text compile errors in the initial announcement calls. No existing accessibility unit tests exist for these views to extend — none added.

Self-audit: VO reading order stays name-first/state-after; no new hardcoded colors (ScarfColor throughout, dark-mode safe); AccessibilityNotification needed AttributedString not Text (caught by build). Deferred: did not restructure NewProjectSheet's inline error into a native .alert (bigger behavior change, more test risk) — used an announcement instead.

Memory: extended existing scarf/conventions/macos-accessibility-label-conventions note (searched first, no fork) with 10 new observations: announcements, severity-in-value, non-color status channels, chart descriptors, sparkline/stat grouping, ScaledMetric, table header semantics, log-tail grouping, WKWebView AX labels, non-modal-but-VO-modal panels.

Files touched (all UI view files only): scarf/scarf/Features/Projects/Views/RegistryDamageBanner.swift, ProjectDoctorSheet.swift, ProjectsSidebar.swift, NewProjectSheet.swift, Widgets/ChartWidgetView.swift, Widgets/StatWidgetView.swift, Widgets/KanbanSummaryWidgetView.swift, Widgets/TableWidgetView.swift, Widgets/StatusGridWidgetView.swift, Widgets/LogTailWidgetView.swift, MiniApp/MiniAppHostView.swift, MiniApp/MiniAppInspectorSurface.swift.

## Artifacts



