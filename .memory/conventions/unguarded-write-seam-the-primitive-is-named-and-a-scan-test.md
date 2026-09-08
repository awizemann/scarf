---
title: Unguarded-write seam: the primitive is named, and a scan test keeps it honest
type: note
permalink: scarf/conventions/unguarded-write-seam-the-primitive-is-named-and-a-scan-test
tags: [writes, guards, testing, gw-enforcement]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/ServerTransport.swift, scarf/Packages/ScarfCore/Tests/ScarfCoreTests/UnguardedWriteScanTests.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift, scarf/scarf/Core/Services/HermesFileService.swift]
source_paths_inferred: false
source_sha: d0bc77bd0c89f2596dcfc69d532f257420f50029
created: 2026-09-04
updated: 2026-09-04
---

## Observations
- [convention] The transport write primitive is `unguardedWriteFile` (never `writeFile`); the one helper seam that wraps it is `ServerContext.unguardedWriteText` — GW-E2a deleted `HermesFileService.unguardedWriteFile` by converting all five of its callers #writes
- [convention] Every raw write call site carries `// UNGUARDED-WRITE(<G|C|O|R>): <reason>` on the same or preceding line — G guard-internal, C create-only scaffold, O authoritative overwrite, R destroy-shaped RMW. The annotation IS the escape hatch: no allowlist file, no suppression pragma #writes
- [fact] `UnguardedWriteScanTests` (ScarfCoreTests) locates the repo by walking 5 levels up from #filePath and scans four non-test roots — `scarf`, `Scarf iOS`, `Packages/ScarfCore/Sources`, `Packages/ScarfIOS/Sources` — skipping `.build/` and `checkouts/`. Reusable pattern for any whole-repo source scan run from the package tests #testing
- [gotcha] Line-scanning every source with a regex costs ~10s; a cheap `line.contains("writeFile(")` prefilter before the regex takes it to 0.6s #testing
- [constraint] A source-scanning test that greps for a symbol name (e.g. the config-writer parity gate's `\.writeText\(` regexes in HermesFileServiceConfigParityTests) silently goes vacuous when that symbol is renamed — rename its regex literals in the same commit #testing
