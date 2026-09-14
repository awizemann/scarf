---
id: t-aud28
title: **[t-aud28]** Residual iOS-target build warnings — CLEARED (6 → 0). Completes the zero-warning goal across ALL three build surfaces (macOS app t-aud26, ScarfCore package t-aud29, iOS app t-aud28). (1) `ScarfGoTabRoot`/`SystemTab` `onSoftDisconnect`/`onForget` (137-138): the synthesized memberwise init of `SystemTab` DROPPED `@Sendable` from its closure params, forcing a non-Sendable→`@MainActor @Sendable` conversion at the call site. Fix = mark the closure types `@MainActor @Sendable` through the chain (main-actor-isolated closures, so safe) AND give `SystemTab` an explicit init that preserves `@Sendable` on the params (the memberwise one wouldn't). (2) `ChatView:1388/1399`: captured `var modelOK` in concurrent code → capture it by value in the `MainActor.run` capture list (immutable copy). (3) `ProjectsListView`: removed dead `try`/`do`/`catch` around the detached `loadRegistry()` (non-throwing — returns empty registry on failure, so both `try` and `catch` were unreachable). Verified: clean `scarf mobile` iOS BUILD SUCCEEDED, 0 warnings; all files iOS-only so macOS unaffected.
status: archived
---

## Description



## Plan



## Artifacts



