---
title: Which Scarf surface writes which config file (Skills, Models, Settings)
type: note
permalink: scarf/architecture/which-scarf-surface-writes-which-config-file-skills-models
tags: [settings, models, skills, config, testing]
source_paths: [scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift, scarf/scarf/Features/Models/Views/ModelPresetsView.swift, scarf/scarf/Features/Skills/Views/SkillsView.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SkillsScanner.swift]
source_paths_inferred: false
source_sha: 479886cf715072b2f386431c01089bbd3e560510
created: 2026-09-08
updated: 2026-09-10
reviewed: 2026-09-11
reviewed_by: claude-opus-5
---

Established while writing the P2c UI journeys (t-877c6e6f, 2026-09-08), because the obvious mental model is wrong in two places and a test written to it asserts against a file the surface never touches.

Verified by driving the real app against an isolated Hermes home and reading the files back.

## Observations
- [fact] The Models SECTION does NOT write config.yaml. It is CRUD over Scarf's own preset catalog at `<home>/scarf/model_presets.json` (`ModelPresetService`); presets are a per-project overlay applied over ACP `session/set_model`, not a global default. Asserting config.yaml against it is a category error #models
- [fact] Switching the ACTIVE model is Settings → General → Model: `applyModelPickerSelection` → `LocalModelConfigPlan` → `hermes config set`, writing `model.default` and `model.provider` (NOT `model.name`) into `<home>/config.yaml`. The two always move together — a provider left behind routes chats to the wrong endpoint #settings
- [fact] `~/.hermes/skills/` is `<category>/<skill>`, not a flat list: the fixture's `hermes skills repair-official openhue` lands at `skills/smart-home/openhue`. `smart-home` is the category the Skills list renders as a section header; `openhue` is the skill. `SkillsScanner` builds `HermesSkill.id` as `"<category>/<name>"` while `name` is the bare name #skills
- [gotcha] Scarf's Skills → Uninstall passes `skill.id` (`<category>/<name>`) to a CLI that accepts only the BARE name, and the CLI's rejection EXITS 0 — so `finishUninstall` reported success and nothing was removed. Verified against v0.21; FIXED 2026-09-08 (t-ec6d2e6d): the view passes the bare name and `uninstallSucceeded(exitCode:output:)` treats an `Error:` line as failure. `skills uninstall --yes` arrives at v0.20.5 (v2026.8.19), not v0.21 — `SkillsViewModel.swift:667` carries the floor — so the stdin "y" confirmation stays as the pre-0.20.5 fallback #skills #gotcha
- [convention] The Settings persistence journey uses `timezone` specifically because it lives in config.yaml. `SCARF_HERMES_HOME` does not isolate `UserDefaults`, so a UserDefaults-backed setting both pollutes the developer's own preferences and "persists" for a reason unrelated to the home under test #testing

## Relations
- relates_to [[Model Presets Feature]]
- relates_to [[Seeding a Hermes home through the CLI (v0.21) — verbs that work and traps]]
- relates_to [[UI-test fixture home builder (make-ui-fixture.sh) contract]]
