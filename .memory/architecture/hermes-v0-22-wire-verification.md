---
title: Hermes v0.22 Wire Verification
type: note
permalink: scarf/architecture/hermes-v0-22-wire-verification
tags: [hermes, acp, state-db, verification, v022]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/SessionResume.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesYAML.swift]
source_paths_inferred: false
source_sha: 60e38b31e53c0c0db6a6853677d27cfaa2f68ce4
created: 2026-10-25
updated: 2026-10-25
---

Source-grounded findings from the v0.21.6 → v0.22.5 audit, including deliberate no-ops so the next audit doesn't re-litigate them. Hermes tags are now `vX.Y.Z`; v0.22.2 reverted v0.22.1's gateway work and v0.22.3 restored it.

## Observations
- [fact] From v0.22.3 (and at 0.22.1) `hermes acp` returns GatewayACPAgent (acp_adapter/server.py:245-249@v0.22.5): a thin viewer of the profile gateway daemon. Wire protocol unchanged (agent-client-protocol==0.9.0). Changed behaviour: /queue submits its own admission and the running prompt returns first; no _meta on title-only session_info_update (Scarf re-derives compression lineage from state.db); session/load failure = JSON-RPC -32603 with data.details 'not_found'; closing the client doesn't stop the turn; set_mode refuses mid-turn; set_model can ask (`model-confirm-*` card), defer, or raise model_switch_cancelled; clarify arrives as a permission card (`clarify-*`, choice-N allow_once, skip reject_once); new current_mode_update; session/new can fail acp_policy_unavailable / profile_mismatch #acp
- [fact] state.db: every column Scarf reads unchanged v2026.9.24 → v0.22.5; DDL moved to hermes_state_common.py; FTS byte-identical. From v0.22.3 cli/tui/gui/acp sessions are stored source='local' with the surface in created_source (column from v0.21.6; gateway/session_policy.py:85-109). Scarf PRAGMA-detects created_source and shows displaySource; routing/filters stay on raw source #schema
- [fact] config.yaml from v0.21.6 loads via ruamel (hermes_yaml.py): duplicate keys fatal for gateway/cron (require_parseable_user_config), bare y/Y/n/N booleans; ruamel's bool set = PyYAML's plus those four. `security.tirith_*` removed by _migrate_to_50. compression.threshold_tokens default back to None at v0.21.6 #config
- [fact] Left core into plugin-catalog (installable, sha-pinned): honcho/mem0/openviking/supermemory/hindsight (0.21.6), holographic + spotify (0.21.7; `hermes spotify login`, flags verified in NousResearch/hermes-official-plugins spotify_cli.py:9-14 at every catalog pin), homeassistant (0.21.6), singularity (0.22.5). Plugin enable/disable success lines became `✓ Plugin <k> enabled.` / `⊘ Plugin <k> disabled.` at v0.22.3 #plugins
- [fact] Verified NO-OP at v0.22.5: jobs.json path and cron runs/incidents/doctor output, kanban JSON, log format, curator state, skills hub columns, web (Tavily window holds) and TTS rosters, gateway list/status markers, pairing, allowlist mapping, all gateway env vars except HASS_*, `hermes acp` argv, backup --keep 0, profile/peer/kanban argparse. The MCP `install failed:` marker is NOT dead: printed through v2026.8.31 #noop

## Relations
- relates_to [[Hermes v0.22 Compatibility Decisions]]
- relates_to [[Hermes Release Audit Process]]
