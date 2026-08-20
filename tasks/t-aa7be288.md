---
id: t-aa7be288
title: R2 [iOS]: App Store compliance — FileTimestamp manifest + export-compliance answer
status: todo
added: 2026-08-20
priority: high
---

## Description

(a) Add NSPrivacyAccessedAPICategoryFileTimestamp with reason C617.1 to scarf/Scarf iOS/PrivacyInfo.xcprivacy — MetricKitSubscriber.swift:83,148 uses contentModificationDate and linked ScarfCore uses .modificationDate (SSHTransport.swift:126, LocalTransport.swift:135); current manifest declares only UserDefaults CA92.1 → ITMS-91053 rejection risk for build 61. (b) Decide ITSAppUsesNonExemptEncryption (project.pbxproj:539,583 currently YES = obliges ERN/CCATS docs each submission; standard-crypto SSH client usually qualifies for the exemption → NO). Evidence: documents/release-audit-v2.19.2-to-main-2026-08-20.md findings 2-3.

## Plan



## Artifacts



