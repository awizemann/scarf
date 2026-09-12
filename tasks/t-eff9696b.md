---
id: t-eff9696b
title: Audit P33: prove the config.yaml read in platform-setup forms; writeChain for direct-YAML saves
status: done
added: 2026-09-10
priority: high
---

## Description

Round-3 whole-surface audit (`documents/hermes-v0.21.1-whole-surface-audit-round3.md`, concurrency/forms section). Needs product decision (forms write the resolved default vs Settings' sentinel posture) from the report.

- HIGH · PRE (newly visible after P22) · `PlatformSetupHelpers.loadForm` proves the `.env` read (`loadProven`, `:37-43`) but takes the tolerant config read (`loadConfig()` → `.empty` on unreadable, `:198`; `readText(…) ?? ""`, `:201`). `WhatsAppCloudSetupViewModel` is config-only (`:50-51`, `whatsappCloud` non-optional), so one blipped read + Save writes ten empty `config set` pairs incl. `extra.access_token`/`app_secret`/`verify_token` and `enabled: false` (`:86-98`) with no message (GW-F6 through the other half). Same shape in `SignalSetupViewModel.swift:60` and `EmailSetupViewModel`'s `rawConfigText ?? ""`. `loadConfigResult()` (`HermesFileService.swift:50`) exists and is unused here. Fix: `FormSnapshot.configFailure`, surface like `envFailure`, `commitSave` refuses when unproven.
- MED · PRE · `SettingsViewModel.saveDirectYAML` (`:1012-1085`; `agent.reasoning_overrides`, `model_catalog.excluded_providers`, `profile_routes`) never joins `writeChain`; `runConfigMigrate` does (`:1143-1165`). A toggle during a direct-YAML save can be lost.
- LOW · `GatewayBehaviorViewModel.save()` has no `HermesCLIRunner` seam and `load()` no `!isBusy` guard (`:68-72,190-192`) — fold in t-fc76a90d.
- LOW · "Reload" buttons on all 15 setup views are not disabled while busy; `loadSnapshot`'s guard swallows the press silently (`PlatformSetupHelpers.swift:267`).
- LOW · `HealthViewModel.swift` three ad-hoc `runHermes` calls without a named timeout were fixed in P29; three ad-hoc `Process` spawns outside the diff still use unbounded `waitUntilExit()` and read stderr after the wait: `ProjectTemplateService.swift:414`, `ProjectTemplateExporter.swift:364`, `AppRelauncher.swift:82`.
- LOW · `MCPLoginController.finish()` leaves a pre-publish run's `readabilityHandler` installed until EOF (benign, `:451`).
- LOW · `SessionsViewModel.runHermes` (`:1047-1050`) has zero callers and is MainActor-isolated — delete.

## Plan



## Artifacts

Commits on `fix/whole-surface-audit-r3`:
- `0e64b7fe` fix(p33): prove the config.yaml read in all 15 platform-setup forms
- `30616b14` fix(p33): put `saveDirectYAML` on Settings' serialised write chain
- `871ced40` fix(p33): bound the last three ad-hoc Process spawns (C10), drop dead code

SHIPPED
- HIGH: `HermesFileService.loadConfigProven()` / `ProvenConfig` / `LoadRefusal` (built on `GuardedTextFile.load`, NOT on `loadConfigResult()` — that cannot tell absent from unreadable and judges on one read); `FormSnapshot.configFailure` + `loadFailure`; `PlatformSetupForm.loadRefusal` latched by `loadSnapshot` and refused by `commitSave`; a refused read leaves `config`/`rawConfigText` nil so a form's `apply` does not reset fields. Covers all 15 setup VMs through the one shared choreography.
- Product decision 9 documented on `PlatformSetupForm` + memory note `scarf/decisions/setup-forms-write-the-resolved-default-settings-treats`. No behaviour change.
- MED: `saveDirectYAML` joins `writeChain` like `runConfigMigrate`; body split to `performDirectYAMLSave`.
- LOW: `Process.waitDraining(timeout:pipes:)` (Health's shape hoisted) adopted by `ProjectTemplateService` (unzip, 120s), `ProjectTemplateExporter` (zip, 120s), `AppRelauncher` (open -n, 20s) — bounded wait AND concurrent drain, read ends closed by their own reader.
- LOW: dead `SessionsViewModel.runHermes` deleted.

Tests: `scarfTests/ConfigReadProofP33Tests` (6). 5 of 6 watched fail before the fix (12 issues) with the three source files stashed; `aFormOnAnAbsentConfigYamlStillSaves` passes on both sides deliberately as the anti-over-fix clamp.

NOT SHIPPED (deliberate)
- The 15 "Reload" buttons are ALREADY `.disabled(viewModel.isBusy)` — checked all fifteen views. The round-3 LOW is stale.
- `MCPLoginController.finish()`'s `readabilityHandler` LOW is a false positive: `finish` is reachable only from `pump`, which fires only after `sawEOF`, which is set in the handler's own empty-data branch immediately after it has already cleared itself.
- `GatewayBehaviorViewModel` seam left to `t-fc76a90d`.
- `AppRelauncher.relaunch()` is now bounded but still waits ON the main actor; the hop needs `ProfilesViewModel.switchAndRelaunch`'s `MainActor.run` restructured → filed as `t-b15ba4c3`.

