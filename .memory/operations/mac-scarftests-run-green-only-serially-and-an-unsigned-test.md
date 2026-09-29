---
title: Mac scarfTests run green only serially, and an unsigned test host can stall on a keychain prompt
type: note
permalink: scarf/operations/mac-scarftests-run-green-only-serially-and-an-unsigned-test
tags: [testing, xcodebuild, keychain, gotcha]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantSigner.swift, scarf/scarfTests/ProjectTemplateTests.swift, scarf/scarfTests/SpawnDisciplineP43Tests.swift, scarf/Full.xctestplan]
source_paths_inferred: false
source_sha: ebfef32ea30937a78516be06e7bba5bbf07f0ac3
created: 2026-09-18
updated: 2026-09-29
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

Measured 2026-09-18 while making feat/voice pass the Mac suite (t-30667749), with a throwaway worktree of main for comparison. Flags were `-skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO` and each tree had its own DerivedData.

## Observations
- [gotcha] Bare `xcodebuild test -scheme scarf -destination 'platform=macOS'` runs the Full plan (scarfTests + scarfUITests) with Swift Testing's in-process parallelism, and on this machine main fails 50-58 scarfTests in that mode. The failures are main-actor timeouts in ChatViewModelStartLifecycleTests, ScarfMiniAppBridgeTests, BotAgentViewModelTests, SessionDeletedSignalTests, and `SpawnDisciplineP43Tests.onlyReadEndsLeak` (fd delta 45 < 90). The green gate is `-only-testing:scarfTests -parallel-testing-enabled NO`, which ran 1461/1461 on feat/voice in about 8 min. Compare parallel failures against main before blaming a branch #testing
- [gotcha] With CODE_SIGNING_ALLOWED=NO, scarfUITests-Runner never connects ("hung before establishing connection", or a signal kill), identically on main. UI tests need a signed build (scripts/ui-gate.sh) #testing
- [gotcha] A 25-minute 'stalled' Mac test run was a login-keychain access prompt. Tests reach the REAL item `com.scarf.miniapp-grants` / `hmac-key-v1` through `MiniAppGrantSigner.signingKey()`, for example via ProjectTemplateUninstaller -> ProjectLifecycleService.cleanUpAfterRemoval -> MiniAppGrantStore.revokeAll and GwF1RefusalOrderingTests. Each fresh DerivedData is a new ad-hoc code identity, so SecurityAgent prompts and every keychain call in the host blocks on a Security mutex until someone answers. `sample <test-host pid>` shows threads in SecItemCopyMatching / __psynch_mutexwait, and a SecurityAgent process whose start time matches the stall #testing #keychain
- [convention] Run long xcodebuild test runs in the background with output in a file and a stall detector (log size unchanged for 3 min). On a stall, sample the test-host process before killing it. The sample names the blocked test and frame, which a timeout never does #testing

## Workaround when nobody can answer the prompt (t-dd450d3a, 2026-09-18)

- [convention] An unattended agent can't answer the SecurityAgent prompt. Skip the suites that reach the real keychain (all via ProjectConfigKeychain.get / MiniAppGrantSigner.signingKey): GwF1RefusalOrderingTests KeychainEnvMirrorSlugGuardTests ProjectTemplateConfigInstallTests ProjectTemplateInstallerTests ProjectTemplateUninstallTrustBoundaryTests ProjectTemplateUninstallerTests ProjectsE2cGuardedWriterTests ProjectsF6RobustnessTests ProjectsG2SpliceBoundsTests ProjectsS2D2AppTests TemplateKeychainRefTrustTests. `-skip-testing:` takes the SUITE STRUCT name, not the file name (ProjectTemplateTests.swift holds several). In zsh, build the flags as an array: a space-joined string reaches xcodebuild as one "Unknown build action". With these skipped, feat/voice-f2a ran 1395/1395 in about 2 min #testing #keychain



## Fixed 2026-09-18 (t-788e4587, feat/voice-keychain@13e31f6c)

