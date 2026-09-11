---
title: Hermes Version Targeting Strategy
type: note
permalink: scarf/integration/hermes-version-targeting-strategy
tags: [hermes, versioning, capability-gating]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: ca6ae1e8832242f31b5c6ccdd3b390186b1af8cb
created: 2026-05-29
updated: 2026-09-10
reviewed: 2026-09-10
reviewed_by: claude-opus-5
---

## Observations
- [current-target] Scarf targets Hermes **v0.21.1 (v2026.9.7)** as of the `feat/hermes-v0211-parity` branch (2026-09-08; shipping Scarf version TBD at release prep) — the last SHIPPED release, v3.1.0, targets v0.21.0 (v2026.8.31) — landed through a series of capability flag additions across v0.18 (v2026.7.1), v0.19 (v2026.7.20), v0.20 (v2026.8.3), v0.20.3 (v2026.8.16.2), v0.20.4 (v2026.8.18), v0.20.5 (v2026.8.19), v0.20.6 (v2026.8.27), and v0.21 (v2026.8.31). All versions v0.6.0 through v0.21.1 are verified; older hosts degrade gracefully. NOTE: the vendored hermes-agent checkout at ~/Developer/ScarfBox/Vendor/hermes-agent may sit on an older tag — `git show <target-tag>:<path>` or a detached worktree when verifying against v0.21.0 #target
- [philosophy] Every release-gated UI surface is capability-gated via HermesCapabilities flags. Pre-target hosts must render byte-identical to prior Scarf versions — never throw on unknown CLI subcommands #gating
- [flag-grouping] Group HermesCapabilities flags at the top of the file by introducing release: `MARK: v0.14 (v2026.5.16) flags`, `MARK: v0.15 (v2026.5.28) flags`, etc. Current file has sections through v0.21.1 (v2026.9.7). CAUTION (P23): a MARK group's NAME is not evidence for its members' floors — flags filed under the "v0.20" and "v0.20.4" marks turned out to be 0.18.1–0.20.3. `git ls-tree` the file or grep the subparser at the tag before trusting the heading #convention
- [verification] Verify exact flag/config/wire shapes against the tagged Hermes source (e.g. `v2026.8.31`) BEFORE implementation — flags like HERMES_INFERENCE_MODEL silently no-op for ACP because `_make_agent` doesn't consult them #pitfalls
- [keep-in-sync] On every Hermes bump, reconcile ModelCatalogService.{overlayOnlyProviders, modelAliases, demotedProviders, imageGenModels, providerDisplayNameOverrides} against hermes_cli/{providers.py, models.py, xai_retirement.py}; for the provider tables run `./scripts/check-hermes-tables.py --tag <target-tag>` (since P27 the script reads Hermes AT the tag via `git show` — the positional is just the checkout, which no longer has to be checked out at the tag; `--worktree` opts back into the working tree, and the verdict must read `lanes=5/5`, since a `SKIPPED lane N` exits 2) — it mechanically gates ModelCatalogService.providerAliases ↔ ALIASES, ModelPreflight.aggregatorProviders ↔ is_aggregator overlays, and overlayOnlyProviders ↔ overlays absent from models.dev (see [[Aggregator providers must skip the model/provider mismatch preflight]]); reconcile platform roster against plugins/platforms/ + gateway/platforms/; reconcile search/TTS backend lists. From v0.21.1 the checklist also covers: the **web backend roster** (`WebToolsBackendRoster` vs `plugins/web/`, INCLUDING a re-check of every modelled removal — a patch tag can re-add one), **lane 4** of check-hermes-tables (plugin-registered providers auto-appended to CANONICAL_PROVIDERS vs `overlayOnlyProviders`, resolved through both `providers.py::ALIASES` and `models_catalog_static._PROVIDER_ALIASES`), the **gateway multiplexer branch** in `gateway status`/`gateway list` parsing, and the **cron dispatch rows** (`Dispatch:` / `⚠ Delivery UNVERIFIED:`) #maintenance
- [schema] state.db schema has been unchanged since v0.11 (added messages.reasoning_content + sessions.api_call_count). v0.12–v0.15 require no DB migration; v0.16 adds a `messages.active` soft-delete column (first schema change since v0.11) — Scarf schema-detects it via `HermesDataService.hasMessagesActiveColumn` and conditionally applies `AND active = 1`; v0.18 adds `messages.compacted` (in-place compaction soft-archive, schema v17) — schema-detected via `HermesDataService.hasCompactedColumn`, and SEARCH widens to `(active = 1 OR compacted = 1)` while transcript/activity queries stay active-only (mirrors Hermes search_messages vs context-load semantics). Scarf reads state.db and parses CLI output from `hermes status`, `hermes doctor`, `hermes tools`, `hermes sessions`, `hermes gateway`, `hermes pairing` with automatic schema detection for backward compatibility #schema
- [automatic-gains] Most v0.15+ work (run_agent.py refactor, cold-start perf, promptware defense, session_search rebuild, Ink TUI, web dashboard, Docker s6, API-server REST) is server-side and benefits Scarf transparently with no code change #server-side

## Relations
- extends [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.15 Capability Gating Decisions]]
