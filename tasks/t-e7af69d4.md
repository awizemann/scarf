---
id: t-e7af69d4
title: Surface image_gen.provider (incl. new meta-ai backend)
status: todo
added: 2026-09-08
priority: low
---

## Description

Split out of Phase 6 of the v0.21.1 parity plan (t-eefcfa4e) to avoid widening its scope.

Scarf's Auxiliary tab has an `image_gen.model` picker but NO `image_gen.provider` picker. Consequence: the model picker is FAL-only in effect — `tools/image_generation_tool.py:191` reads `image_gen.model` for the FAL pipeline, while every other backend reads its own `image_gen.<provider>.model` (e.g. `plugins/image_gen/xai/__init__.py:120` `load_image_gen_config("xai").get("model")`). A user on a non-FAL backend has no way to pick either the backend or its model.

Work:
- Add `imageGenProvider` to HermesConfig + `HermesConfig+YAML` (`str("image_gen.provider", default: "")`) and a `setImageGenProvider` setter, mirroring `imageGenModel` exactly.
- Add a picker row on AuxiliaryTab. Backends at v2026.9.7 (`plugins/image_gen/`): fal, openai, openai-codex, openrouter, xai, krea, deepinfra, meta-ai.
- GATES REQUIRED (floors established by walking every tag, do not trust this list without re-checking):
  * `meta-ai` is NEW at v2026.9.7 (v0.21.1) — needs a capability flag; nothing existing covers it.
  * `deepinfra` first appears at v2026.7.20 — needs its own floor since Scarf supports Hermes back to v0.6.
  * fal/krea/openai/openai-codex/openrouter/xai exist at every tag Scarf supports.
- An unset provider keeps Hermes's in-tree FAL fallback (`image_generation_tool.py:168-177`), so "" must mean "write no key", not "fal".

Files: scarf/scarf/Features/Settings/Views/Tabs/AuxiliaryTab.swift:330, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift:657, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift:619, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift

## Plan



## Artifacts



