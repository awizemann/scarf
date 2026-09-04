---
id: t-18d1fedf
title: Projects follow-up: re-sync stale v1.2.0 skill copy in templates/ staging
status: done
added: 2026-09-03
---

## Description

P6 investigated (2026-09-04). Confirmed templates/awizemann/template-author/staging/skills/scarf-template-author/SKILL.md is genuinely stale (version: 1.2.0, 504 lines, "skill invoked by trigger phrases") vs the canonical v2.0.0 tool-first copy at scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md (version: 2.0.0, 599 lines, "READ THIS FIRST — use the scarf-projects tools, don't hand-edit Scarf's files"). The BuiltinSkills.bundle copy is the one Scarf actually ships to ~/.hermes/skills/scarf/ at runtime — genuinely canonical.

Per Memophant's write_tier_file tool description, the templates/ tier is READ-ONLY over MCP ("the agent APPLIES templates; authoring them is a Memophant flow") — a write with tier:"templates" is rejected outright, confirming charter C7 and the calling agent's instruction that this tier must not be hand-edited by an agent. No sanctioned agent-facing sync tool exists today, so NO EDIT was made to templates/ — it remains at v1.2.0, genuinely stale.

Left tools/widget-schema.json untouched: its comment correctly names the templates/ staging path as where the skill file for template authors lives; it isn't a broken pointer, so repointing it would not fix anything.

Recommendation for a human/maintainer-driven fix: either (a) have a human copy scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md over the templates/ staging copy through Memophant's own template-authoring flow (outside MCP), or (b) decide the templates/ staging copy is a deliberately different, human-curated variant (in which case leave it alone). Flagging to Alan for a decision — could not be verified/synced by the agent.

## Plan



## Artifacts

Alan synced by hand (cp from BuiltinSkills.bundle); orchestrator verified byte-identical, version 2.0.0. Tier commit remains Alan's via Memophant.

