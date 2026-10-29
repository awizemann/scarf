---
id: t-8d3fafa5
title: P1 step 2: live-chat budget, re-attach, approval mode, SSH single-flight recovery
status: done
added: 2026-10-29
---

## Description

Parent t-f759fabb. See documents/plans/2026-10-29-parallel-chats-p1-build-plan.md step 2.

## Plan



## Artifacts

Commit 52a3552e on feat/parallel-chats. Two audit rounds; second clean. scarfTests 2050 pass serially. Known limits noted in code: ControlMasterKey under-count (aliases/default user/ssh_config Port), Bot Chat + terminal uncounted, re-attach reloads transcript from state.db, brief over-budget window during Stop's bounded cancel. Carried to step 3: dialog Stop can show a contradictory "Not sent" hint if SwiftUI writes the binding before the action; Stop on an autostart chat drops the typed message without a hint.

