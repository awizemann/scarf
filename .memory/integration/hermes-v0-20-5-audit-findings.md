---
title: Hermes v0.20.5 Audit Findings
type: note
permalink: scarf/integration/hermes-v0-20-5-audit-findings
tags: [hermes, audit, compatibility, v0.20.5]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift]
source_paths_inferred: false
source_sha: 5ba704c22e0558122a7ab9e26806bd21a9473031
created: 2026-08-26
updated: 2026-08-26
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

## Observations

- [verdict] Hermes v0.20.5 (v2026.8.19, tag commit fcbd1076a9, ~804 commits over v0.20.4) audited 2026-08-26. **Schema: unchanged (SCHEMA_VERSION 26, zero DDL). ACP wire: unchanged** (adapter delta is model-catalog construction only). Light additive cycle. Full report: documents/hermes-v0.20.5-audit-report.md. #verdict
- [breaking] `hermes version` subcommand REMOVED (dropped from `_BUILTIN_SUBCOMMANDS`, subcommands/version.py deleted); bare `hermes version` falls through to a chat prompt. `--version` now carries the full output incl. `commits behind`. Scarf HealthViewModel.swift:164/:346 must gate argv: `--version` on ≥0.20.5, `version` below (older `--version` prints short form — verified live on v0.20.0). #breaking
- [providers] New zero-auth aggregator provider `opencode-free` (keyless, base opencode.ai/zen/v1): needs overlayOnlyProviders entry, aliases `free`/`opencode_free`, aggregatorProviders entry, display "OpenCode Free"; check-hermes-tables.py FAILs ×3 until reconciled. Overlays gained `keyless: Bool` — HermesProviderOverlay must model it so the UI suppresses the API-key row. Pre-existing gap found: aggregatorProviders has bare `opencode` but canonical ids are opencode-zen/-go/-free. #providers
- [config] `agent.max_turns` default 500 → unlimited (accepts none/unlimited/inf/0/-1) — Scarf's capability-aware default display (500 at v0.20+) is stale at v0.20.5 and can't write unlimited. `stt.provider` no longer seeded — unset = autodetect; Scarf's "local" default picker misleads; add "Auto (unset)". No silent write no-ops: every key Scarf writes survives. New keys worth Settings: web.keyless_fallback / web.keyless_rescue / web.provider_tier.<vendor> (keyless web-search ring incl. new Keenable backend), agent.run_budget_seconds, agent.stall_guards, agent.execution_guidance. `_config_version` 37→38. #config
- [cli] `profile list` now renders `name (display_name)` — parseProfileList would leak the suffix into `profile use` argv (medium confidence, verify on a live 0.20.5 binary). `sessions delete/prune` spare pinned by default (delete can silently no-op); sessions import/delete/prune now return non-zero on failure. gateway verbs unchanged in output but internals moved to `launchctl print` — smoke-test after bump. New verbs (worktree list/prune, update --plan/--keep-stash, skills uninstall --yes, cron --reasoning-effort) are NO-OP until adopted; cron flag needs gating (argparse rejects unknown args on older hosts). TUI fuzzy /model + Ctrl+P palette unreachable from non-TTY. #cli
- [gate-plan] Ship an `isV0205OrLater` group: hasVersionFlagFullOutput, hasCronReasoningEffort, + flags for adopted settings. jobs.json optional `reasoning_effort` round-trips losslessly through HermesCronJob extras already. #gating
- [no-op] Explicit NO-OPs (don't re-litigate): MCP catalog/mcp add/curator/skills-hub/bundled skills; gateway platform roster + allowlist location + gateway list shape; FTS/search; managed scope; xai_retirement; demoted providers; security commits (Electron/server-side); pairing/status/tools list/config/plugins argv verified unchanged. #noop
- [verify-further] (1) Compaction classifier: `agent/context_compressor.py` is a NEW file this window — verify Scarf's v2.20.0 compaction-summary marker classification still matches before target bump. (2) Relay exclusivity: GATEWAY_RELAY_URL force-disables messaging platforms even when config-enabled (escape: GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS) — candidate Health banner. (3) image_gen.use_gateway → image_gen.provider key migration; AuxiliaryTab copy stale. (4) gateway_restart_notification default mismatch (Hermes true / Scarf false) — pre-existing, confirm vs parser. #verify

## Relations
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes Version Compatibility Target]]
- supersedes_context [[Hermes v0.20.4 Audit Findings]]

- [done] Verify-further item (1) CLOSED 2026-08-26: `agent/context_compressor.py` existed at BOTH tags (the "new file" read was wrong; the +141-line diff is internal salvage/anti-thrash logic — salvage_grown_transcript, record_rejected_compaction) and `classify_summary_content` is byte-identical v2026.8.18↔v2026.8.19. ACP replay classification (`server.py _history_summary_meta`, `_meta.hermes.compactionSummary`/`sessionProvenance`) also present at both tags — pre-v0.20.5, already covered by prior cycles. Scarf's v2.20.0 compaction-summary styling remains valid; NO change needed. (Cross-checked with peer session scarfbox-90's 0.16→0.20.5 ACP digest; claims verified against tagged source.) #done
