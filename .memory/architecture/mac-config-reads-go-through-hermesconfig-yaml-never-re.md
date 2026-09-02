---
title: Mac config reads go through HermesConfig(yaml:) — never re-duplicate the parser
type: note
permalink: scarf/architecture/mac-config-reads-go-through-hermesconfig-yaml-never-re
tags: [settings, config-parsing, drift]
source_paths: [scarf/scarf/Core/Services/HermesFileService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift]
source_paths_inferred: false
source_sha: 9f427585f8ab2fff3fae17c157496506c52ab319
created: 2026-07-14
updated: 2026-07-14
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

Alan's 2026-07-14 bug report ("settings drop downs are saving but not showing selected") was parser drift, not a save failure: SettingsViewModel.setSetting reloads config after every `hermes config set`, but the Mac app read config through a 360-line duplicate of ScarfCore's parser that had missed every v0.17/v0.18 key addition, so the reloaded struct snapped those fields back to defaults and PickerRow rendered a blank selection. Most visible surface: Web Tools tab search/extract backend dropdowns.

## Observations
- [fact] HermesFileService.loadConfig/loadConfigResult route through ScarfCore's HermesConfig(yaml:) — the app's duplicated parseConfig was deleted in 3e0184d #settings #parsing
- [gotcha] The old Mac-side parseConfig duplicate drifted: v0.17/v0.18 keys (web.*, curator.consolidate, max_concurrent_sessions, image_gen.model, openrouter.response_cache, display.timestamps, docker_extra_args, telegram extras, whatsapp_cloud) were added only to ScarfCore, so Settings dropdowns saved values the Mac reload never showed #drift
- [convention] New config keys are added ONLY in ScarfCore (HermesConfig model + HermesConfig+YAML parser); the Mac app must never grow its own key->field mapping #convention
- [fact] HermesFileService.parseNestedYAML/stripYAMLQuotes are now thin delegates to HermesYAML with ParsedYAML type-aliased to ScarfCore's, keeping the 5 app features (Plugins, QuickCommands, Personalities, EmailSetup, CredentialPools) on the canonical raw-YAML parser #parsing
- [fact] HermesFileServiceConfigParityTests (scarfTests) pins the drifted key set + save-then-reload flow; it fails if an app-side mapping ever reappears #tests


## Drift-audit systemic finding (2026-07-14)
- [fact] A full app-target-vs-ScarfCore duplication sweep confirmed the config parser was mostly a ONE-OFF, not a pervasive pattern: ACP wire encoding, path/home resolution (HermesPathSet/HermesProfileScope), capability gating (HermesCapabilities), ModelPreflight, and the YAML helpers (post-3e0184d) all have single owners with app-side delegation. Architecture is sound. #audit
- [gotcha] The DRIFT CLASS is: an app-target WRITE path (`SettingsViewModel.setSetting("x.y")`, 120 of them) paired with a ScarfCore READ path (`HermesConfig(yaml:)`) where key sets can silently diverge → saves-but-reloads-stale. The convention ("keys go in ScarfCore only") is DOCUMENTATION, not a gate; HermesFileServiceConfigParityTests is a fixed-fixture guard that does NOT enumerate the 120 writers. Enforcement fix = a DERIVED parity test (t-2d258871). #enforcement
- [gotcha] iOS `ChatView.confirmModelPreflight` is ALREADY divergent — writes model.provider/default raw, skipping LocalModelConfigPlan's clear-on-switch scrub → stale base_url routes iOS chat to wrong endpoint (GH#27132 class, the bug we fixed on Mac). Live on iOS, untracked until now → t-52f4564b. #ios-divergence

## Relations
- relates_to [[local-provider-config-keys-hermes-reader-verified-v0-17-0]]
