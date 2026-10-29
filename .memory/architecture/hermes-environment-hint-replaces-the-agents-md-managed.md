---
title: HERMES_ENVIRONMENT_HINT replaces the AGENTS.md managed block on Hermes 0.16+
type: note
permalink: scarf/architecture/hermes-environment-hint-replaces-the-agents-md-managed
tags: [issue-142, hermes-v0.16]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md]
source_paths_inferred: false
source_sha: 066664901806e40290fd1d630d87d06f20d97157
created: 2026-09-29
updated: 2026-09-29
reviewed: 2026-10-28
reviewed_by: audit:claude-code (background)
---

## Observations
- [fact] Hermes reads HERMES_ENVIRONMENT_HINT in build_environment_hints (agent/prompt_builder.py:866 @ v2026.6.5 = 0.16.0), falling back to config agent.environment_hint; absent at v2026.5.29.2 #hermes #issue-142
- [decision] HermesCapabilities.supportsEnvironmentHint gates on isV016OrLater; .empty is false so undetected hosts keep the managed AGENTS.md block (C1) #capabilities
- [invariant] ProjectContextBlock.renderEnvironmentHint is marker-free, deterministic, and carries only name/path/tenant/projectId — no config field names, cron list, template id or slash names; it lands in Hermes's cached system prompt #context
- [constraint] The long platform reference moved into the scarf-template-author skill (2.0.4); any skill change must also reach templates/awizemann/template-author/staging/skills/, which is a Memophant-managed tier left uncommitted #skills

## Relations
- relates_to [[The skill is tool-first and Scarf deletes skills that lie about it]]
