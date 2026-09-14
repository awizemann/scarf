---
id: t-aud15
title: **[t-aud15]** Cleanup batch — DONE (4 of 5): (1) `CitadelServerTransport` `@unchecked Sendable` docstring added; (2) `MCPServerPresetPickerView` force-unwrap removed (`if !empty, let docsURL = URL(...)` instead of `?? URL(...)!`); (3) deleted dead `loadSkillContent`/`saveSkillContent`/`isValidSkillPath` from `HermesFileService` (zero callers; `SkillsViewModel` owns the live copies); (4) `SSHScriptRunner` `CancelFlag`/`LockedData` `NSLock` → `OSAllocatedUnfairLock` (project lock convention, matches `HermesProfileResolver`). SKIPPED (5) `ModelPickerSheet` service caching — services need `@Environment` serverContext + are accessed in 4 spots; verifier rated re-instantiation negligible, so caching adds risk for ~0 gain. Verified: macOS + iOS BUILD SUCCEEDED, no new warnings.
status: archived
---

## Description



## Plan



## Artifacts



