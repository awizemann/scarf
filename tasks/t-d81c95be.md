---
id: t-d81c95be
title: P1a Chat stream: stray approval tool rows + working timer (#145)
status: done
added: 2026-09-26
priority: high
---

## Description

A2: Hermes ≥0.21.4 closes permission / edit-approval requests with a tool_call_update for ids perm-check-N / edit-approval-N that never had a tool_call start (acp_adapter/permissions.py:54-64@v2026.9.21, edit_approval.py:199-207@v2026.9.24). Scarf's handleToolCallComplete (RichChatViewModel.swift:2291-2339) appends an empty role:"tool" message. Ignore updates for unknown ids. VERIFY: tool calls left open at turn end now closed with status "failed" (tools.py build_tool_abandoned, events.py flush_open_tool_calls) — no duplicate result rows; session/set_model returns -32603 "Session is busy" mid-turn — confirm Scarf's model chip can't fire mid-turn or handles it. Combined from Phase B #145: replace the frozen 3-dot waiting indicator (RichChatMessageList.swift:159-166,233-251; .symbolEffect(.pulse) never animates plain circles) with a live "Working · 0:12" elapsed timer from currentTurnStart (RichChatViewModel.swift:2617). Mac + iOS parity where the indicator exists.

## Plan



## Artifacts

Commits 6c1e9550, 78f020c8; merged a06dc205. openToolCallIds guard in ScarfCore RichChatViewModel (no flag — at v2026.9.14 the only tool_call_update sender is build_tool_complete for started ids; both new closes floor at v2026.9.21). Busy set_model already reverts + surfaces error; test pins it. New workingSince + WorkingElapsedIndicator (Mac) / AgentThinkingRow clock (iOS), TimelineView-isolated. ChatToolCallUpdateGuardTests (9), ChatModelSwitchBusyTests. Follow-ups: ScarfMiniAppBridge forwards stray closes to mini-apps; consider disabling model badge mid-turn on ≥0.21.4; new strings need catalog extraction.

