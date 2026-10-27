---
title: build-detached.sh from an agent worktree needs -skipPackagePluginValidation; agent screen capture is blank
type: note
permalink: scarf/operations/build-detached-sh-from-an-agent-worktree-needs
tags: [build, agents, operations]
source_paths: [scripts/build-detached.sh]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-18
updated: 2026-10-26
---

## Observations
- [gotcha] Running ./scripts/build-detached.sh from a fresh agent worktree fails with 'Validate plug-in SwiftTermBuildInfoPlugin' (the plugin trust is per checkout path); run it as bash -c 'EXTRA_XCODEBUILD_ARGS=(-skipPackagePluginValidation -skipMacroValidation); source ./scripts/build-detached.sh' — the script already splices EXTRA_XCODEBUILD_ARGS into its xcodebuild call #build #agents
- [gotcha] screencapture from an agent's Bash returns an all-black image (no Screen Recording grant), so agents can't screenshot the running dev copy; render SwiftUI views in a throwaway app-hosted test via NSHostingView + cacheDisplay (light and dark appearance) instead, which also renders AppKit-backed Pickers #testing #agents
- [decision] The app's Package.resolved (scarf/scarf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/) is committed since c322e008 (2026-10-26): before that it was gitignored and SwiftTerm is only upToNextMajor from 1.0.0, so fresh clones and worktrees resolved the newest SwiftTerm 1.x and failed at EmbeddedSetupTerminal.swift:194. Bumping a package means committing the updated Package.resolved, or release.sh's clean-tree check stops the release #build #agents
