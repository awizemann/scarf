---
id: t-a7bbd63d
title: B04 Kanban, bots & profiles: comments decode, stats, complete, acp toolset, routing, export, bot rename
status: done
added: 2026-09-27
priority: high
---

## Description

Wave 1. Findings: S13-F1 (comments never show — lenient ids, per-element decode; events id 0), S13-F2 (stats by_assignee nested), S13-F3 (complete requires result), S03-F3/S13-F4 (kanban opt-in must target acp platform), S13-F5 (routing explainer user_id/bot_profile), S13-F6 (.tgz export name), S13-F7 (default bot rename). Plan: documents/plans/hermes-v0215-blind-reaudit-remediation-plan.md.

## Plan

B04 (worktree Scarf-wt/b04, branch fix/hermes-v0215-blind-b04)
- S13-F1: HermesKanbanTaskDetail decodes comments/events per element (lossy) and assigns stable synthesized ids (Hermes show --json has no id, kanban.py:492-498; lists are append-only, created_at ASC). Fill empty taskId from the task. Blast: Mac inspector + ScarfGo detail sheet (ForEach identity). Tests: real show --json generated with the v0215 venv against a scratch HERMES_HOME.
- S13-F2: HermesKanbanStats.byAssignee -> [String: [String: Int]] decoded leniently (nested at every tag since #17805). Blast: toolbar glance, project widget, ScarfGo. Test with real stats --json.
- S13-F3: new cap hasKanbanEmptyCompletionGate (floor v0.21.4, _gate_empty_completion first at v2026.9.21). Plan marks non-review completes resultRequired; board shows the sheet for every drop to Done that needs a result, sheet copy + disabled Complete when required, VM pre-validates before any unblock step so Blocked/Scheduled never half-move. Stored task.result satisfies the gate. Older hosts unchanged.
- S03-F3/S13-F4: 0.21.5 is the first tag where ACP reads platform_toolsets.acp (session.py:480-489; earlier tags hard-code hermes-acp). New cap flag; chat surfaces target acp on >=0.21.5: detect explicit acp list (authoritative) else top-level toolsets; enable inserts kanban into an existing acp list or writes acp: [hermes-acp, kanban] (verified with the tag venv to keep defaults exactly). Pre-0.21.5 behaviour unchanged (report the pre-0.21.5 truth).
- S13-F5: specificity adds +16 for user_id; isAcceptedByHermes rejects empty user_id; explainer covers bot_profile scope.
- S13-F6: HermesProfileArchive normalises .tgz to .tar.gz (profiles.py:2120, archive_safe.py:35).
- S13-F7: default bot rename = display name (free text, <=64), keep selection on default.
Memory/wiki: kanban notes (toolset gating, show json), profile routing, profile export.

## Artifacts

Merged into fix/hermes-v0215-blind as f7de530c (incl. 3d224452 hermetic tests, 1c444874 per-band kanban onboarding: below 0.21.5 rich chat can never get kanban → "needs 0.21.5" with no Enable). Integration ScarfCore build + Mac build-for-testing OK after merge. App-hosted suites deferred to B10 (console locked) — list in plan.

