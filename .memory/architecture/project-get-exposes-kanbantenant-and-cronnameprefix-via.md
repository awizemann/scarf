---
title: project_get exposes kanbanTenant and cronNamePrefix via existing ScarfCore readers
type: note
permalink: scarf/architecture/project-get-exposes-kanbantenant-and-cronnameprefix-via
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfProjectsMCPKit/ProjectMCPTools.swift, scarf/Packages/ScarfCore/Sources/ScarfProjectsMCPKit/ProjectMCPToolCatalog.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanTenantReader.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectCronAttribution.swift]
source_paths_inferred: false
source_sha: 4beace9d6d71c2aae455ed7eae5b600642f0f3b0
created: 2026-09-29
updated: 2026-09-29
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] Phase 4 of issue #142: `project_get` (`scarf/Packages/ScarfCore/Sources/ScarfProjectsMCPKit/ProjectMCPTools.swift`, `get(_:)`) now adds two optional fields to its JSON payload, reusing the SAME derivations `ProjectContextBlock.renderManagedBlock` uses for its AGENTS.md prose — no parallel logic:
  - `kanbanTenant` — `KanbanTenantReader(context:).tenant(forProjectPath: entry.path)`, present only when `.scarf/manifest.json` has minted one. Callers pass it as `hermes kanban create --tenant <kanbanTenant>`.
  - `cronNamePrefix` — `ProjectCronAttribution.projectTag(uuid) + " "` (i.e. `"[proj:<uuid>] "` WITH a trailing space, ready to prepend to a `--name` value), present only when the registry entry has a `uuid` (every project registered via `project_register` has one). `ProjectCronAttribution.projectTag` itself returns no trailing space — the space is added at the call site because the field's contract is "a prefix a name must start with," matching the space `ProjectContextBlock.swift:375`'s cron-jobs prose already inserts.
  - Neither field required a ScarfCore change — both readers (`KanbanTenantReader`, `ProjectCronAttribution`) were already public and already used by `ProjectContextBlock`.
  - `ProjectMCPToolCatalog`'s `project_get` description text was extended to document both fields and their intended use, so an agent discovers them without needing `ProjectContextBlock`'s rendered prose.
- Hermes Kanban investigated (read-only) at tag `v0.21.4+canary.20260927T065737Z`: `--tenant` has NO environment-variable or cron-job-config default. `hermes_cli/kanban_parser.py:84` defines `_TENANT = _arg("--tenant", help="Tenant namespace")` with no `default=os.environ.get(...)` — contrast `--author` in the same file (`_triage_sweep_args`, ~line 68) whose help text explicitly documents `$HERMES_PROFILE` as its default. `hermes_cli/kanban.py` reads `os.environ.get("HERMES_KANBAN_TASK"/"HERMES_KANBAN_RUN_ID")` for run-scoping but never for tenant. `cron/` has no tenant-related env var either (`grep -rn "TENANT" cron/` matches only unrelated doc prose and a `scope_id` comment in `scheduler_delivery.py:1454`). So a cron job MUST pass `--tenant <value>` explicitly on every `hermes kanban create` invocation it makes — there's no way to set it once for the job. This is why exposing `kanbanTenant`/`cronNamePrefix` via `project_get` matters for #142: an agent (or the cron job's own prompt) has to look the tenant up per-call.

- [correction] The "no env default" finding holds for the CLI only. The agent's `kanban_create` TOOL falls back to `os.environ.get("HERMES_TENANT")` (tools/kanban_tools.py:1055, schema note kanban_tools_schemas.py:406 @ v0.21.4 canary). Hermes itself sets HERMES_TENANT for Kanban workers (hermes_cli/kanban_db_dispatch.py:2820), and workers also use it to namespace memory writes — so setting it on a Scarf chat is NOT side-effect free; unverified which release introduced the fallback. #gotcha #kanban


## Relations
- relates_to [[scarf-projects MCP server: bundled helper, ScarfCore services, no parallel writers]]
- relates_to [[Kanban Board Architecture (v2.7.5)]]
