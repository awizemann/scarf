---
title: Hermes v0.20.4 Audit Findings
type: note
permalink: scarf/integration/hermes-v0-20-4-audit-findings
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesCronJob.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift]
source_paths_inferred: false
source_sha: 6a4e87bbc982d020cfdea31b2dfc5cec9413393c
created: 2026-08-20
updated: 2026-08-20
---

Source-verified audit of Hermes v0.20.1–v0.20.4 (v2026.8.3..v2026.8.18, ~3,016 commits) against Scarf's v0.20.0 target, run 2026-08-20. Full report: documents/hermes-v0.20.4-audit-report.md. No implementation yet — pending Alan's scope decision.

## Observations
- [verdict] Schema effectively unchanged (messages/FTS/session_model_usage byte-identical; sessions +4 additive cols: git_metadata_generation, title_source, hidden, last_read_at; SCHEMA_VERSION 25→26 declarative). ACP wire clean (no new discriminators; session_info_update now fires mid-turn, same payload). Light-to-medium additive cycle. #verdict
- [breaks] Three genuine breaks-on-upgrade: (1) personality pickers go empty — built-ins moved from config.yaml to hermes_cli/personality.py BUILTIN_PERSONALITIES; (2) iOS cron withEnabled(true) can't resume paused jobs — new is_job_runnable() gates on state=="paused"/paused_at, Scarf must clear both (macOS CLI path fine); (3) skills update silently skips locally-edited skills exit 0 — Scarf updateAll over-reports. Plus provider drift: new overlay-only provider `actual` (+aliases actual-computer/actualcomputer/aci) and openai-codex label → "ChatGPT or Codex Subscription". And sessions.hidden needs an AND hidden=0 probe-gated filter. #tier1
- [pre-existing] Personalities feature was already dead twice over: prefix filter `personalities.` vs actual `agent.personalities.` keys, and reads `.prompt` where Hermes uses `.system_prompt`. Also cron jobs.json whole-file decode fails on null prompt/name/state; stale doc comments in GatewayPlatformSettings.swift:21-29 and the HermesDataService FTS-parity comment; Discord allowed_channels has no editor (kind(for:) nil). #bugs
- [gating] All v0.20.1–0.20.4 features need patch-level atLeastSemver(0,20,4) flags (isV0204OrLater), NOT the existing isV020OrLater — a v0.20.0 host lacks everything here. Schema cols use column probes per convention. #gating
- [noop] Deliberate NO-OPs recorded in the report: platform roster unchanged (22), gateway list byte-identical, managed_scope.py zero diff, all security commits server-side, jobs.json envelope unchanged, no `cron attach` subcommand, no written config key renamed (migrations 34–37 are value rewrites; migration 34 force-resets personality selection once). #noop
- [method] cli.py has NO argparse — the real verb roster is `_BUILTIN_SUBCOMMANDS` in hermes_cli/main.py; diff that next cycle, not cli.py add_parser. All four historic argv bugs confirmed fixed. #method

## Relations
- relates_to [[Hermes Version Compatibility Target]]
- relates_to [[Hermes v0.20.0 Audit Findings]]
- implements [[Hermes Capability Gating Pattern]]
