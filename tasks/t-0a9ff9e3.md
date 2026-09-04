---
id: t-0a9ff9e3
title: Projects F1: re-audit fix batch — mini-app base anchor, legacy re-mint, consent hardening, main-actor holds
status: done
added: 2026-09-04
priority: urgent
---

## Description

Fix batch F1 for the P8 re-audit findings: (1) HIGH mini-app containment anchor movable (MiniAppAssetResolver.isSymlinkContained re-resolves base at check time); (2) MEDIUM unbounded legacy FNV keychain window — opportunistic re-mint; (3) MEDIUM ImageHostConsentStore UserDefaults poisonable — HMAC via MiniAppGrantSigner key; (4) LOW consentProjectId ""-fallback; (5) LOW indexInRegistryLocked missing expecting:; (6) LOW MiniAppGrantSigner nil/"" fingerprint payload collision; plus perf/a11y: main-actor consent save + grant reads, ImageWidgetView .combine flattening, facet signature ordering, ServerTransport blob key erasure, ForEach id:\.self over agent strings.

## Plan



## Artifacts

All 12 findings fixed. New: ScarfCore PhysicalPath.swift, LegacyKeychainRefMigrator.swift, ProjectsF1HardeningTests.swift. Modified: MiniAppAssetResolver (BaseAnchor + frozen-base containment), MiniAppGrantSigner (fingerprint presence byte in v2 — confirmed unreleased; detached-payload tag API), ImageHostConsentStore (HMAC-tagged records), ProjectStore (expecting: threaded), ServerTransport/SSHTransport (reserved blob key survives apply), ProjectConfigService (opportunistic legacy re-mint), ProjectTemplateUninstaller (PathGuard forwards to PhysicalPath), MiniAppSchemeHandler + ScarfMiniAppBridge (anchor at mount/use), MiniAppLaunchView (off-main save + grant reads, busy/error UI, permission dedupe), ImageWidgetView (nil-root refusal, a11y grouping), ProjectCockpitViewModel (facet signature top-up). Tests: ScarfCore 2149 pass (+15), scarf scheme 713 pass, iOS build succeeds. Memory: 4 notes edited (path-containment convention, keychain binding decision, beacon gate decision, sync-IO convention).

