---
id: t-0fbb1c3c
title: Voice fix F1: iOS dictation — tap starts endless recording; stuck transcribing
status: done
added: 2026-09-18
priority: urgent
---

## Description

From the final audits (t-f8c66377).
1. HIGH, privacy. `Scarf iOS/Chat/ChatView.swift` dictationGesture: `holdBegan()` runs on the sequenced gesture's `.first`, which fires at touch-down. A quick tap, or a VoiceOver double-tap, fails the 0.2 s LongPress, so `.onEnded` never runs and the recording stays on with `dictationHoldStarted` stuck at true. Start recording only once the long press has succeeded (`.second(true, _)`), make every failed or cancelled gesture path reset, and add tests that fail on the old behaviour (extract the gesture decision into testable logic if needed).
2. MEDIUM. `OnDeviceDictation.transcribe` can't be cancelled and has no timeout. The `recognitionTask` handle is dropped, and the `SFSpeechRecognizer` is a local that ARC may release. A callback that never arrives leaves the phase stuck at `.transcribing`, which disables both dictation and Live Voice until the app relaunches. Keep the recognizer and task alive, cancel on `handleViewDisappearing` via withTaskCancellationHandler, and add a bounded timeout that resets to idle with a notice.
Standards: tests that fail when the fix is removed, the real iOS build, a fresh-eyes check.

## Plan



## Artifacts

Commit 87155f87 on feat/voice-f1 (worktree /private/tmp/claude-501/-Users-awizemann-Developer-Scarf/8f7ad21f-5689-4a2d-80cc-46d164b93a99/scratchpad/voice-f1): "fix(ios): stop endless dictation recordings and hung transcription".

Files touched: scarf/Scarf iOS/Chat/ChatView.swift, scarf/Scarf iOSTests/DictationGestureReducerTests.swift (new), scarf/Packages/ScarfIOS/Sources/ScarfIOS/Speech/{OnDeviceDictation,PushToTalkController}.swift, scarf/Packages/ScarfIOS/Tests/ScarfIOSTests/PushToTalkControllerTests.swift.

Bug 1 (endless recording): dictationGesture started a take on the sequenced gesture's `.first` event (fires at touch-down, before the 0.2s long press succeeds). SwiftUI never calls `.onEnded` for a gesture that fails to recognize, so a quick tap / VoiceOver double-tap left the mic on forever. Fixed by gating holdBegan() on `.second(true, _)` only, extracted into a pure `DictationGestureReducer` type (unit-testable without simulating touches).

Bug 2 (stuck transcribing): OnDeviceSpeechTranscriber.transcribe dropped the SFSpeechRecognitionTask handle and didn't retain the recognizer, with no cancellation or timeout — a hung completion handler parked PushToTalkController.phase at .transcribing forever (disabling dictation + Live Voice). Fixed with RecognitionTaskHolder (retains recognizer+task, wired via withTaskCancellationHandler which force-resumes the continuation on cancel) plus a bounded 20s timeout race in PushToTalkController.transcribe(with:url:timeout:) via withThrowingTaskGroup.

Test numbers: ScarfIOS `swift test` 89/89 passed (24 in PushToTalkControllerTests, incl. new hungTranscriptionResetsToIdleWithNoticeAfterTimeout). Real iOS build: xcodebuild -scheme "scarf mobile" -destination "generic/platform=iOS Simulator" -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO → BUILD SUCCEEDED. "Scarf iOSTests" target on booted simulator (iPhone 17 Pro, 83D95064-1CCC-481D-B2DD-1161CC2EF3FA): 50/50 passed in 8 suites, incl. new DictationGestureReducerTests (8 tests).

Revert-proof: reverted DictationGestureReducer.onChanged to the original `.first`-triggers-begin bug and reran on the real simulator — touchDownAloneNeverBeginsATake and quickTapNeverStartsOrReleasesATake failed exactly as expected (action == .begin, shouldRelease == true), other 6 gesture tests still passed. Reverted the timeout race in PushToTalkController.holdReleased() back to a bare `try await transcriber.transcribe(...)` and reran `swift test` — hungTranscriptionResetsToIdleWithNoticeAfterTimeout failed (notice stayed nil instead of .transcriptionFailed). Both fixes then restored and the full verification suite (package tests + real build + simulator tests) rerun clean before committing.

Memory: corrected/extended "Push-to-talk dictation (ScarfIOS)" (scarf/architecture/push-to-talk-dictation-scarfios-on-device-only-privacy) with both gotchas (SequenceGesture .first-fires-at-touch-down semantics; SFSpeechRecognitionTask retain+cancel pattern).

Not moved to done per instructions — leaving for review.

