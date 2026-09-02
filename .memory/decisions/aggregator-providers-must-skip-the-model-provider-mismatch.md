---
title: Aggregator providers must skip the model/provider mismatch preflight
type: note
permalink: scarf/decisions/aggregator-providers-must-skip-the-model-provider-mismatch
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: 6f67608679153925b5c6d55816c917ddd76bc3a2
created: 2026-07-03
updated: 2026-07-04
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

## Observations
- [bug] GH issue #121: Scarf 2.15.0 showed a false "Model/provider mismatch in config.yaml" banner for a valid OpenRouter config (`model.provider: openrouter`, `model.default: xiaomi/mimo-v2.5`). Both one-click fix buttons would have corrupted the working config. #chat #preflight
- [root-cause] `ModelPreflight.detectMismatch` (ScarfCore/Services/ModelPreflight.swift) treated ANY slash in `model.default` as a stale provider prefix. Aggregator providers namespace model IDs as `org/model` natively — the slash is part of the model ID, not a provider prefix. #root-cause
- [decision] Skip the mismatch check entirely when `model.provider` canonicalizes to a Hermes aggregator. Set mirrors `is_aggregator = True` in hermes_cli/providers.py: openrouter, opencode, opencode-go, kilo, huggingface, novita; plus the bare `openai` → `openrouter` alias from Hermes ALIASES. Held in `ModelPreflight.aggregatorProviders` / `aggregatorAliases`. #decision
- [kept] The original stale-prefix detection for direct providers (e.g. `anthropic/claude…` under `nous` after a Credential Pools OAuth switch → -32603 at first prompt) still fires — pinned by `detectMismatchStillFiresForNonAggregatorProviders`. #regression-guard
- [sync] On every Hermes bump, reconcile `ModelPreflight.aggregatorProviders` + `aggregatorAliases` against hermes_cli/providers.py `is_aggregator` flags and ALIASES — same cadence as the ModelCatalogService tables. #maintenance
- [fix] Landed on main as d1285b0 (2026-07-03) with tests in ModelPreflightTests. #fixed

## Relations
- extends [[Hermes Version Targeting Strategy]]
- relates_to [[Hermes v0.15 Capability Gating Decisions]]


## Follow-up hardening (6a12139, 2026-07-03)
- [decision] The banner's "Use <prefix>" one-click fix is now validated: `detectMismatch(_:knownProviders:)` takes the canonical provider roster (models.dev catalog + overlays via `ModelCatalogService.loadProviders()`); an unrecognized prefix still fires the banner but sets `prefixIsKnownProvider = false`, and ChatView hides the "Use <prefix>" button (which would have written a nonexistent provider) leaving only the strip fix + an aggregator hint. #decision
- [decision] `ModelCatalogService.providerAliases` + `canonicalProviderID(_:)` are a verbatim mirror of hermes_cli/providers.py ALIASES / normalize_provider. detectMismatch canonicalizes BOTH prefix and provider before comparing, so alias pairs (`claude/…` vs `anthropic`, `x-ai/…` vs `xai`, provider `zhipu` vs `zai/…` prefix) no longer false-positive. Reconcile this table on every Hermes bump. #maintenance
- [gotcha] The roster must be ignored when only overlay providers loaded (fresh install, `models_dev_cache.json` not yet written by Hermes) — otherwise real providers like `anthropic` read as unknown and the primary fix button disappears. ChatViewModel checks `contains(where: { !$0.isOverlay })` and caches the result per VM because the catalog read can be a multi-megabyte SSH pull; roster load is deferred to the rare mismatch-detected path. #gotcha


## Verification + mechanical gate (2026-07-04)
- [fact] The vendored Hermes checkout at ~/Developer/ScarfBox/Vendor/hermes-agent sits exactly on the `v2026.6.5` tag (commit 3c231eb39, "chore: release v0.16.0"), clean tree — the mirrored tables match Scarf's v0.16.0 target precisely, not a newer working copy. #verified
- [decision] `scripts/check-hermes-tables.py` now mechanically diffs the three hand-mirrored tables against hermes_cli/providers.py (AST-parsed, no imports): providerAliases ↔ ALIASES incl. changed mappings, aggregatorProviders ↔ is_aggregator overlays, overlayOnlyProviders ↔ overlays absent from models.dev. Missing entries FAIL (exit 1); Scarf overlays that models.dev has since absorbed only WARN (dormant fallback — loadProviders() lets the catalog entry win). Wired into the hermes-release-audit skill (surface table + Step 6). #decision
- [decision] Dormant overlays are KEPT deliberately (d04d5bf): `lmstudio` and `tencent-tokenhub` are now in models.dev so their overlayOnlyProviders entries only merge on stale-cache hosts — but Scarf supports Hermes back to v0.6, Hermes v0.16 still ships both in HERMES_OVERLAYS, and the model-ID validator's overlay fall-through (ModelCatalogService.swift ~L385) was designed for exactly this catalog evolution. Entries are annotated in-source; check-hermes-tables.py WARNs on them by design — a WARN there is policy, not drift. #decision


## v0.17 re-verification (2026-07-04, post-v2.15.1 cut)
- [fact] check-hermes-tables.py also passes against the ACTUAL Hermes target tag v2026.6.19 (v0.17.0) via `git show v2026.6.19:hermes_cli/providers.py` — ALIASES and aggregator overlay data are byte-identical v0.16→v0.17, so v2.15.1 shipped correct tables despite the vendored checkout sitting on v0.16.0. #verified
- [done] Hermes v0.17 changed `is_aggregator()` to normalize aliases first and return True for any `custom:`-prefixed provider. ModelPreflight now MIRRORS this: `detectMismatch` skips `custom` and any `custom:*` provider outright (ModelPreflight.swift:122-123, citing Hermes #48305), so a custom provider (e.g. LiteLLM proxy) serving org/model IDs no longer raises the false mismatch banner. Landed via task t-ed3700b2 (TASKS.md Done). #fixed
