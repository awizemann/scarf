---
id: t-todo-resume
title: **[todo/misc]** RichChatViewModel (v2.8.1): handle a completion arriving after an auto-resumed session: `RichChatViewModel.swift:1636`.
status: todo
added: 2026-06-13, source: t-aud16
---

## Description

RichChatViewModel TODO(v2.8.1) — handle a completion arriving after an auto-resumed session. Live marker drifted to RichChatViewModel.swift:2044 (was ~1636). Needs a dogfooding pass against a v0.21 host: the ACP adapter replays history including compaction summaries (acp_adapter/server.py:1404-1434); confirm whether an auto-resume lands as a visible ACP event.

## Plan



## Artifacts



