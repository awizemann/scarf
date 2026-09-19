---
title: Unguarded-write seam: the primitive is named, and a scan test keeps it honest
type: note
permalink: scarf/conventions/unguarded-write-seam-the-primitive-is-named-and-a-scan-test
tags: [writes, guards, testing, gw-enforcement]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/ServerTransport.swift, scarf/Packages/ScarfCore/Tests/ScarfCoreTests/UnguardedWriteScanTests.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift, scarf/scarf/Core/Services/HermesFileService.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-04
updated: 2026-09-07
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [convention] The transport write primitive is `unguardedWriteFile` (never `writeFile`); the one helper seam that wraps it is `ServerContext.unguardedWriteText` — GW-E2a deleted `HermesFileService.unguardedWriteFile` by converting all five of its callers #writes
- [convention] Every raw write call site carries `// UNGUARDED-WRITE(<G|C|O|R>): <reason>` on the same or preceding line — G guard-internal, C create-only scaffold, O authoritative overwrite, R destroy-shaped RMW. The annotation IS the escape hatch: no allowlist file, no suppression pragma #writes
- [fact] `UnguardedWriteScanTests` (ScarfCoreTests) locates the repo by walking 5 levels up from #filePath and scans four non-test roots — `scarf`, `Scarf iOS`, `Packages/ScarfCore/Sources`, `Packages/ScarfIOS/Sources` — skipping `.build/` and `checkouts/`. Reusable pattern for any whole-repo source scan run from the package tests #testing
- [gotcha] Line-scanning every source with a regex costs ~10s; a cheap `line.contains("writeFile(")` prefilter before the regex takes it to 0.6s #testing
- [constraint] A source-scanning test that greps for a symbol name (e.g. the config-writer parity gate's `\.writeText\(` regexes in HermesFileServiceConfigParityTests) silently goes vacuous when that symbol is renamed — rename its regex literals in the same commit #testing

- [convention] The previous-line annotation only counts when that line IS A COMMENT (GW-F5 / SEC F4). Before that, an INLINE-annotated call laundered its annotation to the very next line's call — two raw writes, one reason #writes
- [convention] Rule 3 (GW-F5): a Foundation write (`.write(`/`createFile(`) on a line that also names a Scarf live-state file in a string literal FAILS the scan — `servers.json`, `projects.json`, `project.json`, `manifest.json`, `miniapp_grants.json`, `session_project_map.json`, `model_presets.json`, `config.yaml`, `auth.json`, `.env`, `MEMORY.md`, `USER.md` (plus their `.bak`/`.corrupt-` spellings). Exempt: the three transports and the three guards. Deliberately narrow — Foundation writes in general are NOT scanned because export/save-panel/temp sites are legitimate and a blanket rule would be noise #writes
- [gotcha] The suite's docstring used to claim it made an unguarded write "impossible to perform silently". It does not, and the claim now names its own holes: WRAPPER LAUNDERING (one annotated helper, N invisible callers — only a reviewer catches it) and Foundation writes outside rule 3's narrow list. `#if` branches are NOT an evasion: a textual scan sees both arms #testing
- [convention] Prove a scan rule bites with a temporary canary file under `scarf/scarf/…` before trusting it — SwiftPM does not compile the Mac app sources, so a canary there fails the SCAN without breaking the build, and is deleted before commit #testing

## Relations
- builds_on [[scarf/architecture/guarded-writes-for-shared-json-mutate-the-graph-one-store]]
- builds_on [[scarf/architecture/guardedtextfile-is-the-one-guard-for-scarf-s-non-json-hand]]
- relates_to [[scarf/architecture/the-transport-writefile-grep-is-not-the-write-surface]]
- precedes [[scarf/decisions/guards-were-applied-per-writer-so-four-shared-files-each]]
