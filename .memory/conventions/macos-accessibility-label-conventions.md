---
title: macOS Accessibility Label Conventions
type: note
permalink: scarf/conventions/macos-accessibility-label-conventions
tags: [accessibility, voiceover, localization]
source_paths: [scarf/scarf/Features/Servers/Views/AddServerSheet.swift, scarf/scarf/Features/Servers/Views/ManageServersView.swift, scarf/scarf/Features/Projects/Views/ProjectsSidebar.swift, scarf/scarf/Features/Skills/Views/SkillsView.swift]
source_paths_inferred: false
source_sha: c09ee3811bd75bae2d7416178d880f5d5b8c64b6
created: 2026-08-28
updated: 2026-09-02
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

Learned applying these rules across Monitor, Manage, Interact, Projects, Kanban, Cron and Config in the 2026-09 section-audit F8 pass. Per-site detail lives in [[Section-audit remediation 2026-09]].

- [gotcha] A `Button` nested inside another `Button`'s label is FLATTENED by AppKit — the inner control takes no keyboard focus and VoiceOver activation fires the OUTER button's action. Likewise `.onTapGesture` on a row is mouse-only (no button trait, no Full Keyboard Access, nothing to activate). Both are structural fixes, never labelling ones #accessibility
- [convention] A control labelled `Text("")` / `EmptyView()` with its visible name in a sibling `Text` is nameless to VoiceOver and untargetable by Voice Control — pass the real label to the control and add `.labelsHidden()`. And `.help()` is a mouse-hover tooltip, never an accessibility label #accessibility
- [convention] Repeated row actions ("Open", "Remove", "Pin") must carry the row's subject in their label, or Voice Control has nothing sayable to target and VoiceOver cannot tell the rows apart #accessibility
- [decision] Hot paths (per-token streaming, thousands-of-rows lists) get `.combine` / `.contain` with a STATIC label — `.accessibilityLabel(Text(verbatim: expr))` re-evaluates `expr` on every body pass, while `.combine` costs nothing until accessibility asks. Note that `.accessibilityLabel` on a plain container does NOT name a group: it propagates down and overwrites every child's, so pair it with `children: .contain` #accessibility
- [convention] Colour-only state takes a TRAIT when the control is selectable (`.isSelected` on tabs, filter pills) and an `.accessibilityValue` when it is a status readout — not interchangeable. An indefinite `.repeatForever` state animation must additionally gate on `@Environment(\.accessibilityReduceMotion)`, with the spoken form deriving from the same precedence order as the colour so the two cannot disagree. Decorative glyphs and emoji need `.accessibilityHidden(true)` or their Unicode name is announced ahead of the content #accessibility

Coverage: the frontmatter `source_paths` are still the four files from the original 2026-08-28 pass — this note now describes far more of the app than those anchor. F8's anchors, which the rules above were derived from and verified against, are `Features/Settings/Views/Components/SettingsComponents.swift`, `Features/Sessions/Views/SessionsView.swift`, `Features/Kanban/Views/KanbanCardView.swift`, `Features/Logs/Views/LogsView.swift`, `Features/Chat/Views/RichMessageBubble.swift`, `Features/Cron/Views/CronView.swift` and `Features/Projects/Views/ProjectSessionsView.swift` (all under `scarf/scarf/`).

## Relations

- relates_to [[Localization Workflow]]
