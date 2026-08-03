---
title: ScarfGo iOS Companion App
type: note
permalink: scarf/architecture/scarf-go-i-os-companion-app
tags: [ios, scarfgo, ssh]
source_paths: [README.md, scarf/scarf.xcodeproj/project.pbxproj, scarf/Packages/ScarfDesign, scarf/Packages/ScarfIOS]
source_sha: 8da06bf74aa0b22581939e623f70e5dc0af37ff6
created: 2026-05-29
updated: 2026-06-25
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---

## Observations
- [structure] ScarfGo is a separate iOS target (`scarf mobile`) in the same Xcode project. Both `scarf` (Mac) and `scarf mobile` import the shared `ScarfDesign` and `ScarfCore` Swift packages under `scarf/Packages/`. #targets
- [design] ScarfGo uses pure-Swift SSH via Citadel — no `ssh` binary on iOS. Generates Ed25519 keypair on device; private key stored in iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, excluded from iCloud sync. #security
- [scope] Feature surface: multi-server, project-scoped chat, session resume, memory editor, cron list, skills tree, settings (read-only). All sessions are scoped to a project via the same Scarf-managed AGENTS.md block the Mac app writes. #features
- [profiles] Profile switching (#120, Design B): ScarfGo switches WHICH Hermes profile it views per-server WITHOUT mutating the host's `active_profile` (Mac app/terminal undisturbed). File layer scopes via `IOSServerConfig.remoteHome` → `HermesPathSet`; process layer (chat ACP + every hermes CLI) prepends `HERMES_HOME=<root>/profiles/<name>` via `HermesProfileScope.hermesHomeShellAssignment` in `CitadelServerTransport.asyncRunProcess`/`ACPClient+iOS`. Selection lives in `ScarfGoCoordinator.selectedProfile` (persisted per-server via `IOSProfileSelectionStore`); `ScarfGoTabRoot` rebuilds the tab tree (`.id`) on switch and `ChatController.deinit` tears down the old ACP session. `ProfilesView` is now a switcher (was read-only). Create/rename/delete/import-export stay Mac-only. #profiles #ios
- [distribution] Public TestFlight: https://testflight.apple.com/join/qCrRpcTz . Requires iOS 18.0+. #distribution
- [constraint] iOS Dynamic Type clamped at scene root in `ScarfIOSApp.swift`: `.dynamicTypeSize(.xSmall ... .accessibility2)`. iOS adopts native `.navigationTitle` + `.large` instead of `ScarfPageHeader` on tab roots. #accessibility

## Relations
- relates_to [[iOS Platform Rules]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
- shares_with [[Scarf Design System (ScarfDesign)]]
