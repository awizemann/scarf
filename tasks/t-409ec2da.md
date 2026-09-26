---
id: t-409ec2da
title: P7b Chat view models: reconnect currency, reconcile cursor, mid-turn send, turn-end cleanup
status: done
added: 2026-09-26
priority: high
---

## Description

Source: documents/plans/2026-09-26-p6-surface-audit-findings-and-fix-plan.md §P7b. (1) HIGH reconnect ladder has no currency check after awaits — Mac ChatViewModel.swift:2268-2310, iOS Scarf iOS/Chat/ChatView.swift ~2756-2815: after client.start()/loadSession, guard !Task.isCancelled and that no newer client/session has been installed, else stop this client and return. (2) HIGH RichChatViewModel.reconcileWithDB (:2730-2770): update oldestLoadedMessageID / hasMoreHistory / earlierHistoryCutoffId consistently with the rows it installs, re-check sessionId before assigning; must not duplicate or drop paged-back history. (3) MED addUserMessage mid-turn (:1965-1981, /steer or queued prompt) clears streaming text/tool calls without finalising → finalise first when working. (4) MED openToolCallIds never cleared at turn end → removeAll() in handlePromptComplete, handleConnectionLost, finalizeOnDisconnect. (5) MED iOS runPrompt (ChatView.swift:2356-2415): add client-identity guard and a CancellationError arm so an old turn's synthesized failure can't land on a fresh chat. (6) LOW stopReason "cancelled" from an intentional cancel (voice barge-in / Stop) must not show a failure banner/bubble — coordinate with P7a which makes cancel actually reach Hermes. (7) LOW workingSince on attach to an already-running turn: seed from the last user message's timestamp in the fetched rows (or omit the clock) rather than Date(); must not reset on poll flicker. (8) LOW move iOS AgentThinkingRow below PermissionWrapper so PermissionWrapper keeps its doc comment. P7a (a parallel agent) owns ACPClient.swift — don't edit it.

## Plan



## Artifacts

Commits eb1bedaf, 059831a8, fd3229c2 (+ merge f19a399b). Reconnect ladders stop themselves if superseded (Mac nil check; iOS identity check); reconcileWithDB keeps paged-back rows and updates cursor/hasMoreHistory; mid-turn send finalises first; openToolCallIds cleared at turn end/disconnect; iOS runPrompt stale-turn guard; deliberate cancel never raises the banner (noteTurnCancelRequested for voice barge-in); workingSince seeded from last user row; stopACP waits (≤2 s) for the cancelled prompt's answer before stop(). Tests ScarfCore 9, Mac 3, iOS 2 (all fail unfixed); ScarfCore 3741 pass. Follow-ups: loadEarlier lacks a post-await session re-check; iOS ladder retrying from .failed replaces the old client without stopping it.

