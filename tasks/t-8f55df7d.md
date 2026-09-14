---
id: t-8f55df7d
title: Extend the managed-install read-only lock past Settings
status: todo
added: 2026-09-11
---

## Description

Found while shipping P39 (round-4 decision 1).

P39 added `HermesManagedInstall` + `HermesManagedInstallCache` (`scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesManagedInstall.swift`) — a once-per-home read of `$HERMES_HOME/.managed` mirroring `get_managed_system` (`hermes_cli/config.py:276-290` @ v2026.9.7) — and wired it into ONE surface: `SettingsView` renders read-only behind one banner, and `SettingsViewModel.enqueueConfigWrite` refuses locally.

## Panes closed

- **Settings** (Mac + the iOS mirror in `IOSSettingsViewModel`) — P39/P39b/P39c, `8f92f236` … `d4e4f6cf`.
- **Plugins** — **P47** (round-5 decision 1), `1e88ab3e` on `fix/whole-surface-audit-r5`. `PluginsViewModel` reads the probe on `load()`'s detached hop and renders one banner; `enable`/`disable` refuse locally, and the install sheet's "Enable after installing" toggle is locked with its BINDING reading `false` (a `.disabled` toggle keeps the value it held, and this one defaults to on). Scoped to ACTIVATION only: `cmd_install` / `cmd_update` / `cmd_remove` write the plugin DIRECTORY (`hermes_cli/plugins_cmd.py:740`, `:794-830`, `:887-898` @ v2026.9.7), which `is_managed()` never guards — the P39c "a lock scoped by 'does Hermes refuse it' must exclude what Hermes never sees" rule. The env-var-only fallthrough is `HermesPluginInstallOutcome.configWriteRefusal` (`managedRefusalAnchored` + `failureWins` before `parse`'s `enabled`). The **iOS** Plugins pane (`scarf/Scarf iOS/Plugins/PluginsView.swift`) has no mutation controls at all, so it needs no lock.

## Still open — panes with only the after-the-fact verdict

MCP servers, project-skills trust, the per-bot Agent surface, quick commands, personalities, credential-pool strategies and the fifteen platform-setup forms. On a managed host each of those still offers a control whose every click ends in the same refusal banner.

Shape (unchanged): hoist the probe to the place capabilities are pushed into view models (`HermesVersionCache`'s callers) so each pane reads one flag, and reuse the `managedBanner` view P39 added — `PluginsViewModel.managedBannerText` is now the second worked example, including how to scope the lock to the controls Hermes actually refuses. Keep the "one banner per surface, not per control" rule. A host without the marker file must stay byte-identical (charter C1), and an env-var-only (`HERMES_MANAGED`) managed host — invisible to Scarf's transport — must keep falling through to the marker.

## Plan



## Artifacts

P51 note (round-5, `c93c2287`): the fifteen platform-setup forms — named above as one of the still-open panes — now have a single shared pre-flight gate in `PlatformSetupForm.commitSave` (`scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift`), added for the control-character refusal. It already sits after the latched `loadRefusal` bounce and before `isSaving = true`, which is exactly where a managed-install refusal belongs for all fifteen at once. When this task's forms pane is picked up, that is the seam — one banner per surface still applies, and the lock must be scoped to what Hermes actually refuses (`set_config_value`'s managed arm, `hermes_cli/config.py:3450-3452` @ `v2026.9.7`), not to the `.env` half, which `HermesEnvService` writes through the transport and `is_managed()` never sees.

