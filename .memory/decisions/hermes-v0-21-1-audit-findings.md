---
title: Hermes v0.21.1 Audit Findings
type: note
permalink: scarf/decisions/hermes-v0-21-1-audit-findings
tags: [hermes, audit, compatibility, v0.21.1, hermes-v0-21-1]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesSearchIndex.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/WebToolsBackendRoster.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scripts/check-hermes-tables.py, documents/hermes-v0.21.1-audit-report.md]
source_paths_inferred: false
source_sha: 18806e7c4dbac0ffd6ff7e91c12d27440d0a8cc5
created: 2026-09-08
updated: 2026-09-08
reviewed: 2026-09-19
reviewed_by: audit:claude-code (background)
---

## Observations
- [fact] Hermes v0.21.1 (v2026.9.7), audited 2026-09-08 over the v2026.8.31 delta (~5,995 commits, mostly a `hermes_cli` modularization): state.db `messages` DDL byte-identical (sessions gained additive `tool_names` / `compression_recovery_deadline`, new `conversation_generations` table, SCHEMA_VERSION 26→30 all FTS-only), ACP wire byte-clean (same 9 advertised commands, same 9 `session_update` discriminators), zero removals/renames/arity changes on the 88 argv Scarf issues, provider tables and gateway platform roster value-identical. A light additive cycle — the real work was five new surfaces plus eight pre-existing bugs. Full report: documents/hermes-v0.21.1-audit-report.md #verdict
- [gotcha] Corrections the phases made to the audit report, so the next audit does not re-litigate them: Tavily is a one-release removal WINDOW (0.21.0 only), not a floor; `keenable`'s floor is v0.20.5 not v0.20.6; four Phase-4 surfaces (`skills search --json` v0.17, `browse-sh` v0.15, the provider `--source` filters + `debug share -y` + `computer-use permissions status --json` v0.18) are far older than they look because the modularization moved their argparse blocks; B7 is FOUR unreachable providers, not six (`gemini` is reachable via models.dev's `google`, `custom` is Scarf's own surface); the cron lifecycle refusal arrives as stdout JSON, not stderr; the MCP device-code prompt is on STDERR, not stdout; there is NO full FTS rebuild at first v0.21.1 open and the rebuild keys date to v2026.7.30; `--completion-contract` has no `kanban edit` half. #verification
- [constraint] Genuinely forced by v0.21.1: `check-hermes-tables.py` crashed on the `ALIASES` dict-comprehension inversion; Tavily's re-add; the `perplexity` web backend; `agent.service_tier` gaining bounded `auto`/`cold` + `fast_auto_seconds`; the false "no remote sink" telemetry copy now that `telemetry.shared_metrics.send`/`.endpoint` exist; `gateway status`'s third PID-less multiplexer verdict; the `messages_fts` 8 KB tool-content prefix; and `quarantine_zeroed_state_db` moving state.db aside under a live sqlite handle. #forced
- [done] Adopted behind `isV0211OrLater` and per-feature flags across Phases 0–6 (commits 9e012c95…23867474 on `feat/hermes-v0211-parity`): `plugins compat --json` banner, `cron create --paused` / `--failure-deliver` / dispatch diagnostics, kanban completion contracts + `last_failure_error`, `auth priority` / cooldown clearing, MCP device-code OAuth with the code surfaced, Computer Use permission card, the eight-key config batch, the fast-mode picker and split telemetry opt-ins, the FTS LIKE fallback + rebuild note, and the inode-identity state.db reopen. #adopt
- [gotcha] Phase 8 corrections to the cycle's own claims: `image_gen.model` is read by FOUR backends (fal, krea, openai, openai-codex), not the FAL pipeline alone; `skills uninstall --yes` DOES exist, from v2026.8.19 (0.20.5), so the "no --yes flag" note was stale; the nine new gateway platform rows have per-row floors (weixin 0.9, qqbot 0.10, irc 0.12, msgraph_webhook 0.14, photon 0.17; dingtalk/sms/api_server 0.4, wecom 0.6) and `gateway_restart_notification` is confirmed v0.13 (commit b71f80e6ce, first tagged v2026.5.7), `True` from its first commit. #verification
- [decision] Deliberate NO-OPs this cycle, as amended in Phase 8 — `hasComputerUseDoctorJSON` and `hasGatewayMultiplexerStatus` were DELETED rather than left unconsumed (an unread flag is drift bait; the multiplexer verdict is output-detected, which is correct on every host, and the doctor payload is cua-driver's with no stable contract): no `sessions.*` retention UI (user declined; A11 verified safe without one); deliveries.db / cron executions table stay server-side; ACP `plan` and `usage_update` still fall to `.unknown` (B8, product decision); `computer-use doctor --json` is not consumed (its payload is cua-driver's, with no stable contract) — the normalized `permissions status --json` is read instead; no `--nous` / `--no-redact` surface for `debug share`; no `plugins compat <path>` author mode; no setup forms for the nine new gateway platform rows (spun out as t-1ca040c2); no `image_gen.provider` picker for the new meta-ai backend (t-e7af69d4); `sessions.tool_names` is schema-tested but not decoded into the session model (no consumer). #noop

## Relations
- relates_to [[Hermes Version Compatibility Target]]
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Hermes v0.21.0 Audit Findings]]
- relates_to [[Hermes messages_fts contract: an 8 KB tool prefix and two rebuild markers]]
