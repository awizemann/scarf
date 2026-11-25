---
title: ScarfGo chat-open timing labels and the model preflight cache
type: note
permalink: scarf/architecture/scarfgo-chat-open-timing-labels-and-the-model-preflight
tags: [scarfgo, performance, gh150]
source_paths: [scarf/Scarf iOS/Chat/ChatView.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflightCache.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/SessionResume.swift, scarf/Scarf iOS/App/ScarfIOSApp.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/HermesQueryBackend.swift]
source_paths_inferred: false
source_sha: d6fad1d094f9131d4ed3245996ff6ca75a784dcd
created: 2026-11-24
updated: 2026-11-24
reviewed: 2026-11-24
reviewed_by: audit:claude-code (background)
---

gh#150. How to read where a ScarfGo chat open spends its time, and why the model check no longer runs per chat.

## Observations
- [fact] ScarfGo times each awaited chat start/resume step under ScarfMon .sessionLoad as ios.start.* / ios.resume.* (modelPreflight, acpClientStart, newSession, projectResolve, prepareProjectContext, fetchSource, capabilities, sessionLoad, loadSessionHistory); users see them in Settings → Diagnostics → Performance only with Recording mode = Full #scarfmon
- [decision] ModelPreflightCache remembers a positive model-configured verdict per ServerID for the app process; negatives are never cached; cleared on confirmModelPreflight and on forgetting the server; cache hits count as ios.modelPreflight.cacheHit, not as a modelPreflight timing #ios
- [fact] Local baseline 2026-11-24 (simulator over localhost SSH, Hermes v0.21.5): modelPreflight 178 ms via SFTP, acpClientStart ~1 s, newSession ~3.4 s (Hermes's own session/new) #performance
- [gotcha] The Chat tab starts a chat on first appearance, so a check right after connecting runs before the user can enable Full recording; restart the app to capture an uncached preflight #testing


- [decision] A chat reopen looks up source and cwd through one private, lazily opened data service (SessionResume.withSessionLookup), shared by iOS and Mac; the cwd column comes from the preflight's hasSessionsCwdColumn flag, not a separate PRAGMA. Gateway-backed reopen: 5 -> 3 SSH execs before history #performance
- [fact] Reopen baseline 2026-11-24 (simulator, localhost SSH, Hermes v0.21.5): total 4.7 s = session/load 3.4 s (Hermes) + acpClientStart 1.0 s + fetchSource 121 ms + loadSessionHistory 157 ms #performance
- [gotcha] Testing ScarfGo against a throwaway sshd: regenerating its host key makes ScarfGo's pinning refuse the server, and the model preflight then shows "pick a model" instead of a connection error (task t-7e71a22a). Read a ScarfGo public key with `xcrun simctl pbpaste booted`, not from a screenshot #testing

## Relations
- relates_to [[scarf/architecture/scarf-go-i-os-companion-app]]
- relates_to [[scarf/architecture/ios-session-resume-must-fall-back-to-newsession-for-non-acp]]
- relates_to [[scarf/architecture/chat-session-layer-mechanism-map-and-2026-07-13-diagnosis]]
