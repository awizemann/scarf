---
id: t-eefcfa4e
title: v0.21.1 P6: Providers, image-gen, kanban contract, auth priority, MCP device flow
status: done
added: 2026-09-08
---

## Description

Phase 6 of the Hermes v0.21.1 parity plan (brief: documents/hermes-v0.21.1-parity-agent-brief.md; findings: documents/hermes-v0.21.1-audit-report.md). Depends on P0 (flags, script lane 4).

Scope:
1. B7: add `overlayOnlyProviders` entries in ModelCatalogService.swift:737 for the plugin-registered providers absent from models.dev (meta-ai, router, commandcode, commandcode-anthropic, gemini, custom — hermes_cli/models_catalog_static.py:356-367), with the auth env/key name and base URL from each plugin's registration; run scripts/check-hermes-tables.py against a v2026.9.7 worktree until lane 4 is clean. Check the gemini-vs-google models.dev key question (VERIFY item) and resolve it.
2. B6: refresh `imageGenModels` (ModelCatalogService.swift:712) from tools/image_generation_catalog.py:37 FAL_MODELS + DEFAULT_MODEL, and add the new `meta-ai` image-gen provider (plugins/image_gen/meta-ai/plugin.yaml). Keep older entries that Hermes still accepts only if the catalog still lists them.
3. C5 kanban: `--completion-contract` on create/edit (hermes_cli/kanban_parser.py:189) gated on `hasKanbanCompletionContract`; decode `completion_contract` and `last_failure_error` from `kanban list --json` (kanban_output.py:18-24) as optionals and render last_failure_error on the card/detail. Read memory on the kanban CLI contracts first (search "kanban").
4. C6 auth: `auth priority <provider> <type> <n>`, `auth refresh <provider> [type]`, `auth add --priority`, optional target on `auth reset` (hermes_cli/subcommands/auth.py). Gate on `hasAuthPriority`. In Credential Pools add reorder (priority) and a per-credential "clear cooldown" (refresh) action. Verify every argv against `hermes auth --help` output shape at the tag.
5. C7 MCP: `mcp_servers.<n>.oauth.flow: browser|device` config key and `hermes mcp login <n> --flow {browser,device}` (subcommands/mcp.py:59, tools/mcp_oauth_device.py:108-126). Gate on `hasMCPOAuthFlow`. Add the flow field to HermesMCPServer and the editor; when device flow is chosen, run login and surface the verification URL + user code from stdout in a sheet instead of swallowing it. Read memory note architecture/hermes-mcp-config-is-a-yaml-mcp-servers-block-scarf first.
6. Tests for each parser, gate, and the provider tables script.

## Plan



## Artifacts

Branch `feat/hermes-v0211-parity`. Five commits, nothing pushed.

- `95ad4c15` fix(models): reach the four plugin providers, and an image-gen list that matches Hermes (B7 + B6)
- `d7f2190a` feat(kanban): completion contracts, and the real failure reason on the card (C5)
- `bea2b110` feat(auth): reorder a credential pool, and clear one credential's cooldown (C6)
- `d4169c52` feat(mcp): device-code OAuth — the flow key, and a sign-in that shows the code (C7)
- `23867474` fix(scripts,mcp): read the pre-modularization table paths, and clamp the flow picker (fresh-eyes fixes)

Floors re-established the Phase-4 way (symbol walked across every tag over BOTH old and new file locations): `hasKanbanCompletionContract`, `hasAuthPriority`, `hasMCPOAuthFlow` are all genuinely v0.21.1 — commits ac07da2674, 1a4bb74a40, f5afe8bd40, each first contained in v2026.9.7. No flag needed moving; the P0 doc comments were already right.

Corrections to the audit report:
- B7 is FOUR providers, not six. `gemini` is a static CANONICAL_PROVIDERS slug reachable through models.dev's `google` (via `models_catalog_static._PROVIDER_ALIASES`), and `custom` is Scarf's LocalModelProviders surface. Neither got a row.
- C5's "on create/edit" has no edit half: `kanban edit` at v2026.9.7 takes only `--result` + step handoff.
- C7's device prompt is on STDERR, not stdout.

Deliberate NO-OPs:
- `auth add --priority` — the same placement is one menu click away after the add, and the add sheet is shared with the OAuth flow.
- `image_gen.provider` picker incl. the new meta-ai image-gen backend — Scarf has no provider surface at all to add it to; that is a new Settings row needing its own floors. Split to t-e7af69d4.
- No flag for B6/B7: the FAL catalog is value-identical at both tags and all four plugin providers predate v0.21.1; overlayOnlyProviders is a merge-if-absent table.

Tests: ScarfCore 2378 passed; scarfTests 839 passed. New: `pluginRegisteredProvidersAreReachable`, rewritten `imageGenModelAllowlistShape`, `createRequestArgvIncludesCompletionContract`, `taskDecodesV0211FieldsAndToleratesTheirAbsence`, suite `CredentialPoolsAdminArgvTests` (the two index bases), suite `HermesMCPOAuthFlowTests` (oauth-block preservation + verbatim device-prompt drift alarm). ACPClientStartIdempotenceTests flaked once under full parallel load, passed on rerun.

`scripts/check-hermes-tables.py`: lane 4 clean against a v2026.9.7 worktree AND against the installed pre-tag checkout (only the 3 documented dormant-overlay WARNs + the kimi-coding non-literal skip).

Memory: appended "Phase 6" to `scarf/decisions/hermes-v0-21-1-compatibility-decisions`; appended "R3" to `scarf/architecture/hermes-mcp-config-is-a-yaml-mcp-servers-block-scarf`.

