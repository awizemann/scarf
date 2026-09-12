---
id: t-f43f0af5
title: Sweep the pre-P30 test tree for subscript-after-count-expect
status: todo
added: 2026-09-10
---

## Description

`scarf/scarfTests/HermesP38SourceSweepTests.noSubscriptFollowsACountExpectation` enforces the test-host stability rule — no bare subscript immediately after a count `#expect`, because `#expect` RECORDS and continues, so a wrong count runs into an out-of-bounds trap and a trap takes the whole `scarfTests` host down (three crash reports in round 3).

P38 scoped it to the 17 round-3/round-4 phase suites (`phaseSuiteFiles` in that file) because a repo-wide run reports roughly 100 pre-existing sites and a sweep that fails on day one is a sweep somebody disables.

This task is the mechanical pass over the rest. To see the list, widen the sweep to the full `testRoots` (delete the `phaseSuiteFiles.contains` guard) and run
`xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:scarfTests/HermesP38SourceSweepTests`.

Highest-density files from that run: `HermesDataServiceBackendTests.swift`, `RemoteSQLiteBackendTests.swift`, `M5FeatureVMTests.swift`, `MarkdownContentViewCoalesceTests.swift`, `HermesCuratorParserTests.swift`, `MessageGroupCoalesceTests.swift`, `HermesV021CronParityTests.swift`, `ScarfMonTests.swift`.

Two legitimate fixes: `guard xs.count == n else { Issue.record(...); return }` before the subscripts, or `let x = try #require(xs.first)` with the test made `throws`. When the pass lands, drop the `phaseSuiteFiles` scoping and the doc paragraph that explains it.

Note the sweep's matcher has known false positives it will also surface (e.g. `#expect(map["k"] != nil)` reads as a subscript on the receiver of an unrelated `.count`); tighten it in the same pass rather than exempting files.

Related: P38 already fixed every `try! #require` in the tree (19 sites, 5 files) and `noTestForceTriesARequire` holds that repo-wide.

## Plan



## Artifacts



