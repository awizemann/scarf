---
title: Hermes Version Compatibility Target
type: note
permalink: scarf/integration/hermes-version-compatibility-target
tags: [hermes, compatibility, versioning]
source_paths: [README.md, scarf/scarf.xcodeproj/project.pbxproj, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesLogService.swift]
source_paths_inferred: false
source_sha: 8da06bf74aa0b22581939e623f70e5dc0af37ff6
created: 2026-05-29
updated: 2026-08-20
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---

## Observations
- [target] Latest shipped Scarf is **v2.16.0** — the Hermes v0.18 line parity release (branch feat/hermes-v018-parity merged to main, tagged v2.16.0; MARKETING_VERSION 2.16.0). The Hermes catch-up trail: v2.11.0 → Hermes v0.16.0; v2.12.0 → v0.17.0; v2.13.0/v2.15.0 Scarf-internal; v2.15.1 aggregator-mismatch patch; **v2.16.0 → the Hermes v0.18 line, audited at v0.18.0 (v2026.7.1) and re-audited at v0.18.2 (v2026.7.7.2)** — see [[Hermes v0.18.0 Audit Findings]] and [[Hermes v0.18.2 Audit Findings]]. **Scarf's current Hermes target is v0.18.2 (v2026.7.7.2)**; v0.15+ remain fully supported, minimum v0.6.0. #current
- [compatibility] Minimum supported Hermes: v0.6.0 (2026-03-30). All versions v0.6.0 through v0.18.2 are verified. Older Hermes versions degrade gracefully — new behavior is capability-gated. #minimum
- [v018-target] v0.18.0 (v2026.7.1) shipped upstream and became Scarf's target in v2.16.0, re-audited against the v0.18.1/v0.18.2 patches (v2026.7.7.2). v0.18's client-relevant surface is deliberately thin — the `messages.compacted` soft-archive column (schema-detected) plus catalog-sync provider-table changes (MoA overlay, google-gemini-cli → vertex) that carry no capability flag by convention; the two v0.18 flags are `hasCronAttachToSession` and `hasMCPReauth` (see HermesCapabilities.swift `MARK: v0.18 (v2026.7.1) flags`). Predecessor v0.17.0 (v2026.6.19) was the target through Scarf v2.12–v2.15 (see [[Hermes v0.17 Compatibility Decisions]]) and required no forced compatibility changes; Scarf added the WhatsApp/SimpleX/Telegram surfaces, curator-consolidation toggle, and session-cap. Every v0.16/v0.17/v0.18 surface is capability-gated or schema-detected so older hosts render byte-identical. #status
- [schema] Scarf reads Hermes's SQLite state.db and parses CLI output from `hermes status`, `hermes doctor`, `hermes tools`, `hermes sessions`, `hermes gateway`, `hermes pairing`. Automatic schema detection provides backward compatibility: v0.16 added the `messages.active` soft-delete column (first schema change since v0.11; detected via `hasMessagesActiveColumn`); v0.17 introduced no further schema change; v0.18 adds `messages.compacted` (in-place compaction soft-archive; detected via `HermesQueryBackend.hasCompactedColumn` — SEARCH widens to `(active = 1 OR compacted = 1)` while transcript/activity queries stay active-only). #schema
- [parsing] Log lines may carry an optional `[session_id]` tag between level and logger name; `HermesLogService.parseLine` treats the session tag as an optional capture group so older untagged lines still parse. #logs
- [sync-checklist] On each Hermes bump, keep in sync: `overlayOnlyProviders` / `modelAliases` / `demotedProviders` / `imageGenModels` (vs hermes_cli/providers.py + models.py + xai_retirement.py), the platform roster (vs plugins/platforms/ + gateway/platforms/), and the search/TTS backend lists. #maintenance

## Relations
- implements [[Hermes Capability Gating Pattern]]
- supersedes [[Hermes v0.15 Capability Gating Decisions]]
- relates_to [[Hermes v0.17 Compatibility Decisions]]


- [v020-target] Hermes v0.20.0 (v2026.8.3) audited 2026-08-03 and parity implemented on branch feat/hermes-v020-parity (unmerged pending Alan's review; see [[Hermes v0.20.0 Audit Findings]] and documents/hermes-v0.20.0-audit-report.md). v0.20 capability group: isV020OrLater + hasCompressCommand/hasCuratorAdopt/hasApprovalsSuggest/hasCronRuns/hasSessionsExportFormats. Forced fixes shipped: /compact→/compress gating, curator-managed-skills header dual parse, provider tables (vercel/fireworks/vertex/upstage/deepseek), buzz platform, capability-aware max_turns display (500 at v0.20+, 60 before). Pre-existing bugs fixed same cycle: skills uninstall/update --yes (never existed; uninstall needs stdin "y"), agent.runtime_metadata_footer→display.runtime_footer.enabled, google_chat/teams platform ids, global display.busy_ack_enabled, slash_command_notice_ttl_seconds removed. Adopted features: pinned/last-activity sidebar + session_model_usage dashboard (schema-detected), export formats (md/html/qmd/trace + --redact; remote contexts stdout-only jsonl/trace), approvals suggest, cron runs history, compaction-summary styling (hydration-layer marker classification mirroring ContextCompressor.classify_summary_content — NOT the ACP _meta replay path, which the DB clobbers). state.db SCHEMA_VERSION 25: all additive, DDL now lives in hermes_state_common.py. check-hermes-tables.py default path now ~/.hermes/hermes-agent. #v020


- [update-2026-08-12] The v0.20 parity work is fully MERGED to main (shipped in the v2.18.x line; the "unmerged pending review" caveat above is stale). The Phase 3 leftovers run also landed on main 2026-08-12 (commits 0bdbf90..75456b4): browser.cloud_provider key fix, HermesVersionCache single cached/persisted version probe, and the remaining v0.20 settings surfaces except import-agent/sync (still t-1cc0a505). New capability flags added with per-key semver floors (v0.18/v0.19/v0.20) — see HermesCapabilities.swift. Scarf's Hermes target remains v0.20.0 (v2026.8.3); upstream main has ~1,200 unreleased commits including the Browser Use CLI 3.0 default-backend flip — audit when the next tag lands (skill: hermes-release-audit). #current


- [v0204-target] Hermes v0.20.4 (v2026.8.18) audited 2026-08-20 (patch line v0.20.1–v0.20.4, ~3,016 commits); parity implemented on branch feat/hermes-v0204-parity (12 commits, UNMERGED pending Alan's review, not pushed). Schema effectively additive (sessions +hidden/+last_read_at/+title_source/+git_metadata_generation, SCHEMA_VERSION 26); ACP wire clean. New patch-level flag group isV0204OrLater (8 flags). See [[Hermes v0.20.4 Audit Findings]] and [[Hermes v0.20.4 Compatibility Decisions]]. Once merged, Scarf's target becomes v0.20.4; upstream method note: diff _BUILTIN_SUBCOMMANDS in hermes_cli/main.py (cli.py has no argparse). #current
