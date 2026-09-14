---
title: Hermes v0.21.0 Audit Findings
type: note
permalink: scarf/decisions/hermes-v0-21-0-audit-findings
tags: [hermes, audit, compatibility, v0.21.0, bot-mode]
status: deprecated
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/BotsService.swift, documents/hermes-v0.21.0-audit-report.md]
source_paths_inferred: false
source_sha: 9aec389666695ed97c2ba7294b30bf2d49d68fb9
created: 2026-09-01
updated: 2026-09-01
reviewed: 2026-09-08
reviewed_by: audit:claude-code (background)
---

## Observations
- [fact] Hermes v0.21.0 (v2026.8.31, 'Pantheon') audited 2026-09-01. Point-in-time snapshot: SCHEMA_VERSION still 26, DDL changes via auto-migrator (messages._compressed_summary, gateway_heartbeats table, lazily-created hosted_room_* tables in state.db). ACP wire fully clean: acp_adapter delta 2 commits/30 lines, _ADVERTISED_COMMANDS byte-identical. **NOTE: v0.21.1 (v2026.9.7) released 2026-09-07 and supersedes many of these findings. Current state → hermes-v0.21.1-audit-report.md.** Full v0.21.0 report: documents/hermes-v0.21.0-audit-report.md #verdict
- [gotcha] v0.21.0 release notes contain inaccuracies verified against source: `hermes approval-check` does NOT exist (zero hits in tree); 'six new providers' is really 3 new (router/Ramp, nebius-token-factory, tencent-tokenplan); Slack 'native live cards #85476' not in this range; model_overrides and sessions pin/unpin predate v0.20.5 #release-notes-lie
- [constraint] v0.21.0 forced fixes (many reassessed by v0.21.1): auxiliary.web_extract.* block deleted (Scarf writes 7 dead keys, partially addressed by t-80fb5589); tavily backend removed in v0.21.0 but readded in v0.21.1 (floor logic updated); gateway_turn_lease_timeout default changed (0.21.0→0.21.1 brings new `agent.fast_mode` values); curator pin/unpin exit codes; offline --version; config migration v39; MCP catalog staleness; session preview carrier-stripping; cron jobs.json ID-keyed map support; provider table additions; skills roster changes (hermes-agent now essential) #forced
- [fact] Bot Mode architecture unchanged: a bot IS a profile with identity in profile.yaml ui_meta['hermes-bots'] (64KB, per-key CAS via profiles.configure); canonical Bot Chat is ordinary hidden session titled 'Bot Chat'; avatars need blobatar@2.0.0 npm port; group rooms 100% Electron-client-orchestrated; Phase A scoped to existing surfaces (roster, Bot Chat, DMs, routines) #bot-mode
- [done] v0.21.0 adoption phase (Sep 2026): tasks t-90c8afa2 (cron incidents/doctor/resume), t-e81e9f48 (peer CLI basics), t-432e7d7d (swift-stats analytics) completed. Adoption work blocked on v0.21.0 gates implemented and verified. v0.21.1 adds new adoption surfaces (see v0.21.1 audit) #adopt

## Relations
- relates_to [[Hermes Version Management]]
- implements [[Hermes Capability Gating Pattern]]
- superseded_by [[Hermes v0.21.1 Audit Findings]] (released 2026-09-07; documents/hermes-v0.21.1-audit-report.md)
- relates_to [[Hermes v0.20.5 Audit Findings]]
