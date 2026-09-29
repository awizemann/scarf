---
title: Release-config xcodebuild fails on stale DerivedData; clean build is the check
type: note
permalink: scarf/operations/release-config-xcodebuild-fails-on-stale-deriveddata-clean
tags: [build, release, xcodebuild]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfProjectsMCPKit/ProjectMCPTools.swift]
source_paths_inferred: false
source_sha: ebfef32ea30937a78516be06e7bba5bbf07f0ac3
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

## Observations
- [gotcha] An incremental `xcodebuild -scheme scarf -configuration Release build` can fail with bogus `cannot find type 'ProjectDoctorService' in scope` / `'RegistryLoadResult' is not a member type` errors in ScarfProjectsMCPKit — a stale Release ScarfCore.swiftmodule in DerivedData, not a real regression #build
- [convention] Reproduced on clean `main` with all local changes stashed before blaming a diff; `-configuration Release clean build` succeeds. Always add `clean` when verifying the Release config, and stash-test before treating a Release-only error as yours #build

## Relations
- documents_gotcha_in [[scarf/ops/build-and-release-workflow]]
