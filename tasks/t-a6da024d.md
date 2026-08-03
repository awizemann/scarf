---
id: t-a6da024d
title: v0.20 Wave B2 — curator header parse + adopt surface
status: done
added: 2026-08-03
---

## Description

HermesCuratorReport.swift:226: accept both "agent-created skills:" and "curator-managed skills: N total (agent-created=X bundled=Y)" headers + new sentinel "no curator-managed skills"; optionally capture the agent-created/bundled split. Update HermesCuratorParserTests.swift:20,73,106 + add 0.20-format fixtures. Then gated on hasCuratorAdopt: parse unmanaged block in status, add CuratorService adopt/list-unmanaged verbs + minimal UI (unmanaged count + adopt action).

## Plan



## Artifacts



