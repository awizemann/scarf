---
title: Hermes routable provider table gates the model picker
type: note
permalink: scarf/architecture/hermes-routable-provider-table-gates-the-model-picker
tags: [providers, hermes-v0.21.5, blind-reaudit]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: 12018c8f8fa9d17404a94138589a6d39f7a61d97
created: 2026-09-27
updated: 2026-09-28
---

S06-F1 (blind re-audit, B02). The models.dev cache Scarf's picker reads lists ~223 providers; Hermes routes only the names its resolver accepts. Everything else fails at `auth.resolve_provider` with "Unknown provider '<id>'" before any key lookup (`hermes_cli/auth.py:1500-1509` @ v2026.9.24), and ACP may then fall back to another provider.

## Observations
- [fact] `HermesRoutableProviders.providerIDs` (ScarfCore) is every `model.provider` spelling `resolve_runtime_provider` accepts by name: `_REGISTRY_ROWS` ids + plugin rows/aliases mirrored by `sync_plugin_provider_registry` + `_plugin_aliases()` keys landing on those or openrouter/custom + `auto`, `moa`, `_VERTEX_NAMES`, `_DIRECT_API_BASE_URLS` (`openai` becomes a custom endpoint). 194 names; 38 of 223 models.dev keys route at v2026.9.24. `custom:<name>` is accepted by prefix #providers
- [decision] Alan (2026-09-27): HIDE unroutable providers. `ModelCatalogService.loadProviders` drops them and `ModelPickerSheet` won't restore/save one; the Mac chat shows a 'Hermes can't use provider X' banner via `ModelPreflight.unroutableProvider`. Gated on `hasRoutableProviderTable` — originally v0.21.4+, widened to v0.6.0+ with per-version bands in B02b (see "Older bands" below); undetected hosts unchanged #decision
- [gotcha] Named custom providers (`providers:` map / `custom_providers:` list) route ANY name through the named-custom rung, so preflight stays quiet when `model.provider` matches `HermesConfig.namedCustomProviders` (entries with api/url/base_url, by key or `name:`) or `hasUnreadCustomProviders` (legacy list / flow-form map). Per-provider knobs like `providers.anthropic.request_timeout_seconds` don't count, and neither does Hermes's default `providers: {}`. Known gap: a named custom provider whose name is also a models.dev id (e.g. `providers.mistral`) loses its picker row and must be picked via "Custom…". User plugins under $HERMES_HOME can add names Scarf can't see — hence a warning, not a block. B11: the picker (restore + Save gate) shares the same rule via `ModelPreflight.isUnroutable(_:customProviders:capabilities:)`; Settings General and Delegation pass `ModelPreflight.CustomProviders(config)` (delegation resolves through the same resolver, `tools/delegate_tool_config.py:375` @ v2026.9.24). Bot and model-preset pickers still pass `.none` #gotcha
- [convention] `scripts/check-hermes-tables.py` lane 8 derives the set statically at the tag and FAILs both ways; verified once equal to Hermes's own `is_runtime_provider_routable` in the tag's venv. Verdict must read `lanes=8/8` #maintenance
- [fact] S06-F4 in the same phase: DeepSeek retired ids map to `deepseek-flash` from v0.21.2 (commit 6964eebd35, first tag v2026.9.11) and to `deepseek-v4-flash` below it; `ModelCatalogService.resolveModelAlias(capabilities:)` picks by `hasDeepSeekFlashRetiredAlias` #deepseek

## Relations
- relates_to [[Aggregator providers must skip the model/provider mismatch preflight]]
- relates_to [[Hermes Capability Gating Pattern]]


## Older bands (B02b, 2026-09-27)
- [decision] Alan's rule: a finding that is also broken on older Hermes is fixed there too, at its true floor — "older hosts unchanged" protects new features, never a known bug. `resolve_provider` raises "Unknown provider" for non-registry names at every tag since v2026.3.30 (v0.6), so the filter/warning now apply from v0.6.0 (`hasRoutableProviderTable` = semver ≥ 0.6.0). Undetected hosts and < v0.6 stay unfiltered. #decision
- [fact] `HermesRoutableProviders.olderBands` = 18 reverse deltas from the current set, newest first (e.g. `openai` only routes from v0.21.4 via `_DIRECT_API_BASE_URLS`; `vercel` routes <0.15.0 and ≥0.19.1; `moa`/vertex ≥0.18.0; `google`→gemini ≥0.8.0; `opencode-free` 0.20.5–0.21.3). Base v0.6 set = 56 names. Measured by calling each tag's OWN `resolve_runtime_provider` (git archive + one Hermes venv, scratch HERMES_HOME; a credential error counts as routed): `scripts/probe-hermes-routable-bands.py` (check mode, or `--emit` to regenerate). Gotcha: before ~v2026.9.x `_PROVIDER_ALIASES` was a LOCAL of `resolve_provider`, so probing only registry + `_plugin_aliases()` keys under-counts old tags (missed `free`/`opencode_free` at 0.20.5–0.21.0); the probe therefore also tries every id-shaped string literal in the resolver modules. Static derivation is impossible below v2026.9.21 (resolver shape changed; plugins registered differently before v2026.5.7). #fact
- [convention] Lane 8 still gates the CURRENT band statically. When lane 8 fails at a new tag, update `providerIDs` AND add a band for the previous set (run the probe script). Released tags never change, so older bands are frozen. #maintenance
