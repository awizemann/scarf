---
id: t-caba4971
title: Audit P26: Citation and doc-comment sweep (C2)
status: done
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

Shipped in `ced2866c` on `fix/whole-surface-audit-r2` (comment-only except two small code fixes). Every corrected citation was re-read out of `git -C ~/.hermes/hermes-agent show v2026.9.7:<path>` before being written. NB the Hermes repo is FLAT — `hermes_constants.py`, `cli.py`, `cron/`, `gateway/`, `tools/`, `hermes_cli/` are at the repo root, there is no `hermes/` prefix.

## Fixed

1. **PowerSettingsWriter.swift:3-5,13-17** — `VALID_REASONING_EFFORTS` is `hermes_constants.py:873` (`VALID_REASONING_EFFORTS = ("minimal", "low", "medium", "high", "xhigh", "max", "ultra")`), `parse_reasoning_effort` is `:876`, alias set `:885` (`if effort in {"none", "false", "disabled"}:`). ALSO corrected an overstatement the finding didn't list: the doc called `off` a Hermes-valid disable alias. It is not in either set — `canonicalDisableSpelling` (already correct since P19) exists precisely because of that. No behaviour change.
2. **HermesCLIOutcome.swift:13-15** — nine bare `return`s are `skills_hub.py:659,662,667,669,685,693,701,712,718` (all verified by line). **:171-173** — `_install_blocked` reached from the scan verdict at `:699` (was `:707`); `is already installed at` `:682`, `Use --force to reinstall.` `:684` (was `:683-686`). Other cites in that block (`_print_error` :134-135, `_pinned_sources` :582, `_print_fetch_failure` :592, `_install_blocked` def :498, `_invalid_path` :506, `:520`, `:525`, `:537`, `_confirm_install` :642) were all verified CORRECT and left alone.
3. **HealthViewModel.swift:88-92** — MARK + doc now say `hermes security audit`.
4. **HermesCapabilities.swift** `hasKanbanDiagnostics` — rewritten to the surface it really gates: `kanban diagnostics [--json]` (`kanban_parser.py:251-256`, emitter `kanban.py:627-695`, JSON `:678-681`) + `kanban create --max-retries N` (`kanban_parser.py:176-181` inside the `create` subcommand at `:148-204` — NOT `add`, caught in fresh-eyes). `hallucination_gate` / `auto_blocked_reason` return zero `git grep` hits at v2026.9.7; the only zombie machinery is `reap_worker_zombies` (`kanban_db_dispatch.py:190`), internal with no wire surface — the doc now says that rather than "no zombie detection in Hermes", which would have been false.
5. **KanbanColumnView.swift:20-22,30-31** — the v0.13 gate makes `KanbanCardView` return `[]` for its diagnostics list (`KanbanCardView.swift:75`), no auto-block sub-line exists; `supportsKanbanCompletionContract` gates the v0.21.1 `last_failure_error` row (`KanbanCardView.swift:325-327`), not a v0.16 goal-mode badge.
6. **HermesKanbanDiagnostic.swift:203 + KanbanModelsTests.swift:616** — `:676-678` → `:678-681` (`_print_json([{"task_id": tid, **meta.get(tid, {}), "diagnostics": …}` at `:679-680`, `return 0` at `:681`). **KanbanService.swift:157-160** carried a DIFFERENT wrong cite (`kanban.py:350-370`, which is `_cmd_add`'s arg validation); the "unchanged since v2026.5.7" claim is true and now cites `v2026.5.7:kanban.py:1365-1375`, verified byte-equivalent JSON shape.
7. **KanbanFilters.swift:8-9** — `list_tasks` appends `AND tenant = ?` for any non-`None` value (`hermes_cli/kanban_db.py:1472-1479`; note the path is `hermes_cli/kanban_db.py`, not root `kanban_db.py`), so `--tenant ""` matches only the empty-string tenant and no spelling means NULL. No Scarf caller passes `""`, so comment-only.
8. **Past-EOF `gateway/config.py`** (file is 840 lines). `profile_routes` / `multiplex_profiles` form precedence is `gateway/config_loader.py:76` (`("profile_routes", …, "none", …)`) + `_bridge_lookup:100-104`, consumed at `gateway/config.py:745`; `multiplex_profiles` itself at `config.py:708-710`; `multiplex_profile_allowlist` at `config_loader.py:75` presence bridge + `config.py:668-670` `pick()` consumed at `:734`. Fixed at `ProfileRoutesYAML.swift:10,75`, `HermesProfileRoutes.swift:168,193`, `ProfileRoutesWriter.swift:13`, `SettingsViewModel.swift:959`, `ProfileRoutesTests.swift:58`, `HermesConfig+YAML.swift:978`, `HermesV0204ConfigTests.swift:122`. The platform-`extra` bridge (`config.py:1719-1809`) is really `config_loader.py:197-213` `_SHARED_KEYS` → `_bridged_keys:224-236` → `extra.update(bridged)` `:283`, plus `PlatformConfig.from_dict` `:415,419,442` — fixed at `SectionAuditF5PlatformExtraKeyTests.swift:8-19`. Also fixed `gateway/run.py:23923` (file is 5475 lines) → `:4211-4212` in `_profile_name_for_source`.
9. **slack adapter** `:9058` (file is 6508 lines) → `plugins/platforms/slack/adapter.py:5920` inside `_slack_require_mention` (`:5917-5925`). (The `HermesConfig+YAML.swift:482` instance the finding named was **already fixed by P23** — it now cites `config_loader.py:200` and `adapter.py:5917-5926`.)
10. **Checkpoints flip claim** (`HermesConfig+YAML.swift:192,418`) — `enabled` never flipped in the supported window; `cli.py` reads `cp_cfg.get("enabled", False)` at v2026.3.30:1163, v2026.8.31:5501 and v2026.9.7:2755. Only `max_snapshots` moved (50 → 20 at v0.13.0; v2026.9.7:2756 = 20). The parse comment now says `enabled` is an absent-vs-explicit-false sentinel, not a flip sentinel.
11. **`displayCheckpointsEnabled`'s doc** was attached above `displayTelegramRichMessages` (`HermesConfig.swift:1374-1391`), leaving the checkpoints resolver undocumented — moved it onto its own function and anchored both resolvers at the target tag.
12. **`withEnabled`** (`HermesCronJob.swift:255-258`) — `_evaluate_due_job:2910` and the roster filter do NOT call `is_job_runnable`. Its one in-file call site is the claim gate `cron/jobs.py:2509`; the scheduler's own scan filter is `cron/scheduler_provider.py:261` (other callers: `hermes_cli/config.py:3114`, `tools/cronjob_tools.py:191`).
13. **Repeat consumption** (`IOSCronViewModel.swift:180`, `M5FeatureVMTests.swift:679`) — `:3019-3032` is past EOF (jobs.py is 3172 lines but the real chain is) `mark_job_run:2239` → `_advance_after_run:2266` → `repeat["completed"] += 1` at `:2203-2217`. The function is `_advance_after_run`, not `_apply_run_completion` (which does not exist at this tag). Also fixed the adjacent past-EOF `jobs.py:3210-3231` "loader recomputes" claim — `load_jobs:1237-1283` does NOT recompute; the real path is `_evaluate_due_job:2925` → `_recover_missing_next_run:2690-2705`.
14. **`openai-api`** (`ModelCatalogService.swift:500-507,526`) — `PROVIDER_TO_MODELS_DEV` carries `"openai-api": "openai"` at `agent/models_dev.py:110`, so it is a faithful mirror, not a Scarf extension.
15. **`buzz`** (`HermesTool.swift`) — the grouping header was **already fixed by P23 (`7644b37d`)** to `-- v0.19.1 additions` with the floor-walk rationale; one leftover "`buzz` has had since v0.20" at `:171` is now v0.19.1. Re-walked all 32 tags: `plugins/platforms/buzz/` first exists at `v2026.7.30` = 0.19.1.
16. **check-hermes-tables.py:139,222,422** — skip set is `models_catalog_static.py:360-362` (the `auth_type in {…}` test opens at `:360`), `_canonical_slugs` skip is `:360`. Script logic untouched (P27 owns it); it still runs green (`OK aliases=87 aggregators=8 overlays=25`).
17. **`decodeSkills`** (`HermesCronJob.swift:80-89`) — overstatement rewritten. Hermes does NOT degrade: `_normalize_skill_list` falls through to `list(skills)` (`cron/jobs.py:391`), which raises TypeError on a number/bool and returns the KEYS of a mapping, unguarded through `_apply_skill_fields:403` → `_normalize_job_record:456` → `list_jobs:1851`. The comment now documents Scarf's divergence as deliberate (read-only viewer; one bad row must not blank the board). No behaviour change.
18. **`latenessDisplay`** (`HermesCronJob.swift:1024-1032`) — the catch-up path cannot produce `-1s late`: the writer clamps with `max(0.0, (now - d.next_run_dt).total_seconds())` at `cron/jobs.py:2972` before stamping `lateness_seconds`. The clamp guards a hand-edited `jobs.json` only; comment now says so.
19. **`computeConfiguredPlatforms`** (`PlatformsViewModel.swift:128`) — CODE. Now uses `HermesYAML.plainKeySeparatorIndex` (made `public`, documented as the one separator rule shared with the parser and `GatewayConfigWriter.flowPairSeparatorIndex`) instead of `firstIndex(of: ":")`. `slack:dev: {}` no longer registers a configured `slack`. Side benefit: `slack:{}` (no space) is now correctly rejected, matching what PyYAML does with it.
20. **`overlayMetadata(for:)`** (`ModelCatalogService.swift:181-189`) — CODE. Added the raw-then-canonical fallback `providerByID:341-352` and `validateModel:604` already have. `grok-oauth` (alias → `xai-oauth`, an `overlayOnlyProviders` key) previously returned nil, so `CredentialPoolsOAuthGate` saw no `authType` and `CredentialPoolsView.keyless` read false for an OAuth-only provider.
21. **Stale MCP cites** (folds in `t-1d25d4d5`) — `mcp_oauth_device.py`: the three-line prompt `print` is `:126-127` (was `:125-126`), the `min(expires_in, timeout)` deadline is `:124-125` (was `:123-124`), the poll loop is `:132-144` (was `:131-140`). Fixed at `HermesMCPDevicePrompt.swift:40,50` and `MCPLoginController.swift:251-254`. `gateway.py:8958` is past EOF (6202 lines) → `hermes_cli/gateway.py:6133` (`print("✗ Gateway is not running")`), fixed at `GatewayViewModel.swift:353` and `GatewayViewModelTests.swift:68`.

## NO-OPs (already fixed, with evidence)

- **`pluginsDisableFailure` dead marker** (named in the audit doc's P26 summary, not in the task bullets) — ALREADY FIXED. `HermesCLIOutcome.swift:310-324` already documents `was removed.` as dead with the floor walk, and the marker is already out of the list. Re-verified: `_refuse_legacy_relay` is defined at `plugins_cmd.py:996` inside `cmd_enable` (`:987`) and called only from `:1002`/`:1007`; `cmd_disable` is `:1182`. Every cite in that block is correct.
- **`HermesConfig+YAML.swift:477-478,482`** (the `config.py:1719-1720 → :1809` and `adapter.py:9058` instances the finding located there) — ALREADY FIXED by P23: the Telegram reader now cites `plugins/platforms/telegram/adapter.py:5030` and the Slack one `gateway/config_loader.py:200` + `adapter.py:5917-5926`.
- **`HermesTool.swift` `buzz` grouping header** — ALREADY FIXED by P23 (`7644b37d`); only the one-line `since v0.20` leftover needed touching.
- **`GatewayViewModel.swift:130`** `hermes_cli/subcommands/gateway.py:108` — checked because it looked past-EOF; it is CORRECT (`gateway_subparsers.add_parser("list", help=…)` with no arguments). Left alone.

## Tests

- New `scarf/Packages/ScarfCore/Tests/ScarfCoreTests/HermesP26CitationSweepTests.swift` — 4 tests: alias fallback resolves `grok-oauth` → `xai-oauth` overlay (with table preconditions asserted so a table edit fails loudly), raw id still wins, unknown stays nil, and the `plainKeySeparatorIndex` contract (`slack:dev: {}` → key `slack:dev`; `slack:dev` → nil).
- New `colonInsideATopLevelKeyDoesNotInventAPlatform` in `scarf/scarfTests/ConfigYAMLScalarQuotingTests.swift` drives the VM end to end.
- Revert-proof: reverting the `overlayMetadata` fallback fails `overlayMetadataResolvesAnAliasSpelling` with 3 issues; reverting `computeConfiguredPlatforms` to `firstIndex(of: ":")` fails the new Mac test on both `slack` and `teams`. (Gotcha: `-only-testing:<Suite>/<swiftTestingFunc>` silently selected NOTHING and reported TEST SUCCEEDED — the revert check has to run the whole suite.)
- ScarfCore: **2590 tests / 172 suites PASS**. First full run flagged 4 issues in `ACPClientStartIdempotenceTests`, `SSHScriptRunnerTests.drainsLargeStdoutWithoutTimeout` and `M0bTransportTests.localTransportRunProcessDrainsLargeStdoutAndStderr` — all known load-flaky, all pass in isolation, none of those files touched; the second full run was clean.
- `scarfTests/ConfigYAMLScalarQuotingTests`: 11/11 pass on macOS.
- `xcodebuild -scheme scarf -configuration Debug build`: BUILD SUCCEEDED.
- `python3 scripts/check-hermes-tables.py`: OK (3 deliberate dormant-overlay WARNs + the known `kimi-coding` non-literal WARN).

## Fresh-eyes findings on my own diff

1. I had written "no darwin zombie detection in Hermes" — FALSE, `reap_worker_zombies` exists at `kanban_db_dispatch.py:190`. Narrowed the claim to "internal child-process reap with no wire surface" before committing. (A wrong correction is worse than the original.)
2. I had written `kanban add --max-retries`; the subcommand is `create` (`kanban_parser.py:148`). Fixed.
3. I cited `hermes_cli/kanban.py:629` as the `_cmd_diagnostics` def; it is `:627`. Fixed.
4. I cited `gateway/config.py:437` for the `extra:` read; that line is `reply_to_mode`. The real read is `:419` inside `from_dict` at `:415`, passed at `:442`. Fixed.
5. Regression check on the separator change: `slack: {}`, `slack:`, `slack:\t`, `slack:  # work` and CRLF all still resolve (covered by the pre-existing `flowEmptyAndCommentedSectionsCountAsConfigured` cases, which still pass). The one newly-rejected shape is `slack:{}`, which YAML does not read as a block mapping either — so this is strictly more faithful.
6. Regression check on the `overlayMetadata` fallback: could it return a WRONG overlay? `canonicalProviderID("openai")` → `openrouter`, which has no overlay, so `openai` still answers via its raw key. Every alias whose canonical form has an overlay shares that provider's auth shape by construction, and all three consumers (`CredentialPoolsOAuthGate.authType`, `CredentialPoolsView.keyless`, `ModelPickerSheet`) want exactly that. It now matches `providerByID`.

## Tasks created

None — everything I found in passing (`gateway/run.py:23923`, `jobs.py:3210-3231`, the `off`-alias overstatement, `gateway.py:6112-6115`/`subcommands/gateway.py:108` verification) was inside the same comments this phase rewrites, so fixing them in place beat deferring them. `check-hermes-tables.py`'s logic was left entirely to P27.

