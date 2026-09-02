---
title: Hermes v0.21.0 Audit Findings
type: note
permalink: scarf/integration/hermes-v0-21-0-audit-findings
tags: [hermes, audit, compatibility, v0.21.0, bot-mode]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/BotsService.swift, documents/hermes-v0.21.0-audit-report.md]
source_paths_inferred: false
source_sha: 676f7d8dffc2c34a567124e08b36d30c650ca587
created: 2026-09-01
updated: 2026-09-01
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

Source-verified audit of Hermes v0.21.0 vs Scarf's v0.20.5 target, run 2026-09-01 via 8 fan-out surface agents. NO implementation yet — pending Alan's scope decision. Deliberate NO-OPs recorded in the full report so the next audit doesn't re-litigate: ACP clean, gateway list output byte-identical, platform roster unchanged at 22, aggregator set unchanged, delegation defaults already matched, cron runs format unchanged, skills-hub columns unchanged.

## Observations
- [fact] Hermes v0.21.0 (v2026.8.31, 'Pantheon', 2,287 commits over v0.20.5) audited 2026-09-01. SCHEMA_VERSION still 26 but DDL changed via auto-migrator: new messages._compressed_summary column, gateway_heartbeats table, and ~10 lazily-created hosted_room_* tables in state.db (gate on sqlite_master, never version). ACP wire fully clean: acp_adapter delta is 2 commits/30 lines, _ADVERTISED_COMMANDS byte-identical. Full report: documents/hermes-v0.21.0-audit-report.md #verdict
- [gotcha] v0.21.0 release-note lies verified against source: `hermes approval-check` does NOT exist (zero hits in tree); 'six new providers' is really 3 new (router/Ramp, nebius-token-factory, tencent-tokenplan); Slack 'native live cards #85476' not in this range; model_overrides and sessions pin/unpin predate v0.20.5 #release-notes-lie
- [constraint] Forced fixes for v0.21 parity: auxiliary.web_extract.* block deleted (Scarf writes 7 dead keys), tavily backend removed (WebToolsTab still offers it), gateway_turn_lease_timeout default 1800→5s (stepper floor 60 can't express it), curator pin/unpin new exit-1 path, offline --version emits no update line, config migration v39 retires bfl toolset, MCP catalog 20→65 with dead Atlassian /v1/sse URL prefilled, session-preview carrier-stripping drift, cron jobs.json now allows ID-keyed map + bare repeat (Scarf decodes array-only), provider tables 3 FAILs, bundled skills 82→58 with hermes-agent now ESSENTIAL (disable = silent no-op) #forced
- [fact] Bot Mode architecture: a bot IS a profile — identity in profile.yaml ui_meta['hermes-bots'] (64KB, per-key CAS via profiles.configure); canonical Bot Chat = ordinary hidden session uniquely titled 'Bot Chat'; bot-to-bot DM = documented CLI `hermes -p <name> chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file <tmp>`; group rooms are 100% Electron-client-orchestrated (only a 16-msg mirror is shared); avatars need blobatar@2.0.0 npm port for byte-identity (assets/avatar.png readable when backfilled). Scarf can build roster+Bot Chat+DMs+routines (Phase A) on surfaces it already speaks; rooms are a second project #bot-mode
- [todo] Adopt candidates gated isV021OrLater: hermes peer run/status/stop (async runs, JSON shapes captured in report), cron incidents/doctor + resume --run-now + --deliver bot-chat, gateway control socket (identify/status line-JSON over UNIX socket — better liveness than parsing gateway list), gui --setup-tcc-identity, kanban boards export/import, status_bar.fields + auxiliary.review + unattended_mode + voice.client_direct settings. Pre-existing bugs found: gateway status markers never match (GatewayViewModel.swift:124), update-badge misses singular/no-count shapes, dotted quick-command names corrupt config (0.21 adds \. escaping as fix), ACP plan/usage_update discriminators unhandled since v0.18 #adopt

## Relations
- relates_to [[Hermes Version Compatibility Target]]
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.20.5 Audit Findings]]
