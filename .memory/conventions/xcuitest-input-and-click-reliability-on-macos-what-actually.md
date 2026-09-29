---
title: XCUITest input and click reliability on macOS: what actually works
type: note
permalink: scarf/conventions/xcuitest-input-and-click-reliability-on-macos-what-actually
tags: [testing, xcuitest, gotcha, a11y, swiftui]
source_paths: [scarf/scarf/Features/Settings/Views/SettingsView.swift, scarf/scarf/Features/Skills/Views/SkillsView.swift]
source_paths_inferred: false
source_sha: 12018c8f8fa9d17404a94138589a6d39f7a61d97
created: 2026-09-08
updated: 2026-09-29
reviewed: 2026-09-27
reviewed_by: audit:claude-code (background)
---

Learned building the P2c config journeys (t-877c6e6f, 2026-09-08). Every item was OBSERVED on Alan's Mac Studio across ~12 full `xcodebuild test` cycles, not inferred — several first presented as product bugs and were not.

The general shape: XCUITest's synthesized events against SwiftUI are lossy under load, so a journey must VERIFY each interaction rather than assume it, and must not idle. `ConfigJourneyUITests` carries the working patterns (`ensureFrontmost`, retried `openSection`, verified `replaceText`).

## Observations
- [gotcha] `typeText` DROPS AND REORDERS characters under load — observed `AntarctUica/Troll`, `Antarctica/Tr` and `Antar9ctica/Troll` writing the same 16-char string, and a provider field that came out as `uitest/` (a fragment of the neighbouring field). Never type-and-assume: read the field back with `waitUntil { field.value as? String == text }` and retry. Keep sentinel strings SHORT — every character is a synthesized event #testing #gotcha
- [gotcha] Type through the APPLICATION (`app.typeKey`/`app.typeText`) after clicking the field, not through the element: element-scoped typing re-resolves and re-focuses per call, and that extra round trip is what raises `Failed to synthesize event: Timed out while synthesizing event`. Select-all then type REPLACES the selection, so drop the separate `.delete` keystroke — it was the specific call observed timing out #testing #gotcha
- [gotcha] XCUITest CANNOT change the selection of a SwiftUI `.pickerStyle(.segmented)` Picker. The segments surface as RadioButtons with correct labels/values, `.click()` reports success, and the binding never moves (tried by label and by index, app confirmed frontmost). A `.accessibilityIdentifier` on the Picker does not reach the AppKit-synthesized segments either. RESOLVED (t-42c56c2f, 2026-09-08): the button-per-tab pattern is now `ScarfTabStrip<Tab: ScarfTabStripTab>` in `scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfComponents.swift`, extracted from `SettingsView.tabStrip` — both `SettingsView` and `SkillsView` render their tab rows through it now, each button carrying `<prefix>.tab.<rawValue>` (`settings.tab.*`, `skills.tab.*`) plus an `.isSelected` accessibility trait. Reach for this component first for any new driveable tab strip rather than a segmented Picker or a fresh copy of the pattern #testing #swiftui #gotcha
- [gotcha] Clicks are dropped silently whenever the app is not frontmost, which happens routinely from the second test onward in one `xcodebuild test` invocation (observed while other agents' UI-test runs shared the Mac — serialize runs first, see the serialization note — but the defence is still worth keeping). Call `activate()` before each interaction phase and RETRY clicks that have an observable outcome — re-clicking an already-selected sidebar row or an open sheet's trigger is a harmless no-op #testing
- [gotcha] Long idle polling KILLS the run: a 60 s `waitForExistence` left the app with no window at all, and later tests in the same invocation then failed to find anything. Keep waits proportionate — a 90 s wait on a known-failing step took the whole suite down with it #testing #gotcha

## Relations
- relates_to [[XCUITest runner gotchas: env vars need TEST_RUNNER_, identifiers propagate, ⌘1 keystrokes get dropped]]
- relates_to [[UI gate: section root identifiers and the Smoke/Full/Live test plans]]
- relates_to [[XCUITest runs must be serialized on one Mac: parallel agents cannot each drive Scarf]]
- relates_to [[Driving Cron and Kanban from XCUITest: what actually works]]


## Reading TEXT out of the tree, and polling a streaming transcript (t-d714835d, 2026-09-08)

Learned building the Live chat journey (`ChatJourneyUITests`). Both items cost a full failing run each and were diagnosed by printing `app.windows.firstMatch.debugDescription` from the failure branch — which is now the first thing to reach for when a query "finds nothing" against a surface a screenshot proves is rendered.

- [gotcha] SwiftUI `Text` publishes its content as the accessibility **VALUE, not the label** — `StaticText … value: PONG`, label empty. A `label CONTAINS "…"` predicate silently matches NOTHING in a transcript, a page header, or any other body copy; the only labels are the composed ones AppKit synthesizes for controls (a chat sidebar row Button's label is "Reply with exactly: PONG, 1 min, 37 sec, 0"). Worse, a long value is TRUNCATED with an ellipsis in the tree ("Reply with exactly…" for a 24-char string), so never predicate on a substring past the first few words — parse the stable prefix instead (the Sessions journey reads only the leading integer of "N sessions · M messages · SIZE"). Text FIELDS are the exception: a TextView/TextField reports its full value, which is what makes `setText`'s read-back work #testing #a11y #gotcha
- [convention] Discriminate a model's ANSWER from the user's echo by the bubble's ROLE, not by excluding the prompt text: `RichMessageBubble` wraps each bubble in a Group whose accessibilityLabel is "You" / "Assistant", so `windows.descendants(.group).matching(label == "Assistant").descendants(.staticText).matching(value CONTAINS token)` is a real assertion. A prompt like "Reply with exactly: PONG" contains its own answer, so any unscoped search passes on the echo and proves nothing ran #testing
- [gotcha] Do NOT poll a streaming surface with a closure that ENUMERATES matches (`allElementsBoundByIndex`): resolving every match against a tree being rebuilt underneath raises "Failed to resolve remote element … (Underlying Error: Interrupted by waiter)", which XCTest records as a FAILURE at the query line and masks the real assertion. Use a lazy `firstMatch` + `waitForExistence`, and spend a long budget as N short chunks (9×10 s for 90 s) so the "one long idle wait leaves the app with no window" rule still holds. Keep the expensive enumeration for the failure branch only #testing #gotcha
- [gotcha] A freshly minted isolated home has NO `state.db`, so `SessionsViewModel.loadImpl` returns at its `guard opened` and `storeStats` stays nil — the Sessions header renders its static tagline instead of "0 sessions · …". A journey that reads a baseline off that header must treat "no stats line" as zero, not as a broken read #testing
- [convention] A Live journey that needs a provider must PROBE before touching the UI — one `hermes -z` with `HERMES_HOME` at the test's own isolated home, bounded (60 s), skipping with the CLI's stderr quoted. Otherwise a credential problem presents as "no reply bubble" 90 s into the run and reads as a product bug. Note the probe itself creates a session in that home, so read any session baseline AFTER it #testing



## Chat-surface findings from the 3.5.0 issue tests (Issues35UITests, 2026-09-29)

- [gotcha] A row with `.accessibilityElement(children: .combine)` over a `.textSelection(.enabled)` Text exposed NO text at all — screenshot showed `ResumeContinuityNoticeRow`, but no element matched `label/value CONTAINS` anywhere in the tree, and with an identifier added its label was empty. Fix: `.accessibilityElement(children: .ignore)` + an explicit `.accessibilityLabel(Text(verbatim: text))` (also what VoiceOver needed). When a query misses something a screenshot proves is rendered, export attachments (`xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`, names in manifest.json) before assuming a product bug #testing #a11y #gotcha
- [gotcha] Badges inside a session row Button (`sessions.row.<id>`, `chat.session.<id>`) lose their own identifier (container rewrite); assert the Branch badge via the row's composed label ("Branch of “Parent”"), which both rows carry #testing
- [convention] Chat journeys that only need `hermes acp` running (resume, /title, history rendering) spend NO tokens: clicking a seeded chat row spawns ACP and loads/creates a session without a provider turn. There is still no fake ACP agent, so a LIVE turn (e.g. the live duration stopwatch) cannot be asserted deterministically; prove history-derived behaviour on seeded `messages` rows instead #testing
- [gotcha] Revert-proofing a slash intercept: ChatViewModel intercepts client-side slash commands in TWO places (no-client branch in `sendText`, and `sendViaACP`'s switch). Sabotaging only one left `/title` on a bound chat working — disable both when checking a test fails on revert #testing
