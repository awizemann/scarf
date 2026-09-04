---
id: t-2cea158a
title: Projects P6: skill rewrite to prefer MCP tools + bad-skill cleanup
status: done
added: 2026-09-03
priority: high
---

## Description

Phase 6 of projects-first-class (branch feat/projects-first-class; depends on P5 t-3d915f7f). (1) Bump scarf-template-author (Resources/BuiltinSkills.bundle, semver-gated by SkillBootstrapService) to instruct: use the scarf-projects MCP tools for registration, dashboard writes, and config; hand-edit files ONLY when the tools are absent (remote hosts). Kill step 8's raw projects.json append as the primary path. Update scarf-miniapp-author only if its instructions reference registry editing. (2) SkillBootstrapService learns a known-bad-skills denylist (starting with scarf-project-workflows) and removes matching installed skills at bootstrap. (3) Update the AGENTS.md managed-block platform reference (ProjectContextBlock.renderManagedBlock static section) to mention the tools — note: changing rendered bytes affects the byte-identical idempotency tests; update fixtures deliberately. Tests: bootstrap version-gating + denylist, ProjectAgentContextService idempotency stays green.

## Plan



## Artifacts



