---
id: t-todo-retry
title: **[todo/misc]** Wire `/retry` to a slash command / ACP path: `ChatInspectorPane.swift:357`.
status: done
added: 2026-06-13, source: t-aud16
---

## Description

Resolved by gh#147 (P2 of 2026-09-29 open-issues plan): the tool inspector's permanently-disabled "Re-run" button was REMOVED rather than wired. Hermes's ACP adapter offers no retry (/retry and /undo are CLI/gateway only, acp_adapter/commands.py _COMMANDS), and a client-side resend would duplicate the turn in Hermes's history. Typed /retry and /undo now show a "not available in Scarf chat yet — use the Hermes CLI" hint and are never sent. Revisit only if Hermes adds retry to the ACP adapter (would need a capability flag, C1).

## Plan



## Artifacts



