---
id: t-cd33bd6d
title: v0.21 final audit + memory validation + release handoff
status: todo
added: 2026-09-01
priority: high
---

## Description

After W0–W9 land: orchestrator audits all work against documents/hermes-v0.21.0-audit-report.md (every Tier-1 item closed or consciously deferred), validates subagent-created memories (dedupe/retire redundant ones), runs a fresh-eyes adversarial audit agent over the full branch diff, confirms build + full ScarfCore tests + check-hermes-tables green, updates Hermes Version Compatibility Target + wiki/Hermes-Version-Compatibility.md, writes decisions/hermes-v0-21-compatibility-decisions, removes the ~/.hermes/hermes-agent-v0.21.0-audit worktree, then hands off to scarf-release-prep for v2.23.0 (merge pending Alan's review).

## Plan



## Artifacts



