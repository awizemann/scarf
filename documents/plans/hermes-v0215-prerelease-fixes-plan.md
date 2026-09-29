# Pre-release audit fixes — plan (C-phases)

Source: `documents/audits/hermes-v0.21.5-prerelease-audit.md` + section reports in
`documents/audits/hermes-v0.21.5-prerelease-audit/`. Alan (2026-09-28): fix all eight, same process.
Brief: `documents/plans/hermes-v0215-blind-reaudit-remediation-agent-brief.md` (same rules: charter, older-band rule,
scope rule, foreground fresh-eyes reviewer, memory/wiki, commits by path, no push) — with branch
`fix/hermes-v0215-prerelease-<phase>`, integration branch `fix/hermes-v0215-prerelease`, and findings from the
pre-release audit. New strings go straight into Localizable.xcstrings + tools/translations/*.json (6 languages).

## Phases (file-disjoint, run in parallel)
| Phase | Findings | Main files |
|---|---|---|
| C01 Personalities, project context, bundled commands, copy | S03-F1 (P1 SOUL.md), S11-F1 (P1 AGENTS.md shadowing), S03-F2 (bundled widget kinds), S04-F1 (Export All md/qmd), S06-F1 (proxy help copy) | PersonalitiesView/VM, ProjectContextBlock, ProjectAgentContextService, BuiltinSlashCommands.bundle, SessionsViewModel, HermesProxyView |
| C02 Mini-apps remote, kanban dispatch, iOS quoting | S12-F1 (mini-app Open on remote), S13a-F1 (drag to Running when dispatch skips), S15-F1 (iOS `$` in shellJoin) | MiniAppSchemeHandler, ProjectCockpitView, KanbanBoardViewModel, KanbanService, CitadelServerTransport |

## Defaults
- S03-F1: fill the editor from the loaded file; never save a draft that wasn't loaded; refuse to replace a non-empty
  SOUL.md with an empty draft without confirmation.
- S11-F1: when AGENTS.md is absent and a CLAUDE.md / .cursorrules (or any higher/lower-priority context file Hermes
  would load) exists, don't create a shadowing AGENTS.md — put Scarf's block into the file Hermes actually loads
  (match Hermes precedence at the tag, per band). Repair: projects already shadowed by a Scarf-only AGENTS.md get it
  folded back (only if the file contains nothing but Scarf's block).
- S12-F1: on remote contexts disable mini-app Open with an honest note (no asset copying).
- Close-out C03: merge, full gate (scarfTests, ScarfCore, ScarfIOS, iOS build, tables, scripts, catalog, Smoke UI if the
  fixture model works), orchestrator audit, merge to main locally.
