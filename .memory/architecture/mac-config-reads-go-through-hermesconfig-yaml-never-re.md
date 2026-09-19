---
title: Mac config reads go through HermesConfig(yaml:) — never re-duplicate the parser
type: note
permalink: scarf/architecture/mac-config-reads-go-through-hermesconfig-yaml-never-re
tags: [settings, config-parsing, drift]
source_paths: [scarf/scarf/Core/Services/HermesFileService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-07-14
updated: 2026-07-14
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [fact] HermesFileService.loadConfig/loadConfigResult route through ScarfCore's HermesConfig(yaml:) — the app's duplicated parseConfig was deleted in 3e0184d #settings #parsing
- [gotcha] The old Mac-side parseConfig duplicate drifted: v0.17/v0.18 keys (web.*, curator.consolidate, max_concurrent_sessions, image_gen.model, openrouter.response_cache, display.timestamps, docker_extra_args, telegram extras, whatsapp_cloud) were added only to ScarfCore, so Settings dropdowns saved values the Mac reload never showed #drift
- [convention] New config keys are added ONLY in ScarfCore (HermesConfig model + HermesConfig+YAML parser); the Mac app must never grow its own key->field mapping #convention
- [fact] HermesFileService.parseNestedYAML/stripYAMLQuotes are now thin delegates to HermesYAML with ParsedYAML type-aliased to ScarfCore's, keeping the 5 app features (Plugins, QuickCommands, Personalities, EmailSetup, CredentialPools) on the canonical raw-YAML parser #parsing
- [fact] HermesFileServiceConfigParityTests (scarfTests) pins the drifted key set + save-then-reload flow; it fails if an app-side mapping ever reappears #tests
- [fact] Shared keys reading now uses platform-aware bridge logic (P46): `gateway_restart_notification` routes through `sharedPlatformScalar` for slack/telegram to prevent unintended top-level config block creation on nested-only hosts — an active enforcement preventing the very drift this convention guards against #enforcement #shared-keys

## Drift-audit systemic finding (2026-07-14)
- [fact] A full app-target-vs-ScarfCore duplication sweep confirmed the config parser was mostly a ONE-OFF, not a pervasive pattern: ACP wire encoding, path/home resolution (HermesPathSet/HermesProfileScope), capability gating (HermesCapabilities), ModelPreflight, and the YAML helpers (post-3e0184d) all have single owners with app-side delegation. Architecture is sound. #audit
- [done] The DRIFT CLASS was: an app-target WRITE path (`SettingsViewModel.setSetting("x.y")`, 120 of them) paired with a ScarfCore READ path (`HermesConfig(yaml:)`) where key sets could silently diverge → saves-but-reloads-stale. Enforcement fix = a derived parity test (t-2d258871), implemented 2026-09-02 — now failing builds catch any new writes without matching readers. #enforcement
- [gotcha] iOS `ChatView.confirmModelPreflight` is ALREADY divergent — writes model.provider/default raw, skipping LocalModelConfigPlan's clear-on-switch scrub → stale base_url routes iOS chat to wrong endpoint (GH#27132 class, the bug we fixed on Mac). Live on iOS, untracked until now → t-52f4564b. #ios-divergence

## Relations
- relates_to [[local-provider-config-keys-hermes-reader-verified-v0-17-0]]
