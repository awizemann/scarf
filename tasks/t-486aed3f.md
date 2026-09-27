---
id: t-486aed3f
title: R18b R15 fixes: duplicate project crash, sessions errors, chat
status: done
added: 2026-09-27
priority: urgent
---

## Description

From R15: T2-F1 (P1) crash from Dictionary(uniqueKeysWithValues:) on duplicate project paths at SessionsViewModel.swift:406-408, IOSDashboardViewModel.swift:129-131, ChatViewModel.swift:2973-2975, RemoteRestoreService.swift:450-452 — use uniquingKeysWith at all sites AND refuse a duplicate normalized path in ProjectsViewModel.addProject and ProjectTemplateInstaller (~406); grep for any other uniqueKeysWithValues fed by user data. T2-F2 failed state.db reads shown as empty on Sessions tab ("No sessions match this filter"), Insights (zeros), Project Sessions ("may have been deleted"); transient SSH failure wipes a loaded Sessions list (SessionsViewModel.swift:382, HermesDataService.swift:2550-2553, InsightsViewModel.swift:158-161, ProjectSessionsViewModel.swift:98,107) — surface errors like the Dashboards do, keep last good data. T2-F3 Dashboard previews drawn from all sessions incl. delegates → untitled listed session shows raw id; fetch previews for listed ids like Insights. T1-F1 Bot Chat CLI turns killed at 300 s (BotConversationViewModel.swift:623) — Hermes's Bot Mode never kills them (tools/bot_mode_dm.py:282): no hard kill for a live turn (or a much longer cap with honest state), keep the DB poll alive. T1-F2 ACPClient.swift:1385 hint names nonexistent `hermes sessions clone`. T1-F3 Hermes's permission timeout closing tool_call_update for perm-check-N is dropped → sheet stays open, later Allow does nothing (ACPMessages.swift:584-602, RichChatViewModel.swift:2680-2704). T1-F4 chat sidebar delete failure is silent (ChatViewModel.swift:3153).

## Plan

R18b plan (worktree Scarf-wt/r18b, branch fix/hermes-v0215-audit-r18b @ 8b311060)

T2-F1 (P1 crash): new ScarfCore helper that maps session→project name from registry + sidecar with first-row-wins on a shared path; use it at SessionsViewModel, ChatViewModel.loadRecentSessions, IOSDashboardViewModel. RemoteRestoreService re-anchor mapping via a static helper using uniquingKeysWith. Refuse a duplicate normalized path in ProjectsViewModel.addProject and ProjectTemplateInstaller (preflight + locked register). Other uniqueKeysWithValues sites checked (directory listings, Doctor ids already deduped, bot ids, static preset keys) — not user-duplicable. Tests: ScarfCore helper + restore re-anchor over two rows at one path + addProject refusal; scarfTests Sessions load + chat sidebar load with a duplicate-path registry and a scratch state.db; ScarfIOS Dashboard load with duplicate registry; installer refusal.
T2-F2: SessionListSnapshot + InsightsSnapshot carry queryError; checked variants for Insights period fetches; SessionsViewModel/InsightsViewModel/ProjectSessionsViewModel keep last good data and expose loadError; banner on Sessions, Insights, Project Sessions (Mac + iOS). Tests: failing-query fixtures.
T2-F3: previews for listed rows only (dashboard/session-list snapshots restrict the preview statement to the listing; iOS Dashboard uses fetchSessionPreviews(sessionIds:)). Test: delegate child with newer user row doesn't push out an untitled listed row's preview.
T1-F1: Bot Chat CLI turn: no 300 s kill — long ceiling (Hermes _run_local_turn has no timeout, tools/bot_mode_dm.py:411-421), honest timeout copy, refresh transcript before stopping the poll on failure. Test the ceiling constant + failure refresh.
T1-F2: hint points at the chat model switcher / new chat. Test.
T1-F3: keep toolCallId on PendingPermission; an unknown-id tool_call_update matching a queued permission resolves it with a "Hermes stopped waiting" hint. Tests.
T1-F4: sidebar total delete failure sets a hint. Test.
Memory: chat-session-layer mechanism map (perm-check), sessions/insights notes, bot mode decisions, projects registry notes.

## Artifacts

Merged as 3c055c7a (5 commits). Agent: full scarfTests 1770 serial green (all app-hosted suites ran), ScarfCore 4041, ScarfIOS 116; duplicate-path regression tests reach the old trap. Follow-ups filed as t-14157321 (Bot Chat Stop control + 3 pre-existing minors).

