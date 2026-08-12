---
id: t-bfd15aef
title: Reliable connect-time Hermes version read (persist + single cached probe) — enabler for any floor/nudge
status: done
added: 2026-07-14
---

## Description

Blast-radius investigation finding (2026-07-14). Hermes version detection is today a best-effort side-probe: HermesCapabilitiesStore runs `hermes --version` once per store-init, Task.detached, 10s timeout, NOT persisted, any failure → .empty → all capability flags false (HermesCapabilities.swift:699-751). The ACP connect handshake carries NO version (protocolVersion:1 only, ACPClient.swift:209). There are ≥4 independent uncached --version probes (ProjectTemplateInstaller:240, FleetApplyExecutor:172, RemoteRestoreService:168, HealthViewModel uses `hermes version`). Today this is SAFE because unknown=hide-features (fail-safe). But it's (a) inefficient (repeated probes) and (b) the blocking prerequisite for ANY hard version floor — a fail-dangerous connect-block on an unreliable/nil-prone probe would falsely block working hosts. FIX: one cached, persisted, connect-time version read shared by the capability store and all probe sites; surface a reliable semver early. Independent value (perf + consistency) even if no floor is ever adopted. Foundational for t-c1ed7f7c's floor option. Risk: MED (touches connect path + capability store).

## Plan



## Artifacts



