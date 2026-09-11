---
id: t-fc76a90d
title: Route GatewayBehaviorViewModel's save through the HermesCLIRunner seam
status: todo
added: 2026-09-10
priority: low
---

## Description

Out-of-phase finding noticed during P22 (t-840a1f4d).

`GatewayBehaviorViewModel.save()` (`scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/GatewayBehaviorViewModel.swift:150-200`) calls `PlatformSetupHelpers.saveForm(context:envPairs:configKV:)` from its own `Task.detached` without passing a `runner`, so unlike the 15 per-platform forms P22 swept it has no `HermesCLIRunner` seam and its `hermes config set` spawns are unobservable to a test. It also builds its own `Task.detached` block rather than adopting the new `PlatformSetupForm` protocol.

Fix: give it a `cliRunner: HermesCLIRunner? = nil` init parameter and pass it through to `saveForm`, and consider adopting `PlatformSetupForm` for the load/save choreography (it already carries the `isLoading`/`isSaving` flags the protocol requires). Add the off-main assertion to `MainActorSpawnDisciplineP22Tests`.

## Plan



## Artifacts



