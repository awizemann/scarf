---
id: t-aud25
title: **[t-aud25]** Injectable local Hermes home (test isolation) — DONE; full `swift test` **610/610**, zero real-`~/.hermes` contact. Added an additive per-instance seam to `ServerContext` (ScarfCore): new `public private(set) var localHomeOverride: String?` (production always nil → `.local` resolves the real `~/.hermes` via `HermesPathSet.defaultLocalHome` unchanged) consulted by `paths` only for `.local`, plus a `static func local(home: URL)` factory that **preserves `localID`** (so existing `vm.context.id == ServerContext.local.id` assertions hold) — deliberately per-instance, NOT the process-global `SCARF_HERMES_HOME` env override (which races parallel suites). Migrated 4 coupled tests to temp homes: `ModelPresetServiceDiskTests` (dropped the real-file backup/restore `sandboxed` hack + `.serialized`), `M0cServicesTests.projectDashboardServiceReturnsEmptyRegistryOnMissingFile` (now asserts unconditionally, was skipped on dev machines), `M0dViewModelsTests.richChatViewModelInitsEmpty`, and `RemoteSQLiteBackendTests.openWithDefaultTildeHomeExpands` (un-skipped; temp `$HOME` via a new `LocalSQLite3Transport.homeOverride` that exports `HOME` to the spawned `/bin/sh`, so `~/.hermes` expands to a tmpdir — removed the real-home move/symlink dance). **Plan correction:** the `richChatViewModelInitsEmpty` failure was MIS-DIAGNOSED in the plan — `RichChatViewModel.init` loads NOTHING from disk; it failed because `availableCommands` at init is `[/new, /steer]` (both static in-code fallbacks; `/steer` is unconditionally visible pre-session), so `hasBroaderCommandMenu` is true regardless of `~/.hermes`. Fixed by injecting a temp home (hygiene) AND correcting the stale assertion to check the real invariant (the loaded acp/project/global/quick command arrays are empty). Verified: `swift test` 610/610; macOS + iOS app BUILD SUCCEEDED (additive change, no app breakage). Pre-existing ScarfCore-*package* warnings surfaced by `swift build` (ACPMessages/GatewayConfigWriter/RichChatViewModel) → split to t-aud29.
status: archived
---

## Description



## Plan



## Artifacts



