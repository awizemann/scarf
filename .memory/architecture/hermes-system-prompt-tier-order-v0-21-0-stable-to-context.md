---
title: Hermes system prompt tier order (v0.21.0): stable to context to volatile, so AGENTS.md precedes MEMORY.md
type: note
permalink: scarf/architecture/hermes-system-prompt-tier-order-v0-21-0-stable-to-context
tags: [hermes, context-assembly, agents-md, memory, verified]
created: 2026-09-01
updated: 2026-09-01
---

Verified against the v0.21.0 audit tree at ~/.hermes/hermes-agent-v0.21.0-audit while designing the "project charter as a Scarf feature" brief (t-94ea4f69, documents/charter-for-users-design-brief.md). Paths below are relative to that tree. This is the ordering any Scarf feature that needs text to outrank accumulated memory must reason from.

## Observations
- [fact] build_system_prompt (agent/system_prompt.py:1036) joins exactly three tiers in fixed order at :1054 — stable, context, volatile #hermes-context-files
- [fact] SOUL.md is the FIRST stable part (identity slot, agent/system_prompt.py:476-487, read from <home>/SOUL.md per agent/prompt_builder.py:2214); AGENTS.md/Project Context is CONTEXT tier (:884-909); MEMORY.md and USER.md are VOLATILE tier (:928-937) — so project instruction files ALREADY precede accumulated memory in the assembled prompt #hermes-context-files
- [gotcha] No Hermes config key injects arbitrary always-on text ahead of memory: agent.system_prompt / display.personality is appended at the TAIL at API-call time (agent/conversation_loop.py:1636-1637) and plugin sections are restricted to position after_memory (hermes_cli/plugins.py:558) #pitfalls
- [fact] AGENTS.md loads as a MERGED directory chain git-root to cwd with per-dir '## relpath' headings and an AGENTS.override.md preference (agent/prompt_builder.py:2259-2341), unlike CLAUDE.md/.cursorrules which are cwd-only; .hermes.md/HERMES.md is a nearest-ancestor walk that SHADOWS AGENTS.md entirely via first-match-wins at :2454-2459 #agents-md
- [constraint] v0.21 protected_instruction_files is a BOOLEAN plus basename-only fnmatch extra patterns; the protected set is hardcoded {agents.md, claude.md, soul.md, .cursorrules} at tools/file_tools.py:737-739 plus any file whose immediate parent dir is .hermes — un-bypassable by yolo/allowlists (:843-940) but enforced ONLY in write_file_tool and patch_tool, never in the terminal tool (:725) #security

## Relations
- relates_to [[Project-Scoped Chat and AGENTS.md Context]]
- relates_to [[Hermes Capability Gating Pattern]]
