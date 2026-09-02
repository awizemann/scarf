---
title: Hermes v0.20.4 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-20-4-compatibility-decisions
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPersonalities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesCronJob.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/OptionalMCPCatalog.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/CuratorService.swift]
source_paths_inferred: false
source_sha: 6f67608679153925b5c6d55816c917ddd76bc3a2
created: 2026-08-20
updated: 2026-08-20
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

What shipped for the Hermes v0.20.4 (v2026.8.18) cycle and why. Branch feat/hermes-v0204-parity, 12 commits (7181436..2430b64), built 2026-08-20 by 9 phase agents + fresh-eyes audit + 3 fix agents. MERGED to main (08bb30e) and SHIPPED in v2.20.0 (cut 2026-08-20, Sparkle update verified by Alan). Findings basis: [[Hermes v0.20.4 Audit Findings]].

## Observations
- [decision] Capability gating is PATCH-level this cycle: isV0204OrLater = atLeastSemver(0,20,4) with 8 flags (cron pause-marker, builtin personalities, curator ledger/purge/entry-rollback, skills project-trust/update-force, MCP identity_header) — isV020OrLater would wrongly light on v0.20.0 hosts. Schema features (hidden, last_read_at, listable-children) use column probes plus a JSON1 probe (remote infers from sqlite3 version ≥3.38). #gating
- [decision] Personalities: 14 built-ins hardcoded (HermesPersonalities.swift) and unioned with agent.personalities entries ONLY when hasBuiltinPersonalitiesInCode — on pre-0.20.4 hosts config is authoritative (a deleted built-in stays deleted). Prompt preview ports render_personality_prompt (system_prompt + Tone/Style lines). Fixed pre-existing prefix bug (agent.personalities.) and system_prompt/bare-string forms. #personalities
- [decision] iOS cron enable/disable now routes through `hermes cron resume|pause` via CitadelServerTransport (full Hermes semantics: next_run_at recompute, one-shot refusal), JSON write demoted to fallback that clears next_run_at (Hermes recomputes on load) and never runs after a CLI refusal. stateDisplay uses ported effective_job_state (enabled=true never shows paused). Pause-marker writes are UNGATED — markers are native on v0.20.0 too; hasCronPauseMarkerGate exists as documentation only. #cron
- [decision] Unread indicator uses Hermes-faithful last_active = MAX(last_activity_at, MAX(messages.timestamp)) correlated subquery (heartbeat is rate-limited/best-effort so messages-max dominates); only in the list query, gated on hasLastReadAtColumn; Scarf never writes last_read_at. #sessions
- [decision] multiplex_profile_allowlist: top-level spelling wins over gateway.* (mirrors Hermes); flow lists parse via shared HermesYAML.parseFlatFlowList (also used by ProjectSkillsScanner); scalar AND mapping values fail closed to []; ProfileRoutesSection warning fires only when multiplexing configured. #config
- [decision] MCP identity_header reader matches Hermes validation exactly (drops header on unknown value_from / blank name / value-less static; strict_redirect_headers uses Python truthiness); editor refuses to write configs the reader would drop. Catalog picker (20-entry v0.20.4 roster) prefills; .http entries write NO transport key (matching hermes mcp install); asana/atlassian/paypal/square are http despite /sse URLs. Byte-preservation regression suite pins unknown-nested-block survival. #mcp
- [decision] Curator purge is a separate permanent-delete surface (dry-run preview → destructive sheet; model-owned canPurge gate) distinct from prune=archive; ledger parser is column-offset-exact vs _cmd_ledger; purge sentinel matched case-insensitively (Hermes prints lowercase). #curator
- [fact] Deliberately descoped to backlog: approvals test / peer / verify / plugins search CLI surfaces, cron monitor-mode editor fields (--continuity/--monitor-script/--monitor-url round-trip via extra already), compression.codex_responses_native + security.approval.transport + curator.archive_ttl_days + skills.ledger settings, Discord allowed_channels editor. #descoped
- [gotcha] Process learning: the fresh-eyes lead auditor fabricated findings citing sub-agent results it never received, then self-retracted; orchestrator re-verified every retracted claim directly — all happened to be substantively true. Lesson: require auditors to cite only their own tool-call evidence, and re-verify before acting on any multi-agent audit. Also: cli.py has no argparse — diff _BUILTIN_SUBCOMMANDS in hermes_cli/main.py next cycle. #process
- [fact] Final state: 1335 ScarfCore tests / 81 suites green, macOS + iOS builds green, check-hermes-tables.py exits 0 at the tag. Audit-report erratum: background_review nests under auxiliary. (not agent.) — corrected in code, report line stale. #verification

## Relations
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.20.4 Audit Findings]]
- supersedes_partially [[Hermes v0.20 Compatibility Decisions]]
