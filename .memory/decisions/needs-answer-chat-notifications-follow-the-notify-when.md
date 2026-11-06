---
title: Needs-answer chat notifications follow the "Notify when Hermes finishes" toggle
type: note
permalink: scarf/decisions/needs-answer-chat-notifications-follow-the-notify-when
source_paths: [scarf/scarf/Core/Services/ChatNotificationService.swift]
source_paths_inferred: false
source_sha: daa40485a10bcf22688d5e4b8f16e43de182a70c
created: 2026-10-30
updated: 2026-10-30
reviewed: 2026-11-01
reviewed_by: audit:claude-code (background)
---

Parallel chats P1 (2026-10-30): Alan confirmed that a background chat's "needs your answer" notification (approval or clarify) obeys the same "Notify when Hermes finishes" setting as finish notifications. With the toggle off, no banner is posted. The chat row's needs-answer badge still shows either way.

## Observations
- [decision] `ChatNotificationPolicy.needsAnswerFollowsToggle = true`; Alan confirmed it, so don't flip it without asking #notifications #parallel-chats
- [ux] The row badge (needsAnswer has the highest row-state priority) is the always-on signal; the banner is opt-in #chat-list
- [howto] Making approvals always notify is a one-line change to that flag #notifications

## Relations
- relates_to [[Hermes ACP multi-session behaviour by version (one process vs one per chat)]]
