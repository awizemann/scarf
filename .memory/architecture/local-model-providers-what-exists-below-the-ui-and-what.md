---
title: Local model providers — what exists below the UI and what filters them out
type: note
permalink: scarf/architecture/local-model-providers-what-exists-below-the-ui-and-what
created: 2026-07-13
updated: 2026-07-13
source_sha: 1d075b7d4c3e8904c9eeaed03de35d70db6b0d72
source_paths: scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/LocalModelProviders.swift
source_paths_inferred: false
reviewed: 2026-07-14
reviewed_by: claude-opus-4-8
---

Investigation 2026-07-13 (pre-design for the local/remote model toggle). Source-verified against main @ v2.16.2.

## Observations
- [fact] Hermes accepts local providers TODAY via aliases Scarf already mirrors (ModelCatalogService.swift:810-817): `ollama`→`custom`, `vllm`/`llamacpp`/`llama.cpp`→`local`, `lm-studio`→`lmstudio`. Writing `model.provider: ollama` is valid Hermes config; Scarf canonicalizes only for validation. #providers
- [fact] Provider visibility pipeline (ModelCatalogService.loadProviders, :132-176): a provider appears in pickers iff it is in `~/.hermes/models_dev_cache.json` OR `overlayOnlyProviders`. There is NO deliberate hiding of local providers — absence from both tables is the sole filter. `demotedProviders` is empty; nothing demotes local. #pipeline
- [fact] Cache status on this machine: `lmstudio` present (3 models — VISIBLE in pickers today, buried alphabetically), `ollama-cloud` present (43 models, cloud only). Bare `ollama`, `custom`, `local`, `vllm`, `llamacpp` ABSENT from cache and overlays → invisible. #cache
- [fact] The hidden working path: ModelPickerSheet's "Custom…" mode (ModelPickerSheet.swift:32-36,164) takes free-form provider+model IDs — typing provider `ollama` works end-to-end today; nothing surfaces or documents it. #ui
- [fact] Fail-safes already in place for local: `validateModel` treats any model ID as provisionally valid for overlay-only providers with no models; ModelPreflight mismatch banner skips `custom`/`custom:*` (Hermes is_aggregator providers.py:492, never-second-guess rule #48305 — see [[Aggregator providers must skip the model/provider mismatch preflight]]). AuthType `.virtual` (moa precedent) renders "No credentials needed". #failsafe
- [constraint] Do NOT add `custom`/`local` to `overlayOnlyProviders` to surface them: scripts/check-hermes-tables.py lane 3 FAILS for any Scarf overlay key not in Hermes HERMES_OVERLAYS. Local surfacing must be a UI-level grouping, not new provider-table entries. #constraint
- [fact] base_url: config parser knows `auxiliary.<task>.base_url` (HermesConfig+YAML.swift:119-120); LM Studio default `http://127.0.0.1:1234/v1` with `LM_BASE_URL` env override baked into the (dormant) overlay. A PRIMARY-model base_url editor needs Hermes-reader verification first — per the v0.18 gotcha, `hermes config set` accepts any key with zero validation (how web_tools.* stayed dead for five cycles). #gotcha
- [fact] "Local" in Scarf's multi-server world means local to the HERMES HOST, not the Mac — an Ollama on a remote server is reachable via the existing transport (e.g. `ollama list` / GET :11434/api/tags through runProcess) for live model enumeration. #design
- [fact] HermesProxy is NOT a local-model path — it attaches upstream OAuth credentials (nous adapter); unrelated. Model entry points inventory (12 surfaces): Settings General ModelPickerRow, Auxiliary per-task, chat preflight sheet, mismatch banner, chat model badge/preset switcher (ACP session/set_model), Proxy picker, Credential Pools, platform setup, ModelPresetsView, project manifest binding, iOS read-only, SessionInfoBar chip. #inventory

## Relations
- relates_to [[Aggregator providers must skip the model/provider mismatch preflight]]
- relates_to [[Hermes v0.18 Compatibility Decisions]]
- relates_to [[Hermes v0.16 Compatibility Decisions]]
