---
title: macOS Accessibility Label Conventions
type: note
permalink: scarf/conventions/macos-accessibility-label-conventions
tags: [accessibility, voiceover, localization]
source_paths: [scarf/scarf/Features/Servers/Views/AddServerSheet.swift, scarf/scarf/Features/Servers/Views/ManageServersView.swift, scarf/scarf/Features/Projects/Views/ProjectsSidebar.swift, scarf/scarf/Features/Skills/Views/SkillsView.swift]
source_paths_inferred: false
source_sha: 20f286c14389245de47c0c93a461d7bcc3a002d6
created: 2026-08-28
updated: 2026-08-28
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

Established during the 2026-08-28 accessibility pass driven by the Walkabout macOS shakedown (W19/W22). Form fields and list rows in the macOS target now carry .accessibilityLabel; follow these rules when adding UI.

## Observations
- [convention] Every macOS TextField whose visible label is a sibling Text needs .accessibilityLabel matching the visible label exactly (Voice Control resolves spoken names against it) #accessibility
- [convention] List rows use .accessibilityElement(children: .combine) on static content with a name-first, state-after label helper; interactive controls stay OUTSIDE the combined group so they remain reachable #voiceover
- [gotcha] An explicit .accessibilityLabel on a combined group REPLACES the combined text — any visible content omitted from the label becomes unreachable to VoiceOver (hubRow description regression, caught in P4 audit) #accessibility
- [gotcha] .accessibilityLabel(someStringVariable) binds the StringProtocol overload and is never extracted/localized — compose helper fragments with String(localized:); call-site interpolated literals extract fine as %@ keys #i18n
- [gotcha] Headless xcodebuild never merges new string keys back into Localizable.xcstrings (verified byte-identical); the merge-back only happens on an interactive Xcode IDE build #i18n

## Relations
- relates_to [[Localization Workflow]]
