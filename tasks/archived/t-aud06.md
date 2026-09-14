---
id: t-aud06
title: **[t-aud06]** ⌘, Settings command — ADDED. New `AppCoordinatorFocusedValueKey` / `FocusedValues.appCoordinator`; `ContentBoundRoot` publishes its coordinator via `.focusedValue`; `CommandGroup(replacing: .appSettings)` hosts `OpenSettingsCommand` (`Button "Settings…" .keyboardShortcut(",", .command)`) that sets the focused window's `selectedSection = .settings` (disabled when no Scarf window focused). Routed through the focused window because settings is an in-window sidebar section, not a separate Settings scene. Verified: macOS BUILD SUCCEEDED, no new warnings; menu behavior to be confirmed at runtime.
status: archived
---

## Description



## Plan



## Artifacts



