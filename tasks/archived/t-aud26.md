---
id: t-aud26
title: **[t-aud26]** Residual macOS build warnings — CLEARED (5 → 0). (1) `OAuthKeepaliveCronService.swift` `defaultSchedule`/`defaultPrompt` → `nonisolated static let` (they were `@MainActor`-isolated statics read from the `nonisolated` detached `enable()` closure → implicitly-async cross-actor access, the Swift-6 error-class warning; `jobName` was already `nonisolated` — the author missed these two; immutable `String` constants, so the change is behavior-neutral). (2) `CatalogViewModel.swift:121` dropped the redundant `await` on the non-async `applyLoad`. (3) `RichChatInputBar.swift:502` `_ =` on the fire-and-forget `provider.loadObject` (discarded `NSProgress` intentional). (4) `HealthViewModel.swift:687` `_ = NSWorkspace.shared.open(url)` inside the `MainActor.run` closure (the non-discardable `Bool` was the closure's return → `MainActor.run`'s unused result). (5) `TemplateMarkdown.swift:62` `var lines` → `let lines` (only `i` is mutated). Verified: clean macOS BUILD SUCCEEDED, **0 warnings**. iOS (`scarf mobile`) BUILD SUCCEEDED but surfaces 6 separate iOS-target-only warnings (not in t-aud26's macOS scope, none in files I touched) → split to t-aud28.
status: archived
---

## Description



## Plan



## Artifacts



