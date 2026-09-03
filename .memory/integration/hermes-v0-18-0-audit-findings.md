---
title: Hermes v0.18.0 Audit Findings
type: note
permalink: scarf/integration/hermes-v0-18-0-audit-findings
tags: [hermes, v018, audit, verification, wire-format]
source_paths: [scripts/check-hermes-tables.py]
source_paths_inferred: true
source_sha: cc5d3945a2d0813c6559f9a538a83425582641c2
created: 2026-07-04
updated: 2026-07-04
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

## Observations
- [verdict] Light-to-moderate cycle. All upgrade-forced and pre-existing findings implemented in commit 9338c59 (2026-07-04). state.db schema DID change (first since v0.16): `messages.compacted INTEGER NOT NULL DEFAULT 0` (hermes_state.py:764, SCHEMA_VERSION 16→17). ACP wire is a clean NO-OP — `_ADVERTISED_COMMANDS` and all session_update/permission/mode shapes byte-identical (acp_adapter/server.py:465); nothing new reaches the ACP client unhandled. #verdict #implemented
- [schema] In-place compaction (`archive_and_compact()`, hermes_state.py:3346) marks summarized-away rows active=0+compacted=1; rewind/undo rows stay active=0+compacted=0. Hermes `search_messages` now filters `(m.active = 1 OR m.compacted = 1)` (hermes_state.py:4224). FIXED: Scarf now schema-detects `hasCompactedColumn` and widens the clause when present (HermesDataService.swift:792). #upgrade-forced #done
- [providers] v0.18 removes `google-gemini-cli` (OAuth) entirely, replacing it with `vertex` (Google Vertex AI, OAuth2 SA/ADC; hermes_cli/models.py:1035) + 4 aliases google-vertex/vertex-ai/gcp-vertex/vertexai (models.py:1197-1200); drops aliases gemini-cli/gemini-oauth. Adds overlay-only provider `moa` (Mixture of Agents, transport openai_chat, auth virtual, base moa://local; providers.py:47-51). FIXED: Both `vertex` and `moa` added to ModelCatalogService.overlayOnlyProviders; google-gemini-cli aliases removed; check-hermes-tables.py passes. #upgrade-forced #done
- [cron] NEW per-job `attach_to_session` optional bool (cron/jobs.py:867,1024 — zero matches at v2026.6.19; verified new in v0.18). FIXED: Scarf's HermesCronJob now models it (HermesCronJob.swift:40, case .attachToSession); round-trip preserved in withEnabled() (line 239). #upgrade-forced #done
- [preexisting-webtools] Scarf's Web Tools tab silent no-op on BOTH sides, pre-existing since at least v0.14: Scarf was writing `web_tools.backend`/`web_tools.search.backend`/`web_tools.extract.backend` and reading the same dead keys (Hermes reads `web.backend`/`web.search_backend`/`web.extract_backend`). FIXED: Both SettingsViewModel (lines 459-461) and HermesConfig+YAML (lines 592-594) now use the correct `web.*` keys. #preexisting #bug #done
- [preexisting-cron] `HermesCronJob.withEnabled()` omits `workdir`, `contextFrom`, `noAgent` from the copy — toggling enabled permanently dropped those fields from jobs.json. FIXED: withEnabled() now forwards all fields (lines 236-239); method moved onto HermesCronJob (line 203) so next field addition can't miss it; HermesConfig.buildJob() also updated. #preexisting #bug #done
- [cli] All 42+ Scarf CLI invocations survive v0.18 unchanged (zero breaking argparse changes). New optional verbs worth roadmap consideration: `hermes serve` (headless backend, --port/--no-open), `hermes journey` (learning timeline), `hermes mcp reauth [name|--all]` (OAuth refresh). `hermes status --all` flag removed — Scarf never used it. #no-op
- [gateway] No breaking platform changes. 9 core platforms migrated to plugin implementations — backward compatible, Scarf's runtime discovery unaffected. NEW optional PlatformConfig field `typing_indicator: bool = true` (gateway/config.py:345) — candidate Settings toggle. Email now defaults `unauthorized_dm_behavior: "ignore"` (config.py:789) — onboarding copy nuance. Pairing-syncs-to-allowlist (1bfe08145) mirrors approvals into *_ALLOWED_USERS env vars, operator-initiated, YAML allowlists Scarf writes are untouched. #no-op
- [mcp-skills] No changes required: new `mcp_security.py` validator (stdio threat shapes + hermes-0day IOC blocklist) is internal; curator gains `--consolidate` flag + one lenient-parsed status line; skills roster: +computer-use bundled, devops→optional-skills, red-teaming removed, +payments category, +unreal-engine MCP catalog — all handled generically by Scarf's scanners. #no-op
- [config-keys] New v0.18 config keys worth Settings consideration (all optional): agent.{verify_on_stop, verify_guidance, max_verify_nudges, coding_instructions, intent_ack_continuation, max_live_sessions}, display.{reasoning_style, reasoning_full, friendly_tool_labels, pet}, web.extract_char_limit, browser.allow_unsafe_evaluate, compression.in_place, terminal.daemon_term_grace_seconds. #candidates
- [no-op-list] Deliberate NO-OPs (don't re-litigate): gateway /resume+/sessions IDOR series, browser private-network guard, compaction END-MARKER fixes, compression interrupt queueing, kanban creator-wake routing, codex-runtime migration plumbing, MoA desktop preset persistence, delegate toolsets-arg removal, contextvar isolation (GHSA-96vc-wcxf-jjff), _save_mcp_server bool return. All server/desktop-internal. #no-ops

## Relations
- extends [[Hermes Version Targeting Strategy]]
- relates_to [[Hermes v0.17 Compatibility Decisions]]
- implements [[Hermes Release Audit Process]]
- relates_to [[Hermes v0.17.0 Audit Findings]]
- documented_in_commit 9338c595
