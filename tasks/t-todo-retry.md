---
id: t-todo-retry
title: **[todo/misc]** Wire `/retry` to a slash command / ACP path: `ChatInspectorPane.swift:357`.
status: todo
added: 2026-06-13, source: t-aud16
---

## Description

Wire /retry in ChatInspectorPane.swift:357 (button currently disabled). Verified at Hermes v0.21 (tag v2026.8.31): /retry exists only on the gateway (gateway/slash_commands.py:2645) and is NOT in the ACP command set (acp_adapter/server.py:601-612) — blocked on Hermes exposing retry via ACP. Re-check on each Hermes release audit.

## Plan



## Artifacts



