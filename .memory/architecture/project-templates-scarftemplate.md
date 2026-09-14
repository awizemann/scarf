---
title: Project Templates (.scarftemplate)
type: note
permalink: scarf/architecture/project-templates-scarftemplate
tags: [templates, projects, install]
source_paths: [scarf/scarf/Core/Services/ProjectTemplateService.swift, scarf/scarf/Core/Services/ProjectTemplateInstaller.swift, scarf/scarf/Core/Services/ProjectTemplateExporter.swift, scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift, scarf/scarf/Core/Services/TemplateURLRouter.swift]
source_paths_inferred: false
source_sha: 94c88e7f1322110b4bfd71534d632d453bdc177e
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-09-12
reviewed_by: audit:claude-code (background)
---

## Observations
- [format] .scarftemplate is a zip containing: template.json (manifest with id/name/version/contents claim), README.md (preview), AGENTS.md (REQUIRED — cross-agent instructions standard used by Claude Code, Cursor, Codex, Aider, and 20+ other agents), dashboard.json, optional instructions/ (CLAUDE.md/GEMINI.md/.cursorrules/.github/copilot-instructions.md), optional skills/<name>/ (installed to ~/.hermes/skills/templates/<slug>/), optional cron/jobs.json (registered with `[tmpl:<id>] …` prefix, immediately paused), optional memory/append.md (appended to MEMORY.md between scarf-template:<id>:begin/end markers) #format
- [services] ProjectTemplateService (inspect + validate + plan), ProjectTemplateInstaller (execute plan), ProjectTemplateExporter (build from project), ProjectTemplateUninstaller (reverse via lock file). UI in Features/Templates/. Deep links via TemplateURLRouter + scarfApp.swift onOpenURL #services
- [deep-link] scarf://install?url=<https URL> and file:// URLs for .scarftemplate files trigger install flow #url-scheme
- [lock-file] <project>/.scarf/template.lock.json is written after every install and drives uninstall. Only files in lock.projectFiles are removed — user-added files (e.g. sites.txt) preserved. If every file in dir was template-installed, dir is removed; otherwise dir stays. Skills namespace removed wholesale (isolated). Cron jobs removed via `hermes cron remove <id>`. Memory block stripped between markers, rest of MEMORY.md intact #uninstall
- [security-design] Templates can only write file types declared in manifest (README, AGENTS, dashboard, instructions/, skills/, slash-commands/, memory/append.md, optional config). buildPlan creates TemplateFileCopy only for these types, preventing writes to config.yaml, auth.json, sessions, or credential paths via architectural guarantee (not explicit refusal check). Preview sheet is load-bearing: user's only trust boundary is that the sheet is honest about everything about to be written #security
- [no-undo] No 'undo' for uninstall — destructive. Re-install means running install flow again #semantics

## Relations
- extended_by [[Template Configuration Schema (v2)]]
- extended_by [[Template Catalog Pipeline]]
- relates_to [[Project-Scoped Chat and AGENTS.md Context]]
