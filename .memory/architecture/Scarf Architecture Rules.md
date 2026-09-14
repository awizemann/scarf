---
title: Scarf Architecture Rules
type: note
permalink: scarf/architecture/scarf-architecture-rules
tags: [architecture, rules]
aliases: [Core Engineering Constraints, scarf/architecture/core-engineering-constraints]
source_paths: [scarf/scarf.xcodeproj/project.pbxproj, scarf/Packages/ScarfCore/Package.swift]
source_paths_inferred: false
source_sha: 40e8ab1f137314b4c9199b2bf8ce8addbef95980
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-09-11
reviewed_by: claude-opus-5
---

## Observations
- [pattern] MVVM-F (Model-View-ViewModel-Feature): each feature is a self-contained module under Features/<Name>/{Views,ViewModels} #mvvm-f
- [rule] Features never import sibling features — cross-feature communication only via Core/Services or AppCoordinator #isolation
- [navigation] Single @Observable AppCoordinator owns all navigation state, injected via .environment() at the app root #navigation
- [dependencies] No external Swift package dependencies in core app — uses system SQLite3, Foundation JSON, AttributedString markdown. Exceptions: SwiftTerm (terminal/QR scan), Sparkle (updates); ScarfGo additionally uses Citadel (iOS SSH) #dependencies
- [concurrency] Swift 5 language mode (swift-tools 6.0; strict Swift 6 concurrency deferred). @MainActor is the default isolation; services use nonisolated + async/await. Blocked on replacing `[[String: Any]]` in ACPEvent.availableCommands and ACPToolCallEvent.rawInput with typed payloads #swift6-deferred
- [sandbox] App sandbox is disabled so Scarf can read ~/.hermes/ directly #sandbox
- [data-access] Read-only access to ~/.hermes/state.db (WAL mode) — never write the SQLite DB. Scarf writes only to memory files (MEMORY.md, USER.md, SOUL.md), cron jobs.json, and config.yaml fragments #db #data
- [code-quality] Zero-warning build required; no commented-out code, TODOs, or deferred functionality in PRs; one feature/fix per PR #quality
- [structure] Xcode project uses PBXFileSystemSynchronizedRootGroup — files auto-discovered from disk, no manual project.pbxproj membership edits needed for new files #xcode
- [platform] Build targets: macOS 14.6+ (Sonoma) for Scarf, iOS 18.0+ for ScarfGo, Swift 6 tools, Xcode 16.0+ #platform

## Relations
- implemented_by [[Scarf Project Layout]]
- relates_to [[Scarf Design System (ScarfDesign)]]
