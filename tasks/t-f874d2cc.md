---
id: t-f874d2cc
title: P1 step 3: row state, per-chat drafts, background approvals, notifications
status: done
added: 2026-10-29
---

## Description

Parent t-f759fabb. See documents/plans/2026-10-29-parallel-chats-p1-build-plan.md step 3.

## Plan



## Artifacts

Commit 47efbd13 on feat/parallel-chats. Two audit rounds; second clean. scarfTests 2080 pass serially. Needs running-app checks: controlActiveState for minimized windows, banners while frontmost, cold-launch click routing, openWindow with two windows on one server, stored OpenWindowAction after its window closes, glyph look + VoiceOver. Needs-answer follows the "Notify when Hermes finishes" toggle (ChatNotificationPolicy.needsAnswerFollowsToggle) — pending Alan's confirmation. Follow-up: held-prompt ordering race (pre-existing) being fixed separately.

