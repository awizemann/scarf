---
id: t-caba4971
title: Audit P26: Citation and doc-comment sweep (C2)
status: todo
added: 2026-09-09
---

## Description

Round-2 whole-surface audit phase P26. Source: `documents/hermes-v0.21.1-whole-surface-audit-round2.md`; brief: `documents/hermes-v0.21.1-parity-agent-brief.md`. Opus agent, fresh-eyes review, memory note. All LOW; charter C2 — comments that assert things about Hermes that are not true, several introduced or left by P14/P15/P16 themselves. All Hermes refs at v2026.9.7.

- `PowerSettingsWriter.swift:4` cites `hermes_constants.py:942` for `VALID_REASONING_EFFORTS` (actual `:873`); `:5`/`:15` cite `:967` for `parse_reasoning_effort` (function `:876`, alias set `:885`)
- `skillsInstallFailure` doc: the nine bare returns are `skills_hub.py:659,662,667,669,685,693,701,712,718`, not `:691,:696,:711,:715`; "is already installed at" is `:682` not `:683`; `_install_blocked` is `:699` not `:707` · `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift:13-15,136-137`
- Health section header/doc say "Supply-chain audit (`hermes audit`, v0.15)" and "True while `hermes audit` is shelling out" — the verb is `security audit`, and the same file elsewhere warns bare `hermes audit` is not a verb · `scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift:88-93`
- `hasKanbanDiagnostics`'s doc still describes the deleted surface (hallucination gate, `auto_blocked_reason`, darwin zombie detection, "read through the `kanban show` JSON surface"); the flag now gates `kanban diagnostics --json` + `max_retries` · `HermesCapabilities.swift:164-168`
- `KanbanColumnView.swift:20-22,30-31` — `:22` still cites "the diagnostics dot + auto-block sub-line"; `supportsKanbanCompletionContract` documented as the v0.16 goal-mode badge gate
- `hermes_cli/kanban.py:676-678` cited for the fleet diagnostics JSON shape; `_print_json` is `:679-680`. Two places · `HermesKanbanDiagnostic.swift:203`; `KanbanService.swift:154-160`
- `KanbanListFilter`'s comment claims Hermes treats `--tenant ""` as "no tenant"; `list_tasks` appends `AND tenant = ?` for any non-`None` value · `KanbanFilters.swift:8-9,58-60` · `kanban_db.py:1472-1479`
- Past-EOF `gateway/config.py` citations: `:1719-1720 → :1809` (real `config_loader.py:197-215,226-236,283`) at `HermesConfig+YAML.swift:477-478`; `:1190-1195,1413-1423` at `:794`; `:1345-1352` at `ProfileRoutesYAML.swift:74`; `:1356` at `SettingsViewModel.swift:894` — real `gateway/config.py:668-670,708-710,734`. File is 840 lines.
- Past-EOF `plugins/platforms/slack/adapter.py:9058` for `require_mention`; file is 6508 lines, real read `:5917-5920` · `HermesConfig+YAML.swift:482`
- Checkpoints parse comment claims "v0.21 flipped both server-side defaults"; the file's own resolvers prove `enabled` never flipped in range and put 50→20 at v0.13.0 · `HermesConfig+YAML.swift:330-332` vs `HermesConfig.swift:1376-1391,1421-1430`
- `displayCheckpointsEnabled`'s entire doc comment is attached to `displayTelegramRichMessages`, leaving the checkpoints resolver undocumented · `HermesConfig.swift:1376-1410`
- `withEnabled`'s doc cites `_evaluate_due_job :2910` / roster filter `:3009`; `is_job_runnable` has ONE call site, `cron/jobs.py:2509` · `HermesCronJob.swift:247-248`
- `cron/jobs.py:3019-3032` cited for repeat consumption; real site `:2193-2212` (`_apply_run_completion`) via `mark_job_run:2239` · `IOSCronViewModel.swift:180`
- `capabilityProviderOverrides`' doc claims `openai-api` is a Scarf extension Hermes has no entry for — `PROVIDER_TO_MODELS_DEV` carries `"openai-api": "openai"` · `ModelCatalogService.swift:500-507,526` · `agent/models_dev.py:111`
- `buzz` filed under "-- v0.20 additions" but first appears v2026.7.30 = 0.19.1 · `HermesTool.swift:120-124`
- Table-script offsets: skip set is `models_catalog_static.py:361-362` not `:365`; the `_canonical_slugs` skip is `:360` not `:357` · `scripts/check-hermes-tables.py:139,222,422`
- `decodeSkills` claims a non-list/non-string `skills` is "treated as skill-less"; `_normalize_skill_list` raises out through `list_jobs` · `HermesCronJob.swift:80-84` · `cron/jobs.py:384-397`
- `latenessDisplay` claims the catch-up path can produce `-1s late`; Hermes clamps at the writer · `HermesCronJob.swift:1002-1004` · `cron/jobs.py:2972`
- `computeConfiguredPlatforms` splits at `firstIndex(of: ":")`, contradicting its own comment and diverging from `plainKeySeparatorIndex`/`flowPairSeparatorIndex` · `PlatformsViewModel.swift:115` vs `:106-107`
- `overlayMetadata(for:)` is the one provider-resolution path doing a RAW-only lookup with no alias fallback, unlike `providerByID:341-352` and `validateModel:604` · `ModelCatalogService.swift:181-183`
- Stale MCP cites: `mcp_oauth_device.py:125-126` → `:126-127`; `:123-124` → `:124-125`; `:131-140` → `:132-144` (`HermesMCPDevicePrompt.swift:40,50`, `MCPLoginController.swift:189-192`); `gateway.py:8958` is past EOF (file 6202 lines; real `:6133`) · `GatewayViewModel.swift:306`

## Plan



## Artifacts



