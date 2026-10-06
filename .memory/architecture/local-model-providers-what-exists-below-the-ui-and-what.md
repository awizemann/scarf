---
title: Local model providers — what exists below the UI and what filters them out
type: note
permalink: scarf/architecture/local-model-providers-what-exists-below-the-ui-and-what
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/LocalModelProviders.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesRoutableProviders.swift]
source_paths_inferred: false
source_sha: 3b042718fac93b0021f7dccf7f75ed4530b394ef
created: 2026-07-13
updated: 2026-09-27
reviewed: 2026-10-06
reviewed_by: audit:claude-code (background)
---

Investigation 2026-07-13 (pre-design for the local/remote model toggle). Source-verified against main @ v2.16.2. Updated 2026-09-01 and re-grounded 2026-09-10 to correct line number drift and expand scope. **Updated 2026-09-26** to reflect capability-gated provider visibility (v0.21.4+). **Updated 2026-09-29** to add routable provider filtering layer (ccaa817b+).

## Observations
- [fact] Hermes accepts local providers TODAY via aliases Scarf already mirrors (ModelCatalogService.swift: provider alias mappings include `ollama`→`custom`, `vllm`/`llamacpp`/`llama.cpp`→`local`, `lm-studio`→`lmstudio`). Writing `model.provider: ollama` is valid Hermes config; Scarf canonicalizes only for validation. #providers
- [fact] Provider visibility pipeline (ModelCatalogService.loadProviders:140+) is now filtered on THREE axes: (1) capability gates like `hasOpenCodeFreeProvider` and `hasChatGPTCodexAliases`; (2) routable-provider filtering via `HermesRoutableProviders.isRoutable()` that limits what Hermes can actually route at each version; (3) legacy overlay tables for removed providers like `opencode-free`. A provider appears in pickers iff it is in `~/.hermes/models_dev_cache.json` AND `HermesRoutableProviders.isRoutable(id, capabilities)` is not false, OR in `overlayOnlyProviders` AND routable, OR (for pre-0.21.4 hosts) in `legacyOverlayOnlyProviders` when `capabilities.hasOpenCodeFreeProvider` is true. Routable-provider banding (HermesRoutableProviders.swift:94+) is frozen per Hermes version back to v0.6; older or undetected hosts bypass filtering and get the full list. #pipeline #routable
- [fact] Cache status on this machine: `lmstudio` present (3 models — VISIBLE in pickers today, buried alphabetically), `ollama-cloud` present (43 models, cloud only). Bare `ollama`, `custom`, `local`, `vllm`, `llamacpp` ABSENT from cache and overlays → invisible. #cache
- [fact] The hidden working path: ModelPickerSheet's "Custom…" mode (ModelPickerSheet.swift:263,504) takes free-form provider+model IDs — typing provider `ollama` works end-to-end today; nothing surfaces or documents it. #ui
- [fact] Fail-safes already in place for local: `validateModel` treats any model ID as provisionally valid for overlay-only providers with no models; ModelPreflight mismatch banner skips `custom`/`custom:*` (Hermes is_aggregator providers.py:492, never-second-guess rule #48305 — see [[Aggregator providers must skip the model/provider mismatch preflight]]). AuthType `.virtual` (moa precedent) renders "No credentials needed". The validation now also respects capabilities so that removed providers fail gracefully on newer Hermes versions. #failsafe
- [constraint] Do NOT add `custom`/`local` to `overlayOnlyProviders` to surface them: scripts/check-hermes-tables.py lane 3 FAILS for any Scarf overlay key not in Hermes HERMES_OVERLAYS. Local surfacing must be a UI-level grouping, not new provider-table entries. #constraint
- [fact] base_url: config parser knows `auxiliary.<task>.base_url` (HermesConfig+YAML.swift); LM Studio default `http://127.0.0.1:1234/v1` with `LM_BASE_URL` env override baked into the (dormant) overlay.
- [gotcha] From v0.21.1 (v2026.9.7) `model.provider: llamacpp` IGNORES `model.base_url` at runtime (`runtime_provider_custom.py:537-540` @ v2026.9.24) — Scarf writes `model.provider: custom` for its llama.cpp row on v0.21.1+ instead. See [[Local provider config keys — Hermes reader-verified (v0.17.0)]] for the full mechanism. #llamacpp #v0.21.1 A PRIMARY-model base_url editor needs Hermes-reader verification first — per the v0.18 gotcha, `hermes config set` accepts any key with zero validation (how web_tools.* stayed dead for five cycles). #gotcha
- [fact] "Local" in Scarf's multi-server world means local to the HERMES HOST, not the Mac — an Ollama on a remote server is reachable via the existing transport (e.g. `ollama list` / GET :11434/api/tags through runProcess) for live model enumeration. #design
- [fact] HermesProxy is NOT a local-model path — it attaches upstream OAuth credentials (nous adapter); unrelated. Model entry points inventory (12 surfaces): Settings General ModelPickerRow, Auxiliary per-task, chat preflight sheet, mismatch banner, chat model badge/preset switcher (ACP session/set_model), Proxy picker, Credential Pools, platform setup, ModelPresetsView, project manifest binding, iOS read-only, SessionInfoBar chip. #inventory

## Relations
- relates_to [[Aggregator providers must skip the model/provider mismatch preflight]]
- relates_to [[Hermes v0.18 Compatibility Decisions]]
- relates_to [[Hermes v0.16 Compatibility Decisions]]
