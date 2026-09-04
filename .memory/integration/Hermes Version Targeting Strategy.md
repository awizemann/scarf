---
title: Hermes Version Targeting Strategy
type: note
permalink: scarf/integration/hermes-version-targeting-strategy
tags: [hermes, versioning, capability-gating]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: 5ba704c22e0558122a7ab9e26806bd21a9473031
created: 2026-05-29
updated: 2026-07-04
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

## Observations
- [current-target] Scarf targets Hermes v0.21.0 (v2026.8.31) as of shipped v3.1.0 — landed through a series of capability flag additions across v0.18 (v2026.7.1), v0.19 (v2026.7.20), v0.20 (v2026.8.3), v0.20.6 (v2026.8.27), and v0.21 (v2026.8.31). All versions v0.6.0 through v0.21.0 are verified; older hosts degrade gracefully. NOTE: the vendored hermes-agent checkout at ~/Developer/ScarfBox/Vendor/hermes-agent may sit on an older tag — `git show <target-tag>:<path>` or a detached worktree when verifying against v0.21.0 #target
- [philosophy] Every release-gated UI surface is capability-gated via HermesCapabilities flags. Pre-target hosts must render byte-identical to prior Scarf versions — never throw on unknown CLI subcommands #gating
- [flag-grouping] Group HermesCapabilities flags at the top of the file by introducing release: `MARK: v0.14 (v2026.5.16) flags`, `MARK: v0.15 (v2026.5.28) flags`, etc. Current file has sections through v0.21 (v2026.8.31) #convention
- [verification] Verify exact flag/config/wire shapes against the tagged Hermes source (e.g. `v2026.8.31`) BEFORE implementation — flags like HERMES_INFERENCE_MODEL silently no-op for ACP because `_make_agent` doesn't consult them #pitfalls
- [keep-in-sync] On every Hermes bump, reconcile ModelCatalogService.{overlayOnlyProviders, modelAliases, demotedProviders, imageGenModels, providerDisplayNameOverrides} against hermes_cli/{providers.py, models.py, xai_retirement.py}; for the provider tables run `scripts/check-hermes-tables.py <hermes-checkout-at-target-tag>` — it mechanically gates ModelCatalogService.providerAliases ↔ ALIASES, ModelPreflight.aggregatorProviders ↔ is_aggregator overlays, and overlayOnlyProviders ↔ overlays absent from models.dev (see [[Aggregator providers must skip the model/provider mismatch preflight]]); reconcile platform roster against plugins/platforms/ + gateway/platforms/; reconcile search/TTS backend lists #maintenance
- [schema] state.db schema has been unchanged since v0.11 (added messages.reasoning_content + sessions.api_call_count). v0.12–v0.15 require no DB migration; v0.16 adds a `messages.active` soft-delete column (first schema change since v0.11) — Scarf schema-detects it via `hasMessagesActiveColumn` and conditionally applies `AND active = 1`; v0.18 adds `messages.compacted` (in-place compaction soft-archive, schema v17) — schema-detected via `hasCompactedColumn`, and SEARCH widens to `(active = 1 OR compacted = 1)` while transcript/activity queries stay active-only (mirrors Hermes search_messages vs context-load semantics). Scarf reads state.db and parses CLI output from `hermes status`, `hermes doctor`, `hermes tools`, `hermes sessions`, `hermes gateway`, `hermes pairing` with automatic schema detection for backward compatibility #schema
- [automatic-gains] Most v0.15+ work (run_agent.py refactor, cold-start perf, promptware defense, session_search rebuild, Ink TUI, web dashboard, Docker s6, API-server REST) is server-side and benefits Scarf transparently with no code change #server-side

## Relations
- extends [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.15 Capability Gating Decisions]]
