---
id: t-f43f0af5
title: Sweep the pre-P30 test tree for subscript-after-count-expect
status: archived
added: 2026-09-10
---

## Description

`scarf/scarfTests/HermesP38SourceSweepTests.noSubscriptFollowsACountExpectation` enforces the test-host stability rule — no bare subscript immediately after a count `#expect`, because `#expect` RECORDS and continues, so a wrong count runs into an out-of-bounds trap and a trap takes the whole `scarfTests` host down (three crash reports in round 3).

**Scope history.** P38 scoped it to a hand-kept list of 17 phase suites. P45 replaced that with the phase-NAME pattern (`…P<n>…Tests.swift`) plus a population floor. **P46** widened it again, to the name pattern OR every test file this branch touched (`branchTouchedTestFiles`, pinned against `git diff --name-only 5be08f2e..HEAD -- '*Tests.swift'` by `theBranchScopeMatchesGit`) — because a phase that fixes sites in an ordinarily-named suite writes code no sweep reads. That widening found and fixed seven sites in `M5FeatureVMTests.swift`.

**What is left, counted at P46 (2026-09-11): 90 sites in 35 files, all OUTSIDE the current scope.** By file:

- HermesDataServiceBackendTests.swift: 11
- RemoteSQLiteBackendTests.swift: 9
- MarkdownContentViewCoalesceTests.swift: 5
- MessageGroupCoalesceTests.swift: 5
- HermesCuratorParserTests.swift: 5
- ScarfMonTests.swift: 4
- ProjectRegistryMigrationTests.swift: 3
- HermesV021PeerParityTests.swift: 3
- M0cServicesTests.swift: 3
- HermesV021CronParityTests.swift: 3
- ProjectDoctorServiceTests.swift: 3
- HermesGatewayListServiceTests.swift: 3
- HermesV020ParityWaveC3Tests.swift: 3
- ProjectsViewModelTests.swift: 2
- FleetApplyExecutorTests.swift: 2
- HealthComputerUseSectionTests.swift: 2
- AdjacentRegistryGuardTests.swift: 2
- SkillsHubParserTests.swift: 2
- BotModePhaseAB1Tests.swift: 2
- TranscriptActivitySegmentTests.swift: 2
- ModelPresetServiceTests.swift: 2
- one each: MarkdownContentViewParseTests, RemoteProfileExportPipelineTests, TemplateE2ETests, HermesConfigPatchSafetyTests, CatalogViewModelTests, BotsViewModelTests, HermesPersonalitiesTests, HermesV0211GatewayParityTests, SectionAuditF3CLIContractTests, LocalModelEnumeratorTests, LocalSQLiteBackendWALOpenTests, M6ConfigCronTests, ProjectsG2HardeningTests, HermesPluginCompatTests

To see the live list, drop the `Self.isInSweepScope` guard in `noSubscriptFollowsACountExpectation` and run
`xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:scarfTests/HermesP38SourceSweepTests`.

Three legitimate fixes: `guard xs.count == n else { Issue.record(...); return }` before the subscripts; `let x = try #require(xs.first)` with the test made `throws`; or turn the count expectation itself into `try #require(xs.count == n)`, which stops the test rather than the host and is what P46 used for the seven `M5FeatureVMTests` sites.

When the pass lands, drop the scoping and the doc paragraphs that explain it.

Note the matcher has known false positives it will also surface (e.g. `#expect(map["k"] != nil)` reads as a subscript on the receiver of an unrelated `.count`); tighten it in the same pass rather than exempting files.

**Two sibling rules added in P46**, both scoped the same way and both worth widening in the same pass: `noTestOptionalTriesARequire` (`try? #require` discards the requirement and continues with nil — 9 sites fixed in scope) and `noTestSleepsAFixedHalfSecondOrMore` (a fixed sleep ≥ 500 ms; 2 sites, both allowed with a written reason).

Related: P38 already fixed every `try! #require` in the tree (19 sites, 5 files) and `noTestForceTriesARequire` holds that repo-wide.

## Plan



## Artifacts

Closed by P48 (`t-86311c5a`), commit `3719917d` on `fix/whole-surface-audit-r5`. Round-5 decision 7.

**The scoping is gone.** `isInSweepScope`, `isPhaseSuite`, `branchTouchedTestFiles`, `legacySuiteFiles` and the `theBranchScopeIsFullyScanned` deletion floor are all deleted from `HermesP38SourceSweepTests`, and the doc paragraphs explaining them are replaced with a short history of why the scoping existed. All three rules now run over every `.swift` file under `scarf/scarfTests`, `scarf/Scarf iOSTests` and `scarf/Packages/ScarfCore/Tests`, behind one premise floor (484 files matched; floor 300). **Phases after P48 append nothing** — the addendum's lesson 7 is updated to say so.

**89 subscript-after-count sites fixed in 35 files** (the ticket counted 90; the matcher tightening below accounted for one). Each was fixed the way P46 fixed the `M5FeatureVMTests` seven: the count expectation itself becomes `try #require(xs.count == n)`, which stops the test rather than the host, with the enclosing `@Test func` marked `throws`.

**`try? #require` was already clean** outside the old scope — zero sites repo-wide.

**The matcher was tightened, not the files exempted**, as the ticket asked. The known false positive it names (`#expect(map["k"] != nil)` reading as a subscript on an unrelated `.count` receiver) generalises to: an optional-chained subscript (`map[1]?.first`) is a `Dictionary` read and cannot trap, and the `?` right after the closing bracket is the proof, since an `Array` subscript is non-optional and cannot be chained that way.

**Sleeps:** everything pollable was converted — two FSEvents naps in `HermesFileWatcherAtomicReplaceTests` (600/700 ms) now poll under a 5 s ceiling, `KeychainEnvMirrorTests`'s one-second mtime gap is 100 ms (APFS resolves nanoseconds), and the one `GwF4OutcomeMessageChannelTests` auto-clear that actually fires polls for it. Seven sites remain with a written reason each: three assert a NON-event (a failure that must not auto-clear — nothing to poll for), two are watchdogs a healthy run cancels before they elapse, one is a fixture, one a deliberate no-observable window.

Verified: Mac full serial 1284 tests / 180 suites / 0 failures / 118 s; ScarfCore 3038 / 233 / 0.