- [fact] `ProjectConfigKeychain` now auto-detects an XCTest host (`ProcessInfo` `XCTestConfigurationFilePath` for xcodebuild-hosted runs, `NSClassFromString("XCTestCase")` as a `swift test` fallback) and routes `set`/`get`/`delete` through a new `InMemoryKeychainStore` instead of `Security.framework` whenever it's true — unconditionally, so every default-arg call site (`ProjectConfigService()`, `ProjectTemplateUninstaller`'s default `keychain` param, and `MiniAppGrantStore(context:)`'s `MiniAppGrantSigner`) becomes hermetic with zero call-site changes. Production is unchanged: a shipped Scarf.app never links XCTest #testing #keychain
- [fact] Verified: `-only-testing:scarfTests -parallel-testing-enabled NO` now runs the full suite (no more skip list) with zero Keychain/SecurityAgent prompts — 1469 tests / 214 suites in ~143s. All eleven previously-skipped suites (GwF1RefusalOrderingTests, KeychainEnvMirrorSlugGuardTests, ProjectTemplateConfigInstallTests, ProjectTemplateInstallerTests, ProjectTemplateUninstallTrustBoundaryTests, ProjectTemplateUninstallerTests, ProjectsE2cGuardedWriterTests, ProjectsF6RobustnessTests, ProjectsG2SpliceBoundsTests, ProjectsS2D2AppTests, TemplateKeychainRefTrustTests) passed. One unrelated pre-existing failure remains (`HermesP38SourceSweepTests.noTestSleepsAFixedHalfSecondOrMore`, flagging `Packages/ScarfIOS/Tests/ScarfIOSTests/PushToTalkControllerTests.swift:119`'s un-allowlisted `Task.sleep(for: .seconds(3_600))` — Live Voice/PushToTalk territory, out of scope here) #testing #keychain
- [gotcha] The obvious seam (route test items to a differently-NAMED real Keychain service via `testServiceSuffix`, as `ProjectConfigKeychain`/`MiniAppGrantSigner` already did) does NOT fix the prompt: it still calls `SecItemAdd`/`SecItemCopyMatching`, which still asks `Security.framework` to check the calling process's ad-hoc code identity. Only a true in-memory substitute (never touching `Security.framework` at all) closes it #testing #keychain #gotcha
- [gotcha] A mint-on-first-use key store (`MiniAppGrantSigner.signingKey()`'s get-absent-mint-set) is check-then-act, not atomic. Fine against the real Keychain (`SecItemAdd` rejects a concurrent duplicate) but a plain in-memory dictionary `set()` silently overwrites, so two unsuffixed signers racing under Swift Testing's default in-process parallelism could mint different keys and leave the loser unable to verify its own tag. Closed with `InMemoryKeychainStore.setIfAbsent` (one lock acquisition) — guarded by `KeychainTestSeamGuardTests.concurrentFirstUseSignersConvergeOnOneKeyUnderRace`, which reliably reproduced the failure 5/5 runs before the fix and passed 5/5 after #testing #keychain #concurrency
- [convention] A guard test suite (`KeychainTestSeamGuardTests` in `Packages/ScarfCore/Tests/ScarfCoreTests/`) asserts `ProjectConfigKeychain()`/`MiniAppGrantSigner()` constructed with NO test parameters resolve to the in-memory seam under XCTest, so a future refactor that breaks the auto-detection fails loudly there instead of stalling scarfTests 20+ minutes into an unattended run #testing #keychain
- [todo] Swept the Mac `scarfTests` target (and its production dependencies) for other real Contacts/Calendar/mic/speech/Apple-Events/location/photos access; none found reachable from scarfTests. Two unreached-by-tests findings worth knowing about, neither fixed: `scarf/Core/Services/ChatNotificationService.swift` calls `UNUserNotificationCenter.requestAuthorization(options:)` (a macOS notification permission prompt, lazily requested on first `postPromptCompleted` call — no scarfTests reference it) and `scarf/Features/Webhooks/Views/WebhooksView.swift`'s `openGatewaySetupInTerminal()` builds an `NSAppleScript` targeting Terminal.app (an Apple Events/Automation TCC prompt on first use — button-triggered only, no scarfTests reference it either). Both are safe today only because nothing exercises them in tests #testing #keychain #tcc



## Relations
- relates_to [[Fast test-iteration commands (swift test vs xcodebuild)]]
- relates_to [[Integrity is not authenticity: agent-writable Scarf sidecars need a Keychain-held MAC]]
- relates_to [[XCUITest runs must be serialized on one Mac: parallel agents cannot each drive Scarf]]


## Test-host "Restarting after unexpected exit" with no crash report (R17, 2026-09-27)

- [gotcha] A scarfTests host that dies with no .ips report and no failure attributed to the test is usually NOT a product crash: unified log (`/usr/bin/log show --start … | grep <host pid>`) showed `[com.apple.dt.xctest] Exiting due to IDE disconnection` → exit(74), after xcodebuild logged `Lost connection to testmanagerd`. The per-user testmanagerd had exited and respawned ~20 s earlier while ANOTHER project's `xcodebuild test` (Herald/Orchestric) ran concurrently. Check `pgrep -f "xcodebuild.* test"` (any project, not only Scarf) before and during a gate run; the gate log's victim test (GatewayAndPluginsVerdictP40c) passed alone and in four full runs #testing #xcodebuild
- [fact] Since R17 the unit-test host (`Analytics.isSyntheticHost`) skips the launch bootstraps that write the real `~/.hermes` (skills, slash commands, env mirror, projects MCP registration); XCUITest app launches still run them #testing


- [gotcha] Shared Mac (2026-09-27): other projects (Herald, Orchestric) run app-hosted `xcodebuild test` on the same machine; run only one at a time. Wait with `pgrep -f "[x]codebuild.* test"` — the brackets matter: `until ! pgrep -f "xcodebuild.* test"` matches its own shell command line and never exits. When the console is locked (`ioreg -n Root -d1 -a | grep -A1 IOConsoleLocked` → true), app-hosted tests hang indefinitely: defer them and run ScarfCore/ScarfIOS `swift test` + `build-for-testing` instead. #testing


- [gotcha] Release treats Swift warnings as errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`), Debug doesn't. A gate that only builds/tests Debug can pass while `./scripts/build-detached.sh` (Release) fails — happened 2026-09-28 after the pre-release fixes (isolated Equatable conformance used off-main, a captured weak self in `Task.detached`+`MainActor.run`, unused lets). Every release gate must include one Release build (`./scripts/build-detached.sh` or `-configuration Release build`). #testing #release


- [gotcha] `ChatSessionsR16bMacTests/secondSendDuringAutostartWaitsForTheReplayToDrain()` flakes on main as well as on feature branches, even run alone and serially (2026-09-29, #142 P6: 5 isolated `test-without-building -only-testing` runs each; main@2b1f8da3 4/5 pass, feat/142-environment-hint 3/5; every failure at ChatSessionsR16bMacTests.swift:254 `promptTexts == ["first", "second"]`). Not a branch regression. `SessionDeletedSignalTests/sessionsTabDeleteOfAttachedSessionMidTurnTearsDownChatClient()` passed 5/5 on both trees #testing #flake
