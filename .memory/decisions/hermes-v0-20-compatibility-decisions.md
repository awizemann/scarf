---
title: Hermes v0.20 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-20-compatibility-decisions
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesMessage.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/CuratorService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesTool.swift]
source_paths_inferred: false
source_sha: dbb5d6212a1e38529bdf3e6b1caeac7f8b81f41c
created: 2026-08-03
updated: 2026-08-03
---

What shipped for the Hermes v0.20.0 (v2026.8.3) cycle and why (branch feat/hermes-v020-parity, built 2026-08-03 by orchestrated sub-agents in three waves + a fresh-eyes fix round; full findings: [[Hermes v0.20.0 Audit Findings]]).

## Observations
- [decision] Compaction-summary styling is driven by HYDRATION-LAYER content classification (marker prefixes "[CONTEXT COMPACTION — REFERENCE ONLY]", legacy "[CONTEXT SUMMARY]:", merged delimiter — mirroring Hermes ContextCompressor.classify_summary_content), NOT the ACP _meta.hermes.compactionSummary replay flags. Rationale: Hermes persists summaries as ordinary active state.db rows; Scarf's loadSessionHistory wholesale-replaces messages, so replay-side styling either no-ops or double-renders (proven by fresh-eyes audit). The _meta parsing is kept in ACPMessages but replay stays fully suppressed pre-engagement. #decision
- [decision] max_turns absent-key parse keeps the 0 sentinel; the DISPLAY default is capability-resolved (HermesConfig.displayMaxTurns: 500 at v0.20+, 60 before). Never bake a new upstream default into the parser — it leaks writes to old hosts. #decision
- [decision] Remote-context session export offers only stdout-capable formats (jsonl/trace); path formats (md/html/qmd) are local-only because the CLI writes on the remote host. #decision
- [decision] Curator adopt: bulk "Adopt All" requires a confirmation alert; adopt/adoptAll always pass --yes because hermes curator adopt prompts [y/N] on TTY. skills uninstall has NO --yes flag and prompts unconditionally — Scarf feeds stdin "y\n". #decision
- [decision] A2A deliberately NOT added to the platform roster (infrastructure plugin, no user config surface). Buzz added with NO GatewayAllowlistKind mapping (user-gated via allowed_users). #decision
- [decision] Parsers are version-agnostic (curator status accepts both header generations); only UI surfaces and CLI invocations are capability-gated. #convention
- [fact] Phase 3 (new settings key surfaces: compression knobs, reasoning_overrides via direct-YAML, STT/TTS, excluded_providers, profile_routes editor, import-agent, sync) is queued as Memophant task t-1cc0a505 — deliberately deferred. #todo

## Relations
- extends [[Hermes v0.18 Compatibility Decisions]]
- relates_to [[Hermes v0.20.0 Audit Findings]]
- implements [[Hermes Capability Gating Pattern]]


- [done] Power-settings pass shipped post-v2.18.0 (merge db8c070): compression.threshold_tokens/min_tail_user_messages/idle_compact_after_seconds/progress_notices rows; agent.reasoning_overrides table via new GatewayConfigWriter.setMap + PowerSettingsWriter (dict unsupported by `hermes config set` — config_defaults.py:248 says so outright; matching is spelling-tolerant variant matching per hermes_constants.py:1064, NOT substring; valid efforts minimal…ultra + none-alias, hermes_constants.py:942-967); excluded providers key is **model_catalog.excluded_providers** (inventory.py:100 — NOT top-level as the audit note guessed). HermesYAML learned quoted-key parsing (model patterns with `:` round-trip). All gated isV020OrLater; 14 tests in PowerSettingsV020Tests. Remaining Phase 3 backlog: task t-1cc0a505. #done
